# CasperOS Android — optimization playbook

Every tuning that applies to Android on a Bay Trail Z3735F with 2 GB of RAM.
Each entry states **what it does**, **why it helps on this exact hardware**,
and **how to verify it worked** — because on this project, plausible-sounding
tuning that does nothing has been the single most common failure mode.

Nothing here is "add this flag because a blog said so." Where a widely
repeated trick is wrong for this device, it is listed as wrong with a reason.

Ordering is by measured impact on this hardware class: memory first (because
2 GB is the binding constraint), then GPU/compositing, then CPU, then I/O.

---

## 0. Measure before and after

Without a baseline, every "optimization" is a guess. Take these before
touching anything:

```bash
# memory pressure and the killer's view
cat /proc/meminfo | grep -E 'MemTotal|MemAvailable|SwapTotal|SwapFree'
cat /proc/pressure/memory
dumpsys meminfo | head -40

# what is actually drawing frames
dumpsys SurfaceFlinger --latency <layer>
dumpsys gfxinfo <package>

# CPU time by process, top 15
top -b -n1 -o %CPU | head -20

# zram effectiveness — the numbers that matter
cat /sys/block/zram0/mm_stat
# fields: orig_data_size compr_data_size mem_used_total mem_limit ...
```

`mm_stat` gives you the real compression ratio. If `compr_data_size` is not
materially smaller than `orig_data_size`, your swap is doing nothing but
adding latency and you should fix the compressor choice rather than tune
anything else.

---

## 1. Memory — the constraint that decides everything

### 1.1 zram, sized correctly

Android on 2 GB wants roughly a 1:1 or 1.5:1 swap-to-RAM ratio with fast
compression. The kernel's own default (often 50% of RAM) is too small for a
device that will page constantly.

```bash
# create it with lz4 — fastest decompress on Silvermont
echo lz4 > /sys/block/zram0/comp_algorithm
echo 2048M > /sys/block/zram0/disksize      # 1:1 with RAM
mkswap /dev/block/zram0
swapon /dev/block/zram0 -p 100
```

**Why lz4 and not zstd:** zstd compresses ~20–30% better but decompresses
roughly 2–3× slower. On a 1.33 GHz Silvermont, swap-in latency is on the
critical path of touching a page, so decompression speed dominates the
decision. This matches what the Linux image already chose, and the reasoning
has not changed under Android.

**Why not both:** do not stack zswap in front of zram. Two compression layers
means compressing twice and decompressing twice. The kernel config
(`CONFIG_ZSWAP=n`) enforces this deliberately.

**Verify:** `zramctl` shows `DATA COMPR` ratio; anything below ~1.8:1 means
the workload is mostly incompressible (e.g. already-compressed media) and
zram is not where your wins are.

### 1.2 swappiness — the opposite of the usual advice

Most "Linux optimization" guides say `vm.swappiness=10`. **That is wrong
here.** With disk-backed swap you want to avoid swapping; with zram the swap
device is RAM, so a swap-out costs a compress and a page of RAM instead of a
disk read. The kernel documentation for zram-backed swap recommends the
opposite: swap aggressively.

```
vm.swappiness=180
vm.page-cluster=0
```

`page-cluster=0` means "read one page at a time." The default (3) reads 8
pages per fault — sensible for a rotating disk's seek amortization, wasteful
when every page read is a decompression of data you may not need.

**Verify:** after a few hours of real use, `SwapFree` should be substantially
below `SwapTotal` and the device should still feel responsive. If it does not,
swappiness is not reaching the kernel (check `sysctl vm.swappiness`).

### 1.3 Kill the things that hold memory

Strip the image, do not just disable icons. On a 2 GB device the difference
between 350 MB and 700 MB idle is the entire headroom budget.

- **No Google Play Services.** It is one of the largest single RAM consumers
  on Android and requires persistent background processes. Without it the
  device is much lighter. The cost is real: apps that depend on Play
  Services (many banking, maps, and notification-push apps) will not work.
  Decide this consciously — see the project README.
