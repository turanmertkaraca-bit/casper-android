# Boot chain: 32-bit UEFI → 64-bit kernel → Android

This is the part that decides whether the project is possible at all.
It is **not** the same problem as booting Linux, and the difference is worth
stating precisely, because the Linux image's success here does not transfer
for free.

---

## The constraint

| Component | Width | Why |
|---|---|---|
| UEFI firmware | **32-bit (IA32)** | Bay Trail OEMs shipped an IA32 UEFI to save licensing cost |
| CPU | **64-bit (x86_64)** | Silvermont supports long mode |
| GRUB EFI binary | **32-bit (`i386-efi`)** | The firmware can only execute IA32 EFI applications |
| Kernel | **64-bit (x86_64)** | Android x86_64 userspace requires it |
| Android userspace | **64-bit** | `system_server`, zygote, all apps |

The Linux image already solves firmware→kernel. The extra Android-specific
steps are: the boot image format, the ramdisk contents, and `androidboot.*`
parameters. Each is a place to fail.

---

## Why the Linux image's GRUB setup is necessary but not sufficient

`CONFIG_EFI_MIXED=y` provides the 32→64-bit thunk, and GRUB uses the **EFI
handover protocol** to enter the kernel. That part carries over unchanged,
and Debian's amd64 config already sets `EFI_MIXED=y` (verified).

Three caveats, in order of how likely they are to bite:

### 1. EFI_MIXED cannot be entered through the EFI stub

The kernel's own EFI stub (`CONFIG_EFI_STUB`) cannot start a mixed-mode
kernel. Something else must do the handover. GRUB does it correctly. **This
means you cannot just point a `BOOTX64.EFI`-style direct kernel entry at it**,
and it means any bootloader that bypasses handover will hang with no output.

Consequence: the 32-bit `BOOTIA32.EFI` must be the thing that loads the
kernel. You cannot have `BOOTX64.EFI` do it — the firmware will not run it.

### 2. Android kernels are normally booted as a *boot image*, not a bare bzImage

Android's boot flow is `boot.img` = kernel + ramdisk + cmdline + (optionally)
a second stage. GRUB loading a bare `bzImage` skips the ramdisk convention
that `init` expects. There are two workable routes:

- **Unpack the boot image** and have GRUB load `kernel` + `initrd` directly,
  passing the cmdline as kernel arguments. Simplest, and it is what
  Android-x86 does.
- **Add a second-stage loader** that parses `boot.img` and enters the kernel
  with the right cmdline.

Route 1 is recommended for bring-up: fewer moving parts, and the cmdline is
visible in the GRUB entry for debugging.

### 3. Android's `init` will fail in ways that look like kernel failures

Before blaming the kernel, distinguish these:

| Symptom | Usually means |
|---|---|
| No serial output at all after GRUB | Kernel did not enter — handover/mixed-mode problem |
| Kernel boot messages, then hangs | `init` could not find `/system` or the ramdisk is wrong |
| Reboot loop after ~2 s | `init` started, failed a property/`binder` step, watchdog rebooted |
| `logcat` works but no UI | SurfaceFlinger/zygote failed — userspace, not boot |

Getting **serial console output** is the single highest-value debugging
investment. On this hardware, configure `earlycon` + `console=ttyS0` (or the
Bay Trail HSUART) and capture it. Without it, a failed boot is a black screen
and you are guessing.

---

## Cmdline

Baseline, carried from the Linux image where still relevant:

```
console=ttyS0,115200 earlycon
intel_idle.max_cstate=1
i915.enable_psr=0 i915.enable_dc=0 i915.enable_fbc=0
androidboot.hardware=casper
androidboot.selinux=permissive
```

Notes:

- `androidboot.hardware=casper` selects `init.casper.rc` from the ramdisk.
  If this does not match a real file, `init` fails early and the symptom is a
  reboot loop, not a clear error.
- `androidboot.selinux=permissive` during bring-up only. Tighten before
  daily use, and remember that a permissive boot can mask a policy bug that
  becomes a boot failure the moment you switch to enforcing.
- **Do not** copy `mitigations=off` etc. blindly into this cmdline. Those are
  Linux-image decisions with their own trade-offs (see
  `docs/optimizations.md` §3.4); make the choice deliberately.
- The Linux image's audio parameters (`snd_intel_dspcfg.dsp_driver=2`,
  `snd_hda_intel.*`) were tuned for PipeWire's behaviour. Android's audio HAL
  is different; carry them over only if the RT5640 actually fails without
  them, and verify with `dmesg | grep -i bytcr`.

---

## Go / no-go test

`boot-test.sh` boots the built kernel + a ramdisk under 32-bit OVMF and
reports whether the chain works. Success criterion is deliberately narrow:
**`logcat` produces output.** That single fact proves firmware → GRUB →
64-bit kernel → Android userspace all work.

Do not proceed past this step until it passes.
