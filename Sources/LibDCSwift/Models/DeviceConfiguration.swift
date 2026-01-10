import Foundation
import CoreBluetooth
import Clibdivecomputer
import LibDCBridge

@objc public class DeviceConfiguration: NSObject {
    
    // Helper struct for UI Selection
    public struct ComputerModel: Identifiable, Hashable {
        public let id = UUID()
        public let name: String
        public let family: DeviceFamily
        public let modelID: UInt32
        
        public static func == (lhs: ComputerModel, rhs: ComputerModel) -> Bool {
            return lhs.family == rhs.family && lhs.modelID == rhs.modelID
        }
        
        public func hash(into hasher: inout Hasher) {
            hasher.combine(family)
            hasher.combine(modelID)
        }
    }
    
    // List of selectable models for the UI
    public static let supportedModels: [ComputerModel] = [
        ComputerModel(name: "Shearwater Peregrine", family: .shearwaterPetrel, modelID: 9),
        ComputerModel(name: "Shearwater Peregrine TX", family: .shearwaterPetrel, modelID: 13),
        ComputerModel(name: "Shearwater Petrel", family: .shearwaterPetrel, modelID: 3),
        ComputerModel(name: "Shearwater Petrel 2", family: .shearwaterPetrel, modelID: 3),
        ComputerModel(name: "Shearwater Petrel 3", family: .shearwaterPetrel, modelID: 10),
        ComputerModel(name: "Shearwater Perdix", family: .shearwaterPetrel, modelID: 5),
        ComputerModel(name: "Shearwater Perdix AI", family: .shearwaterPetrel, modelID: 6),
        ComputerModel(name: "Shearwater Perdix 2", family: .shearwaterPetrel, modelID: 11),
        ComputerModel(name: "Shearwater Teric", family: .shearwaterPetrel, modelID: 8),
        ComputerModel(name: "Shearwater Tern", family: .shearwaterPetrel, modelID: 12),
        ComputerModel(name: "Shearwater NERD 2", family: .shearwaterPetrel, modelID: 7),
        ComputerModel(name: "Suunto EON Steel", family: .suuntoEonSteel, modelID: 0),
        ComputerModel(name: "Suunto EON Core", family: .suuntoEonSteel, modelID: 0),
        ComputerModel(name: "Suunto D5", family: .suuntoEonSteel, modelID: 0),
        ComputerModel(name: "Scubapro G2", family: .uwatecSmart, modelID: 0),
    ]

    /// Represents the family of dive computers that support BLE communication.
    public enum DeviceFamily: String, Codable, CaseIterable {
        case suuntoEonSteel
        case shearwaterPetrel
        case hwOstc3
        case uwatecSmart
        case oceanicAtom2
        case pelagicI330R
        case maresIconHD
        case deepsixExcursion
        case deepbluCosmiq
        case oceansS1
        case mcleanExtreme
        case divesoftFreedom
        case cressiGoa
        case diveSystem
        
        /// Converts the Swift enum to libdivecomputer's dc_family_t type
        public var asDCFamily: dc_family_t {
            switch self {
            case .suuntoEonSteel: return DC_FAMILY_SUUNTO_EONSTEEL
            case .shearwaterPetrel: return DC_FAMILY_SHEARWATER_PETREL
            case .hwOstc3: return DC_FAMILY_HW_OSTC3
            case .uwatecSmart: return DC_FAMILY_UWATEC_SMART
            case .oceanicAtom2: return DC_FAMILY_OCEANIC_ATOM2
            case .pelagicI330R: return DC_FAMILY_PELAGIC_I330R
            case .maresIconHD: return DC_FAMILY_MARES_ICONHD
            case .deepsixExcursion: return DC_FAMILY_DEEPSIX_EXCURSION
            case .deepbluCosmiq: return DC_FAMILY_DEEPBLU_COSMIQ
            case .oceansS1: return DC_FAMILY_OCEANS_S1
            case .mcleanExtreme: return DC_FAMILY_MCLEAN_EXTREME
            case .divesoftFreedom: return DC_FAMILY_DIVESOFT_FREEDOM
            case .cressiGoa: return DC_FAMILY_CRESSI_GOA
            case .diveSystem: return DC_FAMILY_DIVESYSTEM_IDIVE
            }
        }
        
