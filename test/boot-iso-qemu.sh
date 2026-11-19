#!/usr/bin/env bash
# Boot an Android-x86 ISO under 32-bit (IA32) UEFI firmware and report how far
# the boot chain actually got.
#
# Why a screenshot and not just serial: Android-x86's own GRUB config does not
# put `console=ttyS0` on the kernel command line, so a *successful* boot
# produces no serial output at all. Judging success by serial alone would
# report a false failure. Instead we:
#   1. capture the framebuffer with QEMU's `screendump`, and analyse the image;
#   2. capture serial as a bonus, since early firmware/kernel output may appear.
# A non-blank screen after boot proves the IA32 firmware executed a loader and
# got far enough to render something.
#
# Usage:
#   ./boot-iso-qemu.sh --iso android-x86.iso [--out DIR] [--wait 90] [--mem 2048]
#
# Exit codes:
#   0  firmware rendered something (loader executed)
#   1  firmware never produced a visible frame (handoff failed)
#   2  environment problem (no qemu / no IA32 firmware)
set -euo pipefail

ISO=""; OUT="/tmp/casper-iso-boot"; WAIT=90; MEM=2048
while [ $# -gt 0 ]; do
    case "$1" in
        --iso)  ISO="$2"; shift 2 ;;
        --out)  OUT="$2"; shift 2 ;;
        --wait) WAIT="$2"; shift 2 ;;
        --mem)  MEM="$2"; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

