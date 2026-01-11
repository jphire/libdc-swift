import Foundation
import CoreBluetooth
import Clibdivecomputer
import LibDCBridge
#if canImport(UIKit)
import UIKit
#endif

public class DiveLogRetriever {
    public class CallbackContext {
        var logCount: Int = 1
        let viewModel: DiveDataViewModel
        var lastFingerprint: Data?
        let deviceName: String
        let deviceUUID: String
        var deviceSerial: String?
        var deviceTypeFromLibDC: String?  // Exact device type string from libdivecomputer
        var hasNewDives: Bool = false
        weak var bluetoothManager: CoreBluetoothManager?
        var devicePtr: UnsafeMutablePointer<device_data_t>?
        var hasDeviceInfo: Bool = false
        var storedFingerprint: Data?
        var isCompleted: Bool = false
        var fingerprintMatched: Bool = false  // Track if we stopped due to fingerprint match
        
        var detectedFamily: dc_family_t = DC_FAMILY_NULL
        var detectedModel: UInt32 = 0
        
        init(viewModel: DiveDataViewModel, deviceName: String, deviceUUID: String, storedFingerprint: Data?, bluetoothManager: CoreBluetoothManager) {
            self.viewModel = viewModel
            self.deviceName = deviceName
            self.deviceUUID = deviceUUID
            self.storedFingerprint = storedFingerprint
            self.bluetoothManager = bluetoothManager
        }
    }

    private static let diveCallbackClosure: @convention(c) (
        UnsafePointer<UInt8>?,
        UInt32,
        UnsafePointer<UInt8>?,
        UInt32,
        UnsafeMutableRawPointer?
    ) -> Int32 = { data, size, fingerprint, fsize, userdata in
        guard let data = data,
              let userdata = userdata,
              let fingerprint = fingerprint else {
            return 0
        }
        
        let context = Unmanaged<CallbackContext>.fromOpaque(userdata).takeUnretainedValue()
        
        if context.bluetoothManager?.isRetrievingLogs == false {
            logInfo("🛑 Download cancelled")
            return 0
        }
        
        // 1. Capture Device Info (Once)
        if !context.hasDeviceInfo,
           let devicePtr = context.devicePtr,
           devicePtr.pointee.have_devinfo != 0 {
            context.deviceSerial = String(format: "%08x", devicePtr.pointee.devinfo.serial)
            context.detectedModel = devicePtr.pointee.devinfo.model
            
            // Capture the exact device type string from libdivecomputer
            if let modelCStr = devicePtr.pointee.model {
                context.deviceTypeFromLibDC = String(cString: modelCStr)
                logInfo("📱 Device Type from libdivecomputer: \(context.deviceTypeFromLibDC!)")
            }
            
            if let desc = devicePtr.pointee.descriptor {
                context.detectedFamily = dc_descriptor_get_type(desc)
            }
            
            logInfo("📱 Detected Device Hardware - Family: \(context.detectedFamily), Model: \(context.detectedModel)")
            
            // Now that we have device info, load the stored fingerprint if we don't have it yet
            if context.storedFingerprint == nil,
               let deviceType = context.deviceTypeFromLibDC,
               let serial = context.deviceSerial {
                context.storedFingerprint = context.viewModel.getFingerprint(forDeviceType: deviceType, serial: serial)
                if let fp = context.storedFingerprint {
                    logInfo("📍 Loaded stored fingerprint after device info: \(fp.hexString)")
                }
            }
            
            // Update storage if hardware tells us something different (e.g. 13 vs 9)
            DeviceConfiguration.updateDeviceConfigurationFromHardware(
                deviceAddress: context.deviceUUID,
                deviceDataPtr: devicePtr,
                deviceName: context.deviceName
            )
            
            context.hasDeviceInfo = true
        }
        
        let fingerprintData = Data(bytes: fingerprint, count: Int(fsize))
        
        // Capture the FIRST dive's fingerprint (most recent dive on the device)
        // This is what we'll compare against on the next download
        if context.logCount == 1 {
            context.lastFingerprint = fingerprintData
        }
        
        // Check if this dive matches our stored fingerprint (already downloaded)
        if let storedFingerprint = context.storedFingerprint {
            if storedFingerprint == fingerprintData {
                logInfo("✨ Found matching fingerprint - all new dives downloaded")
                logInfo("   Stored: \(storedFingerprint.hexString)")
                logInfo("   Current: \(fingerprintData.hexString)")
                context.fingerprintMatched = true
                return 0  // Stop enumeration - we've reached already-downloaded dives
            } else {
                logInfo("📥 Dive #\(context.logCount) - New dive found")
                if context.logCount == 1 {
                    logInfo("   Stored fingerprint: \(storedFingerprint.hexString)")
                    logInfo("   Current fingerprint: \(fingerprintData.hexString)")
                }
            }
        } else {
            logInfo("📥 Dive #\(context.logCount) - Downloading (no stored fingerprint)")
        }
        
        // 4. Parse & Store Dive
        var familyToUse: dc_family_t
        var modelToUse: UInt32
        
        // PRIORITY ORDER FOR MODEL SELECTION:
        // 1. Hardware Detection (Most reliable if available)
        // 2. Stored/Forced Configuration (What the user selected)
        // 3. Name-based Detection (Fallback)
        
        if context.detectedModel != 0 {
            familyToUse = context.detectedFamily
            modelToUse = context.detectedModel
        } else if let stored = DeviceStorage.shared.getStoredDevice(uuid: context.deviceUUID) {
            familyToUse = stored.family.asDCFamily
            modelToUse = stored.model
            logInfo("ℹ️ Using Stored Configuration - Model: \(modelToUse)")
        } else if let deviceInfo = DeviceConfiguration.fromName(context.deviceName) {
            familyToUse = deviceInfo.family.asDCFamily
            modelToUse = deviceInfo.model
        } else {
            logError("❌ Unknown device configuration")
            return 0
        }

        guard let deviceFamily = DeviceConfiguration.DeviceFamily(dcFamily: familyToUse) else {
            logError("❌ Failed to map C family ID \(familyToUse) to Swift DeviceFamily enum")
            return 0
        }

        do {
            let diveData = try GenericParser.parseDiveData(
                family: deviceFamily,
                model: modelToUse, 
                diveNumber: context.logCount,
                diveData: data,
                dataSize: Int(size)
            )
            
            DispatchQueue.main.async {
                context.viewModel.appendDives([diveData])
                context.viewModel.updateProgress(count: context.logCount)
            }
            
            context.hasNewDives = true
            context.logCount += 1
            return 1  
        } catch {
            logError("❌ Failed to parse dive #\(context.logCount): \(error)")
            return 1 
        }
    }
    
