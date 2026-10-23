# ble-smoke — local BLE test (no EAS)

macOS CLI against **this** `libdc-swift` checkout. Iterate on connect / protocol open / dive download without RescuePro or paid EAS builds.

## Quick start

1. Put the dive computer in **transfer / BLE** mode and keep it awake near the Mac.
2. Allow Bluetooth for Terminal (or iTerm) when macOS prompts.
3. Run:

```bash
cd /Users/janne/Code/psdpro/libdc-swift
./scripts/ble-smoke.sh              # scan → open → download first match
./scripts/ble-smoke.sh scan
./scripts/ble-smoke.sh open --name "EON Core 2051100734" --address "<UUID>"
./scripts/ble-smoke.sh download --name "EON Core …" --address "<UUID>"
```

Stdout is NDJSON (`device`, `open-ok` / `open-failed`, `dive`, `done`). Diagnostics go to stderr.

## What it exercises

Same stack as RescuePro / Connect helper: `CoreBluetoothManager` → `openBLEDevice` (forced family/model) → `dc_device_foreach`.

If open fails, look for `stage=` in the error (e.g. `connect/discover/notify` vs `dc_device_open/CMD_INIT`).

## After code changes

Just re-run `./scripts/ble-smoke.sh` — it rebuilds release. No push, no EAS.

When open+download works here, then do one RescuePro native build (`npx expo run:ios` locally is free; EAS only when you need a device build from the cloud).
