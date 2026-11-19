#!/usr/bin/env bash
# Verify an Android-x86 ISO can boot on 32-bit UEFI (the N220's firmware).
#
# Why this exists: the tablet's firmware is IA32-only while the CPU is x86_64.
# Booting therefore requires the kernel to be 64-bit AND to expose the 32-bit
# EFI handover entry point (that is what CONFIG_EFI_MIXED produces). If the
# entry point is absent, no amount of GRUB configuration helps: the firmware
# cannot enter the kernel and the device black-screens.
#
# This check reads the ISO's own files and parses the bzImage boot-protocol
# header directly. It needs no QEMU and no root, so it runs anywhere and gives
# a definitive answer in seconds instead of after a 15-minute boot attempt.
#
# Usage: ./check-iso.sh /path/to/android-x86_64-9.0-r2.iso
# Exit:  0 = compatible, 1 = not compatible, 2 = usage/IO problem
set -euo pipefail

ISO="${1:-}"
[ -n "$ISO" ] || { echo "usage: $0 <android-x86.iso>" >&2; exit 2; }
[ -f "$ISO" ] || { echo "no such file: $ISO" >&2; exit 2; }

echo "=== $ISO"
echo "size: $(stat -c %s "$ISO") bytes"

python3 - "$ISO" <<'PY'
import struct, sys

path = sys.argv[1]
BS = 2048
f = open(path, 'rb')

# ── ISO9660: walk the directory tree ──────────────────────────────────────
def sector(n, count=1):
    f.seek(n * BS)
    return f.read(BS * count)