    #if os(iOS)
    private static var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif
    
    private static let fingerprintLookup: @convention(c) (
        UnsafeMutableRawPointer?, 
        UnsafePointer<CChar>?, 
        UnsafePointer<CChar>?, 
        UnsafeMutablePointer<Int>?
    ) -> UnsafeMutablePointer<UInt8>? = { context, deviceType, serial, size in
        guard let context = context, let size = size else {
            logWarning("⚠️ Fingerprint lookup called with nil context or size")
            return nil
        }
        
        let viewModel = Unmanaged<DiveDataViewModel>.fromOpaque(context).takeUnretainedValue()
        
        if let serialStr = serial.map({ String(cString: $0) }),
           let typeStr = deviceType.map({ String(cString: $0) }) {
             logInfo("🔍 Fingerprint lookup called:")
             logInfo("   Device Type: \(typeStr)")
             logInfo("   Serial: \(serialStr)")
             
             if let fingerprint = viewModel.getFingerprint(forDeviceType: typeStr, serial: serialStr) {
                logInfo("✅ Returning stored fingerprint to libdivecomputer: \(fingerprint.hexString)")
                size.pointee = fingerprint.count
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: fingerprint.count)
                fingerprint.copyBytes(to: buffer, count: fingerprint.count)
                return buffer
            } else {
                logInfo("❌ No fingerprint found for device: \(typeStr), serial: \(serialStr)")
            }
        } else {
            logWarning("⚠️ Fingerprint lookup called with nil device type or serial")
        }
        return nil
    }
    
    private static var currentContext: CallbackContext?
    
    public static func retrieveDiveLogs(
            from devicePtr: UnsafeMutablePointer<device_data_t>,
            device: CBPeripheral,
            viewModel: DiveDataViewModel,
            bluetoothManager: CoreBluetoothManager,
            onProgress: ((Int, Int) -> Void)? = nil,
            completion: @escaping (Bool) -> Void
        ) {
            let retrievalQueue = DispatchQueue(label: "com.libdcswift.retrieval", qos: .userInitiated)
            
            retrievalQueue.async {
                DispatchQueue.main.async { viewModel.resetProgress() }
                
                guard let dcDevice = devicePtr.pointee.device else {
                    DispatchQueue.main.async {
                        viewModel.setDetailedError("No device connection found", status: DC_STATUS_IO)
                        completion(false)
                    }
                    return
                }

                let deviceName = device.name ?? "Unknown Device"

                // Get device type from stored configuration (user-selected) for consistent fingerprint lookups
                let storedDevice = DeviceStorage.shared.getStoredDevice(uuid: device.identifier.uuidString)
                let deviceTypeForFingerprint: String
                if let stored = storedDevice,
                   let modelInfo = DeviceConfiguration.supportedModels.first(where: { $0.modelID == stored.model && $0.family == stored.family }) {
                    deviceTypeForFingerprint = modelInfo.name
                    logInfo("📍 Using stored device config: \(modelInfo.name)")
                } else {
                    deviceTypeForFingerprint = DeviceConfiguration.getDeviceDisplayName(from: deviceName)
                    logInfo("📍 Using device name: \(deviceTypeForFingerprint)")
                }

                // Always fetch device info first if not available
                // This ensures we have the serial number for fingerprint lookup
                if devicePtr.pointee.have_devinfo == 0 {
                    logInfo("📍 Fetching device info before download...")
                    let semaphore = DispatchSemaphore(value: 0)
                    var fetchSuccess = false
                    
                    DeviceConfiguration.fetchDeviceInfo(deviceDataPtr: devicePtr) { success in
                        fetchSuccess = success
                        semaphore.signal()
                    }
                    
                    semaphore.wait()
                    
                    if !fetchSuccess {
                        logError("❌ Failed to fetch device info")
                        DispatchQueue.main.async {
                            viewModel.setDetailedError("Failed to fetch device info", status: DC_STATUS_IO)
                            completion(false)
                        }
                        return
                    }
                }

                var storedFingerprint: Data? = nil
                if devicePtr.pointee.have_devinfo != 0 {
                    let serial = String(format: "%08x", devicePtr.pointee.devinfo.serial)
                    storedFingerprint = viewModel.getFingerprint(forDeviceType: deviceTypeForFingerprint, serial: serial)

                    if let fingerprint = storedFingerprint {
                        logInfo("📍 Found stored fingerprint for incremental download: \(fingerprint.hexString)")
                        logInfo("   Device: \(deviceTypeForFingerprint), Serial: \(serial)")
                    } else {
                        logInfo("📍 No stored fingerprint - will download all dives")
                        logInfo("   Device: \(deviceTypeForFingerprint), Serial: \(serial)")
                    }
                } else {
                    logError("❌ Device info still not available after fetch attempt")
                    logInfo("📍 Proceeding with full download")
                }

                let context = CallbackContext(
                    viewModel: viewModel,
                    deviceName: deviceName,
                    deviceUUID: device.identifier.uuidString,
                    storedFingerprint: storedFingerprint,
                    bluetoothManager: bluetoothManager
                )
                context.devicePtr = devicePtr
                
                let contextPtr = UnsafeMutableRawPointer(Unmanaged.passRetained(context).toOpaque())
                
                let progressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
                    if devicePtr.pointee.have_progress != 0 {
                        onProgress?(Int(devicePtr.pointee.progress.current), Int(devicePtr.pointee.progress.maximum))
                    }
                }
                
                devicePtr.pointee.fingerprint_context = Unmanaged.passUnretained(viewModel).toOpaque()
                devicePtr.pointee.lookup_fingerprint = fingerprintLookup
                
                if storedFingerprint != nil {
                    logInfo("🔄 Starting dive enumeration (Incremental Download - only new dives)...")
                } else {
                    logInfo("🔄 Starting dive enumeration (Full Download - all dives)...")
                }
                
                let enumStatus = dc_device_foreach(dcDevice, diveCallbackClosure, contextPtr)

                // Log the exact error code for debugging
                if enumStatus != DC_STATUS_SUCCESS {
                    let errorName: String
                    switch enumStatus {
                    case DC_STATUS_UNSUPPORTED: errorName = "UNSUPPORTED"
                    case DC_STATUS_INVALIDARGS: errorName = "INVALIDARGS"
                    case DC_STATUS_NOMEMORY: errorName = "NOMEMORY"
                    case DC_STATUS_NODEVICE: errorName = "NODEVICE"
                    case DC_STATUS_NOACCESS: errorName = "NOACCESS"
                    case DC_STATUS_IO: errorName = "IO"
                    case DC_STATUS_TIMEOUT: errorName = "TIMEOUT"
                    case DC_STATUS_PROTOCOL: errorName = "PROTOCOL"
                    case DC_STATUS_DATAFORMAT: errorName = "DATAFORMAT"
                    case DC_STATUS_CANCELLED: errorName = "CANCELLED"
                    default: errorName = "UNKNOWN(\(enumStatus))"
                    }
                    logError("❌ dc_device_foreach returned DC_STATUS_\(errorName) (code: \(enumStatus))")
                    logError("   Context: hasNewDives=\(context.hasNewDives), logCount=\(context.logCount)")
                }

                progressTimer.invalidate()

                DispatchQueue.main.async {
                    // Determine the outcome of the download
                    let downloadSucceeded: Bool
                    let shouldSaveFingerprint: Bool
                    
                    switch enumStatus {
                    case DC_STATUS_SUCCESS:
                        // Normal successful completion
                        downloadSucceeded = true
                        shouldSaveFingerprint = context.hasNewDives
                        
                    case DC_STATUS_PROTOCOL:
                        // Protocol error - could be genuine error OR early termination from callback
                        if context.fingerprintMatched {
                            // We stopped because we found matching fingerprint (no new dives)
                            logInfo("ℹ️ Download stopped at stored fingerprint - no new dives")
                            downloadSucceeded = true
                            shouldSaveFingerprint = false  // Don't update fingerprint if no new dives
                        } else if context.hasNewDives {
                            // We got some dives but then hit protocol error - partial download
                            logWarning("⚠️ Protocol error after downloading \(context.logCount - 1) dive(s)")
                            downloadSucceeded = false
                            shouldSaveFingerprint = false  // Don't save partial download fingerprint
                        } else if context.storedFingerprint != nil {
                            // Protocol error with fingerprint but no dives downloaded
                            logInfo("ℹ️ Protocol error with stored fingerprint - likely no new dives")
                            downloadSucceeded = true
                            shouldSaveFingerprint = false
                        } else {
                            // Protocol error before getting any dives - genuine error
                            logError("❌ Protocol error before downloading any dives")
                            downloadSucceeded = false
                            shouldSaveFingerprint = false
                        }
                        
                    default:
                        // Any other error status
                        downloadSucceeded = false
                        shouldSaveFingerprint = false
                    }
                    
                    // Handle the outcome
                    if !downloadSucceeded {
                        logWarning("⚠️ Download incomplete - fingerprint NOT saved to allow full retry")
                        viewModel.setDetailedError("Download incomplete - DC_STATUS error code: \(enumStatus)", status: enumStatus)
                        completion(false)
                    } else {
                        // Download completed successfully
                        if shouldSaveFingerprint, let lastFP = context.lastFingerprint, let serial = context.deviceSerial {
                            // Use stored device configuration (user-selected) for consistent fingerprint storage
                            let deviceType: String
                            if let stored = DeviceStorage.shared.getStoredDevice(uuid: context.deviceUUID),
                               let modelInfo = DeviceConfiguration.supportedModels.first(where: { $0.modelID == stored.model && $0.family == stored.family }) {
                                deviceType = modelInfo.name
                            } else {
                                // Fall back to libdivecomputer name or device name
                                deviceType = context.deviceTypeFromLibDC ?? context.deviceName
                            }
                            logInfo("✅ Download completed - saving fingerprint of last dive for incremental downloads")
                            logInfo("   Device Type: \(deviceType)")
                            logInfo("   Serial: \(serial)")
                            logInfo("   Fingerprint: \(lastFP.hexString)")
                            viewModel.saveFingerprint(lastFP, deviceType: deviceType, serial: serial)
                            viewModel.updateProgress(.completed)
                        } else if context.fingerprintMatched || (context.storedFingerprint != nil && !context.hasNewDives) {
                            logInfo("ℹ️ No new dives found")
                            viewModel.updateProgress(.noNewDives)
                        } else {
                            viewModel.updateProgress(.completed)
                        }
                        completion(true)
                    }
                    
                    context.isCompleted = true
                    Unmanaged<CallbackContext>.fromOpaque(contextPtr).release()
                    
                    #if os(iOS)
                    endBackgroundTask()
                    #endif
                }
                
                currentContext = context
            }
        }
    
    #if os(iOS)
    private static func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
    #endif
    
    public static func getCurrentContext() -> CallbackContext? {
        return currentContext
    }
}