- **No telephony stack** — no `com.android.phone`, no RIL. The tablet has no
  modem. Every telephony service that runs is pure waste.
- **No vendor bloat, no AOSP demo apps, no print services, no live wallpapers.**
- Mask, do not merely disable, the services you do not use — a disabled app
  is still installed and still costs disk; a masked service cannot be started
  by another app's intent.

### 1.4 lmkd tuning

Android's low-memory killer reads `/proc/pressure/memory` (PSI). Tune the
thresholds to kill background apps earlier than defaults, because on 2 GB the
alternative is the foreground app stalling.

```
# /system/etc/init/lmkd.rc or a device init.rc override
write /sys/module/lowmemorykiller/parameters/minfree "8192,10240,12288,16384,20480,24576"
```

Numbers are in 4 KB pages. Convert to MB (×4/1024) and sanity-check against
your actual idle footprint before trusting the values above: `/system` and
`/data` sizes on this device class vary, and lmkd thresholds written for a
4 GB phone will thrash a 2 GB tablet.

**Verify:** `dumpsys activity lru` after opening 5–6 apps. You want the
oldest background apps evicted, not the launcher recreated.

### 1.5 Transparent huge pages: off

`CONFIG_TRANSPARENT_HUGEPAGE=n`. On 2 GB, khugepaged's scanning competes for
CPU, and the compaction stalls show up as visible UI jank. The TLB benefit is
real but smaller than the cost at this RAM size. This is already a Linux-image
decision; carry it over.

### 1.6 earlyoom is not needed — and may fight lmkd

The Linux image uses `earlyoom` because a stock Debian desktop has no
low-memory killer. Android **has** one, and it is better informed (PSI-based,
per-process oom_score_adj reflecting foreground/visible/service state).
Running both means two independent killers with different opinions, and the
one that wins may not be the one that understands Android's process
importance. **Do not install earlyoom on the Android side.**

---

## 2. GPU and compositing — where the "BlissOS felt laggy" problem lives

The touch lag you saw on BlissOS is a compositing problem, not a touch
problem. Gen7 with 4 EUs cannot afford per-frame work that a modern phone
does for free. These are the changes that matter, in order.

### 2.1 Keep the compositor out of the path

Every frame SurfaceFlinger composites on the GPU ("client composition") is a
full-screen blit on 4 EUs. When a hardware overlay plane is available, the
display controller scans it out for free and the GPU is idle.

- `debug.sf.enable_hwc_vds=1`
- `debug.sf.disable_client_composition_cache=0`
- Verify with `dumpsys SurfaceFlinger` — look for the composition type per
  layer. You want `DEVICE`, not `CLIENT`. If everything says `CLIENT`, the
  overlay path is not being used and that alone explains sluggish scrolling.

This is the single highest-value graphics change on this GPU. Check it first.

### 2.2 Kill animations

Animations on a 4-EU GPU are the difference between "usable" and "stuttery" —
the same conclusion the Linux image reached about Hyprland blur, and it
applies identically here.

```bash
settings put global window_animation_scale 0
settings put global transition_animation_scale 0
settings put global animator_duration_scale 0
```

### 2.3 Buffer count: do not raise it

**"Triple buffering" is not a performance switch.** Android's BufferQueue is
already triple-buffered by default (one buffer being drawn, one queued, one
being scanned out). Raising it to 4:
- adds one frame of latency (~16 ms at 60 Hz),
- costs one extra full-screen buffer of RAM (1366×768×4 ≈ 4 MB, per surface),
- helps only when the producer is consistently *faster* than the display.

On this device the producer is consistently *slower*, so extra buffers only
add latency. If memory pressure is the problem, consider reducing to double
buffering for specific surfaces rather than raising it globally.

The genuine wins are: fewer dropped frames (from the overlay path in 2.1),
fewer animations (2.2), and less work per frame (2.4). Not buffer count.

### 2.4 Avoid forced GPU rendering and heavy blur

