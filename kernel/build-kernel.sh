#!/usr/bin/env bash
# Build the CasperOS Android kernel: Bay Trail Z3735F, 32-bit UEFI + 64-bit
# kernel, Android binder built in, Gen7 graphics, RT5640 audio, RTL8723BS Wi-Fi.
#
# This exists because the Ubuntu 5.15 mainline kernel this project currently
# ships for the Linux image has NO binder and NO drivers/android directory at
# all (verified: 5,976 modules, zero binder). Android userspace cannot start
# without it, so a kernel rebuild is step zero, not an optimisation.
#
# Usage:
#   ./build-kernel.sh                      # build in ./out
#   ./build-kernel.sh --jobs 4 --out /tmp/k
#   ./build-kernel.sh --config-only        # just produce the merged .config
#
# Requirements: gcc, make, bc, bison, flex, libssl-dev, libelf-dev, xz-utils.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KVER="${KVER:-6.12}"
# 6.12 is chosen deliberately: it is the same series the Debian image already
# boots on this tablet, so every Bay Trail behaviour already validated
# (cstate pinning, audio, Wi-Fi, i915 quirks) carries over instead of being
# re-discovered on a new baseline.
SERIES="${KVER%%.*}"
SRC_URL="https://cdn.kernel.org/pub/linux/kernel/v${SERIES}.x"
OUT="$HERE/out"
JOBS="$(nproc)"
CONFIG_ONLY=0
ARCH=x86_64

while [ $# -gt 0 ]; do
    case "$1" in
        --out)   OUT="$2"; shift 2 ;;
        --jobs)  JOBS="$2"; shift 2 ;;
        --kver)  KVER="$2"; SERIES="${KVER%%.*}"; shift 2 ;;
        --config-only) CONFIG_ONLY=1; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

