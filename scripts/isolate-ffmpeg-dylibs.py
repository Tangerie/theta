#!/usr/bin/env python3
"""Give the bundled FFmpeg dylibs install names that cannot collide with Instagram's own.

Instagram ships its own stripped FFmpeg in `Instagram.app/Frameworks/` — a ~500 KB
libavcodec and a ~96 KB libavutil, loaded at launch. Their install names are exactly
the ones our vendored FFmpeg uses (`@rpath/libavcodec.framework/libavcodec`, …), and
neither set carries an LC_RPATH, so `@rpath` only ever expands through the app's own
`@executable_path/Frameworks`. The result: when we dlopen our libavformat, dyld hands
it Instagram's stripped libavcodec/libavutil instead of ours, and libraries Instagram
doesn't ship (libswresample) can't be found at all — so the dlopen fails and every AV1
reel falls through to "couldn't convert video".

Fix: move each dylib to `<ffmpeg.framework>/dylibs/<name>` and rewrite its own install
name plus its sibling dependencies to `@loader_path/<name>`. Those strings are shorter
than the `@rpath/…` ones they replace, so they are patched in place with no load-command
resizing, and they can never match Instagram's copies in either direction.

Idempotent. Run against a *staged* copy — never against `layout/` in the repo.

Usage: isolate-ffmpeg-dylibs.py <path to ffmpeg.framework>
"""

import os
import re
import shutil
import struct
import sys

FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
MH_MAGIC_64 = 0xFEEDFACF

LC_ID_DYLIB = 0x0D
LC_LOAD_DYLIB = 0x0C
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_REEXPORT_DYLIB = 0x8000001F
LC_LOAD_UPWARD_DYLIB = 0x80000023
DYLIB_COMMANDS = (LC_ID_DYLIB, LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB,
                  LC_REEXPORT_DYLIB, LC_LOAD_UPWARD_DYLIB)

# @rpath/libfoo.framework/libfoo  ->  libfoo
RPATH_FRAMEWORK = re.compile(rb"^@rpath/([A-Za-z0-9_+.-]+)\.framework/\1$")

SUBDIR = "dylibs"


def slice_offsets(data):
    """Byte offsets of every Mach-O in the file (handles fat binaries)."""
    if len(data) < 8:
        raise ValueError("file too short")
    magic, = struct.unpack(">I", data[:4])
    if magic in (FAT_MAGIC, FAT_MAGIC_64):
        wide = magic == FAT_MAGIC_64
        count, = struct.unpack(">I", data[4:8])
        offsets = []
        entry = 32 if wide else 20
        for i in range(count):
            base = 8 + i * entry
            if wide:
                offset, = struct.unpack(">Q", data[base + 8:base + 16])
            else:
                offset, = struct.unpack(">I", data[base + 8:base + 12])
            offsets.append(offset)
        return offsets
    return [0]


def patch_slice(buf, base, rewrite):
    """Rewrite dylib-name strings in one Mach-O slice. Returns list of (old, new)."""
    magic, = struct.unpack_from("<I", buf, base)
    if magic != MH_MAGIC_64:
        raise ValueError("unsupported Mach-O magic 0x%08x (32-bit slice?)" % magic)
    ncmds, = struct.unpack_from("<I", buf, base + 16)
    changed = []
    pos = base + 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", buf, pos)
        if cmdsize == 0:
            raise ValueError("zero-length load command")
        if cmd in DYLIB_COMMANDS:
            stroff, = struct.unpack_from("<I", buf, pos + 8)
            field_start = pos + stroff
            field_end = pos + cmdsize
            old = bytes(buf[field_start:field_end]).split(b"\0")[0]
            new = rewrite(old)
            if new is not None and new != old:
                if len(new) + 1 > field_end - field_start:
                    raise ValueError("replacement %r does not fit in load command" % new)
                buf[field_start:field_end] = new + b"\0" * (field_end - field_start - len(new))
                changed.append((old.decode(), new.decode()))
        pos += cmdsize
    return changed


def rewriter(known):
    def rewrite(old):
        m = RPATH_FRAMEWORK.match(old)
        if not m:
            return None
        name = m.group(1)
        if name.decode() not in known:
            return None
        return b"@loader_path/" + name
    return rewrite


def main(argv):
    if len(argv) != 2:
        sys.stderr.write("usage: %s <path to ffmpeg.framework>\n" % os.path.basename(argv[0]))
        return 2
    root = argv[1].rstrip("/")
    if not os.path.isdir(root):
        sys.stderr.write("error: not a directory: %s\n" % root)
        return 1

    dest = os.path.join(root, SUBDIR)
    # Every libfoo.framework/libfoo we ship, plus anything already moved on an earlier run.
    known = set()
    for entry in sorted(os.listdir(root)):
        if not entry.endswith(".framework"):
            continue
        name = entry[: -len(".framework")]
        if os.path.isfile(os.path.join(root, entry, name)):
            known.add(name)
    if os.path.isdir(dest):
        known.update(n for n in os.listdir(dest) if os.path.isfile(os.path.join(dest, n)))
    if not known:
        sys.stderr.write("error: no framework binaries found under %s\n" % root)
        return 1

    rewrite = rewriter(known)
    os.makedirs(dest, exist_ok=True)
    moved, patched, skipped = [], [], []

    for name in sorted(known):
        target = os.path.join(dest, name)
        source = os.path.join(root, name + ".framework", name)
        if os.path.isfile(source):
            shutil.copy2(source, target)
            os.remove(source)
            moved.append(name)
        elif not os.path.isfile(target):
            sys.stderr.write("error: %s is neither in its framework nor in %s\n" % (name, SUBDIR))
            return 1

        with open(target, "rb") as fh:
            buf = bytearray(fh.read())
        changes = []
        for off in slice_offsets(buf):
            changes += patch_slice(buf, off, rewrite)
        if changes:
            with open(target, "wb") as fh:
                fh.write(buf)
            os.chmod(target, 0o755)
            patched.append(name)
        else:
            skipped.append(name)

    if moved:
        print("[ffmpeg] moved into %s/: %s" % (SUBDIR, ", ".join(moved)))
    if patched:
        print("[ffmpeg] rewrote install names to @loader_path: %s" % ", ".join(patched))
    if skipped:
        print("[ffmpeg] already isolated: %s" % ", ".join(skipped))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
