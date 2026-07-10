#!/usr/bin/env bash
# Revoke the example app's runtime permissions so the NEXT test run exercises
# the real permission-request flow (the dialog), instead of finding them
# already granted from a previous run.
#
# WHY THIS IS NEEDED: `flutter test integration_test/...` and `patrol` install
# the APK with `adb install -r`, which PRESERVES runtime permissions granted by
# an earlier run. So once CAMERA/RECORD_AUDIO are granted, the OS keeps
# reporting them granted and the app never re-prompts. This is the OS behaving
# normally — not the test harness auto-granting.
#
# `patrol test` already starts each test from a revoked state via the AndroidX
# orchestrator (clearPackageData=true → pm clear → grants wiped). Use this
# script for the PLAIN `flutter test integration_test/...` runs, or to force a
# clean slate before a one-off Patrol run.
#
# Usage:
#   integration_test/support/reset_permissions.sh [adb-serial]
set -euo pipefail

PKG="dev.shreeman.nitro_camera_example"
SERIAL="${1:-}"
ADB=(adb)
[ -n "$SERIAL" ] && ADB=(adb -s "$SERIAL")

# NEVER touch the Android TV at 192.168.165.48.
if [ "$SERIAL" = "192.168.165.48" ] || [ "$SERIAL" = "192.168.165.48:5555" ]; then
  echo "Refusing to target the Android TV ($SERIAL)." >&2
  exit 1
fi

for perm in android.permission.CAMERA android.permission.RECORD_AUDIO; do
  # `pm revoke` fails harmlessly if the app isn't installed or was never
  # granted — swallow that so the script is idempotent.
  "${ADB[@]}" shell pm revoke "$PKG" "$perm" 2>/dev/null || true
  state=$("${ADB[@]}" shell dumpsys package "$PKG" 2>/dev/null \
    | grep "$perm:" | head -1 | tr -d '\r' || true)
  echo "${perm##*.}: ${state:-<app not installed>}"
done
echo "Done — the next run will prompt for permission."
