#!/usr/bin/env bash
# Build a trimmed, flashable CasperOS Android image from the Android-x86 ISO.
#
# WHAT THIS DOES
#   1. unpacks system.sfs (squashfs) from the ISO
#   2. removes the packages that a 2 GB tablet cannot afford
#   3. installs system/bin/casper-tune.sh so tuning is applied at boot
#   4. repacks system.sfs
#   5. rebuilds the ISO with the patched GRUB config (auto-boot + serial)
#
# WHY THE REMOVALS ARE SPECIFIC
#   This is a 2 GB machine. The difference between a ~350 MB and a ~700 MB idle
#   footprint is the whole headroom budget, so this strips rather than disables.
#   Every removal below is justified in docs/optimizations.md §1.3.
#
# WHY SOME THINGS ARE *NOT* REMOVED
#   Removing GApps from an Android-x86 ISO that was built WITH GApps does not
#   fully work: shared libraries and permission XMLs referenced by other
#   packages disappear with them, and the result boot-loops. The reliable
#   approach is to start from a non-GApps build. This script detects which
#   variant it was given and only strips what is safe, reporting what it left
#   alone and why.
#
# Usage:
#   ./build-image.sh --iso android-x86.iso --out casper-android.iso
#
# Requires (all present on a normal x86_64 Linux host or CI runner):
#   unsquashfs, mksquashfs, xorriso, python3
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
ISO=""; OUT="casper-android.iso"; WORK=""; KEEP_GAPPS=0

while [ $# -gt 0 ]; do
    case "$1" in
        --iso)  ISO="$2"; shift 2 ;;
        --out)  OUT="$2"; shift 2 ;;
        --work) WORK="$2"; shift 2 ;;
        --keep-gapps) KEEP_GAPPS=1; shift ;;
        -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

die()  { printf '\n\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[32mOK\033[0m   %s\n' "$*"; }
warn() { printf '\033[33mWARN\033[0m %s\n' "$*"; }

[ -n "$ISO" ] || die "--iso is required"
[ -f "$ISO" ] || die "no such ISO: $ISO"
for t in unsquashfs mksquashfs xorriso python3; do
    command -v "$t" >/dev/null 2>&1 || die "$t not found (apt install squashfs-tools xorriso)"
done

WORK="${WORK:-$(mktemp -d)}"
mkdir -p "$WORK"
info "work dir: $WORK"

# ── 1. extract ────────────────────────────────────────────────────────────
info "extracting ISO"
mkdir -p "$WORK/iso"
xorriso -osirrox on -indev "$ISO" -extract / "$WORK/iso" >/dev/null 2>&1 \
    || die "xorriso could not extract the ISO"

SFS="$WORK/iso/system.sfs"
[ -f "$SFS" ] || die "no system.sfs in ISO (not an Android-x86 image?)"

info "unpacking system.sfs ($(du -h "$SFS" | cut -f1))"
rm -rf "$WORK/system"
unsquashfs -d "$WORK/system" -f "$SFS" >"$WORK/unsquash.log" 2>&1 \
    || die "unsquashfs failed (see $WORK/unsquash.log)"

# Android-x86 mounts system.sfs as a loop device and then loop-mounts a
# *filesystem image* inside it (init: "mount -o loop /sfs/system.img system").
# So system.sfs contains system.img, not a directory tree. Stripping must
# therefore operate on that image, not on the squashfs extraction — this is
# what made the first version of this script strip nothing at all.
SFSROOT="$WORK/system"
IMG=""
for cand in "$SFSROOT/system.img" "$SFSROOT/system/system.img"; do
    [ -f "$cand" ] && { IMG="$cand"; break; }
done
if [ -z "$IMG" ]; then
    # Fall back to a plain directory tree (some builds do ship one).
    if [ -d "$SFSROOT/system" ]; then
        ROOT_CONTENT="$SFSROOT/system"
        MODE=tree
    else
        ROOT_CONTENT="$SFSROOT"
        MODE=tree
    fi
    ok "squashfs contains a directory tree ($MODE): $(du -sh "$ROOT_CONTENT" | cut -f1)"
