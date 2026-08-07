#!/usr/bin/env bash
# Native CPU profile of nitro_camera on a connected Android device, via the
# NDK's simpleperf.
#
# Why simpleperf and not the RSS/jank signals we already sample: this is the
# only tool that attributes CPU time to actual native FUNCTIONS across
# libnitro_camera.so, the GL driver, libcamera2ndk and the Flutter engine, with
# call stacks. Everything else tells you THAT something is slow, not WHERE.
#
# Usage:
#   tool/android_simpleperf.sh <serial> [seconds] [out_dir]
#
# It ATTACHES to an already-running app rather than launching one, because the
# camera has to be live and permission-granted for the profile to mean
# anything. The reliable way to get there on a permission-restricted device
# (ColorOS refuses `pm grant`) is to let a Patrol test drive the app and attach
# while it runs:
#
#   # terminal 1 — drives a real recording workload, grants permissions natively
#   patrol test --target patrol_test/combo/record_cycles_test.dart -d <serial>
#   # terminal 2 — once the preview is up
#   tool/android_simpleperf.sh <serial> 25
#
# Requires a debuggable or profileable build (flutter debug/profile both work).

set -uo pipefail

SERIAL="${1:?usage: android_simpleperf.sh <serial> [seconds] [out_dir]}"
SECONDS_TO_RECORD="${2:-20}"
OUT_DIR="${3:-build/simpleperf}"

PKG="dev.shreeman.nitro_camera_example"
NDK="${ANDROID_NDK_HOME:-$HOME/Library/Android/sdk/ndk/27.0.12077973}"
SP="$NDK/simpleperf"
# Unstripped .so tree — without this every nitro_camera frame reports as a raw
# address. Profile and debug variants both keep symbols; prefer profile.
SYMS="example/build/app/intermediates/merged_native_libs/profile/mergeProfileNativeLibs/out/lib"
[ -d "$SYMS" ] || SYMS="example/build/app/intermediates/merged_native_libs/debug/mergeDebugNativeLibs/out/lib"

[ -d "$SP" ] || { echo "simpleperf not found at $SP (set ANDROID_NDK_HOME)"; exit 1; }

PID="$(adb -s "$SERIAL" shell pidof "$PKG" 2>/dev/null | tr -d '\r' | awk '{print $1}')"
[ -n "$PID" ] || { echo "$PKG is not running — start it (or a Patrol test) first"; exit 1; }

mkdir -p "$OUT_DIR"
DATA="$OUT_DIR/perf.data"

echo "== simpleperf =="
echo "device  : $SERIAL"
echo "package : $PKG (pid $PID)"
echo "symbols : $SYMS"
echo "duration: ${SECONDS_TO_RECORD}s"
echo

# cpu-clock rather than the default cpu-cycles: cpu-clock is a software event,
# so it works on devices whose kernels gate the PMU from userspace (most
# consumer phones, this OnePlus included). -g captures call graphs via dwarf
# fallback; 1 kHz is plenty of samples for a 20s window without distorting the
# workload.
ADB_SERIAL="$SERIAL" python3 "$SP/app_profiler.py" \
  -p "$PKG" \
  --ndk_path "$NDK" \
  -lib "$SYMS" \
  -o "$DATA" \
  -r "-e cpu-clock -f 1000 -g --duration $SECONDS_TO_RECORD" || {
    echo "record failed"; exit 1;
  }

echo
echo "== top symbols by self time =="
python3 "$SP/report.py" -i "$DATA" --sort dso,symbol -n 2>/dev/null | head -45

echo
echo "== nitro_camera only =="
python3 "$SP/report.py" -i "$DATA" --sort symbol --dsos libnitro_camera.so -n 2>/dev/null | head -30

echo
echo "== per-thread breakdown =="
python3 "$SP/report.py" -i "$DATA" --sort thread -n 2>/dev/null | head -20

# A folded stack file feeds any flamegraph renderer and is far easier to diff
# between a before and an after run than the textual report.
python3 "$SP/stackcollapse.py" -i "$DATA" --kernel-only=no > "$OUT_DIR/folded.txt" 2>/dev/null \
  && echo && echo "folded stacks -> $OUT_DIR/folded.txt ($(wc -l < "$OUT_DIR/folded.txt") stacks)"

echo "perf.data -> $DATA"
