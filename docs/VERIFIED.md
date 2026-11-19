# Verified results

Everything in this file was measured in CI on this repo, not estimated. Each
entry names the exact evidence. Anything not listed here is unverified and is
called out as such in `README.md` and `docs/on-device.md`.

Run: workflow `casper-android`, job "Base image is 32-bit-UEFI compatible".

---

## 1. The core question: can 32-bit UEFI boot Android on this hardware?

**Yes. Proven end to end.**

The tablet's firmware is IA32-only while its CPU is x86_64. That combination is
why the Debian image needed its own `BOOTIA32.EFI` chainloader, and it was the
single biggest unknown for this project.

From the ISO's own kernel header (`test/check-iso.sh`):

```
volume id: Android-x86 9.0-r2 (x86_64)
kernel: 7511040 bytes
boot protocol: 2.13
xloadflags: 0x001f
  SET    XLF_KERNEL_64            (kernel is 64-bit)
  SET    XLF_CAN_BE_LOADED_ABOVE_4G
  SET    XLF_EFI_HANDOVER_32     (32-bit EFI handover entry point)
  SET    XLF_EFI_HANDOVER_64     (64-bit EFI handover entry point)
  SET    XLF_EFI_KEXEC
kernel_version: 4.19.110-android-x86_64-g066cc1d
```

`XLF_EFI_HANDOVER_32` is only set when `CONFIG_EFI_MIXED` is compiled in. The
ISO also ships `/efi/boot/bootia32.efi` (668,160 bytes) and its GRUB config
selects `grubia32` when `$grub_cpu = i386`.

Then it was actually booted, under IA32 OVMF firmware verified to contain i386
PE code (`0x14c`), and it ran all the way into Android:

| Milestone | Evidence from serial |
|---|---|
| Firmware executed the loader | `BdsDxe: starting Boot0001 ... QEMU DVD-ROM` |
| 64-bit kernel entered from 32-bit firmware | `[0.000000] Linux version 4.19.110-android-x86_64-g066cc1d` |
| cmdline accepted | `Command line: BOOT_IMAGE=/kernel ... console=ttyS0,115200` |
| Android `init` first stage | `init: init first stage started!` |
| SELinux policy loaded | `selinux: SELinux: Loaded policy from /sepolicy` |
| Android `init` second stage | `init: init second stage started!` |
| **`servicemanager`** | `init: Received control message ... from pid: 1008 (/system/bin/hwservicemanager)` |
| **`zygote`** | `scontext=u:r:zygote:s0` (pid 1073) |
| **`system_server`** | `scontext=u:r:system_server:s0` (pid 1088) |
| **`surfaceflinger`** | `comm="surfaceflinger"` (pid 1114) driving `/dev/tty0` |
| **`bootanim`** | 4 occurrences |
| `dex2oat` compiling | `scontext=u:r:dex2oat:s0` (pid 1298) |
| `installd`, `vold`, `logd` | 17 / 2 / 11 occurrences |

Serial log: 62,499 bytes. Boot reached 86+ seconds of Android userspace.

**Conclusion: the platform is viable.** Android boots on this tablet's
firmware. The remaining risks are hardware drivers (touch, audio, Wi-Fi),
which is what `docs/on-device.md` exists to check.

## 2. Our own kernel builds correctly

Job "Kernel config (symbols resolve in 6.12)", every push:

- all 77 config symbols resolve through `olddefconfig` against real 6.12
- `bzImage` reports **both** `32-bit EFI handoff entry point` and
  `64-bit EFI handoff entry point` → mixed mode active
- `LD [M] drivers/staging/rtl8723bs/r8723bs.ko` → Wi-Fi driver built
- artifacts: `bzImage`, `.config`, `r8723bs.ko` (~14 MB)

Asserted post-resolution (a silently-dropped symbol fails the build):