        /// Creates a DeviceFamily instance from libdivecomputer's dc_family_t type
        init?(dcFamily: dc_family_t) {
            switch dcFamily {
            case DC_FAMILY_SUUNTO_EONSTEEL: self = .suuntoEonSteel
            case DC_FAMILY_SHEARWATER_PETREL: self = .shearwaterPetrel
            case DC_FAMILY_HW_OSTC3: self = .hwOstc3
            case DC_FAMILY_UWATEC_SMART: self = .uwatecSmart
            case DC_FAMILY_OCEANIC_ATOM2: self = .oceanicAtom2
            case DC_FAMILY_PELAGIC_I330R: self = .pelagicI330R
            case DC_FAMILY_MARES_ICONHD: self = .maresIconHD
            case DC_FAMILY_DEEPSIX_EXCURSION: self = .deepsixExcursion
            case DC_FAMILY_DEEPBLU_COSMIQ: self = .deepbluCosmiq
            case DC_FAMILY_OCEANS_S1: self = .oceansS1
            case DC_FAMILY_MCLEAN_EXTREME: self = .mcleanExtreme
            case DC_FAMILY_DIVESOFT_FREEDOM: self = .divesoftFreedom
            case DC_FAMILY_CRESSI_GOA: self = .cressiGoa
            case DC_FAMILY_DIVESYSTEM_IDIVE: self = .diveSystem
            default: return nil
            }
        }
    }
    
    /// Known BLE service UUIDs for supported dive computers.
    private static let knownServiceUUIDs: [CBUUID] = [
        CBUUID(string: "0000fefb-0000-1000-8000-00805f9b34fb"), // Heinrichs-Weikamp Telit/Stollmann
        CBUUID(string: "2456e1b9-26e2-8f83-e744-f34f01e9d701"), // Heinrichs-Weikamp U-Blox
        CBUUID(string: "544e326b-5b72-c6b0-1c46-41c1bc448118"), // Mares BlueLink Pro
        CBUUID(string: "6e400001-b5a3-f393-e0a9-e50e24dcca9e"), // Nordic Semi UART
        CBUUID(string: "98ae7120-e62e-11e3-badd-0002a5d5c51b"), // Suunto EON Steel/Core
        CBUUID(string: "cb3c4555-d670-4670-bc20-b61dbc851e9a"), // Pelagic i770R/i200C
        CBUUID(string: "ca7b0001-f785-4c38-b599-c7c5fbadb034"), // Pelagic i330R/DSX
        CBUUID(string: "fdcdeaaa-295d-470e-bf15-04217b7aa0a0"), // ScubaPro G2/G3
        CBUUID(string: "fe25c237-0ece-443c-b0aa-e02033e7029d"), // Shearwater Perdix/Teric
        CBUUID(string: "0000fcef-0000-1000-8000-00805f9b34fb")  // Divesoft Freedom
    ]
    
    public static func getKnownServiceUUIDs() -> [CBUUID] {
        return knownServiceUUIDs
    }

