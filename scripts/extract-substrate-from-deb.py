#!/usr/bin/env python3
"""Extract CydiaSubstrate.framework from a mobilesubstrate .deb into dest/."""
import io
import lzma
import os
import shutil
import sys
import tarfile
from pathlib import Path
from typing import Optional, Tuple

DEB_URL = "http://apt.saurik.com/debs/mobilesubstrate_0.9.6301_iphoneos-arm.deb"

MACH_MAGICS = (
    b"\xfe\xed\xfa\xce",  # MH_MAGIC
    b"\xce\xfa\xed\xfe",  # MH_CIGAM
    b"\xfe\xed\xfa\xcf",  # MH_MAGIC_64
    b"\xcf\xfa\xed\xfe",  # MH_CIGAM_64
    b"\xca\xfe\xba\xbe",  # FAT
)


def ar_members(deb_path: Path):
    data = deb_path.read_bytes()
    if not data.startswith(b"!<arch>\n"):
        raise ValueError("not a Unix ar archive")
    off = 8
    while off + 60 <= len(data):
        header = data[off : off + 60]
        name = header[:16].decode("ascii", "ignore").strip().rstrip("/")
        size_str = header[48:58].decode("ascii", "ignore").strip()
        if not size_str.isdigit():
            break
        size = int(size_str)
        off += 60
        payload = data[off : off + size]
        off += size + (size % 2)
        yield name, payload


def decompress_tar_payload(payload: bytes) -> bytes:
    if payload.startswith(b"\xfd7zXZ\x00"):
        return lzma.decompress(payload)
    if payload.startswith(b"\x1f\x8b"):
        import gzip

        return gzip.decompress(payload)
    if payload.startswith(b"\x5d\x00\x00"):
        return lzma.decompress(payload)
    return payload


def open_data_tar(deb_path: Path) -> tarfile.TarFile:
    data_member = None
    for name, payload in ar_members(deb_path):
        if name.startswith("data.tar"):
            data_member = (name, payload)
            break
    if not data_member:
        raise RuntimeError("data.tar* not found in .deb")
    _name, payload = data_member
    raw = decompress_tar_payload(payload)
    return tarfile.open(fileobj=io.BytesIO(raw), mode="r:*")


def is_mach_o(data: bytes) -> bool:
    return len(data) >= 4 and data[:4] in MACH_MAGICS


def read_regular_member(tf: tarfile.TarFile, member: tarfile.TarInfo) -> bytes | None:
    if not member.isreg():
        return None
    extracted = tf.extractfile(member)
    if not extracted:
        return None
    return extracted.read()


def resolve_symlink_target(tf: tarfile.TarFile, linkname: str) -> bytes | None:
    """Resolve deb symlinks (often absolute) to a regular file member in the same tar."""
    if not linkname:
        return None
    target = linkname.strip()
    basename = Path(target).name
    candidates = [
        target,
        target.lstrip("/"),
        "./" + target.lstrip("/"),
        "Library/MobileSubstrate/" + basename,
        "./Library/MobileSubstrate/" + basename,
    ]
    seen = set()
    for cand in candidates:
        if cand in seen:
            continue
        seen.add(cand)
        try:
            m = tf.getmember(cand)
        except KeyError:
            continue
        data = read_regular_member(tf, m)
        if data and is_mach_o(data):
            return data
        if m.issym() or m.islnk():
            nested = resolve_symlink_target(tf, m.linkname)
            if nested:
                return nested
    for member in tf.getmembers():
        if not member.isreg():
            continue
        norm = member.name.lstrip("./")
        if norm.endswith(basename) or basename in norm:
            data = read_regular_member(tf, member)
            if data and is_mach_o(data):
                return data
    return None


def find_substrate_dylib_in_tar(tf: tarfile.TarFile) -> Tuple[Optional[bytes], Optional[str]]:
    best_data = None
    best_name = None
    best_size = 0

    for member in tf.getmembers():
        name = member.name
        lower = name.lower()
        if "substrate" not in lower and "cydia" not in lower:
            continue

        data = None
        if member.isreg():
            data = read_regular_member(tf, member)
        elif member.issym() or member.islnk():
            data = resolve_symlink_target(tf, member.linkname)

        if not data or not is_mach_o(data):
            continue
        if len(data) > best_size:
            best_data = data
            best_name = name
            best_size = len(data)

    if best_data:
        return best_data, best_name or "substrate"
    return None, None


def assemble_framework_from_bytes(dylib_data: bytes, dest_fw: Path, theos_vendor: Path) -> None:
    if dest_fw.exists():
        shutil.rmtree(dest_fw)

    vendor_fw = theos_vendor / "CydiaSubstrate.framework"
    if vendor_fw.is_dir():
        shutil.copytree(vendor_fw, dest_fw)
    else:
        dest_fw.mkdir(parents=True, exist_ok=True)

    binary_dest = dest_fw / "CydiaSubstrate"
    binary_dest.write_bytes(dylib_data)
    os.chmod(binary_dest, 0o755)

    headers_src = theos_vendor / "CydiaSubstrate.framework/Headers"
    if headers_src.is_dir() and not (dest_fw / "Headers").exists():
        shutil.copytree(headers_src, dest_fw / "Headers")


def download_deb(cache_deb: Path) -> None:
    cache_deb.parent.mkdir(parents=True, exist_ok=True)
    if cache_deb.is_file() and cache_deb.stat().st_size > 10000:
        return
    import urllib.request

    print(f"[extract-substrate] Downloading {DEB_URL}", flush=True)
    urllib.request.urlretrieve(DEB_URL, cache_deb)


def main():
    if len(sys.argv) < 2:
        print(f"usage: {sys.argv[0]} <dest-framework-dir> [path-to.deb]", file=sys.stderr)
        sys.exit(2)

    dest = Path(sys.argv[1]).resolve()
    script_dir = Path(__file__).resolve().parent
    repo = script_dir.parent
    theos = Path(os.environ.get("THEOS", Path.home() / "theos"))
    vendor = theos / "vendor/lib"

    if len(sys.argv) >= 3:
        deb_path = Path(sys.argv[2]).resolve()
    else:
        deb_path = repo / "third_party/cache/mobilesubstrate.deb"
        download_deb(deb_path)

    if not deb_path.is_file():
        print(f"[extract-substrate] missing deb: {deb_path}", file=sys.stderr)
        sys.exit(1)

    with open_data_tar(deb_path) as tf:
        dylib_data, src_name = find_substrate_dylib_in_tar(tf)

    if not dylib_data:
        print("[extract-substrate] No Mach-O Substrate binary found inside .deb", file=sys.stderr)
        sys.exit(1)

    assemble_framework_from_bytes(dylib_data, dest, vendor)
    binary = dest / "CydiaSubstrate"
    print(
        f"[extract-substrate] Wrote {dest} ({binary.stat().st_size} bytes from {src_name})",
        flush=True,
    )


if __name__ == "__main__":
    main()