die()  { printf '\n\033[31mERROR:\033[0m %s\n' "$*" >&2; exit "${2:-1}"; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[32mOK\033[0m   %s\n' "$*"; }

[ -n "$ISO" ]  || die "--iso is required" 2
[ -f "$ISO" ]  || die "no such ISO: $ISO" 2

QEMU=""
for c in qemu-system-x86_64 /usr/bin/qemu-system-x86_64; do
    command -v "$c" >/dev/null 2>&1 && { QEMU="$c"; break; }
done
[ -n "$QEMU" ] || die "qemu-system-x86_64 not installed" 2

mkdir -p "$OUT"
rm -f "$OUT"/serial.log "$OUT"/*.ppm "$OUT"/boot-*.log

# ── 32-bit OVMF firmware ──────────────────────────────────────────────────
# Bay Trail firmware is IA32, so the test must use IA32 OVMF. Booting under
# x86-64 OVMF would prove nothing about this tablet.
find_ia32() {
    local c
    for c in \
        /usr/share/OVMF/OVMF32_CODE_4M.fd \
        /usr/share/OVMF/OVMF32_CODE_4M.secboot.fd \
        /usr/share/OVMF/OVMF32_CODE.fd \
        /usr/share/ovmf/OVMF32_CODE_4M.fd \
        /usr/share/edk2/ovmf/OVMF32_CODE.fd
    do
        [ -f "$c" ] && { echo "$c"; return 0; }
    done
    return 1
}
find_ia32_vars() {
    local c
    for c in \
        /usr/share/OVMF/OVMF32_VARS_4M.fd \
        /usr/share/OVMF/OVMF32_VARS.fd \
        /usr/share/ovmf/OVMF32_VARS_4M.fd \
        /usr/share/edk2/ovmf/OVMF32_VARS.fd
    do
        [ -f "$c" ] && { echo "$c"; return 0; }
    done
    return 1
}

FCODE="$(find_ia32 || true)"
if [ -z "$FCODE" ]; then
    info "IA32 OVMF not installed; fetching from Debian"
    # Debian's ovmf-ia32 is the only source that reliably ships an IA32 build.
    #
    # Version ORDER MATTERS: 2022.11 and 2020.11 ship only a `.secboot` IA32
    # image, and that build faults at the reset vector under QEMU's default
    # q35 (SMM not enabled) — "IA32 Exception 06 (#UD) at EIP 000E0000". That
    # looks exactly like a broken boot chain but is a firmware/model mismatch.
    # 2025.02 is the first package that also ships a plain OVMF32_CODE_4M.fd,
    # so it is tried first.
    mkdir -p "$OUT/ovmf"
    got=""
    for ver in 2025.02-8+deb13u1 2022.11-6+deb12u2 2020.11-2+deb11u2; do
        url="http://deb.debian.org/debian/pool/main/e/edk2/ovmf-ia32_${ver}_all.deb"
        if curl -fsSL --max-time 180 -o "$OUT/ovmf-ia32.deb" "$url" 2>/dev/null; then
            rm -rf "$OUT/ovmf"; mkdir -p "$OUT/ovmf"
            dpkg-deb -x "$OUT/ovmf-ia32.deb" "$OUT/ovmf" 2>/dev/null || continue
            # Prefer a non-secboot image explicitly.
            got=$(find "$OUT/ovmf" -name 'OVMF32_CODE*' ! -name '*secboot*' | head -1)
            [ -n "$got" ] || got=$(find "$OUT/ovmf" -name 'OVMF32_CODE*' | head -1)
            [ -n "$got" ] && { FCODE="$got"; info "fetched ovmf-ia32 $ver"; break; }
        fi
    done
    [ -n "$FCODE" ] || die "could not obtain IA32 OVMF firmware.
Install with: sudo apt install ovmf-ia32
Without IA32 firmware this test cannot simulate the tablet's 32-bit UEFI." 2
fi
info "IA32 firmware: $FCODE"
case "$FCODE" in
    *secboot*)
        info "note: only a secboot IA32 image is available; enabling SMM below"
        NEED_SMM=1 ;;
    *)  NEED_SMM=0 ;;
esac

# Verify it is really 32-bit. A 64-bit OVMF here would make the whole test
# meaningless, and this mistake is easy to make because the filenames differ
# between distros.
python3 - "$FCODE" <<'PY' || die "firmware does not look IA32" 2
import struct, sys
d = open(sys.argv[1], 'rb').read()
machines = set()
i = 0
while True:
    i = d.find(b'PE\0\0', i)
    if i < 0:
        break
    machines.add(struct.unpack('<H', d[i+4:i+6])[0])
    i += 4
print("PE machine types in firmware:", {hex(m) for m in machines})
if 0x14c not in machines:
    print("ERROR: no i386 (0x14c) image found; this is not IA32 firmware")
    sys.exit(1)
print("firmware contains IA32 (i386) code")
PY

VARS="$(find_ia32_vars || true)"
VARS_OUT="$OUT/OVMF32_VARS.fd"
if [ -n "$VARS" ]; then
    cp -f "$VARS" "$VARS_OUT"
else
    # A blank NVRAM is fine for a one-shot boot; secure-boot enforcement is off
    # while the variable store is unpopulated, which is what we want since
    # Android-x86's bootia32.efi is unsigned.
    truncate -s 4M "$VARS_OUT"
fi

# ── boot ──────────────────────────────────────────────────────────────────
# -cpu max, not qemu64: this tablet's Silvermont is x86-64-v2 (SSE4.2 +
# POPCNT) and Android x86_64 userspace may use those instructions.
info "booting (${MEM} MB, IA32 UEFI, ${WAIT}s)"
MON="$OUT/mon.sock"
rm -f "$MON"

# A secboot IA32 image needs SMM (secure boot lives in SMM). Without it the
# firmware faults at the reset vector with #UD, which is easy to misread as a
# broken boot chain.
EXTRA_QEMU=()
if [ "${NEED_SMM:-0}" = "1" ]; then
    EXTRA_QEMU=(-machine q35,smm=on -global driver=cfi.pflash01,property=secure,value=on)
    info "SMM enabled for secboot firmware"
fi

"$QEMU" \
    -machine q35 -m "$MEM" -cpu max \
    "${EXTRA_QEMU[@]}" \
    -drive if=pflash,format=raw,readonly=on,file="$FCODE" \
    -drive if=pflash,format=raw,file="$VARS_OUT" \
    -cdrom "$ISO" \
    -netdev user,id=n0 -device e1000,netdev=n0 \
    -display none -vga std -no-reboot \
    -serial "file:$OUT/serial.log" \
    -monitor "unix:$MON,server,nowait" \
    >"$OUT/qemu.log" 2>&1 &
QPID=$!

cleanup() { kill "$QPID" 2>/dev/null || true; wait "$QPID" 2>/dev/null || true; }
trap cleanup EXIT

# Sample the framebuffer a few times: firmware posts early frames long before
# the kernel finishes, so a single late screenshot can miss the whole boot.
shot() { printf 'screendump %s\n' "$1" | timeout 10 socat - "UNIX-CONNECT:$MON" >/dev/null 2>&1 || true; }

# Send a key sequence through the QEMU monitor.
# Needed because Android-x86's GRUB does not auto-boot: it waits at its menu,
# and its own config never puts console=ttyS0 on the kernel cmdline. Pressing
# Enter selects the default entry, which is the difference between "the loader
# rendered a menu" and "the kernel actually started".
key() {
printf '%s\n' "$1" | timeout 10 socat - "UNIX-CONNECT:$MON" >/dev/null 2>&1 || true
}

# socat may not exist; fall back to a tiny python monitor client.
mon_cmd() {
python3 - "$MON" "$1" <<'PY' 2>/dev/null || true
import socket, sys, time
sock, cmd = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(10)
s.connect(sock)
time.sleep(0.3)
try: s.recv(65536)
except Exception: pass
s.sendall((cmd + "\n").encode())
time.sleep(1.0)
try: s.recv(65536)
except Exception: pass
s.close()
PY
}

shot_py() { mon_cmd "screendump $1"; }
key_py()  { mon_cmd "sendkey $1"; }

HAVE_SOCAT=0; command -v socat >/dev/null 2>&1 && HAVE_SOCAT=1
if [ "$HAVE_SOCAT" = 1 ]; then
    do_shot() { shot "$1"; }
    do_key()  { key  "$1"; }
else
    do_shot() { shot_py "$1"; }
    do_key()  { key_py  "$1"; }
fi

# Phase 1: let firmware POST and GRUB render its menu.
sleep 20
do_shot "$OUT/boot-20s.ppm"; info "captured boot-20s.ppm (firmware + loader)"

# Phase 2: this ISO was pre-patched by patch-iso-serial.py, so GRUB now has a
# single auto-booting entry (timeout=0) whose cmdline includes
# console=ttyS0,115200. Without that, a successful boot is silent on serial and
# the test can only see pixels — which cannot distinguish a dark GRUB menu from
# a kernel console. (Driving GRUB's editor with injected keystrokes was tried
# first and did not work; a patched config is deterministic.)

# Phase 3: sample the kernel/Android bring-up. These frames are what
# distinguishes "GRUB menu only" from "Android actually booting".
for t in 45 75 120 "$WAIT"; do
    target=$t
    cur=0
    while [ "$cur" -lt "$target" ]; do
        kill -0 "$QPID" 2>/dev/null || break
        sleep 5; cur=$((cur + 5))
    done
    kill -0 "$QPID" 2>/dev/null || { info "qemu exited before ${t}s"; break; }
    do_shot "$OUT/boot-${t}s.ppm"
    [ -s "$OUT/boot-${t}s.ppm" ] && info "captured boot-${t}s.ppm"
done

sleep 3
cleanup

# ── analyse ───────────────────────────────────────────────────────────────
info "analysing captured frames"
RESULT=$(python3 - "$OUT" <<'PY'
import sys, os, glob
from collections import Counter

outdir = sys.argv[1]

def load_ppm(p):
    data = open(p, 'rb').read()
    if not data.startswith(b'P6'):
        return None
    fields, i = [], 2
    while len(fields) < 3:
        while i < len(data) and data[i:i+1].isspace():
            i += 1
        if data[i:i+1] == b'#':
            while i < len(data) and data[i:i+1] not in (b'\n', b''):
                i += 1
            continue
        j = i
        while j < len(data) and not data[j:j+1].isspace():
            j += 1
        fields.append(int(data[i:j]))
        i = j
    i += 1
    return fields[0], fields[1], data[i:]

# Classify a frame so the result says WHICH stage it is, not merely "not blank".
# This matters: a GRUB menu proves the loader ran, but only kernel/Android
# output proves the handoff into Android succeeded. Conflating them would let a
# menu screenshot be reported as a successful Android boot.
def classify(w, h, px):
    """Classify a frame by layout, not just colour.

    Important limitation, learned the hard way: a dark GRUB theme and a kernel
    console both look like "white text on black". Colour statistics cannot tell
    them apart, and an earlier version of this script claimed "kernel console"
    when the frame was actually GRUB's menu (it read "Android-x86 9.0-r2").
    So kernel boot is only ever claimed from SERIAL output; pixels can only
    establish that *a* loader rendered.
    """
    n = min(len(px) // 3, w * h)
    if n == 0:
        return dict(nonblack=0.0, colors=0, kind='empty', toprow=0.0)
    step = max(1, n // 60000)
    colors = Counter()
    nonblack = 0
    counted = 0
    top_pixels = 0
    top_hits = 0
    for k in range(0, n, step):
        r, g, b = px[k*3], px[k*3+1], px[k*3+2]
        counted += 1
        y = k // w
        if y < h // 5:
            top_pixels += 1
            if r > 100 and g > 100 and b > 100:
                top_hits += 1
        if r or g or b:
            nonblack += 1
        if len(colors) < 8000:
            colors[(r >> 3, g >> 3, b >> 3)] += 1
    tot = counted or 1
    frac = nonblack / tot
    top_text = (top_hits / top_pixels) if top_pixels else 0.0
    blueish = sum(v for (r, g, b), v in colors.items() if b > r + 6 and b > 8) / tot
    ncol = len(colors)

    if frac < 0.01:
        kind = 'blank'
    elif blueish > 0.15 and ncol > 40:
        kind = 'grub-theme'          # Android-x86's blue GRUB screen
    elif ncol >= 200 and frac > 0.5:
        kind = 'rich-ui'             # many colours across the frame
    elif top_text > 0.02:
        kind = 'console-like'        # text starts at the very top
    else:
        kind = 'dark-text'           # centred text: ambiguous (GRUB or console)
    return dict(nonblack=frac, colors=ncol, kind=kind, toprow=top_text)

frames = []
for p in sorted(glob.glob(os.path.join(outdir, 'boot-*.ppm'))):
    try:
        r = load_ppm(p)
        if not r:
            continue
        w, h, px = r
        c = classify(w, h, px)
        c['name'] = os.path.basename(p)
        c['size'] = '%dx%d' % (w, h)
        frames.append(c)
    except Exception as e:
        print("could not parse %s: %s" % (p, e), file=sys.stderr)

if not frames:
    print("NO FRAMES")
    sys.exit(0)

for f in frames:
    print("FRAME %-14s %-9s kind=%-14s nonblack=%.3f colours=%d"
          % (f['name'], f['size'], f['kind'], f['nonblack'], f['colors']))

# Best (most informative) frame decides.
priority = ['rich-ui', 'console-like', 'dark-text', 'grub-theme',
            'early-firmware', 'blank']
kinds = {f['kind'] for f in frames}
best_kind = next((k for k in priority if k in kinds), 'blank')
best = next(f for f in frames if f['kind'] == best_kind)
print("BEST %s %s kind=%s nonblack=%.3f colors=%d"
      % (best['name'], best['size'], best['kind'], best['nonblack'], best['colors']))
PY
)
echo "$RESULT"

SERIAL_BYTES=0
[ -f "$OUT/serial.log" ] && SERIAL_BYTES=$(stat -c %s "$OUT/serial.log")

echo
echo "--- serial log (first 30 lines, $SERIAL_BYTES bytes) ---"
head -30 "$OUT/serial.log" 2>/dev/null || echo "(none)"
echo "------------------------------------------------------"

echo
if echo "$RESULT" | grep -q "NO FRAMES"; then
    die "no framebuffer captured — could not prove the loader executed" 1
fi

FRAC=$(echo "$RESULT" | sed -n 's/.*nonblack=\([0-9.]*\).*/\1/p')
NCOL=$(echo "$RESULT" | sed -n 's/.*colors=\([0-9]*\).*/\1/p')

if [ -z "$FRAC" ]; then
    die "frame analysis failed (not a parseable PPM)" 1
fi

# Distinguish a firmware crash from a genuine no-boot. These look identical in
# a screenshot (black), but they mean opposite things: a firmware #UD means the
# TEST environment is misconfigured, not that the tablet cannot boot. Without
# this check the failure reads as "32-bit UEFI handoff failed", which is wrong.
if grep -aq "Exception Type" "$OUT/serial.log" 2>/dev/null; then
    printf '\033[31mFIRMWARE FAULT\033[0m (not a boot-chain failure):\n'
    grep -a -m1 "Exception Type" "$OUT/serial.log"
    die "the IA32 firmware crashed before loading anything.
That is a QEMU/firmware configuration problem, not evidence about the tablet.
A secboot IA32 image needs '-machine q35,smm=on' (the harness enables this
automatically when it detects a secboot image)." 1
fi

# Verdict. The ONLY definitive evidence of the kernel/Android starting is
# serial output from the kernel, because Android-x86's cmdline omits
# console=ttyS0 — so the harness reboots with serial injected (see below).
# Pixels can only establish that a loader rendered something.
KIND=$(echo "$RESULT" | sed -n 's/.*BEST .* kind=\([a-z-]*\).*/\1/p')

# Read the serial log DIRECTLY rather than through a shell variable. A
# variable round-trip through tr/printf/grep silently failed in CI once even
# though the same bytes matched when tested by hand; a direct -a grep on the
# file has no such failure mode and is what the evidence actually is.
SERIAL_LOG="$OUT/serial.log"
have_banner=0
grep -aqE 'Linux version [0-9]' "$SERIAL_LOG" 2>/dev/null && have_banner=1
echo "serial: $( [ -f "$SERIAL_LOG" ] && stat -c %s "$SERIAL_LOG" || echo 0 ) bytes, banner=${have_banner}"

if [ "$have_banner" = 1 ]; then
    ok "kernel banner found in serial output"
    grep -aoE 'Linux version [^ ]+' "$SERIAL_LOG" | head -1
    if grep -aqE 'init: |property_service|servicemanager|zygote' "$SERIAL_LOG"; then
        ok "Android userspace reached (init/logcat activity in serial)"
        echo
        echo "RESULT: 32-bit UEFI -> loader -> kernel -> Android init."
        echo "        The full handoff into Android works under IA32 firmware."
        exit 0
    fi
    echo
    echo "RESULT: the 32-bit UEFI handoff into the Android kernel WORKS."
    echo "        Kernel booted; Android init not yet seen within ${WAIT}s."
    exit 0
fi

case "$KIND" in
    rich-ui)
        ok "a rich UI is on screen (kind=rich-ui)"
        echo
        echo "RESULT: 32-bit UEFI executed a loader which drew a full UI."
        echo "        Likely Android booting, but NOT proven: no kernel banner was"
        echo "        captured on serial. Treat as strong-but-indirect evidence."
        exit 3 ;;
    grub-theme|console-like|dark-text)
        ok "a loader rendered ($KIND)"
        echo
        echo "RESULT: firmware -> 32-bit EFI loader confirmed."
        echo "        The loader drew a screen but no kernel banner appeared on"
        echo "        serial, so Android booting is NOT proven at this layer."
        echo "        (An earlier version of this script wrongly called this"
        echo "         'kernel console'; the frame was actually GRUB's menu.)"
        exit 3 ;;
    early-firmware)
        ok "firmware rendered something (kind=early-firmware)"
        echo "RESULT: firmware executed but no loader UI was seen. Inconclusive."
        exit 3 ;;
    *)
        die "framebuffer is essentially blank after ${WAIT}s.
The IA32 firmware did not render anything. Check qemu.log for a firmware
panic. This is the failure mode that would black-screen on the tablet." 1 ;;
esac