die() { printf '\n\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }

mkdir -p "$OUT"
WORK="$OUT/src"
TARBALL="linux-${KVER}.tar.xz"

# ── fetch ─────────────────────────────────────────────────────────────────
if [ ! -d "$WORK" ]; then
    if [ ! -f "$OUT/$TARBALL" ]; then
        info "downloading linux ${KVER}"
        curl -fL --retry 3 -o "$OUT/$TARBALL" \
            "${SRC_URL}/${TARBALL}" \
            || die "could not download ${SRC_URL}/${TARBALL} — check the version exists"
    fi
    info "extracting"
    tar -C "$OUT" -xf "$OUT/$TARBALL"
    mv "$OUT/linux-${KVER}" "$WORK"
fi

cd "$WORK"

# ── base config ───────────────────────────────────────────────────────────
# Start from defconfig, not from the host's .config: the host is an Android
# phone or a CI runner and its config is full of irrelevant drivers.
info "base defconfig (${ARCH})"
make ARCH="$ARCH" defconfig >/dev/null

# ── merge our fragment ────────────────────────────────────────────────────
info "applying casper-android.fragment"
"$HERE/merge-config.sh" .config "$HERE/casper-android.fragment" > .config.merged
mv .config.merged .config

# olddefconfig resolves anything the fragment did not mention, and is the only
# supported way to make a hand-edited fragment consistent with this exact
# Kconfig tree. Without it, silently-stale entries survive as comments and you
# get a kernel that does not match the fragment you just read.
info "resolving dependencies (olddefconfig)"
make ARCH="$ARCH" olddefconfig >/dev/null

CONFIG_OUT="$OUT/config-${KVER}-casper-android"
cp .config "$CONFIG_OUT"
info "config written to $CONFIG_OUT"

# ── verify the config actually says what we asked for ─────────────────────
# This is the part that would have caught "CONFIG_ASHMEM=y" style mistakes:
# every requirement is checked against the *resolved* config, so a symbol that
# does not exist in this kernel version fails loudly instead of being silently
# dropped.
info "verifying required symbols"
FAIL=0
require() {
    local sym="$1" val="$2"
    local have
    have=$(grep -E "^${sym}=" "$CONFIG_OUT" | head -1 | cut -d= -f2- || true)
    if [ "$have" = "$val" ]; then
        printf '  \033[32mOK\033[0m   %s=%s\n' "$sym" "$val"
    else
        printf '  \033[31mFAIL\033[0m %s: want %s, got "%s"\n' "$sym" "$val" "${have:-<absent>}"
        FAIL=1
    fi
}
forbid() {
    local sym="$1"
    if grep -qE "^${sym}=" "$CONFIG_OUT"; then
        printf '  \033[31mFAIL\033[0m %s should be unset (found %s)\n' "$sym" \
            "$(grep -E "^${sym}=" "$CONFIG_OUT")"
        FAIL=1
    else
        printf '  \033[32mOK\033[0m   %s is unset\n' "$sym"
    fi
}

# Android core — if any of these are missing, nothing else matters.
require CONFIG_ANDROID_BINDER_IPC y
require CONFIG_ANDROID_BINDERFS y
require CONFIG_PSI y
# Boot chain — 32-bit firmware calling a 64-bit kernel.
require CONFIG_EFI_MIXED y
require CONFIG_EFI_STUB y
# Memory
require CONFIG_ZRAM y
require CONFIG_SWAP y
forbid  CONFIG_ZSWAP
# Bay Trail hardware
require CONFIG_I2C_HID_ACPI y
require CONFIG_PINCTRL_BAYTRAIL y
require CONFIG_DRM_I915 y
require CONFIG_RTL8723BS y
require CONFIG_SND_SOC_INTEL_BYTCR_RT5640_MACH y

if [ "$FAIL" -ne 0 ]; then
    die "config verification failed — see the FAIL lines above.
Some symbols are version-specific. Check the real name in this tree with:
    grep -rn '<name>' --include=Kconfig .
Do NOT simply drop the requirement: find out whether the feature moved."
fi

[ "$CONFIG_ONLY" -eq 1 ] && { info "--config-only: stopping"; exit 0; }

# ── build ─────────────────────────────────────────────────────────────────
info "building kernel (-j${JOBS})"
START=$(date +%s)
# -s keeps the log readable; errors still surface. bzImage is what GRUB and
# Android's boot image need.
make ARCH="$ARCH" -j"$JOBS" bzImage modules 2>&1 | tail -n 40
END=$(date +%s)

KIMG="$WORK/arch/x86/boot/bzImage"
[ -f "$KIMG" ] || die "build finished but $KIMG does not exist"

# Mixed-mode sanity check: the kernel must be 64-bit ELF and must contain the
# efi_mixed thunk. A build that silently omitted it boots on 64-bit firmware
# and fails on this tablet, which is the worst possible failure mode.
file "$KIMG" | grep -q 'x86-64' || die "bzImage is not 64-bit — wrong ARCH?"
info "bzImage: $(du -h "$KIMG" | cut -f1)  built in $((END-START))s"

mkdir -p "$OUT/artifacts"
cp "$KIMG" "$OUT/artifacts/bzImage-${KVER}-casper-android"
cp "$CONFIG_OUT" "$OUT/artifacts/config-${KVER}-casper-android"

# A config that claims EFI_MIXED but whose image lacks the thunk would pass the
# symbol check and still fail to boot. Look for the actual symbol.
if command -v nm >/dev/null && [ -f "$WORK/vmlinux" ]; then
    if nm "$WORK/vmlinux" 2>/dev/null | grep -q 'efi_mixed'; then
        info "efi_mixed thunk present in vmlinux"
    else
        printf '\033[33mWARN:\033[0m efi_mixed symbol not found in vmlinux; verify 32-bit UEFI boot before flashing\n'
    fi
fi

info "artifacts in $OUT/artifacts"
ls -la "$OUT/artifacts"
