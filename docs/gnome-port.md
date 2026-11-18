# Can GNOME be ported to Android? The honest answer

You asked this three times, so here is the real answer with current facts,
not a restatement of "it's impossible."

**Short version:** GNOME *Shell* cannot be ported. GTK — the toolkit GNOME is
built on — **can** now run on Android, as of GTK 4.18 (Feb 2025). But on this
specific GPU it would be software-rendered and slower than what you have now.
So the desktop in this repo is written natively instead, and deliberately looks
GNOME-like.

---

## 1. What changed recently (and why my earlier answer was too absolute)

I previously said "no port, bionic and glibc are incompatible." That is still
true for *linking glibc binaries*, but GTK took a different route: it added a
real **`gdk-android` backend** in GTK 4.18, implementing the GDK abstraction
over Android surfaces and input via JNI. So GTK applications genuinely do
compile and run on Android now.

That means "port GTK" is no longer the blocker. Two other things are.

## 2. Blocker A: GNOME Shell is not a GTK app

This is the part that kills the literal request. GNOME Shell is:

| Piece | What it needs | Available on Android? |
|---|---|---|
| `mutter` (compositor/WM) | DRM/KMS, EGL, libinput, Wayland protocol stack | **No.** Android's display server is SurfaceFlinger with its own window model. Mutter's whole job is to *be* the compositor; on Android that role is already filled, by something with a completely different architecture. |
| `gnome-shell` | Clutter/GObject stack on top of mutter | No — depends on mutter |
| `gjs` / extensions | SpiderMonkey + glibc-oriented ABI | Partially buildable, pointless without the shell |

So porting GNOME Shell means **replacing Android's window management and
display server with mutter** — i.e. not running Android apps properly anymore,
which defeats the entire premise ("only runs Android apps").

This is not a "hard but doable" problem. It is the wrong layer: you would be
swapping out the thing that makes Android apps work.

## 3. Blocker B: GTK on Android has no GL renderer yet, and Gen7 Vulkan is broken

From the GTK team's own 4.18 announcement:

> "We have an Android backend now. It is still experimental, so you should
> expect some rough edges and loose ends. **For example, there is no GL
> renderer support yet.**"

GTK 4.18's Android backend draws through **Vulkan** (with software fallback).
Now the hardware:

- **Gen7 (Bay Trail) Vulkan support is incomplete.** Intel split Gen7/Gen8
  Vulkan off into a legacy `hasvk` driver precisely because those paths are
  "never formally compliant" and "rarely touched". Mesa ships it, but various
  apps report it as broken or falling back.
- Gen7's *OpenGL* driver is **crocus**, which works fine — but GTK's Android
  backend does not use it yet, because there is no GL renderer.
- The result: GTK apps on this tablet would land on the **software renderer**
  (Cairo/CPU). On a 1.33 GHz Silvermont with 4 EUs sitting idle, that is
  strictly worse than the native Android UI, which is hardware-composited.

That directly contradicts your stated goal: *"make it less processing power
intensive."* GTK-on-Android here would be **more** CPU per frame, not less.

## 4. So what did I build instead

A **native Android desktop shell** (`shell/`, ~20 KB APK) that reproduces the
GNOME *interaction model* on top of Android's own compositor:

| GNOME thing | How the shell does it |
|---|---|
| Top panel with Activities | `LinearLayout` panel: Activities button, window title, clock |
| Overview / app grid | Full-screen overlay populated from `queryIntentActivities` |
| Dock | Recent/pinned apps, persisted in SharedPreferences |
| Windowed apps | `ActivityOptions.setLaunchBounds` → **freeform windows**, so several apps share the screen like a PC |
| Click desktop to dismiss | Panel/desktop tap handlers |
| Super key behaviour | Back on desktop is swallowed (PC behaviour, not "exit home") |

Why this is the right call on this hardware:

- **Hardware composited.** Every surface is an opaque quad — the cheapest thing
  Gen7 can draw. No blur, no shadows, no ripple animations (all deliberately
  removed; see `docs/optimizations.md` §2).
- **No runtime, no GTK, no gjs.** ~20 KB APK versus tens of MB of GTK stack
  plus a JS interpreter. On 2 GB of RAM, that difference is the whole point.
- **Flat and dark by design.** Flat surfaces composite as opaque quads; soft
  shadows and transparency force blending, which costs fill rate this GPU does
  not have.

## 5. If you still want real GTK apps later

There is a legitimate path, and it is worth recording:

1. **GTK 4.18+ with a working Android GL renderer** — when that lands, GTK apps
   would draw through crocus/GLES, which Gen7 handles well. Revisit then.
2. **Run GTK apps on Linux, not Android** — i.e. the Waydroid-in-reverse
   approach: Linux host runs GTK apps natively with hardware GL; Android apps
   run in a container. On this tablet that is *faster* for both, because it
   avoids the Gen7 Vulkan gap entirely.
3. **Compile GTK apps with `pixiewood`** (sp1ritCS/gtk-android-builder) if you
   want to experiment — but measure frame times before believing it is viable
   here. Expect software rendering.

## 6. Verdict

- Port **GTK apps** to Android: possible now (GTK 4.18), but software-rendered
  on Gen7 → slower than native. Not recommended for this tablet today.
- Port **GNOME Shell**: no. Wrong layer; would replace SurfaceFlinger and break
  Android app support.
- **Build a GNOME-shaped native shell**: done, in `shell/`. This is what
  actually delivers "looks like a Linux PC, runs Android apps, very light."