def read_dir(extent, size):
    data = sector(extent, (size + BS - 1) // BS)
    out, i = [], 0
    while i < len(data):
        L = data[i]
        if L == 0:                      # rest of sector is padding
            i = (i // BS + 1) * BS
            if i >= len(data):
                break
            continue
        rec = data[i:i + L]
        ext = struct.unpack('<I', rec[2:6])[0]
        sz = struct.unpack('<I', rec[10:14])[0]
        flags = rec[25]
        nl = rec[32]
        name = rec[33:33 + nl]
        if name not in (b'\x00', b'\x01'):
            out.append((name.decode('ascii', 'replace').split(';')[0], ext, sz, flags))
        i += L
    return out

pvd = sector(16)
vol = pvd[40:72].decode('ascii', 'replace').strip()
print("volume id:", vol)

def find_root(vd):
    return (struct.unpack('<I', vd[156 + 2:156 + 6])[0],
            struct.unpack('<I', vd[156 + 10:156 + 14])[0])

def joliet_root():
    """Return (ext, size) of the Joliet root, or None.

    xorriso-built images commonly keep the real tree in the Joliet
    supplementary volume descriptor. Reading only the primary ISO9660 tree
    made this script report "no kernel found" on a perfectly good image.
    """
    for n in range(17, 32):
        vd = sector(n)
        if len(vd) < 2048 or vd[0:1] == b'\xff':
            break
        if vd[1:6] != b'CD001':
            break
        if vd[0:1] == b'\x02':          # supplementary volume descriptor
            esc = vd[88:91]
            if esc in (b'%/@', b'%/C', b'%/E'):
                return find_root(vd)
    return None

def try_root(ext, size):
    """Read a root dir and normalise names (Joliet is UCS-2)."""
    out = []
    for name, e, sz, fl in read_dir(ext, size):
        # Joliet stores UTF-16BE; strip NULs and any escaped sequences.
        clean = name.replace('\x00', '')
        out.append((clean, e, sz, fl))
    return out

candidates = []
pe = find_root(pvd)
candidates.append(('iso9660', pe))
jr = joliet_root()
if jr:
    candidates.append(('joliet', jr))

root = []
root_label = None
for label, (ext, size) in candidates:
    try:
        entries = try_root(ext, size)
    except Exception:
        continue
    if entries and len(entries) > len(root):
        root, root_label = entries, label
if not root:
    print("ERROR: could not read any directory tree", file=sys.stderr)
    sys.exit(1)
print("using %s tree (%d entries)" % (root_label, len(root)))

def find_dir(entries, name):
    want = name.lower()
    for n, e, s, fl in entries:
        if n.lower().split(';')[0] == want and fl & 2:
            return e, s
    return None

# ── 1. Does the ISO ship a 32-bit EFI loader? ─────────────────────────────
efi = find_dir(root, 'efi')
have_ia32 = False
have_x64 = False
if efi:
    boot = find_dir(read_dir(*efi), 'boot')
    if boot:
        for n, e, s, fl in read_dir(*boot):
            low = n.lower()
            if low == 'bootia32.efi':
                have_ia32 = True
                print(f"  found bootia32.efi  ({s} bytes)  <- 32-bit UEFI loader")
            elif low == 'bootx64.efi':
                have_x64 = True
                print(f"  found BOOTx64.EFI   ({s} bytes)  <- 64-bit UEFI loader")

# ── 2. Find the kernel and parse its boot header ──────────────────────────
def find_file_deep(entries, want, depth=2):
    """Find a regular file by name, looking a couple of levels down."""
    want = want.lower()
    for n, e, s, fl in entries:
        if n.lower().split(';')[0] == want and not (fl & 2):
            return e, s
    if depth > 0:
        for n, e, s, fl in entries:
            if fl & 2:
                try:
                    sub = try_root(e, s)
                except Exception:
                    continue
                got = find_file_deep(sub, want, depth - 1)
                if got:
                    return got
    return None

kern = find_file_deep(root, 'kernel', depth=3)

if not kern:
    print("ERROR: no kernel found in ISO", file=sys.stderr)
    sys.exit(1)

f.seek(kern[0] * BS)
kdata = f.read(min(kern[1], 1 << 20))

print(f"\nkernel: {kern[1]} bytes")
sig = kdata[0x202:0x206]
if sig != b'HdrS':
    print("ERROR: no x86 boot-protocol header (HdrS) at 0x202", file=sys.stderr)
    sys.exit(1)

bv = kdata[0x206:0x208]
print("boot protocol: %d.%02d" % (bv[1], bv[0]))

# xloadflags (2 bytes at 0x236) is valid for protocol >= 2.12 and is the
# authoritative statement of which entry points the kernel actually provides.
xlf = struct.unpack('<H', kdata[0x236:0x238])[0]
print("xloadflags: 0x%04x" % xlf)

flags = {
    0: "XLF_KERNEL_64            (kernel is 64-bit)",
    1: "XLF_CAN_BE_LOADED_ABOVE_4G",
    2: "XLF_EFI_HANDOVER_32     (32-bit EFI handover entry point)",
    3: "XLF_EFI_HANDOVER_64     (64-bit EFI handover entry point)",
    4: "XLF_EFI_KEXEC",
}
for bit, desc in flags.items():
    print(("  SET    " if (xlf >> bit) & 1 else "  clear  ") + desc)

kv_off = struct.unpack('<H', kdata[0x20e:0x210])[0]
# The kernel_version field is a pointer into the setup area and is empty or
# misleading in many builds, so prefer the version banner actually embedded in
# .rodata and only fall back to the header field.
kv = ''
import re
m = re.search(rb'\b(\d+\.\d+\.\d+[\w.+-]*)\b', kdata)
if m:
    kv = m.group(1).decode('ascii', 'replace')
elif kv_off and kv_off < len(kdata):
    kv = kdata[kv_off:kv_off + 80].split(b'\x00')[0].decode('ascii', 'replace').strip()
print("kernel_version:", kv or '(not reported)')

# ── verdict ───────────────────────────────────────────────────────────────
kernel_64 = bool((xlf >> 0) & 1)
handover_32 = bool((xlf >> 2) & 1)
handover_64 = bool((xlf >> 3) & 1)

print("\n=== VERDICT")
fail = False
if not have_ia32:
    print("FAIL: no bootia32.efi — IA32 firmware cannot load any loader here")
    fail = True
else:
    print("OK:   ISO provides a 32-bit EFI loader")
if not kernel_64:
    print("FAIL: kernel is not 64-bit; Android x86_64 userspace cannot run")
    fail = True
else:
    print("OK:   kernel is 64-bit")
if not (handover_32 and handover_64):
    print("FAIL: kernel lacks the 32-bit EFI handover entry, so EFI_MIXED is not")
    print("      compiled in. IA32 firmware cannot enter this kernel.")
    fail = True
else:
    print("OK:   kernel has BOTH 32-bit and 64-bit EFI handover entries")
    print("      => CONFIG_EFI_MIXED is active; 32-bit UEFI can boot this kernel")

print("\nRESULT:", "INCOMPATIBLE" if fail else "COMPATIBLE with 32-bit UEFI (N220)")
sys.exit(1 if fail else 0)
PY
