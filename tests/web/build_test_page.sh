#!/usr/bin/env bash
# Build tests/web/tallielight_ui_test.html — a self-contained file:// test page
# that bundles tallielight_ui.html inside the Tasmota page chrome.
#
# tasmota_style.html is fetched automatically from GitHub on first run.
# Re-run with --refresh-style if the Tasmota firmware version changes.
#
# Usage:
#   ./build_test_page.sh                          # rebuild test page (fast, offline)
#   ./build_test_page.sh --refresh-style          # fetch Tasmota CSS from GitHub master, then rebuild
#   ./build_test_page.sh --refresh-style v14.5.0  # fetch a specific Tasmota release tag, then rebuild
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

UI="$ROOT/src/tallielight_ui.html"
TASMOTA_STYLE="$HERE/tasmota_style.html"
TEMPLATE="$HERE/test_harness.html"
OUT="$HERE/tallielight_ui_test.html"

refresh_style() {
  local REF="${1:-master}"
  local BASE="https://raw.githubusercontent.com/arendst/Tasmota/${REF}/tasmota/html_uncompressed"
  fetch() { curl -sf "${BASE}/$1" || { echo "ERROR: could not fetch $1 (bad ref '${REF}'?)" >&2; exit 1; }; }

  local COLOR_H STYLE1_H STYLE2_H STYLE3_H
  COLOR_H=$(fetch HTTP_HEAD_STYLE_ROOT_COLOR.h)
  STYLE1_H=$(fetch HTTP_HEAD_STYLE1.h)
  STYLE2_H=$(fetch HTTP_HEAD_STYLE2.h)
  STYLE3_H=$(fetch HTTP_HEAD_STYLE3.h)

  python3 "$HERE/build_test_page.py" refresh-style \
    "$TASMOTA_STYLE" "$REF" "$COLOR_H" "$STYLE1_H" "$STYLE2_H" "$STYLE3_H"
}

build_page() {
  [[ -f "$UI" ]] || { echo "ERROR: missing $UI"; exit 1; }

  python3 "$HERE/build_test_page.py" build "$UI" "$TASMOTA_STYLE" "$TEMPLATE" "$OUT"
}

# Main logic - refresh style if requested or missing, then build the test page.
if [[ "${1:-}" == "--refresh-style" ]]; then
  refresh_style "${2:-master}"
elif [[ ! -f "$TASMOTA_STYLE" ]]; then
  echo "tasmota_style.html not found — fetching from GitHub…"
  refresh_style
fi

build_page
