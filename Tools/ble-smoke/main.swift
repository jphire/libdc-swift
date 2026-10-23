/**
 * Local BLE smoke test for libdc-swift (no EAS / RescuePro rebuild).
 *
 * Usage:
 *   cd libdc-swift && ./scripts/ble-smoke.sh
 *   ./scripts/ble-smoke.sh scan
 *   ./scripts/ble-smoke.sh open --name "EON Core 2051100734" --address "<UUID>"
 *   ./scripts/ble-smoke.sh download --name "EON Core …" --address "<UUID>"
 *
 * Put the dive computer in transfer/BLE mode and keep it awake near the Mac.
 */

import Foundation
import CoreBluetooth
import LibDCSwift
import LibDCBridge
import Clibdivecomputer

// MARK: - Logging

func log(_ msg: String) {
    fputs(msg + "\n", stderr)
    fflush(stderr)
}

func emit(_ obj: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj),
          let line = String(data: data, encoding: .utf8) else { return }
    print(line)
    fflush(stdout)
}

// MARK: - Scan

private final class ScanDelegate: NSObject, CBCentralManagerDelegate {
    var central: CBCentralManager!
    var shouldStop = false
    var seen = Set<String>()
    var devices: [(name: String, address: String, rssi: Int)] = []

    func start(seconds: TimeInterval = 8) {
        central = CBCentralManager(delegate: self, queue: .main)
        Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.shouldStop = true
            self?.central?.stopScan()
        }
        while !shouldStop {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            log("BT powered on — scanning…")
            central.scanForPeripherals(withServices: nil, options: [
                CBCentralManagerScanOptionAllowDuplicatesKey: false,
            ])
        case .poweredOff, .unauthorized, .unsupported:
            log("Bluetooth unavailable: \(central.state.rawValue)")
            emit(["type": "error", "message": "Bluetooth unavailable"])
            shouldStop = true
        default:
            break
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let address = peripheral.identifier.uuidString
        guard seen.insert(address).inserted else { return }
        let name = peripheral.name
            ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? "Unknown"
        let lower = name.lowercased()
        let interesting =
            lower.contains("suunto") || lower.contains("eon") || lower.contains("d5")
            || lower.contains("shearwater") || lower.contains("perdix") || lower.contains("teric")
            || lower.contains("mares") || lower.contains("pelagic") || lower.contains("scubapro")
            || DeviceConfiguration.fromName(name) != nil
        guard interesting else { return }
        devices.append((name, address, RSSI.intValue))
        emit([
            "type": "device",
            "name": name,
            "address": address,
            "rssi": RSSI.intValue,
            "detected": DeviceConfiguration.fromName(name) != nil,
        ])
        log("  found \(name)  \(address)  rssi=\(RSSI)")
    }
}

private func runScan(seconds: TimeInterval = 8) -> [(name: String, address: String, rssi: Int)] {
    let d = ScanDelegate()
    d.start(seconds: seconds)
    emit(["type": "scan-done", "count": d.devices.count])
    return d.devices
}

// MARK: - Open / download

private func resolveOpenName(_ advertised: String) -> String {
    if DeviceConfiguration.fromName(advertised) != nil { return advertised }
    let lower = advertised.lowercased()
    if lower.contains("eon core") { return "EON Core" }
    if lower.contains("eon steel black") { return "EON Steel Black" }
    if lower.contains("eon steel") { return "EON Steel" }
    if lower.contains("suunto d5") || lower.hasPrefix("d5") { return "Suunto D5" }
    return advertised
}

@discardableResult
private func openDevice(name advertised: String, address: String) -> Bool {
    let ble = CoreBluetoothManager.sharedManager
    // Same process scan fills LibDC discovered list (needed for retrievePeripherals).
    ble.startScanning(omitUnsupportedPeripherals: false)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 2.0))
    ble.stopScanning()

    let openName = resolveOpenName(advertised)
    let detected = DeviceConfiguration.fromName(openName) ?? DeviceConfiguration.fromName(advertised)
    log("open: advertised=\(advertised) openName=\(openName) address=\(address)")
    if let detected {
        log("forced model: family=\(detected.family) model=\(detected.model)")
    } else {
        log("WARNING: could not resolve family/model from name")
    }

    let ok: Bool
    if let detected {
        ok = DeviceConfiguration.openBLEDevice(
            name: openName,
            deviceAddress: address,
            forcedModel: (detected.family, detected.model)
        )
    } else {
        ok = DeviceConfiguration.openBLEDevice(name: openName, deviceAddress: address)
    }

    if ok {
        log("OPEN OK — protocol up (openedDeviceDataPtr set)")
        emit([
            "type": "open-ok",
            "name": advertised,
            "address": address,
            "family": detected.map { String(describing: $0.family) } as Any,
            "model": detected?.model as Any,
        ])
    } else {
        let detail = DeviceConfiguration.lastOpenError ?? "unknown"
        let stageC = get_last_ble_open_stage()
        let stage = stageC != nil ? String(cString: stageC!) : ""
        log("OPEN FAILED: \(detail)")
        if !stage.isEmpty { log("  stage: \(stage)") }
        emit([
            "type": "open-failed",
            "message": detail,
            "stage": stage,
            "name": advertised,
            "address": address,
        ])
    }
    return ok
}

