#!/usr/bin/env bash
# Theta build helper
#   ./build.sh           → rootful .deb
#   ./build.sh rootless  → rootless .deb
#   ./build.sh sideload  → inject into input/Payload → output/Instagram_patched.ipa
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

make_cmd=make
if command -v gmake &>/dev/null; then
	make_cmd=gmake
fi

export COPYFILE_DISABLE=1

MODE="$(echo "${1:-}" | tr '[:upper:]' '[:lower:]')"
# Default = rootful
if [[ -z "$MODE" || "$MODE" == "rootful" ]]; then
	MODE="rootful"
fi

usage() {
	cat <<'EOF'
Usage: ./build.sh [rootful|rootless|sideload]

  (no args) / rootful   Build a rootful jailbreak package
  rootless              Build a rootless jailbreak package
  sideload              Build SIDELOAD=1 dylib and inject into input/Payload

Sideload expects a decrypted Instagram IPA unpacked as:
  input/Payload/Instagram.app/...

Output:
  packages/*.deb                (rootful / rootless)
  output/Instagram_patched.ipa  (sideload)
EOF
}

if [[ "$MODE" == "-h" || "$MODE" == "--help" || "$MODE" == "help" ]]; then
	usage
	exit 0
fi

strip_entitlements() {
	local target="$1"
	[[ -f "$target" ]] || return 0
	/usr/bin/codesign --remove-signature "$target" 2>/dev/null || true
	/usr/bin/codesign -f -s - "$target" 2>/dev/null || true
}

ensure_insert_dylib() {
	local src="$SCRIPT_DIR/tools/insert_dylib.c"
	local bin="$SCRIPT_DIR/tools/insert_dylib"
	if [[ ! -f "$src" ]]; then
		echo "[Build] ERROR: missing $src"
		exit 1
	fi
	if [[ ! -x "$bin" || "$src" -nt "$bin" ]]; then
		echo "[Build] Compiling insert_dylib..."
		cc -O2 -o "$bin" "$src"
	fi
}

stage_substrate_framework() {
	# Copies CydiaSubstrate.framework into $1 (Instagram.app root)
	local app_dir="$1"
	local dest="$app_dir/CydiaSubstrate.framework"
	local extract_py="$SCRIPT_DIR/scripts/extract-substrate-from-deb.py"
	local cached="$SCRIPT_DIR/third_party/CydiaSubstrate.framework"

	copy_fw() {
		local src="$1"
		[[ -d "$src" ]] || return 1
		[[ -f "$src/CydiaSubstrate" || -f "$src/CydiaSubstrate.dylib" ]] || return 1
		rm -rf "$dest"
		mkdir -p "$dest"
		rsync -a "$src/" "$dest/"
		if [[ ! -f "$dest/CydiaSubstrate" && -f "$dest/CydiaSubstrate.dylib" ]]; then
			cp -f "$dest/CydiaSubstrate.dylib" "$dest/CydiaSubstrate"
		fi
		if command -v install_name_tool &>/dev/null; then
			install_name_tool -id "@executable_path/CydiaSubstrate.framework/CydiaSubstrate" "$dest/CydiaSubstrate" 2>/dev/null || true
		fi
		strip_entitlements "$dest/CydiaSubstrate"
		echo "[Build] Staged CydiaSubstrate.framework → $dest"
		return 0
	}

	if [[ -n "${SUBSTRATE_FRAMEWORK_PATH:-}" ]] && copy_fw "$SUBSTRATE_FRAMEWORK_PATH"; then
		return 0
	fi
	if copy_fw "$cached"; then
		return 0
	fi

	# Search nearby IPA unpacks / Sideloadly cache
	local hit
	while IFS= read -r hit; do
		[[ -n "$hit" ]] || continue
		if copy_fw "$(dirname "$hit")"; then
			mkdir -p "$cached"
			rsync -a "$dest/" "$cached/"
			return 0
		fi
	done < <(find "$HOME/Library/Application Support/Sideloadly" "$HOME/Downloads" "$HOME/Desktop" "$SCRIPT_DIR/packages" \
		-path "*/CydiaSubstrate.framework/CydiaSubstrate" -type f 2>/dev/null | head -5)

	if [[ -f "$extract_py" ]]; then
		echo "[Build] Fetching CydiaSubstrate from mobilesubstrate .deb..."
		mkdir -p "$cached"
		if python3 "$extract_py" "$cached"; then
			copy_fw "$cached" && return 0
		fi
	fi

	echo "[Build] ERROR: could not stage CydiaSubstrate.framework"
	echo "[Build] Set SUBSTRATE_FRAMEWORK_PATH or place it at third_party/CydiaSubstrate.framework"
	exit 1
}

