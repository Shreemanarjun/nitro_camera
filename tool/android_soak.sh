#!/usr/bin/env bash
# Native leak/perf soak for nitro_camera on a connected Android device.
#
# Cycles the camera through its lifecycle N times and samples the resources the
# Camera2/EGL/MediaRecorder stack is known to leak, so a leak shows up as a
# monotonic slope rather than a one-off reading:
#
#   VmRSS      /proc/<pid>/status     — total resident set
#   Native     dumpsys App Summary    — malloc arena (ImageReader, MediaRecorder)
#   Graphics   dumpsys App Summary    — gralloc surfaces + textures
#   EGL        dumpsys "EGL mtrack"   — EGL driver allocations (displays, surfaces, contexts)
#   fds        /proc/<pid>/fd         — ImageReader/Surface/ashmem handles
#   threads    /proc/<pid>/task       — HandlerThread / coroutine dispatcher leaks
#
# Usage:
#   tool/android_soak.sh <serial> [cycles] [settle_seconds]
#
# Each cycle backgrounds the app (drives CameraSession.onAppStop -> close) and
# foregrounds it (onAppResume -> reopen). That is the exact path that leaks EGL
# displays, HandlerThreads and ImageReader fds when teardown is incomplete.
#
# /proc is only readable through `run-as`, so the target must be a debuggable
# build (flutter debug or profile). dumpsys needs no such privilege.

set -uo pipefail

SERIAL="${1:?usage: android_soak.sh <serial> [cycles] [settle_seconds]}"
CYCLES="${2:-12}"
SETTLE="${3:-3}"
PKG="dev.shreeman.nitro_camera_example"
ACTIVITY="$PKG/.MainActivity"

adb_() { adb -s "$SERIAL" "$@"; }
pid_of() { adb_ shell pidof "$PKG" 2>/dev/null | tr -d '\r' | awk '{print $1}'; }

sample() { # $1 = pid, $2 = label
  local pid="$1" label="$2" mem proc
  # One dumpsys and one run-as round-trip per sample: adb latency dominates, and
  # spreading the reads would sample different instants of a moving target.
  mem=$(adb_ shell dumpsys meminfo "$pid" 2>/dev/null | tr -d '\r')
  proc=$(adb_ shell "run-as $PKG sh -c 'cat /proc/$pid/status; echo FDS=\$(ls /proc/$pid/fd | wc -l); echo TASKS=\$(ls /proc/$pid/task | wc -l)'" 2>/dev/null | tr -d '\r')

  local rss threads fds native gfx egl
  rss=$(printf '%s' "$proc" | awk '/^VmRSS:/{print $2}')
  fds=$(printf '%s' "$proc" | awk -F= '/^FDS=/{print $2}')
  threads=$(printf '%s' "$proc" | awk -F= '/^TASKS=/{print $2}')
  # App Summary rows are "Label:  <pss>  <rss>" — take Pss.
  native=$(printf '%s' "$mem" | awk '/^ *Native Heap: */{print $3}')
  gfx=$(printf '%s' "$mem" | awk '/^ *Graphics: */{print $2}')
  egl=$(printf '%s' "$mem" | awk '/EGL mtrack/{print $3}')

  printf '%-10s %10s %10s %10s %10s %6s %8s\n' \
    "$label" "${rss:-?}" "${native:-?}" "${gfx:-?}" "${egl:-?}" "${fds:-?}" "${threads:-?}"
}

echo "== nitro_camera android soak =="
echo "device : $SERIAL"
echo "package: $PKG"
echo "cycles : $CYCLES (settle ${SETTLE}s)"
echo

adb_ shell am force-stop "$PKG"
sleep 1
adb_ shell am start -n "$ACTIVITY" >/dev/null 2>&1
sleep "$((SETTLE * 3))"

PID="$(pid_of)"
[ -n "$PID" ] || { echo "app did not start"; exit 1; }
echo "pid    : $PID"
echo

printf '%-10s %10s %10s %10s %10s %6s %8s\n' \
  cycle 'VmRSS(kB)' 'Native(kB)' 'Gfx(kB)' 'EGL(kB)' 'fds' 'thrds'
sample "$PID" baseline

for i in $(seq 1 "$CYCLES"); do
  adb_ shell input keyevent KEYCODE_HOME
  sleep "$SETTLE"
  adb_ shell am start -n "$ACTIVITY" >/dev/null 2>&1
  sleep "$SETTLE"
  # A restarted process invalidates every counter — a crash mid-soak is itself
  # the finding, so stop rather than silently reporting a fresh baseline.
  NOW="$(pid_of)"
  if [ "$NOW" != "$PID" ]; then
    echo "!! process restarted (pid $PID -> ${NOW:-dead}) at cycle $i — app died"
    exit 2
  fi
  sample "$PID" "cycle-$i"
done

echo
echo "== interpretation =="
echo "flat  -> teardown is balanced"
echo "slope -> leak; Gfx/EGL climbing = EGL surface/context, fds = ImageReader/Surface,"
echo "         threads = HandlerThread or coroutine dispatcher never quit"