private final class DiveCountContext {
    var count = 0
}

private let diveCountCb: @convention(c) (
    UnsafePointer<UInt8>?,
    UInt32,
    UnsafePointer<UInt8>?,
    UInt32,
    UnsafeMutableRawPointer?
) -> Int32 = { _, size, _, _, userdata in
    guard let userdata else { return 1 }
    let ctx = Unmanaged<DiveCountContext>.fromOpaque(userdata).takeUnretainedValue()
    ctx.count += 1
    log("  dive #\(ctx.count) (\(size) bytes)")
    emit(["type": "dive", "index": ctx.count, "size": size])
    return 1
}

private func downloadDives() -> Bool {
    let ble = CoreBluetoothManager.sharedManager
    guard let ptr = ble.openedDeviceDataPtr, let device = ptr.pointee.device else {
        log("download: no opened device")
        emit(["type": "error", "message": "no opened device"])
        return false
    }
    ble.isRetrievingLogs = true
    let ctx = DiveCountContext()
    let raw = Unmanaged.passUnretained(ctx).toOpaque()
    log("download: dc_device_foreach…")
    let rc = dc_device_foreach(device, diveCountCb, raw)
    ble.isRetrievingLogs = false
    let ok = rc == DC_STATUS_SUCCESS || rc == DC_STATUS_PROTOCOL
    log("download done status=\(rc) dives=\(ctx.count) ok=\(ok)")
    emit(["type": "done", "status": Int(rc.rawValue), "dives": ctx.count, "ok": ok])
    return ok
}

// MARK: - CLI

private func usage() -> Never {
    fputs(
        """
        Usage:
          ble-smoke scan [--seconds N]
          ble-smoke open --name \"EON Core …\" --address <UUID>
          ble-smoke download --name \"…\" --address <UUID>
          ble-smoke   (interactive: scan, then open+download first match)

        Tip: enable transfer/BLE mode on the computer; keep it awake and close to the Mac.

        """,
        stderr
    )
    exit(1)
}

private func parseFlag(_ args: ArraySlice<String>, _ name: String) -> String? {
    var i = args.startIndex
    while i < args.endIndex {
        if args[i] == name {
            let j = args.index(after: i)
            if j < args.endIndex { return args[j] }
        }
        i = args.index(after: i)
    }
    return nil
}

private func main() {
    let args = Array(CommandLine.arguments.dropFirst())
    let cmd = args.first ?? "interactive"

    switch cmd {
    case "scan":
        let sec = Double(parseFlag(args[args.startIndex...], "--seconds") ?? "8") ?? 8
        _ = runScan(seconds: sec)

    case "open":
        guard let name = parseFlag(args[args.startIndex...], "--name"),
              let address = parseFlag(args[args.startIndex...], "--address") else {
            usage()
        }
        _ = runScan(seconds: 5)
        let ok = openDevice(name: name, address: address)
        exit(ok ? 0 : 2)

    case "download":
        guard let name = parseFlag(args[args.startIndex...], "--name"),
              let address = parseFlag(args[args.startIndex...], "--address") else {
            usage()
        }
        _ = runScan(seconds: 5)
        guard openDevice(name: name, address: address) else { exit(2) }
        let ok = downloadDives()
        exit(ok ? 0 : 3)

    case "interactive", "-i":
        log("=== libdc-swift ble-smoke (local, no EAS) ===")
        let devices = runScan(seconds: 8)
        guard let first = devices.first else {
            log("No dive computers found. Wake the computer / enable BLE transfer.")
            exit(1)
        }
        log("Using first device: \(first.name) \(first.address)")
        guard openDevice(name: first.name, address: first.address) else { exit(2) }
        let ok = downloadDives()
        exit(ok ? 0 : 3)

    case "help", "-h", "--help":
        usage()

    default:
        log("Unknown command: \(cmd)")
        usage()
    }
}

main()