- Do **not** set `debug.hwui.renderer=opengl` / force GPU rendering globally.
  On Gen7 it moves work onto the weaker unit.
- Do **not** use blur effects (`RenderEffect` blur, frosted panels). A
  full-screen blur at 1366×768 on 4 EUs is tens of milliseconds per frame —
  it will not feel like a desktop, it will feel broken. This is the Android
  equivalent of the Hyprland blur decision the Linux image already made.
- Prefer flat, high-contrast UI. It also renders faster.

### 2.5 Fixed 60 Hz, no PSR, no FBC

The Linux image already disables panel self-refresh and frame-buffer
compression on this GPU because they cause flicker and stalls. Carry the same
settings over; a self-refreshing panel that misbehaves under Android shows up
as intermittent stutter that is very hard to attribute later.

### 2.6 Video: H.264 only

Gen7 hardware-decodes H.264 and VP8. **No VP9, no AV1.** YouTube and most
modern services default to VP9/AV1, which forces full software decode on a
1.33 GHz Atom.

There is no Android setting that fixes this — it is codec negotiation. The
options are a client that can force H.264 (e.g. ReVanced with the codec
override), or accepting that video is CPU-bound. This limitation is identical
to the Linux image's `h264ify` situation and does not improve by changing OS.

Cap playback at 720p–1080p30; beyond that the decoder's throughput is the
wall, not the codec.

---

## 3. CPU and scheduling

### 3.1 `intel_idle.max_cstate=1` — non-negotiable

This is the fix for the touchscreen freeze, and it matters more here than on
Linux. The LPSS I2C controller's clock is gated in deep package C-states,
which stalls the bus the touch controller is on. The symptom is a touchscreen
that stops responding until reset.

```
intel_idle.max_cstate=1
```

On Android there is no userspace watchdog as there is in the Linux image
(`touchscreen-watchdog.service` re-binds the device). If the bus wedges, the
only recovery is a reboot. Pinning the C-state costs idle power and buys a
working touchscreen; on a mains-or-light-use tablet that is the right trade.

**Verify:** `grep . /sys/devices/system/cpu/cpu*/cpuidle/state*/usage` over
30 minutes of idling — states above C1 should show no growth.

### 3.2 Governor: schedutil

`CONFIG_CPU_FREQ_GOV_SCHEDUTIL=y`, set as default. Silvermont has no turbo
and a narrow frequency range (1.33–1.83 GHz), so the governor mostly decides
how fast it ramps. `performance` burns power for little gain; `powersave`
makes the UI feel sluggish because ramp-up lags the touch event.
`schedutil` uses the scheduler's own utilization signal and is the right
default — the same choice the Linux image made.

### 3.3 Scheduler: keep CFS

Android's EAS and UCLAMP tuning target heterogeneous SoCs (big.LITTLE).
Z3735F has four identical Silvermont cores. EAS will not help and the extra
hint plumbing is overhead. Leave the default scheduler alone.

### 3.4 `mitigations=off`, with eyes open

The Linux image runs `mitigations=off` for a documented 20–40% syscall win on
Silvermont. The same trade applies. **But** the calculus is different on
Android: apps are sandboxed by design and you will be installing third-party
APKs, which is closer to "running untrusted code" than a personal desktop is.
Recommendation: keep `mitigations=off` while bringing the system up (it makes
the difference very visible in how responsive the UI is), and revisit before
daily use with sideloaded apps. This is a judgement call, not a free win, and
it should be recorded as a deliberate choice rather than inherited silently.

### 3.5 THP off, `nowatchdog`

`transparent_hugepage=never` and `nowatchdog` — both carried from the Linux
image, both still correct. Watchdog timers on a device with no lockup
detection path just cost a timer tick.

---

## 4. Storage and I/O

### 4.1 I/O scheduler: measure, do not assume

The Linux image chose **BFQ** for the eMMC, which favours latency fairness.
Android's own default is **mq-deadline**. These trade throughput for tail
latency in opposite ways. On eMMC, which has poor random-write behaviour,
BFQ's fairness can genuinely improve UI responsiveness under write load —
but it also costs throughput.

