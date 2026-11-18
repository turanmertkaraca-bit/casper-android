#!/system/bin/sh
# casper-tune.sh — apply the CasperOS Android optimisations on the device.
#
# Lives on /system and is invoked once from init on first boot, and again after
# any OTA that resets kernel tunables. Every step prints what it did, because a
# tuning script that silently fails is worse than none: it makes the next
# person debug the wrong layer.
#
# Idempotent. Safe to re-run at any time.
#
# This is the device-side counterpart to docs/optimizations.md; the reasoning
# for each value lives there, not here.

set -u

TAG="casper-tune"

log()  { echo "[$TAG] $*"; }
warn() { echo "[$TAG] WARN: $*"; }

# ── 1. zram: the highest-value memory feature on a 2 GB device ────────────
setup_zram() {
    # Android normally creates zram itself (roidb/init). If it already exists
    # and is in use, do not touch it: resizing a live swap device is a good way
    # to lose pages. Only configure it when absent or inactive.
    if [ -e /sys/block/zram0/disksize ]; then
        local cur
        cur=$(cat /sys/block/zram0/disksize 2>/dev/null || echo 0)
        if [ "$cur" != "0" ]; then
            log "zram0 already configured ($cur bytes), leaving alone"
            verify_zram
            return
        fi
    fi

    local mod=/sys/module/zram/parameters
    # lz4 for swap: fastest decompress on Silvermont. zstd stays available.
    echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null \
        || warn "could not set lz4 compressor"

    # 1:1 with RAM. More than that presents swap the machine cannot back and
    # invites thrash; less under-uses the technique on a 2 GB device.
    local mem_kb
    mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
    local size_bytes=$((mem_kb * 1024))

    echo "$size_bytes" > /sys/block/zram0/disksize || {
        warn "could not set zram disksize"; return; }

    if mkswap /dev/block/zram0 >/dev/null 2>&1; then
        log "zram0: lz4, $((size_bytes / 1024 / 1024)) MB"
    else
        warn "mkswap on zram0 failed"
        return
    fi
    swapon -p 100 /dev/block/zram0 2>/dev/null || swapon /dev/block/zram0
    verify_zram
}

verify_zram() {
    if grep -q zram /proc/swaps 2>/dev/null; then
        log "swap active: $(grep zram /proc/swaps)"
    else
        warn "zram0 is not in /proc/swaps — no compressed swap available"
    fi
}

# ── 2. swappiness: the opposite of the usual "Linux tuning" advice ────────
tune_vm() {
    # zram-backed swap is RAM, so swapping is cheap and should happen eagerly.
    # swappiness=10 (the common advice for disk swap) would waste the savings.
    set_sysctl vm.swappiness 180
    # Read one page per fault, not eight. 8-page reads assume a spinning disk.
    set_sysctl vm.page-cluster 0
    # THP off: khugepaged compaction costs more than the TLB win at 2 GB, and
    # the stalls show up as UI jank.
    if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
        echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null \
            && log "THP: never"
    fi
    # Dirty ratios: eMMC has poor random write behaviour. Flushing earlier and
    # smaller keeps write stalls out of the UI.
    set_sysctl vm.dirty_ratio 20
    set_sysctl vm.dirty_background_ratio 5
    # Android apps are many small processes; keep the pid space out of the way.
    set_sysctl vm.vfs_cache_pressure 100
}

set_sysctl() {
    local key="$1" val="$2"
    if sysctl -w "$key=$val" >/dev/null 2>&1; then
        log "$key=$val"
    else
        warn "could not set $key=$val"
    fi
}

