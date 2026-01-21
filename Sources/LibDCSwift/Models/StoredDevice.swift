import Foundation
import CoreBluetooth

extension Notification.Name {
    public static let deviceForgotten = Notification.Name("com.libdc.deviceForgotten")
}

public class StoredDevice: Codable {
   public let uuid: String
   public let name: String
   public let family: DeviceConfiguration.DeviceFamily
   public let model: UInt32
   public let lastConnected: Date
   public var serial: String?  // Hardware serial number for fingerprint tracking

   public init(uuid: String, name: String, family: DeviceConfiguration.DeviceFamily, model: UInt32, serial: String? = nil) {
       self.uuid = uuid
       self.name = name
       self.family = family
       self.model = model
       self.lastConnected = Date()
       self.serial = serial
   }
   
   private enum CodingKeys: String, CodingKey {
       case uuid
       case name
       case family
       case model
       case lastConnected
       case serial
   }

   public required init(from decoder: Decoder) throws {
       let container = try decoder.container(keyedBy: CodingKeys.self)
       uuid = try container.decode(String.self, forKey: .uuid)
       name = try container.decode(String.self, forKey: .name)
       family = try container.decode(DeviceConfiguration.DeviceFamily.self, forKey: .family)
       model = try container.decode(UInt32.self, forKey: .model)
       lastConnected = try container.decode(Date.self, forKey: .lastConnected)
       serial = try container.decodeIfPresent(String.self, forKey: .serial)  // Optional for backward compatibility
   }

   public func encode(to encoder: Encoder) throws {
       var container = encoder.container(keyedBy: CodingKeys.self)
       try container.encode(uuid, forKey: .uuid)
       try container.encode(name, forKey: .name)
       try container.encode(family, forKey: .family)
       try container.encode(model, forKey: .model)
       try container.encode(lastConnected, forKey: .lastConnected)
       try container.encodeIfPresent(serial, forKey: .serial)
   }
}

@objc public class DeviceStorage: NSObject {
   public static let shared = DeviceStorage()
   
   private let defaults = UserDefaults.standard
   private let storageKey = "com.libdc.storedDevices"
   
   private var storedDevices: [StoredDevice] = []
   
   private override init() {
       super.init()
       loadDevices()
   }
   
   private func loadDevices() {
       if let data = defaults.data(forKey: storageKey) {
           do {
               let devices = try JSONDecoder().decode([StoredDevice].self, from: data)
               storedDevices = devices
               logDebug("Loaded \(devices.count) devices from UserDefaults")
           } catch {
               logError("Failed to decode stored devices: \(error)")
           }
       } else {
           logDebug("No stored devices data found in UserDefaults")
       }
   }
   
   private func saveDevices() {
       do {
           let data = try JSONEncoder().encode(storedDevices)
           defaults.set(data, forKey: storageKey)
           defaults.synchronize() // Force immediate save
           logDebug("Saved \(storedDevices.count) devices to UserDefaults")
       } catch {
           logError("Failed to save devices: \(error)")
       }
   }
   
   public func storeDevice(uuid: String, name: String, family: DeviceConfiguration.DeviceFamily, model: UInt32, serial: String? = nil) {
       let device = StoredDevice(uuid: uuid, name: name, family: family, model: model, serial: serial)
       if let index = storedDevices.firstIndex(where: { $0.uuid == uuid }) {
           // Preserve existing serial if new one not provided
           let existingSerial = storedDevices[index].serial
           let deviceWithSerial = StoredDevice(uuid: uuid, name: name, family: family, model: model, serial: serial ?? existingSerial)
           storedDevices[index] = deviceWithSerial
           logDebug("Updated stored device: \(name)")
       } else {
           storedDevices.append(device)
           logDebug("Added new stored device: \(name)")
       }
       saveDevices()

       // Verify storage
       if let stored = getStoredDevice(uuid: uuid) {
           logDebug("Successfully stored device: \(stored.name)")
       } else {
           logError("Failed to store device: \(name)")
       }
   }

   /// Updates the serial number for an existing stored device
   public func updateDeviceSerial(uuid: String, serial: String) {
       if let index = storedDevices.firstIndex(where: { $0.uuid == uuid }) {
           storedDevices[index].serial = serial
           saveDevices()
           logDebug("Updated serial for device \(storedDevices[index].name): \(serial)")
       }
   }
   
   public func getStoredDevice(uuid: String) -> StoredDevice? {
       return storedDevices.first { $0.uuid == uuid }
   }
   
   public func removeDevice(uuid: String) {
       // Get device info before removing for fingerprint cleanup
       if let device = storedDevices.first(where: { $0.uuid == uuid }) {
           // Get the device type name for fingerprint lookup
           if let modelInfo = DeviceConfiguration.supportedModels.first(where: { $0.modelID == device.model && $0.family == device.family }),
              let serial = device.serial {
               // Clear the fingerprint for this device
               DeviceFingerprintStorage.shared.clearFingerprint(forDeviceType: modelInfo.name, serial: serial)
               logInfo("🗑️ Cleared fingerprint for \(modelInfo.name) (serial: \(serial))")
           } else if device.serial == nil {
               // No serial stored - try to clear fingerprints matching the device type for any serial
               if let modelInfo = DeviceConfiguration.supportedModels.first(where: { $0.modelID == device.model && $0.family == device.family }) {
                   logWarning("⚠️ Device has no serial stored - clearing all fingerprints for \(modelInfo.name)")
                   DeviceFingerprintStorage.shared.clearFingerprintsForDeviceType(modelInfo.name)
               } else {
                   logWarning("⚠️ Device has no serial stored and unknown model - fingerprint may not be cleared")
               }
           }
       }

       storedDevices.removeAll { $0.uuid == uuid }
       saveDevices()
       NotificationCenter.default.post(
           name: .deviceForgotten,
           object: nil,
           userInfo: ["deviceUUID": uuid]
       )
   }
   
   public func getLastConnectedDevice() -> StoredDevice? {
       return storedDevices.max(by: { $0.lastConnected < $1.lastConnected })
   }
   
   public func getAllStoredDevices() -> [StoredDevice]? {
       guard let data = defaults.data(forKey: storageKey) else {
           return nil
       }
       
       do {
           let devices = try JSONDecoder().decode([StoredDevice].self, from: data)
           return devices
       } catch {
           logError("Failed to decode stored devices: \(error)")
           return nil
       }
   }
   
   public func updateStoredDevices(_ devices: [StoredDevice]) {
       storedDevices = devices
       saveDevices()
   }
} 
