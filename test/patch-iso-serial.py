#!/usr/bin/env python3
"""Patch an Android-x86 ISO so it auto-boots with serial console enabled.

WHY THIS EXISTS
---------------
Android-x86's GRUB menu waits for a keypress and its kernel command line never
includes console=ttyS0. Two consequences for automated verification:

  1. Nothing boots unless someone presses Enter.
  2. Even when it boots, a *successful* boot is completely silent on serial,
     so a test can only see pixels — and pixels cannot distinguish a dark GRUB
     menu from a kernel console. (An earlier version of our harness made
     exactly that mistake and reported "the kernel booted" from a screenshot
     of the GRUB menu.)

Driving GRUB's editor with injected keystrokes is fragile and did not work.
Overwriting a config file in the ISO is deterministic, so that is what this
does.

HOW
---
The ISO's GRUB config chain is:

    /boot/grub/grub.cfg  ->  source /efi/boot/android.cfg
    /efi/boot/android.cfg -> (at the end) source $d/custom.cfg for each search dir

So the cleanest injection point is /efi/boot/android.cfg itself. We overwrite
it in place with a small self-contained config that boots the kernel directly
with serial enabled. In-place overwrite avoids rewriting 942 MB of system.sfs
and needs no xorriso.

IMPORTANT: this produces a TEST IMAGE only. It auto-boots and does not present
the normal menu. Never flash it to the tablet.

Usage:
    ./patch-iso-serial.py in.iso out.iso
"""
import os
import struct
import sys

BS = 2048


def read_iso(path):
    with open(path, "rb") as f:
        return f.read()


def pvd(data):
    return data[16 * BS:17 * BS]


def read_dir(data, extent, size):
    """Return [(name, extent, size, is_dir, rec_offset)] for an ISO9660 dir."""
    out = []
    start = extent * BS
    chunk = data[start:start + size]
    i = 0
    while i < len(chunk):
        L = chunk[i]
        if L == 0:
            i = (i // BS + 1) * BS
            if i >= len(chunk):
                break
            continue
        rec = chunk[i:i + L]
        ext = struct.unpack("<I", rec[2:6])[0]
        sz = struct.unpack("<I", rec[10:14])[0]
        flags = rec[25]
        nl = rec[32]
        name = rec[33:33 + nl]
        if name not in (b"\x00", b"\x01"):
            out.append((name.decode("ascii", "replace").split(";")[0],
                        ext, sz, bool(flags & 2), start + i))
        i += L
    return out


def find_path(data, parts):
    p = pvd(data)
    ext = struct.unpack("<I", p[156 + 2:156 + 6])[0]
    size = struct.unpack("<I", p[156 + 10:156 + 14])[0]
    entry = None
    for want in parts:
        entry = None
        for name, e, s, isdir, off in read_dir(data, ext, size):
            if name.lower() == want.lower():
                entry = (name, e, s, isdir, off)
                break
        if entry is None:
            return None
        ext, size = entry[1], entry[2]
    return entry


# The replacement config. Written as a GRUB script.
#
# Notes on each choice:
#  - `search --set=root` with a file test is used instead of trusting a
#    variable (kdir) that this script does not set: the ISO is mounted as a
#    CD-ROM, and `search` finds the volume containing /kernel regardless of
#    how the firmware numbered it.
#  - console=ttyS0 + earlycon is the whole point: it makes the kernel talk.
#  - ignore_loglevel ensures messages are not suppressed by loglevel.
#  - androidboot.hardware=android_x86_64 must match the ramdisk's init rc
#    (verified present in the ISO's ramdisk), or init fails early.
#  - vga=788 (1024x768x16) keeps the framebuffer predictable.
NEW_CFG = (
    "# CasperOS test boot config - written by patch-iso-serial.py\n"
    "set timeout=0\n"
    "set default=0\n"
    "\n"
    'menuentry "CasperOS test: Android-x86 with serial console" {\n'
    "    search --no-floppy --set=root --file /kernel\n"
    "    linux /kernel root=/dev/ram0 console=ttyS0,115200 earlycon ignore_loglevel "
    "androidboot.hardware=android_x86_64 androidboot.selinux=permissive "
    "SRC=/ HWACCEL=0 vga=788\n"
    "    initrd /initrd.img\n"
    "}\n"
    "\n"
    'menuentry "CasperOS test: Android-x86 verbose" {\n'
    "    search --no-floppy --set=root --file /kernel\n"
    "    linux /kernel root=/dev/ram0 console=ttyS0,115200 earlycon ignore_loglevel "
    "DEBUG=2 androidboot.hardware=android_x86_64 androidboot.selinux=permissive "
    "SRC=/ HWACCEL=0 vga=788\n"
    "    initrd /initrd.img\n"
    "}\n"
)


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    src, dst = sys.argv[1], sys.argv[2]

    data = bytearray(read_iso(src))

    ent = find_path(data, ["efi", "boot", "android.cfg"])
    if ent is None:
        print("ERROR: /efi/boot/android.cfg not found in ISO", file=sys.stderr)
        return 1
    name, extent, size, is_dir, rec_off = ent
    if is_dir:
        print("ERROR: android.cfg is a directory?", file=sys.stderr)
        return 1

    cap = ((size + BS - 1) // BS) * BS      # bytes available in its extents
    payload = NEW_CFG.encode("ascii")
    if len(payload) > cap:
        print("ERROR: new config is %d bytes but only %d fit in place.\n"
              "Shorten NEW_CFG (the ISO has no free space to grow a file)."
              % (len(payload), cap), file=sys.stderr)
        return 1

    print("android.cfg: extent %d, %d bytes -> %d bytes (capacity %d)"
          % (extent, size, len(payload), cap))

    # Overwrite the file contents and pad the remainder of its extents with NUL.
    off = extent * BS
    data[off:off + cap] = payload + b"\x00" * (cap - len(payload))

    # CRITICAL: the directory record carries the file's real length in BOTH
    # little- and big-endian form (ISO9660 duplicates every multi-byte field so
    # either-endian readers work). If the record still says 3179, GRUB reads
    # our 697 bytes plus 2482 NUL bytes as part of the script. NULs are not
    # valid GRUB syntax, so the config fails to parse and the ISO appears not to
    # boot at all — a very confusing failure.
    rec = rec_off
    struct.pack_into("<I", data, rec + 10, len(payload))
    struct.pack_into(">I", data, rec + 14, len(payload))
    print("directory record size updated at offset %d (LE+BE)" % (rec + 10))

    with open(dst, "wb") as f:
        f.write(data)

    print("wrote", dst, os.path.getsize(dst), "bytes")
    print("NOTE: test image only - it auto-boots and skips the normal menu.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
