# On-device bring-up checklist

Everything that must be verified on the actual Casper Nirvana N220/N240,
because no VM reproduces it. KVM proves the kernel boots; it cannot prove the
touchscreen works, the speakers make sound, or that the panel is the right way
up.

Work top to bottom. Each step has an explicit pass condition, because "it
seemed fine" is how the touchscreen freeze survived several sessions of this
project in the past.

---

## 0. Before flashing

- **Back up the existing install.** Flashing replaces the partition table.
- **Secure Boot off.** Mainline kernels here are unsigned.
- **Know your recovery path.** A USB keyboard plus `Ctrl+Alt+F2` for a console
  if the session does not start. On a device with no other OS, a bad flash
  means re-flashing from scratch.
- **Serial output configured** if you can. On Bay Trail this is the difference
  between a black screen and a diagnosis; see `docs/boot-chain.md`.

## 1. Boot chain (the go/no-go)

| Check | Pass condition |
|---|---|
| Firmware finds the bootloader | Device appears in the boot menu / boots without a USB keyboard |
| Kernel enters | Boot log visible (serial, or pstore afterwards) |
| Android `init` runs | `logcat` produces output |
| Shell starts | The Casper desktop appears instead of a stock launcher |
| No reboot loop | Stays up for 5 minutes |

If the device black-screens here, stop and read `docs/boot-chain.md` §"Android's
init will fail in ways that look like kernel failures". Do not tune anything
until boot works; every later measurement is meaningless otherwise.

## 2. Touchscreen — the project's original bug

This is the single most important hardware check. The failure mode is a
touchscreen that works, then silently stops until reset.

| Check | Pass condition |
|---|---|
| Basic touch | Taps register in the app grid |
| **30+ minutes of use** | No freeze |
| Suspend → resume → touch | Touch works immediately after wake |
| After 10 minutes idle | Touch still works (this is what the C-state bug breaks) |
| Multi-touch | Two-finger gestures register |

Verify the C-state pin actually took effect — this is the fix, and a cmdline
typo leaves you with a fix that is not applied:

```bash
cat /proc/cmdline | tr ' ' '\n' | grep max_cstate
# must show intel_idle.max_cstate=1

# and confirm deep states are not being entered while idle:
for i in 0 1 2 3; do
  echo "state$i: $(cat /sys/devices/system/cpu/cpu0/cpuidle/state$i/usage 2>/dev/null)"
done
```

State 3 usage should barely grow while the device sits idle. If it climbs,
the pin is not in effect and the touch freeze will return.

## 3. Audio — RT5640 on Intel SST

| Check | Pass condition |
|---|---|
| Sound plays | Audible output from the speakers |
| Pause 60 s, then play | **First second is not cut off** (the power-save bug) |
| No 5-second pop | No audible pop when audio starts |
| Volume control exists | Slider moves actual volume |
| Headphones | Switching works |

```bash
# the codec must be bound to the SST machine driver
dmesg | grep -iE 'bytcr|rt5640|sst'
# the PCM must appear
cat /proc/asound/cards
```

If there is no sound but `dmesg` shows the codec probing, the ALSA UCM profile
name mismatch is the likely cause — the kernel reports `bytcrrt5640` (no dash)
while the profile is named `bytcr-rt5640`. That exact bug is documented in the
Linux image's reference doc; Android's HAL may need the same alias.

## 4. Wi-Fi — RTL8723BS

| Check | Pass condition |
|---|---|
| Interface appears | `ip link` shows `wlan0` |
| Associates | Connects to a network |
| **Several hours of use** | No multi-second stalls |
| Signal at range | Usable two rooms away |

```bash
# the driver is a module, so confirm it actually loaded
lsmod | grep rtl8723bs
# powersave must be off — it causes the stalls
iw dev wlan0 get power_save
```

If `wlan0` never appears, `lsmod` will tell you whether the module failed to
load; remember `CONFIG_RTL8723BS` can only ever be `=m`, never `=y`.

## 5. Display and rotation

| Check | Pass condition |
|---|---|
| Orientation | Landscape, not sideways |
| No flicker | Panel stable during scrolling |
| Brightness | Slider works, no abrupt jumps |
| Sleep/wake | Panel returns to the same brightness |

The panel is physically portrait while the device is used landscape. The Linux
image handles this in the compositor config; on Android the equivalent is the
framebuffer/display rotation in the device init. If the boot animation is
sideways but the desktop is correct, the rotation is applied too late — fix it
in the display HAL, not in the shell.

## 6. Performance — measure, do not eyeball

Run these *before* applying tuning, then after, and compare. Without the
baseline, every change is a guess.

```bash
# memory
grep -E 'MemTotal|MemAvailable|SwapTotal|SwapFree' /proc/meminfo
cat /proc/pressure/memory

# zram effectiveness — the number that says whether this is working
awk '{printf "orig=%dKB comp=%dKB ratio=%.2f\n", $1/1024, $2/1024, $1/$2}' \
  /sys/block/zram0/mm_stat

# what is drawing frames: want DEVICE composition, not CLIENT
dumpsys SurfaceFlinger | grep -iE 'composition|hwc' | head -20

# idle footprint
dumpsys meminfo | head -30
```

Targets for this hardware:

| Metric | Target | Why |
|---|---|---|
| Idle RAM | under ~350 MB | Leaves headroom for a browser |
| zram ratio | above ~1.8:1 | Below that, swap is not paying its way |
| Composition | `DEVICE` for most layers | `CLIENT` means the GPU is blitting every frame |
| Animation scales | 0 | Visible stutter otherwise |

Then apply the device tuning:

```bash
sh /system/bin/casper-tune.sh
```

It prints a verification report at the end — read it rather than assuming the
settings took.

## 7. Desktop shell

| Check | Pass condition |
|---|---|
| Replaces the launcher | Home button returns here, not to a stock launcher |
| App grid populates | All installed apps listed |
| App launches | Tapping a tile opens the app |
| **Windowed launch** | Apps open in a freeform window where supported |
| Dock shows recents | Recently used apps appear |
| Clock updates | Correct time, Turkish locale |
| Back on desktop | Does nothing (PC behaviour), does not exit |

The windowed-launch test is the one that decides whether this feels like a PC
or a phone with a weird launcher. If every app opens full-screen, freeform is
not enabled on the build — that is a device-configuration problem, not a shell
bug, and the shell falls back to fullscreen deliberately rather than crashing.

## 8. Suspend / resume — known-hard

| Check | Pass condition |
|---|---|
| Sleep and wake | Resumes |
| Touch after resume | Works (see §2) |
| Audio after resume | Works |
| Wi-Fi after resume | Reconnects without a stall |

Bay Trail resume re-initialisation is a first-class bring-up task, not a
detail. The Linux image needs a resume hook to re-init the touch controller;
expect the same class of problem here.

## 9. eMMC health

This tablet is from ~2014 and the storage is the part most likely to fail
first.

```bash
cat /sys/block/mmcblk0/device/life_time   # 0x01 = 0-10% used, 0x02 = 10-20% ...
```

Two bands higher than when you started means the write load is too high —
check that swap is on zram and not on this disk.

---

## Reporting a failure

State the layer, not the symptom. "It doesn't boot" is not actionable; these
are:

- **Firmware** — no serial output at all
- **Kernel** — kernel messages, then a hang
- **Init** — reboot loop after ~2 s
- **Userspace** — `logcat` runs, no UI
- **Hardware** — boots and runs, one peripheral dead

Each points at a different file in this repo, and conflating them is what turns
a one-hour fix into a week.