build_jailbreak() {
	local label="$1"
	$make_cmd clean
	if [[ "$label" == "rootless" ]]; then
		echo "[Build] Building rootless package..."
		$make_cmd package ROOTLESS=1
	else
		echo "[Build] Building rootful package..."
		$make_cmd package
	fi
	echo "[Build] Done. Packages in ./packages/"
	ls -la packages/*.deb 2>/dev/null || true
}

resolve_app_binary() {
	# Prints: <app_dir>|<binary_basename>
	local payload_dir="$1"
	local app_dir binary_name input_bin plist

	app_dir="$(find "$payload_dir" -maxdepth 1 -type d -name "*.app" | head -1 || true)"
	if [[ -z "${app_dir}" ]]; then
		echo "[Build] ERROR: no .app found under $payload_dir" >&2
		return 1
	fi

	binary_name="$(basename "$app_dir")"
	binary_name="${binary_name%.app}"

	plist="$app_dir/Info.plist"
	if [[ -f "$plist" ]] && command -v /usr/libexec/PlistBuddy &>/dev/null; then
		local exe
		exe="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist" 2>/dev/null || true)"
		if [[ -n "${exe}" ]]; then
			binary_name="$exe"
		fi
	fi

	input_bin="$app_dir/$binary_name"
	if [[ ! -f "$input_bin" ]]; then
		input_bin="$(find "$app_dir" -maxdepth 1 -type f -perm -111 ! -name '.*' | head -1 || true)"
	fi
	if [[ -z "${input_bin}" || ! -f "$input_bin" ]]; then
		echo "[Build] ERROR: could not find main binary inside $(basename "$app_dir")" >&2
		return 1
	fi

	binary_name="$(basename "$input_bin")"
	printf '%s|%s\n' "$app_dir" "$binary_name"
}

build_sideload() {
	local input_payload="$SCRIPT_DIR/input/Payload"
	local output_dir="$SCRIPT_DIR/output"
	local output_payload="$output_dir/Payload"
	local ipa_out="$output_dir/Instagram_patched.ipa"
	local app_dir="" app_name="" binary_name="" out_app="" out_bin="" patched="" dylib_src=""

	if [[ ! -d "$input_payload" ]]; then
		echo "[Build] ERROR: missing input/Payload"
		echo "[Build] Unpack a decrypted Instagram IPA so you have:"
		echo "[Build]   input/Payload/Instagram.app/Instagram"
		exit 1
	fi

	local resolved
	resolved="$(resolve_app_binary "$input_payload")" || exit 1
	app_dir="${resolved%%|*}"
	binary_name="${resolved##*|}"
	app_name="$(basename "$app_dir")"

	echo "[Build] App: $app_name  binary: $binary_name"
	echo "[Build] Building sideload dylib..."
	$make_cmd clean
	$make_cmd package SIDELOAD=1

	dylib_src=""
	for cand in \
		"$SCRIPT_DIR/.theos/obj/Theta.dylib" \
		"$SCRIPT_DIR/.theos/_/Library/MobileSubstrate/DynamicLibraries/Theta.dylib" \
		"$SCRIPT_DIR/.theos/_/usr/lib/TweakInject/Theta.dylib"
	do
		if [[ -f "$cand" ]]; then
			dylib_src="$cand"
			break
		fi
	done
	if [[ -z "${dylib_src}" ]]; then
		echo "[Build] ERROR: Theta.dylib not found after build"
		exit 1
	fi

	ensure_insert_dylib

	echo "[Build] Preparing output/Payload from input/Payload..."
	rm -rf "$output_dir"
	mkdir -p "$output_dir"
	cp -f -R "$input_payload" "$output_payload"

	out_app="$output_payload/$app_name"
	out_bin="$out_app/$binary_name"
	patched="$output_dir/${binary_name}_patched"

	if [[ ! -f "$out_bin" ]]; then
		echo "[Build] ERROR: missing $out_bin"
		exit 1
	fi

	cp -f "$out_bin" "$patched"
	echo "[Build] Injecting @executable_path/Theta.dylib into ${binary_name}..."
	"$SCRIPT_DIR/tools/insert_dylib" "@executable_path/Theta.dylib" "$patched" --all-yes --inplace

	rm -f "$out_bin"
	cp -f "$patched" "$out_bin"
	chmod +x "$out_bin"
	strip_entitlements "$out_bin"

	echo "[Build] Installing Theta.dylib into app root..."
	cp -f "$dylib_src" "$out_app/Theta.dylib"
	if command -v install_name_tool &>/dev/null; then
		install_name_tool -id "@executable_path/Theta.dylib" "$out_app/Theta.dylib" 2>/dev/null || true
		# Point weak Substrate dependency at the bundled framework
		install_name_tool -change \
			"/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate" \
			"@executable_path/CydiaSubstrate.framework/CydiaSubstrate" \
			"$out_app/Theta.dylib" 2>/dev/null || true
		install_name_tool -change \
			"@rpath/CydiaSubstrate.framework/CydiaSubstrate" \
			"@executable_path/CydiaSubstrate.framework/CydiaSubstrate" \
			"$out_app/Theta.dylib" 2>/dev/null || true
	fi
	strip_entitlements "$out_app/Theta.dylib"

	stage_substrate_framework "$out_app"

	# Optional resources / ffmpeg (best-effort)
	if [[ -d "$SCRIPT_DIR/ThetaResources.bundle" ]]; then
		rm -rf "$out_app/ThetaResources.bundle"
		cp -f -R "$SCRIPT_DIR/ThetaResources.bundle" "$out_app/ThetaResources.bundle"
	fi
	local ffmpeg_src="$SCRIPT_DIR/layout/Library/Application Support/ffmpeg.framework"
	if [[ -d "$ffmpeg_src" ]]; then
		echo "[Build] Embedding ffmpeg.framework..."
		rm -rf "$out_app/ffmpeg.framework"
		# Follow symlink if present
		cp -f -R "$ffmpeg_src" "$out_app/ffmpeg.framework"
		# Instagram ships its own stripped libavcodec/libavutil under Frameworks/, with the same
		# @rpath install names ours use. Without this, dyld binds our libavformat to Instagram's
		# copies and the AV1 transcode path never loads. Do NOT "fix" that by deleting the copies
		# under Frameworks/ — they belong to Instagram.
		python3 "$SCRIPT_DIR/scripts/isolate-ffmpeg-dylibs.py" "$out_app/ffmpeg.framework" \
			| sed 's/^/[Build] /'
	fi

	# Housekeeping
	find "$output_payload" -name ".DS_Store" -delete 2>/dev/null || true
	xattr -rc "$output_payload" 2>/dev/null || true

	echo "[Build] Zipping IPA..."
	rm -f "$ipa_out"
	(
		cd "$output_dir"
		zip -9 -r "Instagram_patched.ipa" Payload
	)

	echo "[Build] Sideload IPA ready:"
	echo "         $ipa_out"
	ls -lh "$ipa_out"
}

case "$MODE" in
	rootful)
		build_jailbreak rootful
		;;
	rootless)
		build_jailbreak rootless
		;;
	sideload)
		build_sideload
		;;
	*)
		echo "[Build] Invalid mode: $MODE"
		usage
		exit 1
		;;
esac