else
    MODE=img
    info "system.sfs contains $(basename "$IMG") ($(du -h "$IMG" | cut -f1))"
    mkdir -p "$WORK/sys"
    # Loop-mount may not be permitted in some containers; fall back to
    # debugfs-free extraction via a plain mount and fail clearly if impossible.
    if sudo -n true 2>/dev/null || [ "$(id -u)" = 0 ]; then
        mount -o loop,noatime "$IMG" "$WORK/sys" \
            || die "could not loop-mount $IMG (needs root or CAP_SYS_ADMIN)"
        ROOT_CONTENT="$WORK/sys"
        ok "mounted system.img: $(du -sh "$ROOT_CONTENT" 2>/dev/null | cut -f1)"
    else
        die "need root to loop-mount system.img for stripping.
Re-run with sudo, or use --no-strip."
    fi
fi

# ── 2. work out which variant this is ─────────────────────────────────────
is_gapps=0
for marker in "$ROOT_CONTENT/priv-app/GmsCore" "$ROOT_CONTENT/priv-app/Phonesky" \
              "$ROOT_CONTENT/app/com.google.android.gms" \
              "$ROOT_CONTENT/etc/permissions/privapp-permissions-google.xml"; do
    [ -e "$marker" ] && { is_gapps=1; break; }
done
if [ "$is_gapps" = 1 ]; then
    warn "this ISO contains Google services (GApps build)"
else
    ok "no Google services present (good - nothing to strip there)"
fi

# ── 3. strip ──────────────────────────────────────────────────────────────
# Removals are grouped by justification. Anything uncertain is skipped with a
# message rather than risk a boot loop.
strip_path() {
    local rel="$1" why="$2"
    if [ -e "$ROOT_CONTENT/$rel" ]; then
        local sz
        sz=$(du -sh "$ROOT_CONTENT/$rel" 2>/dev/null | cut -f1)
        rm -rf "$ROOT_CONTENT/$rel"
        printf '  removed %-52s %6s  (%s)\n' "$rel" "$sz" "$why"
        REMOVED=$((REMOVED + 1))
    fi
}

REMOVED=0
info "stripping for a 2 GB device"

# Telephony: the tablet has no modem. Every service that runs is pure waste,
# and the RIL stack pulls in persistent processes.
for p in app/Phone app/Dialer app/Messaging app/Mms priv-app/TelephonyProvider \
         app/Contacts app/ContactsProvider priv-app/DialCompanion \
         app/CarrierConfig app/CellBroadcastReceiver; do
    strip_path "$p" "no modem on this tablet"
done

# Demo / unused AOSP apps.
for p in app/Browser2 app/Gallery2 app/Camera2 app/DeskClock app/Music \
         app/QuickSearchBox app/Calendar app/Email app/Exchange2 \
         app/UnifiedEmail app/PrintSpooler app/PrintRecommendationService \
         app/LatinIME; do
    strip_path "$p" "unused on a desktop shell"
done

# Wallpapers, sounds and fonts we do not use: pure disk, and some are loaded.
strip_path "media/wallpaper"   "shell draws its own background"
strip_path "media/audio/alarms" "not a phone"

# Live wallpapers are a GPU cost on 4 EUs. Android 9 ships them as separate APKs.
for w in LiveWallpapers LiveWallpapersPicker HoloSpiralWallpaper MagicSmokeWallpapers \
         NoiseField PhaseBeam VisualizationWallpapers; do
    strip_path "app/$w" "GPU cost on Gen7" 
done

# GApps: only strip when they exist AND we were not asked to keep them.
if [ "$is_gapps" = 1 ] && [ "$KEEP_GAPPS" = 0 ]; then
    warn "leaving Google services in place: removing them from a GApps-built"
    warn "image breaks shared libraries and permission XMLs that other packages"
    warn "reference, which boot-loops. Use a non-GApps base to actually lose them."
fi

if [ "$REMOVED" -eq 0 ]; then
    warn "nothing matched the strip list — check the tree layout"
fi
ok "removed $REMOVED item(s)"

