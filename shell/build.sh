#!/bin/sh
# Build the Casper Desktop shell APK with the Android SDK build-tools only.
# No Gradle: this environment cannot run it (no network for the distribution,
# and daemon memory is more than the box has to spare). aapt2 + javac + d8 +
# zipalign + apksigner is a complete, sufficient pipeline for an app with no
# dependencies, and it is fast.
#
# Usage: ./build.sh
# Output: build/casper-desktop.apk
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
SDK="${ANDROID_HOME:-/opt/android-sdk}"
PLATFORM="$SDK/platforms/android-34/android.jar"
BT=""
for v in 35.0.0 34.0.0; do
    [ -d "$SDK/build-tools/$v" ] && { BT="$SDK/build-tools/$v"; break; }
done
[ -n "$BT" ] || { echo "ERROR: no Android build-tools found under $SDK" >&2; exit 1; }
[ -f "$PLATFORM" ] || { echo "ERROR: missing $PLATFORM" >&2; exit 1; }

APP="$HERE/app/src/main"
OUT="$HERE/build"

# Java on this host is aarch64; aapt2/zipalign/apksigner ship x86_64 binaries.
# The existing project wraps them with qemu-user and so do we, falling back to
# the real binary when the host is x86_64.
if [ "$(uname -m)" = "x86_64" ]; then
    AAPT2="$BT/aapt2"; ZIPALIGN="$BT/zipalign"; APKSIGNER="$BT/apksigner"
else
    AAPT2="$HERE/tools/aapt2"; ZIPALIGN="$HERE/tools/zipalign"; APKSIGNER="$HERE/tools/apksigner"
    for t in aapt2 zipalign apksigner; do
        [ -x "$HERE/tools/$t" ] || { echo "ERROR: missing tools/$t wrapper" >&2; exit 1; }
    done
fi

rm -rf "$OUT"
mkdir -p "$OUT/compiled" "$OUT/gen" "$OUT/classes" "$OUT/dex"

echo "==> 1/6 aapt2 compile (resources)"
find "$APP/res" -type f > "$OUT/resfiles.txt"
"$AAPT2" compile -o "$OUT/compiled" $(cat "$OUT/resfiles.txt")

echo "==> 2/6 aapt2 link (resources + manifest)"
"$AAPT2" link \
  -I "$PLATFORM" \
  --manifest "$APP/AndroidManifest.xml" \
  --java "$OUT/gen" \
  --min-sdk-version 26 \
  --target-sdk-version 34 \
  --version-code 1 \
  --version-name 0.1 \
  -o "$OUT/base.apk" \
  "$OUT"/compiled/*.flat

echo "==> 3/6 javac"
find "$APP/java" "$OUT/gen" -name '*.java' > "$OUT/sources.txt"
# Memory limits are deliberate: this host has ~2 GB free and the JVM will
# otherwise try to reserve 1 GB of compressed class space and fail to start.
javac -J-Xmx256m -J-XX:MaxMetaspaceSize=96m -J-XX:CompressedClassSpaceSize=32m \
      -J-XX:+UseSerialGC \
      -source 8 -target 8 \
      -bootclasspath "$PLATFORM" \
      -classpath "$PLATFORM" \
      -d "$OUT/classes" \
      @"$OUT/sources.txt" 2>&1 | grep -v 'bootstrap class path' || true

# javac failures must fail the build. The grep above hides only the harmless
# bootstrap warning, so check that class files were actually produced.
find "$OUT/classes" -name '*.class' | grep -q . || {
    echo "ERROR: compilation produced no classes" >&2; exit 1; }

echo "==> 4/6 d8 (dex)"
find "$OUT/classes" -name '*.class' > "$OUT/classes.txt"
"$BT/d8" -JXmx256m -JXX:MaxMetaspaceSize=96m -JXX:CompressedClassSpaceSize=32m \
  -JXX:+UseSerialGC \
  --release --min-api 26 --lib "$PLATFORM" \
  --output "$OUT/dex" @"$OUT/classes.txt"

echo "==> 5/6 package + align"
cd "$OUT/dex"
zip -q "$OUT/base.apk" classes.dex
cd "$HERE"
"$ZIPALIGN" -f 4 "$OUT/base.apk" "$OUT/aligned.apk"

echo "==> 6/6 sign"
KS="$HERE/keystore.jks"
# keytool and apksigner are JVM tools too. On this host the JVM's default
# 1 GB compressed-class-space reservation fails to initialise outright, so the
# limits must be exported rather than passed per-invocation (apksigner is a
# wrapper script and would not forward them).
export JAVA_TOOL_OPTIONS="-Xmx256m -XX:MaxMetaspaceSize=96m -XX:CompressedClassSpaceSize=32m -XX:+UseSerialGC"
if [ ! -f "$KS" ]; then
    echo "    generating debug keystore"
    keytool -genkeypair -keystore "$KS" -storepass casper -keypass casper \
        -alias casper -keyalg RSA -keysize 2048 -validity 3650 \
        -dname "CN=Casper Desktop, O=CasperOS, C=TR" 2>&1 | grep -vi 'picked up' || true
    [ -f "$KS" ] || { echo "ERROR: keytool failed to create $KS" >&2; exit 1; }
fi
"$APKSIGNER" sign --ks "$KS" --ks-pass pass:casper --key-pass pass:casper \
    --ks-key-alias casper \
    --out "$OUT/casper-desktop.apk" "$OUT/aligned.apk"

"$APKSIGNER" verify "$OUT/casper-desktop.apk" >/dev/null 2>&1 \
    && echo "    signature verified" \
    || { echo "ERROR: APK signature verification failed" >&2; exit 1; }

echo "==> done: $OUT/casper-desktop.apk ($(stat -c %s "$OUT/casper-desktop.apk") bytes)"
