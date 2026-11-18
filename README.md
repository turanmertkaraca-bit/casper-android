# CasperOS Android — architecture and build plan

Android userspace on a Linux kernel, on the Casper Nirvana N220/N240.
Bay Trail Z3735F, 2 GB RAM, **32-bit UEFI on a 64-bit CPU**, Gen7 graphics.

This document is the corrected plan. Read §1 before writing any code — it
contains a finding that changes the project's direction.

---

## 1. Corrections to the plan, with evidence

### 1.1 The Ubuntu 5.15 kernel cannot run Android. It has no binder.

The plan was "use the Ubuntu kernel we ship." I unpacked the exact kernel
this project currently installs and checked:

```
linux-modules-5.15.165-0515165-generic  →  5,976 modules, 0 matching binder
linux-image-unsigned-5.15.165            →  0 occurrences of "binder" in the image
```

There is no `drivers/android/` directory and no `binder_linux.ko` in that
package at all. Ubuntu's own kernel annotations mark
`CONFIG_ANDROID_BINDER_IPC` as a module for their *distro* kernel, but the
mainline builds this project pulls from `kernel.ubuntu.com` are configured
without it.

Android cannot boot without binder. `init` uses it for the very first
property-service handshake, before any app or zygote exists. So this is not
a "load a module later" problem — it is a kernel-rebuild problem, and it is
step zero.

For contrast, I checked the Debian 6.12 kernel (this project's *default*
boot kernel):

```
6.12.107+deb13-amd64 → kernel/drivers/android/binder_linux.ko.xz   ✓ present
debian/config/amd64  → CONFIG_ANDROID_BINDER_IPC=m                 ✓
                       CONFIG_EFI_MIXED=y                           ✓
```

So **Debian 6.12 is already much closer to being Android-capable than the
Ubuntu 5.15 you were planning to use.** It has binder and mixed-mode EFI.

**Decision: build our own kernel.** Do not use the Ubuntu 5.15 for Android.
It is the wrong base and no amount of configuration fixes a driver that was
never compiled.

### 1.2 "Bare minimum Android core from scratch" is not buildable here

AOSP needs roughly 200 GB of disk and 16–32 GB of RAM, and takes 4–8 hours
even on a fast machine. This development environment is an Android phone
`proot`; GitHub Actions gives ~14 GB free disk and 4 cores. Neither can
build AOSP, and no amount of tuning changes that.

What *is* reachable:

| Approach | Buildable here? | Result |
|---|---|---|
| Full AOSP build | No | — |
| Repack a prebuilt Android x86_64 image | **Yes** | Android booting, our kernel, our shell |
| Waydroid (container on a Linux host) | **Yes** | Android apps, Linux desktop stays |
| Write our own launcher/shell as an APK | **Yes** | The desktop UI you actually asked for |

So "from scratch" becomes: **take a minimal prebuilt Android (LineageOS-based,
no GApps), replace the kernel and boot chain with ours, strip it, and replace
the shell with one we write.** That is a real, achievable project. Writing
the Android framework itself is not.

### 1.3 GNOME: the shell cannot be ported, but the GTK situation changed

This deserves an update from my earlier answer, because GTK 4.18 (Feb 2025)
added an official **Android backend**. So "port GTK" is no longer impossible.

Two things still block the literal request:

- **GNOME Shell is not a GTK app.** It is `gnome-shell` on top of **mutter**,
  a full compositor that owns DRM/KMS and the Wayland stack. Android already
  has a compositor (SurfaceFlinger) with a different window model. Porting the
  shell means replacing SurfaceFlinger — which breaks Android app support,
  i.e. the entire premise.
- **GTK's Android backend has no GL renderer yet** (the GTK team's own words),
  so it draws via Vulkan. **Gen7 Vulkan is incomplete** — Intel split it into
  the unmaintained `hasvk` driver — so GTK apps would fall back to **software
  rendering**. On a 1.33 GHz Silvermont that is *more* CPU per frame than the
  native UI, directly contradicting the goal of using less processing power.

So this project builds a **native Android desktop shell** instead: GNOME's
interaction model (panel, activities, app grid, dock, windowed apps) on top of
Android's own hardware-composited surfaces. Full reasoning, evidence and the
path to real GTK later: **[`docs/gnome-port.md`](docs/gnome-port.md)**.