# ── 3. I/O scheduler ──────────────────────────────────────────────────────
tune_io() {
    local dev=/sys/block/mmcblk0/queue/scheduler
    [ -f "$dev" ] || { warn "no $dev"; return; }
    # Measure before changing this. BFQ trades throughput for tail latency and
    # can genuinely help eMMC; mq-deadline is Android's default. See
    # docs/optimizations.md §4.1 for why this is not assumed.
    if grep -q bfq "$dev" 2>/dev/null; then
        echo bfq > "$dev" 2>/dev/null && log "I/O scheduler: bfq"
    elif grep -q mq-deadline "$dev" 2>/dev/null; then
        echo mq-deadline > "$dev" 2>/dev/null && log "I/O scheduler: mq-deadline"
    else
        log "I/O scheduler: leaving kernel default ($(cat "$dev"))"
    fi
    # Keep read-ahead small: this is eMMC, and large readahead wastes RAM we
    # do not have.
    echo 128 > /sys/block/mmcblk0/queue/read_ahead_kb 2>/dev/null \
        && log "read_ahead_kb=128"
}

# ── 4. CPU governor ───────────────────────────────────────────────────────
tune_cpu() {
    local gov=/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
    if [ -f "$gov" ]; then
        echo schedutil > "$gov" 2>/dev/null && log "governor: schedutil"
    fi
    # C-state pinning is the touchscreen fix and MUST come from the kernel
    # cmdline (intel_idle.max_cstate=1), not from here — see
    # docs/optimizations.md §3.1. Verify it took effect rather than assuming.
    if [ -d /sys/devices/system/cpu/cpu0/cpuidle ]; then
        local deep
        deep=$(cat /sys/devices/system/cpu/cpu0/cpuidle/state3/usage 2>/dev/null || echo 0)
        log "cpuidle state3 usage: $deep (should barely grow while idle)"
    fi
}

# ── 5. Wi-Fi: RTL8723BS powersave causes multi-second stalls ──────────────
tune_wifi() {
    for f in /sys/module/rtl8723bs/parameters/*power*; do
        [ -e "$f" ] || continue
        echo 0 > "$f" 2>/dev/null && log "wifi: $(basename "$f")=0"
    done
    # NetworkManager/Android may re-enable it per-interface.
    if command -v iw >/dev/null 2>&1; then
        iw dev wlan0 set power_save off 2>/dev/null \
            && log "wifi: power_save off"
    fi
}

# ── 6. Animation scales: the most visible stutter on a 4-EU GPU ───────────
tune_animations() {
    command -v settings >/dev/null 2>&1 || return
    settings put global window_animation_scale 0 2>/dev/null
    settings put global transition_animation_scale 0 2>/dev/null
    settings put global animator_duration_scale 0 2>/dev/null
    log "animation scales: 0"
}

# ── 7. Trim: keep eMMC write latency from degrading ───────────────────────
tune_trim() {
    # Weekly fstrim. Android often skips this on a device that never sees a
    # charging-idle heuristic it recognises.
    if command -v fstrim >/dev/null 2>&1; then
        fstrim -v /data 2>/dev/null | sed "s/^/[$TAG] /" || true
    fi
}

# ── report ────────────────────────────────────────────────────────────────
report() {
    log "--- memory ---"
    grep -E 'MemTotal|MemAvailable|SwapTotal|SwapFree' /proc/meminfo | sed "s/^/[$TAG] /"
    log "--- pressure ---"
    head -1 /proc/pressure/memory 2>/dev/null | sed "s/^/[$TAG] /" || warn "no PSI (CONFIG_PSI missing!)"
    log "--- zram ratio ---"
    if [ -r /sys/block/zram0/mm_stat ]; then
        awk '{printf "[%s] zram: orig=%d KB comp=%d KB ratio=%.2f\n", "'"$TAG"'", $1/1024, $2/1024, ($2>0?$1/$2:0)}' \
            /sys/block/zram0/mm_stat
    fi
    log "done"
}

main() {
    log "applying CasperOS Android tuning"
    setup_zram
    tune_vm
    tune_io
    tune_cpu
    tune_wifi
    tune_animations
    tune_trim
    report
}

main "$@"