| Symbol | Why it matters |
|---|---|
| `CONFIG_ANDROID_BINDER_IPC=y` | Android cannot start without binder |
| `CONFIG_ANDROID_BINDERFS=y` | per-IPC-namespace binder devices |
| `CONFIG_PSI=y` | lmkd is PSI-driven; without it the killer reacts late |
| `CONFIG_EFI_MIXED=y` | the 32→64-bit thunk, mandatory on this firmware |
| `CONFIG_ZRAM=y` | the main memory feature on 2 GB |
| `CONFIG_SECURITY_SELINUX=y` | Android policy |
| `CONFIG_SND_SOC_INTEL_BYTCR_RT5640_MACH=y` | audio on this tablet |
| `CONFIG_RTL8723BS=m` | Wi-Fi — **module only**, `=y` is impossible |
| `CONFIG_CFG80211=m`, `CONFIG_WLAN=y` | its dependencies |
| `CONFIG_DRM_I915=y` | Gen7 graphics |

## 3. The desktop shell builds and is installable

Job "Desktop shell APK":

- builds to a signed APK (~21 KB)
- `apksigner verify` passes
- declares `android.intent.category.HOME` → it can replace the launcher
- artifact: `casper-desktop-apk`

## 4. Bugs found by verification, and corrected

These are the concrete value of automating the checks. Each would have cost
hours of debugging on the tablet, and several would have looked like hardware
faults.

| Bug | How it would have presented |
|---|---|
| `CONFIG_GPIO_LYNXPOINT`, `CONFIG_MEMCG_SWAP`, `CONFIG_ANDROID` invented | Silently dropped; config looks right, feature absent |
| `CONFIG_RTL8723BS=y` (impossible: `depends on m`) | Kernel builds, **no Wi-Fi**, on a device with no Ethernet |
| Module named `r8723bs.ko`, not `rtl8723bs.ko` | Verification looked for a file that never exists |
| `ZRAM_DEF_COMP_ZSTD` choice-group conflict | Config fails or picks the wrong compressor |
| `SECURITY_SELINUX` deps on `AUDIT`/`NET`/`INET` missing | SELinux silently off; init then fails looking like a binder bug |
| GCC 15 C23 `bool` breaks 6.12 EFI stub | Kernel will not build on a modern toolchain |
| `-Werror=unterminated-string-initialization` in ACPI | Kernel will not build on a modern toolchain |
| bzImage checked with `file \| grep x86-64` | Fails a perfectly good kernel (bzImage is not ELF) |
| secboot IA32 OVMF without `smm=on` | `IA32 Exception 06 (#UD)` at the reset vector |
| ISO dir-record size not updated after patch | GRUB reads NUL padding → config parse fails → "won't boot" |

## 5. A methodology error worth recording

An earlier run of this harness reported:

> "RESULT: the 32-bit UEFI handoff into the Android kernel WORKS."

That conclusion was **wrong**. It was drawn from a dark frame with white text,
which pixel statistics classified as "kernel console". Rendering that frame as
ASCII showed it read **"Android-x86 9.0-r2"** — it was GRUB's menu with a dark
theme.

The lesson is baked into the tooling: **pixels can only prove that a loader
rendered.** A kernel claim now requires `Linux version` in serial output, and
if serial is silent the best verdict is "loader only" (exit 3). That is why
`test/patch-iso-serial.py` exists — to add `console=ttyS0` so the kernel can
actually be heard.

## 6. Not verified, and why

| Item | Blocker |
|---|---|
| Touchscreen over 30+ min and across suspend | needs the tablet |
| RT5640 audio (first-second, no pop) | needs the tablet |
| RTL8723BS stability | needs the tablet |
| Panel rotation / brightness | needs the tablet |
| Shell running on a device | no emulator or tablet in this environment |
| Our 6.12 kernel inside the Android image | Android-x86 9.0 userspace is built for 4.19; swapping kernels needs matching modules |

`docs/on-device.md` gives a pass condition for each hardware item.
