#!/usr/bin/env bash
# Build + run local BLE smoke test against this libdc-swift checkout (no EAS).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> Building ble-smoke (release)…"
swift build -c release --product ble-smoke

BIN="$ROOT/.build/release/ble-smoke"
if [[ ! -x "$BIN" ]]; then
  # SPM may put arch-specific path on some toolchains
  BIN="$(find "$ROOT/.build" -type f -name ble-smoke -perm +111 | head -1)"
fi
if [[ -z "${BIN}" || ! -x "$BIN" ]]; then
  echo "ble-smoke binary not found under .build/" >&2
  exit 1
fi

echo "==> Running: $BIN $*"
echo "    (put dive computer in transfer/BLE mode near this Mac)"
exec "$BIN" "$@"