### 1.4 "Triple buffering" is not a switch you flip for speed

Android's BufferQueue is already triple-buffered by default. Setting it to
four buffers adds latency and RAM, and on 2 GB that is negative-value. The
real Gen7 wins are elsewhere and are covered in `docs/optimizations.md`:
disable compositor animations, reduce buffer count under memory pressure,
avoid client (GPU) composition where a hardware overlay is possible, and keep
the GPU out of the frame path entirely when nothing is moving.

---

## 2. The target architecture

```
 32-bit UEFI firmware
        │
        ▼
 BOOTIA32.EFI  ── GRUB ia32 (32-bit)            ← firmware can only load this
        │
        │  loads a 64-bit kernel + Android initramfs
        ▼
 vmlinuz 6.12 (x86_64, CONFIG_EFI_MIXED=y)      ← the CPU is 64-bit; only
        │                                          the firmware is 32-bit
        ▼
 Android init  ── /system, /data, binderfs
        │
        ▼
 SurfaceFlinger (desktop windowing)  +  our GNOME-style shell APK
        │
        ▼
 Android apps only  (x86_64 native + ARM via native-bridge if needed)
```

Two things carry over unchanged from CasperOS, and they are the parts that
were hardest to get right:

- **32-bit GRUB → 64-bit kernel.** `CONFIG_EFI_MIXED=y` is what makes this
  work, and Debian's amd64 config already sets it.
- **Bay Trail kernel parameters** — `intel_idle.max_cstate=1` above all. This
  is the fix for the LPSS I2C clock gating that freezes the touch controller.
  It matters *more* under Android, because a wedged touch bus with no
  watchdog is indistinguishable from a hung system.

### Why the touch lag you saw on BlissOS is not evidence Android is unusable

BlissOS ships a generic x86_64 kernel with a generic GPU path. On Gen7 it
lands on `i915` with compositing and animations on, no `max_cstate` pin, and
a compositor drawing every frame on a 4-EU GPU. That is a configuration
failure, not an Android limitation. The fixes are exactly the ones this
project already made for Linux, applied to an Android boot — see
`docs/optimizations.md`.

---

## 3. Build order

Each step is independently verifiable. Do not skip ahead: step 2 either works
or the project is not viable, and you want to know that in a day, not a month.

### Step 0 — kernel (this repo, `kernel/`)

Build a Bay Trail kernel with binder built in, `EFI_MIXED`, zram/zswap,
BFQ, and the full set of Gen7 + Bay Trail drivers. Verified by: kernel boots
in QEMU under 32-bit OVMF, `binderfs` mounts, `zram0` appears.

### Step 1 — prove 32-bit UEFI → Android at all

This is the go/no-go. Take any Android x86_64 image, add `BOOTIA32.EFI`
chainloading our kernel + the image's ramdisk, and boot it in QEMU with
32-bit OVMF. Success criterion: `logcat` produces output.

If this fails, the project is not viable and we stop — cheaply. Do not build
the shell before this works.

### Step 2 — strip the Android image

Remove Google services, unused system apps, telephony, and the vendor bloat
that a 2 GB device cannot afford. Target: idle system under ~350 MB.

### Step 3 — the shell

A GNOME-shaped launcher APK: top panel, dock, app grid, window controls on
native desktop windowing. Built with the no-Gradle toolchain already proven
in this workspace (`android-app/build.sh` — aapt2 + javac + d8 + zipalign +
apksigner, no Gradle required). That toolchain is a real asset here: it
builds installable APKs in a constrained environment.

**This step is done** — see `shell/`. It builds to a signed ~21 KB APK and
declares `CATEGORY_HOME`, so it can replace the launcher. What is *not* done
is running it on a device: this environment has no emulator and no attached
tablet, so it is compile-verified and manifest-verified only.

### Step 4 — optimization layer

Apply `docs/optimizations.md`, then tune against measurements.

---

## 4. What I need from you to continue

The base image choice determines everything downstream. See the question at
the end of this session. My recommendation is a **LineageOS-based x86_64
image without GApps**, because it is the lightest base that still supports
native desktop windowing, and it needs no Google services that a 2 GB device
cannot run anyway.