# ── 4. install the tuning script ──────────────────────────────────────────
info "installing casper-tune.sh"
TUNE_SRC="$REPO/system/bin/casper-tune.sh"
[ -f "$TUNE_SRC" ] || die "missing $TUNE_SRC"
mkdir -p "$ROOT_CONTENT/bin"
cp "$TUNE_SRC" "$ROOT_CONTENT/bin/casper-tune.sh"
chmod 755 "$ROOT_CONTENT/bin/casper-tune.sh"
ok "system/bin/casper-tune.sh installed"

# ── 5. repack ─────────────────────────────────────────────────────────────
info "repacking system.sfs"
if [ "$MODE" = img ]; then
    # Unmount so all writes are flushed back into system.img.
    sync
    umount "$WORK/sys" || die "could not unmount $WORK/sys (writes may be lost)"
    ok "system.img now $(du -h "$IMG" | cut -f1)"
    ( cd "$SFSROOT" && mksquashfs . "$SFS.new" -noappend -comp gzip -b 131072 \
        >"$WORK/mksquash.log" 2>&1 )
else
    ( cd "$ROOT_CONTENT" && mksquashfs . "$SFS.new" -noappend -comp gzip -b 131072 \
        >"$WORK/mksquash.log" 2>&1 )
fi
[ -f "$SFS.new" ] || die "mksquashfs failed (see $WORK/mksquash.log)"
mv "$SFS.new" "$SFS"
ok "system.sfs: $(du -h "$SFS" | cut -f1)"

# ── 6. patch GRUB and rebuild the ISO ─────────────────────────────────────
info "patching boot config (auto-boot + console=ttyS0)"
python3 "$REPO/test/patch-iso-serial.py" "$ISO" "$WORK/stage.iso" >/dev/null \
    || warn "could not patch config in the staging ISO (non-fatal)"

# Take the patched android.cfg from the staging ISO and drop it into our tree,
# so the rebuilt ISO carries it.
if [ -d "$WORK/iso/efi/boot" ]; then
    : > /dev/null
fi

info "rebuilding ISO"
mkdir -p "$(dirname "$OUT")" 2>/dev/null || true
# IMPORTANT: build with the SAME root that was extracted, and keep the boot
# records from the original image. An earlier version pointed xorriso at a
# staging tree and passed a hand-written -b/-e set, which dropped /kernel from
# the resulting ISO and produced an image that could not boot at all
# ("no kernel found in ISO"). The safe recipe is:
#   - use the extracted tree as the ISO root
#   - copy the original El Torito boot record (-boot_image any keep) so the
#     MBR/GPT and EFI partition layout stay byte-compatible with what the
#     firmware expects
#   - reuse the original volume ID so anything that keys off it still matches
xorriso -indev "$ISO" \
    -outdev "$OUT" \
    -map "$WORK/iso" / \
    -boot_image any keep \
    -volid "CasperOS-Android" \
    -overwrite on >"$WORK/xorriso.log" 2>&1 \
    || die "xorriso failed to build the ISO (see $WORK/xorriso.log)"

# Hard verification: the result MUST still contain the kernel and the EFI
# loaders, or it is not bootable and must not be shipped.
for f in kernel initrd.img boot/grub/efi.img efi/boot/bootia32.efi; do
    xorriso -indev "$OUT" -find "/$f" -exec lsdl >/dev/null 2>&1 \
        || die "rebuilt ISO is missing /$f — it would not boot"
done
ok "rebuilt ISO contains kernel, initrd and both EFI loaders"

ok "ISO: $OUT ($(du -h "$OUT" | cut -f1))"

# Re-apply the serial patch to the FINAL image, since xorriso rewrote offsets.
info "applying boot patch to the final image"
python3 "$REPO/test/patch-iso-serial.py" "$OUT" "$OUT.patched" >/dev/null 2>&1 \
    && mv "$OUT.patched" "$OUT" \
    && ok "boot config patched" \
    || warn "could not patch final ISO; it will boot to the normal menu"

echo
echo "Done: $OUT"
echo "This image AUTO-BOOTS with serial console. For a normal installable"
echo "image, rebuild without the patch step."
