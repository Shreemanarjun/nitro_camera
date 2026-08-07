#!/usr/bin/env bash
# Dart coverage for the nitro_camera plugin, with the generated FFI bindings
# excluded from the denominator.
#
# Why exclude: `lib/src/nitro_camera.g.dart` and `lib/src/generated/**` are
# emitted by nitro_generator and cannot execute without a loaded native
# library, so no host-side test can reach them. Counting them would cap the
# achievable number at ~67% and, worse, let real regressions in hand-written
# code hide behind a moving generated denominator (regenerating the bindings
# would silently change the score).
#
# Usage:
#   tool/coverage.sh            # report
#   tool/coverage.sh 100        # report and FAIL below the given percentage
#
# Requires lcov (`brew install lcov`).

set -uo pipefail

THRESHOLD="${1:-0}"
RAW=coverage/lcov.info
FILTERED=coverage/lcov.filtered.info

flutter test --coverage "${@:2}" >/dev/null || {
  echo "tests failed — coverage not computed"
  exit 1
}

[ -f "$RAW" ] || { echo "no $RAW produced"; exit 1; }

# lcov writes RELATIVE SF: paths here (`lib/src/...`), so a leading `*/` glob
# never matches — match on the bare filename/segment instead.
lcov --quiet \
  --remove "$RAW" \
    '*nitro_camera.g.dart' \
    '*/generated/*' \
    '*nitro_camera_bindings_generated.dart' \
  --output-file "$FILTERED" \
  --ignore-errors unused,empty >/dev/null 2>&1

python3 - "$FILTERED" "$THRESHOLD" <<'PY'
import sys

path, threshold = sys.argv[1], float(sys.argv[2])
cur, tot, hit, missed = None, {}, {}, {}
for line in open(path):
    line = line.strip()
    if line.startswith('SF:'):
        cur = line[3:]
        missed.setdefault(cur, [])
    elif line.startswith('DA:'):
        num, count = line[3:].split(',')[:2]
        if count == '0':
            missed[cur].append(int(num))
    elif line.startswith('LF:'):
        tot[cur] = int(line[3:])
    elif line.startswith('LH:'):
        hit[cur] = int(line[3:])

rows = sorted((hit.get(f, 0) / t if t else 1.0, hit.get(f, 0), t, f)
              for f, t in tot.items())
print(f'{"cov":>6} {"hit":>5}/{"tot":<5}  file')
for pct, h, t, f in rows:
    short = f.split('/lib/', 1)[-1] if '/lib/' in f else f
    flag = '' if h == t else f'   uncovered: {missed[f][:12]}'
    print(f'{pct * 100:5.1f}% {h:5d}/{t:<5d}  {short}{flag}')

T, H = sum(tot.values()), sum(hit.values())
overall = H / T * 100 if T else 100.0
print(f'\nTOTAL {H}/{T} = {overall:.2f}%  (generated bindings excluded)')

if threshold and overall + 1e-9 < threshold:
    print(f'FAIL: below required {threshold:.2f}%')
    sys.exit(1)
PY