Set it per device and measure with `fio` random 4K reads while scrolling:

```bash
echo bfq > /sys/block/mmcblk0/queue/scheduler
```

Do not assume BFQ wins because it won on the Linux side. The Android I/O
pattern (many small concurrent writers) differs.

### 4.2 Trim

```bash
fstrim -v /data
```
Schedule weekly. eMMC needs it to keep write latency from degrading, and
Android does not always do it on a device without a battery/charging cycle
heuristic. Same reasoning as the Linux image's `fstrim`.

### 4.3 eMMC wear

No scripted monitoring exists in either image. Worth checking occasionally:
```bash
cat /sys/block/mmcblk0/device/life_time
```
Values are in 10% bands. This tablet is from ~2014; if it reads `0x02` or
higher, avoid write-heavy workloads (swap should be zram, never this disk).

### 4.4 `data=writeback` — no

Do not mount `/data` with `data=writeback` to gain throughput. On a device
where the failure mode is filesystem corruption with no recovery media on
hand, the throughput is not worth it.

---

## 5. Power and thermal

- **No thermal daemon needed** at 2.2 W SDP, but do not stack workloads
  during bring-up: a hot Silvermont throttles to its base clock quickly and
  you will misattribute the slowdown to your config.
- **Wi-Fi powersave off** — `iw dev wlan0 set power_save off`, and the
  NetworkManager setting from the Linux image. RTL8723BS powersave causes
  multi-second stalls; this is the same driver, same fix.
- **Suspend/resume**: the Linux image has a resume hook to re-initialise the
  touch controller. Android's equivalent needs the same re-init in a
  `late_resume` path, or the touchscreen will be dead after the first suspend.
  This is a known-hard area on Bay Trail and should be treated as a
  first-class bring-up task, not a detail.

---

## 6. Things that look like optimizations and are not

| Trick | Why it is wrong here |
|---|---|
| `vm.swappiness=10` | Correct for disk swap, wrong for zram. Kills your memory savings. |
| Raise BufferQueue to 4 buffers | Adds latency and ~4 MB/surface. Already triple-buffered. |
| `vm.overcommit_memory=1` | Fights every other conservative memory setting; invites OOM kills. |
| Force GPU rendering (`debug.hwui.renderer`) | Moves work onto the 4-EU Gen7. Slower. |
| `i915.enable_rc6=0` | Removed from the driver in kernel 4.16. Dead parameter. |
| `video.use_native_backlight=1` | Removed ~4.4. Dead parameter. |
| KSM sysctls (`vm.ksm=1`) | Not real sysctls. KSM lives in `/sys/kernel/mm/ksm/`. |
| Full-screen blur / glass UI | Tens of ms per frame on Gen7. Feels broken, not premium. |
| Stacking zswap + zram | Double compression for no benefit. |
| earlyoom alongside lmkd | Two killers with different opinions; lmkd is better informed. |
| 4 GB zram on 2 GB RAM | Presents more swap than the machine can back; invites thrash. |

The "dead parameter" entries above are not hypothetical — they are documented
mistakes from the earlier GLM-generated guide this project had to correct.
Any config generated by an AI should be checked against
`Documentation/admin-guide/kernel-parameters.txt` for the kernel version in
use, because plausible-sounding parameter names are exactly the failure this
project keeps hitting.

---

## 7. Apply order

1. `intel_idle.max_cstate=1` — without this, nothing else can be measured.
2. zram sized 1:1 with lz4 + swappiness 180.
3. Strip the image; verify idle footprint under ~350 MB.
4. Composition type check — get layers off `CLIENT` composition.
5. Animations and blur off.
6. Governor, THP, Wi-Fi powersave.
7. Only then, micro-tuning.

Each step is independently verifiable with the commands in §0. If a step does
not move its own metric, revert it — an unmeasured optimization that stays in
the config is exactly the dead-parameter problem above, and it will cost
someone a day later.
