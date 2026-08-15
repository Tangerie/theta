# Theta

Instagram tweak for jailbreak and sideload. Open Theta from the settings gear on the home feed, or by long-pressing the home tab.

Tested against Instagram **441.0.0**.

## Requirements

- [Theos](https://theos.dev) with `THEOS` set (for example `export THEOS=/opt/theos`)
- Theos `Xcode14.xctoolchain` at `$THEOS/toolchain/Xcode14.xctoolchain`
- Python 3 (used by `scripts/assemble.py` during the build)
- A Mac with Xcode command-line tools

Jailbreak packages also need **Cydia Substrate** on the device (`Depends: mobilesubstrate`). Sideload builds bundle Substrate into the IPA.

## Build

Prefer `./build.sh` from the repo root. Do not set `SIDELOAD` and `ROOTLESS` at the same time.

```sh
./build.sh              # rootful .deb → packages/
./build.sh rootless     # rootless .deb → packages/
./build.sh sideload     # inject into input/Payload → output/Instagram_patched.ipa
```

Equivalent Make invocations:

```sh
make package
make package ROOTLESS=1
make package SIDELOAD=1
```

FFmpeg headers and frameworks live at `layout/Library/Application Support/ffmpeg.framework`. Sideload builds copy that framework into the app when it is present. Reel save still works without FFmpeg via a native AVFoundation fallback.

## Install

### Jailbreak (rootful / rootless)

1. Build with `./build.sh` or `./build.sh rootless`.
2. Copy the `.deb` from `packages/` to the device and install it with Sileo, Zebra, or `dpkg -i`.
   - Rootful: `packages/com.theta.tweak_1.0.0_iphoneos-arm.deb`
   - Rootless: `packages/com.theta.tweak_1.0.0_iphoneos-arm64.deb`
3. Respring if the package manager does not, then open Instagram.

If Theos device install is already configured (`THEOS_DEVICE_IP`), `make install` / `make install ROOTLESS=1` will install and reopen Instagram.

### Sideload

1. Get a **decrypted** Instagram IPA and unpack it so the app binary is at:

   ```
   input/Payload/Instagram.app/Instagram
   ```

   Example:

   ```sh
   unzip Instagram.ipa -d /tmp/ig
   mkdir -p input
   cp -R /tmp/ig/Payload input/
   ```

2. Run `./build.sh sideload`. That compiles `Theta.dylib` with `SIDELOAD=1`, injects it into the Instagram binary, stages `CydiaSubstrate.framework`, and writes `output/Instagram_patched.ipa`.

3. Install that IPA:
   - **Sideloadly / AltStore / SideStore** — open `output/Instagram_patched.ipa` and let the tool re-sign it with your Apple ID.
   - **TrollStore** — install the IPA on-device.

4. Open Instagram. Theta settings use the same gear / home-tab long-press as jailbreak.

If Substrate cannot be found automatically, set `SUBSTRATE_FRAMEWORK_PATH` to a `CydiaSubstrate.framework` directory, or place one at `third_party/CydiaSubstrate.framework`.

## Known issues

| Area | Scope | Status |
| --- | --- | --- |
| **Navigation** (Tab Icon Order, Swipe Between Tabs, Launch Tab, Hide Feed/Explore/Reels/Messages Tab, Messenger Mode) | **Sideload only** | Broken |

Jailbreak Navigation settings are unaffected. Everything else in Theta settings is expected to work on both jailbreak and sideload.

## Layout

```
Source/
  Runtime/          Hook helpers, Substrate loader, sideload shims, entrypoint
  Hooks/
    Behavior/       Ads, stories, confirmations, privacy, live, …
    General/        Date format, external browser, liquid glass
    Media/          Reel tap controls
    Messages/       DM features
    Save/           Media / profile / audio saves
    UI/             Tabs, navigation, settings entry points
    Sideload/       Keychain / app-group fakes
  UI/               Settings, toasts, helpers, lock screen
  Media/            Download UI, AV1 transcoder, DASH
  ProfileAnalyzer/  Follower analytics
Include/            Public headers
scripts/assemble.py Builds TweakCOMPILE.xm (single TU for static hooks)
```
