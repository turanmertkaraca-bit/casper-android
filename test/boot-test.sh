#!/usr/bin/env bash
# Go/no-go: can 32-bit UEFI firmware boot a 64-bit Android kernel?
#
# This is the experiment that decides whether the whole project is viable.
# It is deliberately cheap: QEMU + 32-bit OVMF + our kernel + an Android
# ramdisk. If the chain works, logcat produces output. If it does not, we have
# learned it in minutes rather than after building a shell and an image.
#
# Usage:
#   ./boot-test.sh --kernel out/artifacts/bzImage-6.12-casper-android \
#                  --ramdisk /path/to/initrd.img \
#                  --out /tmp/boot-test
#
# Success:  exit 0, logcat.txt non-empty, verdict BOOT-OK
# Failure:  exit 1 with the last boot stage it reached named
#
# What this DOES verify:
#   - firmware can execute our 32-bit EFI boot path
#   - a 64-bit kernel with EFI_MIXED enters long mode from IA32 firmware
#   - the ramdisk/init path starts far enough to run logcat
# What it does NOT verify (needs the real tablet):
#   - touchscreen, audio, Wi-Fi, suspend/resume, panel rotation
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KERNEL=""; RAMDISK=""; OUT="/tmp/casper-android-boot"; CMDLINE=""
MEM="2048"; WAIT=180

while [ $# -gt 0 ]; do
    case "$1" in
        --kernel)  KERNEL="$2"; shift 2 ;;
        --ramdisk) RAMDISK="$2"; shift 2 ;;
        --out)     OUT="$2"; shift 2 ;;
        --cmdline) CMDLINE="$2"; shift 2 ;;
        --mem)     MEM="$2"; shift 2 ;;
        --wait)    WAIT="$2"; shift 2 ;;
        -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

die()  { printf '\n\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[32mOK\033[0m   %s\n' "$*"; }

[ -n "$KERNEL" ]  || die "--kernel is required (build it with kernel/build-kernel.sh)"
[ -f "$KERNEL" ]  || die "no such kernel: $KERNEL"
[ -n "$RAMDISK" ] || die "--ramdisk is required (from an unpacked Android boot image)"
[ -f "$RAMDISK" ] || die "no such ramdisk: $RAMDISK"

command -v qemu-system-x86_64 >/dev/null || die "qemu-system-x86_64 not found"

mkdir -p "$OUT"
rm -f "$OUT/serial.log" "$OUT/logcat.txt"

# ── 32-bit OVMF firmware ──────────────────────────────────────────────────
# This is the crux. We must use the IA32 build of OVMF, because that is what
# the tablet's firmware is. Booting under 64-bit OVMF would hide the exact
# failure mode this test exists to catch.
find_ia32_ovmf() {
    local c
    for c in \
        /usr/share/OVMF/OVMF32_CODE_4M.fd \
        /usr/share/OVMF/OVMF32_CODE.fd \
        /usr/share/ovmf/OVMF32_CODE_4M.fd \
        /usr/share/edk2/ovmf/OVMF32_CODE.fd
    do
        [ -f "$c" ] && { echo "$c"; return 0; }
    done
    return 1
}

FCODE="$(find_ia32_ovmf || true)"
if [ -z "$FCODE" ]; then
    info "32-bit OVMF not installed; fetching from Debian"
    # Pinned fallback, same approach as the Linux image's installer test:
    # never depend on a live URL alone during a build.
    for ver in 2022.11-6+deb12u2 2024.02-2; do
        url="http://deb.debian.org/debian/pool/main/e/edk2/ovmf-ia32_${ver}_all.deb"
        if curl -fsSL -o "$OUT/ovmf-ia32.deb" "$url" 2>/dev/null; then
            dpkg-deb -x "$OUT/ovmf-ia32.deb" "$OUT/ovmf"
            FCODE="$(find "$OUT/ovmf" -name 'OVMF32_CODE*.fd' | head -1)"
            [ -n "$FCODE" ] && break
        fi
    done
    [ -n "$FCODE" ] || die "could not obtain 32-bit OVMF firmware.
Install it with: sudo apt install ovmf   (needs the ia32 build)
Without IA32 firmware this test cannot simulate the tablet."
fi
info "IA32 firmware: $FCODE"

# VARS must be writable and non-volatile-per-run
VARS="$OUT/OVMF32_VARS.fd"
for v in /usr/share/OVMF/OVMF32_VARS_4M.fd /usr/share/OVMF/OVMF32_VARS.fd \
         /usr/share/edk2/ovmf/OVMF32_VARS.fd; do
    [ -f "$v" ] && { cp -f "$v" "$VARS"; break; }
