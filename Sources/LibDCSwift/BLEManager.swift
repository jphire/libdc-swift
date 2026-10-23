import Foundation
#if canImport(UIKit)
import UIKit
#endif
import CoreBluetooth
import Clibdivecomputer
import LibDCBridge
import LibDCBridge.CoreBluetoothManagerProtocol
import Combine

/// Represents a BLE serial service with its identifying information
@objc(SerialService)
class SerialService: NSObject {
    @objc let uuid: String
    @objc let vendor: String
    @objc let product: String
    
    @objc init(uuid: String, vendor: String, product: String) {
        self.uuid = uuid
        self.vendor = vendor
        self.product = product
        super.init()
    }
}

/// Extension to check if a CBUUID is a standard Bluetooth service UUID
extension CBUUID {
    var isStandardBluetooth: Bool {
        return self.data.count == 2
    }
}

/// Central manager for handling BLE communications with dive computers.
/// Manages device discovery, connection, and data transfer with BLE dive computers.
@objc(CoreBluetoothManager)
public class CoreBluetoothManager: NSObject, CoreBluetoothManagerProtocol, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    // MARK: - Singleton
    private static let sharedInstance = CoreBluetoothManager()
    
    @objc public static func shared() -> Any! {
        return sharedInstance
    }
    
    public static var sharedManager: CoreBluetoothManager {
        return sharedInstance
    }
    
    // MARK: - Published Properties
    @Published public var centralManager: CBCentralManager! // Core Bluetooth central manager instance
    @Published public var peripheral: CBPeripheral? // Currently selected peripheral device
    @Published public var discoveredPeripherals: [CBPeripheral] = [] // List of discovered BLE peripherals
    @Published public var isPeripheralReady = false // Indicates if peripheral is ready for communication
    @Published @objc dynamic public var connectedDevice: CBPeripheral? // Currently connected peripheral device
    @Published public var isScanning = false // Indicates if currently scanning for devices
    @Published public var isRetrievingLogs = false { // Indicates if currently retrieving dive logs
        didSet {
            objectWillChange.send()
        }
    }
    @Published public var currentRetrievalDevice: CBPeripheral? { // Device currently being used for log retrieval
        didSet {
            objectWillChange.send()
        }
    }
    @Published public var isDisconnecting = false // Indicates if currently disconnecting from device
    @Published public var isBluetoothReady = false // Indicates if Bluetooth is ready for use
    @Published public var isConnecting = false // Indicates if a connection attempt is in progress (prevents auto-reconnect)
    @Published private var deviceDataPtrChanged = false

    // MARK: - Private Properties
    @objc private var timeout: Int = -1 // default to no timeout
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var receivedData: Data = Data()
    private let queue = DispatchQueue(label: "com.blemanager.queue")
    /// Dedicated CB callback queue — never use the main queue.
    /// RescuePro (and others) open protocol from `DispatchQueue.main.async`; if CB
    /// also uses main, `discoverServices` RunLoop-waits deadlock and time out (-6).
    private let cbQueue = DispatchQueue(label: "com.libdcswift.corebluetooth")
    private let dataAvailableSemaphore = DispatchSemaphore(value: 0) // Signals when new data arrives
    private let frameMarker: UInt8 = 0x7E
    private var _deviceDataPtr: UnsafeMutablePointer<device_data_t>?
    private var connectionCompletion: ((Bool) -> Void)?
    private var totalBytesReceived: Int = 0
    private var lastDataReceived: Date?
    private var averageTransferRate: Double = 0
    private var preferredService: CBService?
    private var pendingOperations: [() -> Void] = []
    
    // MARK: - Public Properties
    public var openedDeviceDataPtr: UnsafeMutablePointer<device_data_t>? { // Public access to device data pointer with change notification
        get {
            _deviceDataPtr
        }
        set {
            objectWillChange.send()
            _deviceDataPtr = newValue
        }
    }
    
    /// Checks if there is a valid device data pointer
    /// - Returns: True if device data pointer exists
    public func hasValidDeviceDataPtr() -> Bool {
        return openedDeviceDataPtr != nil
    }

    /// Sleep-wait so CB callbacks on `cbQueue` can run (safe from main or background).
    private func waitBrieflyForCallbacks() {
        Thread.sleep(forTimeInterval: 0.05)
    }
    
    // MARK: - Serial Services
    /// Known BLE serial services for supported dive computers
    @objc private let knownSerialServices: [SerialService] = [
        SerialService(uuid: "0000fefb-0000-1000-8000-00805f9b34fb", vendor: "Heinrichs-Weikamp", product: "Telit/Stollmann"),
        SerialService(uuid: "2456e1b9-26e2-8f83-e744-f34f01e9d701", vendor: "Heinrichs-Weikamp", product: "U-Blox"),
        SerialService(uuid: "544e326b-5b72-c6b0-1c46-41c1bc448118", vendor: "Mares", product: "BlueLink Pro"),
        SerialService(uuid: "6e400001-b5a3-f393-e0a9-e50e24dcca9e", vendor: "Nordic Semi", product: "UART"),
        SerialService(uuid: "98ae7120-e62e-11e3-badd-0002a5d5c51b", vendor: "Suunto", product: "EON Steel/Core"),
        SerialService(uuid: "cb3c4555-d670-4670-bc20-b61dbc851e9a", vendor: "Pelagic", product: "i770R/i200C"),
        SerialService(uuid: "ca7b0001-f785-4c38-b599-c7c5fbadb034", vendor: "Pelagic", product: "i330R/DSX"),
        SerialService(uuid: "fdcdeaaa-295d-470e-bf15-04217b7aa0a0", vendor: "ScubaPro", product: "G2/G3"),
        SerialService(uuid: "fe25c237-0ece-443c-b0aa-e02033e7029d", vendor: "Shearwater", product: "Perdix/Teric"),
        SerialService(uuid: "0000fcef-0000-1000-8000-00805f9b34fb", vendor: "Divesoft", product: "Freedom")
    ]

    /// Preferred TX/RX characteristic UUIDs (libdivecomputer wiki / Subsurface).
    /// Property-only matching can pick the wrong char when a service exposes several.
    private struct KnownSerialCharacteristics {
        let service: String
        let write: String
        let notify: String
    }
    private let knownSerialCharacteristics: [KnownSerialCharacteristics] = [
        // Suunto EON Steel / Core / D5 — Rx write-without-response, Tx notify
        KnownSerialCharacteristics(
            service: "98ae7120-e62e-11e3-badd-0002a5d5c51b",
            write: "c6339440-e62e-11e3-a5b3-0002a5d5c51b",
            notify: "d0fd6b80-e62e-11e3-a2e9-0002a5d5c51b"
        ),
    ]
    
    /// Service UUIDs to exclude from discovery
    private let excludedServices: Set<String> = [
        "00001530-1212-efde-1523-785feabcd123", // Nordic Upgrade
        "9e5d1e47-5c13-43a0-8635-82ad38a1386f", // Broadcom Upgrade #1
        "a86abc2d-d44c-442e-99f7-80059a873e36"  // Broadcom Upgrade #2
    ]
    
    // MARK: - Initialization
    private override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: cbQueue)
    }
    
    // MARK: - Service Discovery
    @objc(getPeripheralReadyState)
    public func getPeripheralReadyState() -> Bool {
        return self.isPeripheralReady
    }
    
    @objc(discoverServices)
    public func discoverServices() -> Bool {
        guard let peripheral = self.peripheral else {
            logError("No peripheral available for service discovery")
            return false
        }
        
        // Check if peripheral is actually connected
        guard peripheral.state == .connected else {
            logError("Peripheral not in connected state: \(peripheral.state.rawValue)")
            return false
        }

        // Reuse characteristics from a prior discovery on this GATT link.
        if writeCharacteristic != nil && notifyCharacteristic != nil {
            logInfo("discoverServices: reusing existing write/notify characteristics")
            return true
        }

        let knownUUIDs = knownSerialServices.map { CBUUID(string: $0.uuid) }
        let cached = peripheral.services ?? []
        let hasKnownSerial = cached.contains { isKnownSerialService($0.uuid) != nil }

        if hasKnownSerial {
            assignCharacteristics(from: cached, peripheral: peripheral)
            if writeCharacteristic != nil && notifyCharacteristic != nil {
                logInfo("discoverServices: characteristics already cached on known serial service")
                return true
            }
            for service in cached where isKnownSerialService(service.uuid) != nil {
                preferredService = service
                if service.characteristics == nil || service.characteristics?.isEmpty == true {
                    peripheral.discoverCharacteristics(nil, for: service)
                } else {
                    assignCharacteristics(from: [service], peripheral: peripheral)
                }
            }
        } else {
            // iOS often caches GAP/GATT on an already-connected peripheral *without*
            // the vendor serial service. Do not only dig into those — rediscover known UUIDs.
            logInfo(
                "discoverServices: no known serial in cache (services=\(cached.count)) — discoverServices(known)"
            )
            writeCharacteristic = nil
            notifyCharacteristic = nil
            preferredService = nil
            peripheral.discoverServices(knownUUIDs)
        }
        
        // Wait for characteristics. Callbacks run on cbQueue — sleep, do not pump
        // RunLoop.main (deadlocks when caller is already on the main GCD queue).
        var didFallbackDiscoverAll = false
        let started = Date()
        let timeout = Date(timeIntervalSinceNow: 15.0)
        while writeCharacteristic == nil || notifyCharacteristic == nil {
            if Date() > timeout {
                logError(
                    "Timeout waiting for service discovery (services=\(peripheral.services?.count ?? -1) write=\(self.writeCharacteristic != nil) notify=\(self.notifyCharacteristic != nil))"
                )
                return false
            }
            // Widen search if known-UUID discovery still found nothing useful.
            if !didFallbackDiscoverAll, Date().timeIntervalSince(started) > 4.0 {
                let stillNoSerial = !(peripheral.services ?? []).contains {
                    isKnownSerialService($0.uuid) != nil
                }
                if stillNoSerial {
                    didFallbackDiscoverAll = true
                    logWarning("discoverServices: falling back to discoverServices(nil)")
                    peripheral.discoverServices(nil)
                }
            }
            waitBrieflyForCallbacks()
        }

        logInfo(
            "discoverServices: write=\(self.writeCharacteristic?.uuid.uuidString ?? "?") notify=\(self.notifyCharacteristic?.uuid.uuidString ?? "?")"
        )
        return true
    }
    
    @objc(enableNotifications)
    public func enableNotifications() -> Bool {
        guard let notifyCharacteristic = self.notifyCharacteristic,
              let peripheral = self.peripheral else {
            logError("Missing characteristic or peripheral for notifications")
            return false
        }
        
        // Check if peripheral is actually connected
        guard peripheral.state == .connected else {
            logError("Peripheral not in connected state for notifications: \(peripheral.state.rawValue)")
            return false
        }

        if notifyCharacteristic.isNotifying {
            return true
        }
        
        peripheral.setNotifyValue(true, for: notifyCharacteristic)
        
        let timeout = Date(timeIntervalSinceNow: 15.0)
        while !notifyCharacteristic.isNotifying {
            if Date() > timeout {
                logError("Timeout waiting for notifications to enable")
                return false
            }
            waitBrieflyForCallbacks()
        }
        
        return notifyCharacteristic.isNotifying
    }
    
    // MARK: - Data Handling
    private func findNextCompleteFrame() -> Data? {
        var frameToReturn: Data? = nil
        
        queue.sync {
            guard let startIndex = receivedData.firstIndex(of: frameMarker) else {
                return
            }
            
            let afterStart = receivedData.index(after: startIndex)
            guard afterStart < receivedData.count,
                  let endIndex = receivedData[afterStart...].firstIndex(of: frameMarker) else {
                return
            }
            
            let frameEndIndex = receivedData.index(after: endIndex)
            let frame = receivedData[startIndex..<frameEndIndex]
            
            receivedData.removeSubrange(startIndex..<frameEndIndex)
            frameToReturn = Data(frame)
        }
        
        return frameToReturn
    }
    
    /// ObjC protocol `writeData:` imports to Swift as `write(_:)` (Swift 3 Data rename).
    /// Selector seen from BLEBridge remains `writeData:`.
    @objc public func write(_ data: Data) -> Bool {
        guard let peripheral = self.peripheral,
              let characteristic = self.writeCharacteristic,
              !data.isEmpty else {
            logError("write: missing peripheral/characteristic or empty payload")
            return false
        }
        let type: CBCharacteristicWriteType =
            characteristic.properties.contains(.writeWithoutResponse)
            ? .withoutResponse
            : .withResponse
        // BLE default ATT payload is 20 bytes; HDLC already chunks to 20 for Suunto,
        // but defend against larger writes from other families.
        let maxChunk = 20
        var offset = 0
        while offset < data.count {
            let end = min(offset + maxChunk, data.count)
            let chunk = data.subdata(in: offset..<end)
            peripheral.writeValue(chunk, for: characteristic, type: type)
            offset = end
        }
        return true
    }
    
    @objc public func readDataPartial(_ requested: Int32) -> Data? {
        let requestedInt = Int(requested)
        let startTime = Date()
        // Suunto CMD_INIT / HDLC often needs >3s for the first reply after open.
        let timeout: TimeInterval = 8.0

        while Date().timeIntervalSince(startTime) < timeout {
            var outData: Data?

            queue.sync {
                if !receivedData.isEmpty {
                    let amount = min(requestedInt, receivedData.count)
                    outData = receivedData.prefix(amount)
                    receivedData.removeSubrange(0..<amount)
                }
            }

            if let data = outData {
                return data
            }

            // CB callbacks (didUpdateValueFor) run on cbQueue and signal this semaphore.
            _ = dataAvailableSemaphore.wait(timeout: .now() + 0.05)
        }

        return nil
    }
    
    // MARK: - Device Management
    /// Release protocol / I/O state. By default keeps the GATT link so RescuePro can retry
    /// open/download without re-pairing (Connect-style descriptor open on an existing link).
    @objc public func close(clearDevicePtr: Bool = false, disconnectPeripheral: Bool = false) {
        if disconnectPeripheral {
            isDisconnecting = true
        }
        queue.sync {
            if !receivedData.isEmpty {
                receivedData.removeAll()
            }
        }

        // Drain and signal semaphore to unblock any waiting reads and clear stale signals
        while dataAvailableSemaphore.wait(timeout: .now()) == .success {
            // Drain any accumulated signals
        }
        dataAvailableSemaphore.signal() // Signal once to unblock any waiting read

        if clearDevicePtr {
            if let devicePtr = self.openedDeviceDataPtr {
                if devicePtr.pointee.device != nil {
                    dc_device_close(devicePtr.pointee.device)
                }
                devicePtr.deallocate()
                self.openedDeviceDataPtr = nil
            }
        }

        writeCharacteristic = nil
        notifyCharacteristic = nil
        preferredService = nil

        if disconnectPeripheral {
            DispatchQueue.main.async {
                self.isPeripheralReady = false
                self.connectedDevice = nil
            }
            if let peripheral = self.peripheral {
                self.peripheral = nil
                centralManager.cancelPeripheralConnection(peripheral)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.isDisconnecting = false
            }
        }
    }
    
    public func startScanning(omitUnsupportedPeripherals: Bool = true) {
        centralManager.scanForPeripherals(
            withServices: omitUnsupportedPeripherals ? knownSerialServices.map { CBUUID(string: $0.uuid) } : nil,
            options: nil)
        isScanning = true
    }
    
    public func stopScanning() {
        centralManager.stopScan()
        isScanning = false
    }
    
    @objc public func connect(toDevice address: String!) -> Bool {
        guard let uuid = UUID(uuidString: address) else {
            return false
        }
        // Prefer an already-discovered peripheral (same scan session), then system cache.
        let peripheral =
            discoveredPeripherals.first(where: { $0.identifier == uuid })
            ?? centralManager.retrievePeripherals(withIdentifiers: [uuid]).first
        guard let peripheral else {
            logError("connect(toDevice:): peripheral \(address ?? "?") not in discovered list or CB cache")
            return false
        }
        
        self.peripheral = peripheral
        peripheral.delegate = self
        // Reuse an existing GATT link (RescuePro connects before LibDC open).
        // Set ready synchronously — open waits on the main run loop and must see this immediately.
        if peripheral.state == .connected {
            self.isPeripheralReady = true
            self.connectedDevice = peripheral
            logInfo("connect(toDevice:): already connected \(peripheral.name ?? address ?? "?")")
            return true
        }
        centralManager.connect(peripheral, options: [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
        ])
        return true  // Return immediately, connection status will be handled by delegate
    }
    
    public func connectToStoredDevice(_ uuid: String) -> Bool {
        guard let storedDevice = DeviceStorage.shared.getStoredDevice(uuid: uuid) else {
            return false
        }
        
        return DeviceConfiguration.openBLEDevice(
            name: storedDevice.name,
            deviceAddress: storedDevice.uuid
        )
    }
    
    // MARK: - State Management
    public func clearRetrievalState() {
        DispatchQueue.main.async { [weak self] in
            self?.isRetrievingLogs = false
            self?.currentRetrievalDevice = nil
        }
    }
    
    public func setBackgroundMode(_ enabled: Bool) {
        if enabled {
            // Set connection parameters for background operation
            if let peripheral = peripheral {
                // For iOS/macOS, we can only ensure the connection stays alive
                // by maintaining the peripheral reference and keeping the central manager active
                
                #if os(iOS)
                // On iOS, we can request background execution time
                var backgroundTask: UIBackgroundTaskIdentifier = .invalid
                backgroundTask = UIApplication.shared.beginBackgroundTask { [backgroundTask] in
                    // Cleanup callback
                    if backgroundTask != .invalid {
                        UIApplication.shared.endBackgroundTask(backgroundTask)
                    }
                }
                
                // Store the task identifier for later cleanup
                currentBackgroundTask = backgroundTask
                #endif
            }
        } else {
            #if os(iOS)
            // Clean up any background tasks when disabling background mode
            if let peripheral = peripheral {
                if let task = currentBackgroundTask, task != .invalid {
                    UIApplication.shared.endBackgroundTask(task)
                    currentBackgroundTask = nil
                }
            }
            #endif
        }
    }

    // track background tasks
    #if os(iOS)
    private var currentBackgroundTask: UIBackgroundTaskIdentifier?
    #endif

    public func systemDisconnect(_ peripheral: CBPeripheral) {
        logInfo("Performing system-level disconnect for \(peripheral.name ?? "Unknown Device")")
        DispatchQueue.main.async {
            self.isPeripheralReady = false
            self.connectedDevice = nil
            self.writeCharacteristic = nil
            self.notifyCharacteristic = nil
            self.peripheral = nil
        }
        centralManager.cancelPeripheralConnection(peripheral)
    }
    
    public func clearDiscoveredPeripherals() {
        DispatchQueue.main.async {
            self.discoveredPeripherals.removeAll()
        }
    }
    
    public func addDiscoveredPeripheral(_ peripheral: CBPeripheral) {
        DispatchQueue.main.async {
            if !self.discoveredPeripherals.contains(where: { $0.identifier == peripheral.identifier }) {
                self.discoveredPeripherals.append(peripheral)
            }
        }
    }

    public func queueOperation(_ operation: @escaping () -> Void) {
        if isBluetoothReady {
            operation()
        } else {
            pendingOperations.append(operation)
        }
    }
    
    // MARK: - CBCentralManagerDelegate Methods
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            logInfo("Bluetooth is powered on")
            isBluetoothReady = true
            pendingOperations.forEach { $0() }
            pendingOperations.removeAll()
        case .poweredOff:
            logWarning("Bluetooth is powered off")
            isBluetoothReady = false
        case .resetting:
            logWarning("Bluetooth is resetting")
            isBluetoothReady = false
        case .unauthorized:
            logError("Bluetooth is unauthorized")
            isBluetoothReady = false
        case .unsupported:
            logError("Bluetooth is unsupported")
            isBluetoothReady = false
        case .unknown:
            logWarning("Bluetooth state is unknown")
            isBluetoothReady = false
        @unknown default:
            logWarning("Unknown Bluetooth state")
            isBluetoothReady = false
        }
    }
    
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        logInfo("Successfully connected to \(peripheral.name ?? "Unknown Device")")
        peripheral.delegate = self
        // Set ready on cbQueue first so connectToBLEDevice waiters (sleep) see it
        // without needing the main run loop.
        self.isPeripheralReady = true
        DispatchQueue.main.async {
            self.connectedDevice = peripheral
            self.objectWillChange.send()
        }
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        logError("Failed to connect to \(peripheral.name ?? "Unknown Device"): \(error?.localizedDescription ?? "No error description")")
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        logInfo("Disconnected from \(peripheral.name ?? "unknown device")")
        if let error = error {
            logError("Disconnect error: \(error.localizedDescription)")
        }
        
        DispatchQueue.main.async {
            self.isPeripheralReady = false
            self.connectedDevice = nil
            
            // Don't attempt to reconnect if:
            // 1. We initiated the disconnect
            // 2. A download is currently in progress (will cause race conditions)
            // 3. A connection attempt is already in progress
            if !self.isDisconnecting && !self.isRetrievingLogs && !self.isConnecting {
                // Attempt to reconnect if this was a stored device
                if let storedDevice = DeviceStorage.shared.getStoredDevice(uuid: peripheral.identifier.uuidString) {
                    logInfo("Attempting to reconnect to stored device")
                    _ = DeviceConfiguration.openBLEDevice(
                        name: storedDevice.name,
                        deviceAddress: storedDevice.uuid
                    )
                }
            } else if self.isRetrievingLogs {
                logWarning("⚠️ Disconnected during download - NOT auto-reconnecting to avoid race condition")
            } else if self.isConnecting {
                logWarning("⚠️ Disconnected during connection attempt - NOT auto-reconnecting")
            }
        }
    }
    
    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        if peripheral.name != nil {
            // Add the peripheral if:
            // 1. It's a stored device
            // 2. It's a supported device
            // 3. We haven't already added it
            if DeviceStorage.shared.getStoredDevice(uuid: peripheral.identifier.uuidString) != nil ||
               DeviceConfiguration.fromName(peripheral.name ?? "") != nil {
                addDiscoveredPeripheral(peripheral)
            }
        }
    }

    // MARK: - CBPeripheral Methods
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            logError("Error discovering services: \(error.localizedDescription)")
            return
        }
        
        guard let services = peripheral.services else {
            logWarning("No services found")
            return
        }

        // Prefer known serial services only (Suunto/Shearwater/…).
        let known = services.filter { isKnownSerialService($0.uuid) != nil }
        let targets = known.isEmpty
            ? services.filter { !isExcludedService($0.uuid) }
            : known

        for service in targets {
            if isKnownSerialService(service.uuid) != nil {
                preferredService = service
            }
            if let chars = service.characteristics, !chars.isEmpty {
                assignCharacteristics(from: [service], peripheral: peripheral)
            } else {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            logError("Error discovering characteristics: \(error.localizedDescription)")
            return
        }
        assignCharacteristics(from: [service], peripheral: peripheral)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            logError("Error receiving data: \(error.localizedDescription)")
            return
        }
        
        guard let data = characteristic.value else {
            return
        }
        
        queue.sync {
            // Append new data to our buffer immediately
            receivedData.append(data)
        }

        // Signal that data is available - wake up any waiting read
        dataAvailableSemaphore.signal()

        updateTransferStats(data.count)
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            logError("Error writing to characteristic: \(error.localizedDescription)")
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            logError("Error changing notification state: \(error.localizedDescription)")
        }
    }

    // MARK: - Private Helpers
    /// Assign write/notify only from known dive-computer serial services when possible.
    private func assignCharacteristics(from services: [CBService], peripheral: CBPeripheral) {
        let ordered: [CBService]
        if let preferred = preferredService, services.contains(where: { $0.uuid == preferred.uuid }) {
            ordered = [preferred] + services.filter { $0.uuid != preferred.uuid }
        } else {
            let known = services.filter { isKnownSerialService($0.uuid) != nil }
            ordered = known.isEmpty ? services : known
        }

        for service in ordered {
            if isExcludedService(service.uuid) { continue }
            // Once we have a known serial service, ignore other services' chars.
            if preferredService != nil,
               isKnownSerialService(service.uuid) == nil,
               writeCharacteristic != nil,
               notifyCharacteristic != nil {
                continue
            }
            guard let characteristics = service.characteristics else { continue }

            let serviceKey = service.uuid.uuidString.lowercased()
            let knownChars = knownSerialCharacteristics.first {
                $0.service.lowercased() == serviceKey
            }

            if let knownChars {
                for characteristic in characteristics {
                    let uuid = characteristic.uuid.uuidString.lowercased()
                    if uuid == knownChars.write.lowercased() {
                        writeCharacteristic = characteristic
                    }
                    if uuid == knownChars.notify.lowercased() {
                        notifyCharacteristic = characteristic
                        if !characteristic.isNotifying {
                            peripheral.setNotifyValue(true, for: characteristic)
                        }
                    }
                }
                if writeCharacteristic != nil && notifyCharacteristic != nil {
                    preferredService = service
                    logInfo(
                        "assignCharacteristics: matched known UUIDs for \(serviceKey) write=\(knownChars.write) notify=\(knownChars.notify)"
                    )
                    break
                }
                // Fall through to property matching if UUIDs not present yet.
            }

            for characteristic in characteristics {
                if isWriteCharacteristic(characteristic) {
                    writeCharacteristic = characteristic
                }
                if isReadCharacteristic(characteristic) {
                    notifyCharacteristic = characteristic
                    if !characteristic.isNotifying {
                        peripheral.setNotifyValue(true, for: characteristic)
                    }
                }
            }
            if isKnownSerialService(service.uuid) != nil,
               writeCharacteristic != nil,
               notifyCharacteristic != nil {
                preferredService = service
                break
            }
        }
    }

    private func updateTransferStats(_ newBytes: Int) {
        totalBytesReceived += newBytes
        
        if let last = lastDataReceived {
            let interval = Date().timeIntervalSince(last)
            if interval > 0 {
                let currentRate = Double(newBytes) / interval
                averageTransferRate = (averageTransferRate * 0.7) + (currentRate * 0.3)
            }
        }
        
        lastDataReceived = Date()
    }
    
    private func isKnownSerialService(_ uuid: CBUUID) -> SerialService? {
        return knownSerialServices.first { service in
            uuid.uuidString.lowercased() == service.uuid.lowercased()
        }
    }
    
    private func isExcludedService(_ uuid: CBUUID) -> Bool {
        return excludedServices.contains(uuid.uuidString.lowercased())
    }
    
    private func isWriteCharacteristic(_ characteristic: CBCharacteristic) -> Bool {
        return characteristic.properties.contains(.write) ||
               characteristic.properties.contains(.writeWithoutResponse)
    }
    
    private func isReadCharacteristic(_ characteristic: CBCharacteristic) -> Bool {
        return characteristic.properties.contains(.notify) ||
               characteristic.properties.contains(.indicate)
    }

    /// ObjC / LibDCBridge entry — soft close (keep GATT). Use disconnectPeripheral for user disconnect.
    @objc public func close() {
        close(clearDevicePtr: false, disconnectPeripheral: false)
    }
}

// MARK: - Extensions
extension Data {
    func hexEncodedString() -> String {
        return map { String(format: "%02hhx", $0) }.joined()
    }
}
