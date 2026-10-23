// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "LibDCSwift",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "LibDCSwift",
            targets: ["LibDCSwift"]
        ),
        // Static (default) — required for Expo/RN apps that cannot use use_frameworks! :dynamic
        // (Mapbox + Expo precompiled pods are static; dynamic LibDCBridge breaks EAS pod install).
        .library(
            name: "LibDCBridge",
            targets: ["LibDCBridge"]
        ),
        .library(
            name: "Clibdivecomputer",
            targets: ["Clibdivecomputer"]
        ),
        /// Local macOS CLI: scan / open protocol / download without EAS or RescuePro.
        .executable(
            name: "ble-smoke",
            targets: ["ble-smoke"]
        ),
    ],
    targets: [
        .target(
            name: "Clibdivecomputer",
            path: "libdivecomputer",
            exclude: [
                "doc",
                "m4",
                "src/serial_win32.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include/libdivecomputer"),
                .headerSearchPath("src"),
                .define("HAVE_PTHREAD_H")
            ]
        ),
        .target(
            name: "LibDCBridge",
            dependencies: ["Clibdivecomputer"],
            path: "Sources/LibDCBridge",
            sources: [
                "src/configuredc.c",
                "src/BLEBridge.m"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("../../libdivecomputer/include"),
                .headerSearchPath("../../libdivecomputer/src"),
                .define("OBJC_OLD_DISPATCH_PROTOTYPES", to: "1")
            ],
            linkerSettings: [
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("Foundation")
            ]
        ),
        .target(
            name: "LibDCSwift",
            dependencies: ["LibDCBridge", "Clibdivecomputer"],
            path: "Sources/LibDCSwift",
            sources: [
                "LibDCSwift.swift",
                "Logger.swift",
                "BLEManager.swift",
                "Models/DeviceConfiguration.swift",
                "Models/DiveData.swift",
                "Models/StoredDevice.swift",
                "Models/SampleData.swift",
                "Models/DeviceFingerprint.swift",
                "ViewModels/DiveDataViewModel.swift",
                "Parser/GenericParser.swift",
                "DiveLogRetriever.swift"
            ],
            cSettings: [
                .headerSearchPath("../LibDCBridge/include"),
                .headerSearchPath("../Clibdivecomputer/include")
            ],
            linkerSettings: [
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("Foundation")
            ]
        ),
        .executableTarget(
            name: "ble-smoke",
            dependencies: [
                "LibDCSwift",
                "LibDCBridge",
                "Clibdivecomputer",
            ],
            path: "Tools/ble-smoke",
            exclude: ["Info.plist"],
            linkerSettings: [
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("Foundation"),
                // Embed Bluetooth usage description for macOS TCC.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Tools/ble-smoke/Info.plist",
                ], .when(platforms: [.macOS])),
            ]
        ),
    ]
) 