done
[ -f "$VARS" ] || truncate -s 4M "$VARS"   # blank NVRAM is fine for a one-shot boot

# Sanity: the firmware must be 32-bit. Catching this here prevents the classic
# "tested under x64 OVMF, boots nowhere on the tablet" outcome.
if command -v file >/dev/null; then
    if file "$FCODE" | grep -qi 'IA-32\|i386\|80386'; then
        ok "firmware is IA-32 (matches the tablet)"
    else
        printf '\033[33mWARN:\033[0m %s does not look 32-bit.\n' "$FCODE"
        printf '        Booting under 64-bit firmware would not prove anything\n'
        printf '        about this tablet. Verify before trusting the result.\n'
    fi
fi

# ── kernel sanity ─────────────────────────────────────────────────────────
if command -v file >/dev/null; then
    file "$KERNEL" | grep -q 'x86-64' \
        && ok "kernel is x86-64" \
        || die "kernel is not x86-64; Android x86_64 userspace cannot run on it"
fi

# ── boot ──────────────────────────────────────────────────────────────────
DEFAULT_CMDLINE="console=ttyS0,115200 earlycon intel_idle.max_cstate=1 \
i915.enable_psr=0 i915.enable_dc=0 i915.enable_fbc=0 \
androidboot.hardware=casper androidboot.selinux=permissive"
CMDLINE="${CMDLINE:-$DEFAULT_CMDLINE}"

info "booting (${MEM} MB, 32-bit UEFI, ${WAIT}s)"
# -cpu max is required: a default qemu64 CPU may not expose the instruction set
# the Android userspace expects (SSE4.2/POPCNT), and this CPU is x86-64-v2.
timeout "$WAIT" qemu-system-x86_64 \
    -machine q35 -m "$MEM" -cpu max \
    -drive if=pflash,format=raw,readonly=on,file="$FCODE" \
    -drive if=pflash,format=raw,file="$VARS" \
    -kernel "$KERNEL" \
    -initrd "$RAMDISK" \
    -append "$CMDLINE" \
    -netdev user,id=n0 -device e1000,netdev=n0 \
    -display none -vga std -no-reboot \
    -serial "file:$OUT/serial.log" \
    >"$OUT/qemu.log" 2>&1 || true

# ── verdict ───────────────────────────────────────────────────────────────
# Distinguish the failure stages, because "it didn't boot" is not actionable.
# Each stage has its own evidence in the serial log.
serial_has() { grep -aqE "$1" "$OUT/serial.log" 2>/dev/null; }

STAGE="nothing"
CMD=""
if [ ! -s "$OUT/serial.log" ]; then
    STAGE="no-serial-output"
    CMD="Firmware produced no serial output. Check:
  - is FCODE really the IA32 build?
  - is the kernel 64-bit with CONFIG_EFI_MIXED=y?
  - is a loader using the EFI handover protocol in the chain? (stub cannot do mixed mode)"
elif serial_has 'Linux version'; then
    STAGE="kernel-entered"
    if serial_has 'console \[ttyS0\] enabled|Freeing unused kernel'; then
        STAGE="userspace-handoff"
    fi
    if serial_has 'init:|Booting Android|androidboot'; then
        STAGE="android-init"
    fi
else
    STAGE="firmware-only"
    CMD="Firmware ran but the kernel never printed. This is the mixed-mode
handover problem: EFI_MIXED cannot be entered via the EFI stub. Use GRUB
(i386-efi) as the loader, or a loader implementing the handover protocol."
fi

info "last reached stage: $STAGE"
echo "--- serial log tail ---"
tail -n 30 "$OUT/serial.log" 2>/dev/null || echo "(empty)"
echo "-----------------------"

if [ -n "$CMD" ]; then
    printf '\n\033[31mFAIL\033[0m at stage: %s\n%s\n' "$STAGE" "$CMD" >&2
    exit 1
fi

# logcat is the real success criterion: it means Android userspace is alive.
if serial_has 'logcat|property_service|servicemanager|zygote'; then
    ok "Android userspace reached (${STAGE})"
    exit 0
fi

printf '\n\033[33mINCONCLUSIVE\033[0m: kernel entered, Android init not yet seen.\n'
printf 'Stage was "%s". The boot chain itself works; the ramdisk or cmdline\n' "$STAGE"
printf 'is the next thing to check (androidboot.hardware must name a real\n'
printf 'init.*.rc in the ramdisk).\n'
exit 2
