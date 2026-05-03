#!/usr/bin/env bash
# Run all TallieLight Berry tests off-device.
#
# Requires the Tasmota berry binary on your $PATH. Override BERRY_BIN to point elsewhere.
set -e

BERRY_BIN="${BERRY_BIN:-berry}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

if ! command -v "$BERRY_BIN" &>/dev/null; then
  echo "Berry binary not found: $BERRY_BIN" >&2
  echo "Override with BERRY_BIN=/path/to/berry" >&2
  exit 1
fi

cd "$ROOT"

fail=0
for t in tests/berry/test_*.be; do
  echo "── $t ──"
  if ! "$BERRY_BIN" -m tests/berry/stubs:src "$t" 2>&1 | grep -E "(Batch|FAIL|^  -)"; then
    fail=1
  fi
done

exit $fail