    /// Attempts to open a BLE connection to a dive computer.
    public static func openBLEDevice(
        name: String,
        deviceAddress: String,
        forcedModel: (family: DeviceFamily, model: UInt32)? = nil
    ) -> Bool {
        logDebug("Attempting to open BLE device: \(name) at address: \(deviceAddress)")
        
        var deviceData: UnsafeMutablePointer<device_data_t>?
        let storedDevice = DeviceStorage.shared.getStoredDevice(uuid: deviceAddress)
        
        if let storedDevice = storedDevice {
            logDebug("Found stored device configuration - Family: \(storedDevice.family), Model: \(storedDevice.model)")
        }
        
        // Determine which configuration to use: Forced > Stored > Default(0)
        let familyToUse = forcedModel?.family.asDCFamily ?? storedDevice?.family.asDCFamily ?? DC_FAMILY_NULL
        let modelToUse = forcedModel?.model ?? storedDevice?.model ?? 0
        
        if let forced = forcedModel {
            logInfo("Using forced configuration: \(forced.family) Model: \(forced.model)")
        }
        
        let status = open_ble_device_with_identification(
            &deviceData,
            name,
            deviceAddress,
            familyToUse,
            modelToUse
        )
        
        if status == DC_STATUS_SUCCESS, let data = deviceData {
            logDebug("Successfully opened device")
            logDebug("Device data pointer allocated at: \(String(describing: data))")
            
            if let forced = forcedModel {
                DeviceStorage.shared.storeDevice(
                    uuid: deviceAddress,
                    name: name,
                    family: forced.family,
                    model: forced.model
                )
            } else if storedDevice == nil {
                // Initial save for a new auto-detected device
                if let deviceInfo = fromName(name) {
                    DeviceStorage.shared.storeDevice(
                        uuid: deviceAddress,
                        name: name,
                        family: deviceInfo.family,
                        model: deviceInfo.model
                    )
                }
            }
            
            DispatchQueue.main.async {
                if let manager = CoreBluetoothManager.shared() as? CoreBluetoothManager {
                    manager.openedDeviceDataPtr = data
                }
            }
            return true
        }
        
        logError("Failed to open device (status: \(status))")
        if let data = deviceData {
            data.deallocate()
        }
        return false
    }
    
    // Updates stored device configuration with actual device info from hardware ID
    public static func updateDeviceConfigurationFromHardware(
        deviceAddress: String,
        deviceDataPtr: UnsafeMutablePointer<device_data_t>,
        deviceName: String
    ) {
        guard deviceDataPtr.pointee.have_devinfo != 0 else {
            logDebug("Device info not yet available for \(deviceName)")
            return
        }
        
        let actualModel = deviceDataPtr.pointee.devinfo.model
        
        if let storedDevice = DeviceStorage.shared.getStoredDevice(uuid: deviceAddress) {
            if storedDevice.model != actualModel {
                logInfo("🔄 Updating stored device model from \(storedDevice.model) to actual model \(actualModel) for \(deviceName)")
                DeviceStorage.shared.storeDevice(
                    uuid: deviceAddress,
                    name: deviceName,
                    family: storedDevice.family,
                    model: actualModel
                )
            }
        } else if let deviceInfo = fromName(deviceName) {
            if deviceInfo.model != actualModel {
                logInfo("🔄 Storing device with actual model \(actualModel) (name suggested \(deviceInfo.model)) for \(deviceName)")
                DeviceStorage.shared.storeDevice(
                    uuid: deviceAddress,
                    name: deviceName,
                    family: deviceInfo.family,
                    model: actualModel
                )
            }
        }
    }
    
    public static func fromName(_ name: String) -> (family: DeviceFamily, model: UInt32)? {
        var descriptor: OpaquePointer?
        let rc = find_descriptor_by_name(&descriptor, name)
        if rc == DC_STATUS_SUCCESS, let desc = descriptor {
            let family = dc_descriptor_get_type(desc)
            let model = dc_descriptor_get_model(desc)
            if let deviceFamily = DeviceFamily(dcFamily: family) {
                dc_descriptor_free(desc)
                return (deviceFamily, model)
            }
            dc_descriptor_free(desc)
        }
        return nil
    }
    
    public static func getDeviceDisplayName(from name: String) -> String {
        if let cString = get_formatted_device_name(name) {
            defer { free(cString) }
            return String(cString: cString)
        }
        return name
    }
    
    private var descriptor: OpaquePointer?
    private static var context: OpaquePointer?
    
    public static func setupContext() {
        if context == nil {
            let rc = dc_context_new(&context)
            if rc != DC_STATUS_SUCCESS {
                logError("Failed to create dive computer context")
            }
        }
    }
    
    public static func cleanupContext() {
        if let ctx = context {
            dc_context_free(ctx)
            context = nil
        }
    }
    
    public static func createParser(family: dc_family_t, model: UInt32, data: Data) -> OpaquePointer? {
        guard let context = context else {
            logError("No dive computer context available")
            return nil
        }
        
        var parser: OpaquePointer?
        let rc = create_parser_for_device(
            &parser,
            context,
            family,
            model,
            [UInt8](data),
            data.count
        )
        if rc != DC_STATUS_SUCCESS {
            logError("Failed to create parser: \(rc)")
            return nil
        }
        return parser
    }
}