#import "BLEBridge.h"
#import "configuredc.h"
#import <Foundation/Foundation.h>
#import <objc/message.h>

static id<CoreBluetoothManagerProtocol> bleManager = nil;

void initializeBLEManager(void) {
    Class CoreBluetoothManagerClass = NSClassFromString(@"CoreBluetoothManager");
    bleManager = [CoreBluetoothManagerClass shared];
}

ble_object_t* createBLEObject(void) {
    ble_object_t* obj = malloc(sizeof(ble_object_t));
    obj->manager = (__bridge void *)bleManager;
    return obj;
}

void freeBLEObject(ble_object_t* obj) {
    if (obj) {
        free(obj);
    }
}

static void ble_fail_stage(const char *stage) {
    NSLog(@"%s", stage);
    set_last_ble_open_stage(stage);
}

bool connectToBLEDevice(ble_object_t *io, const char *deviceAddress) {
    if (!io || !deviceAddress) {
        NSLog(@"Invalid parameters passed to connectToBLEDevice");
        ble_fail_stage("ble_packet_open: invalid args");
        return false;
    }
    
    Class CoreBluetoothManagerClass = NSClassFromString(@"CoreBluetoothManager");
    id<CoreBluetoothManagerProtocol> manager = [CoreBluetoothManagerClass shared];
    NSString *address = [NSString stringWithUTF8String:deviceAddress];
    
    bool success = [manager connectToDevice:address];
    if (!success) {
        NSLog(@"Failed to connect to device");
        ble_fail_stage("ble_packet_open: connectToDevice failed");
        return false;
    }
    
    // Wait for connection. CB callbacks use a dedicated queue — sleep, don't pump
    // the main run loop (deadlocks when already on DispatchQueue.main).
    NSDate *timeout = [NSDate dateWithTimeIntervalSinceNow:10.0];
    while ([[NSDate date] compare:timeout] == NSOrderedAscending) {
        if ([manager getPeripheralReadyState]) {
            NSLog(@"Peripheral is ready for communication");
            break;
        }
        usleep(50000); /* 50ms */
    }
    
    // Final check if we're actually ready
    if (![manager getPeripheralReadyState]) {
        NSLog(@"Timeout waiting for peripheral to be ready");
        ble_fail_stage("ble_packet_open: peripheral ready timeout");
        // Soft close — keep GATT so the host app can retry open without re-pairing.
        [manager close];
        return false;
    }

    success = [manager discoverServices];
    if (!success) {
        NSLog(@"Service discovery failed");
        ble_fail_stage("ble_packet_open: discoverServices failed");
        [manager close];
        return false;
    }

    success = [manager enableNotifications];
    if (!success) {
        NSLog(@"Failed to enable notifications");
        ble_fail_stage("ble_packet_open: enableNotifications failed");
        [manager close];
        return false;
    }

    NSLog(@"connectToBLEDevice: GATT ready, services + notifications OK");
    return true;
}

void ble_start_scan(void) {
    Class CoreBluetoothManagerClass = NSClassFromString(@"CoreBluetoothManager");
    id manager = [CoreBluetoothManagerClass shared];
    SEL sel = NSSelectorFromString(@"startScanningWithOmitUnsupportedPeripherals:");
    if ([manager respondsToSelector:sel]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(manager, sel, NO);
    }
}

void ble_stop_scan(void) {
    Class CoreBluetoothManagerClass = NSClassFromString(@"CoreBluetoothManager");
    id manager = [CoreBluetoothManagerClass shared];
    if ([manager respondsToSelector:@selector(stopScanning)]) {
        [manager performSelector:@selector(stopScanning)];
    }
}

bool discoverServices(ble_object_t *io) {
    Class CoreBluetoothManagerClass = NSClassFromString(@"CoreBluetoothManager");
    id<CoreBluetoothManagerProtocol> manager = [CoreBluetoothManagerClass shared];
    return [manager discoverServices];
}

bool enableNotifications(ble_object_t *io) {
    Class CoreBluetoothManagerClass = NSClassFromString(@"CoreBluetoothManager");
    id<CoreBluetoothManagerProtocol> manager = [CoreBluetoothManagerClass shared];
    return [manager enableNotifications];
}

dc_status_t ble_set_timeout(ble_object_t *io, int timeout) {
    return DC_STATUS_SUCCESS;
}

dc_status_t ble_ioctl(ble_object_t *io, unsigned int request, void *data, size_t size) {
    return DC_STATUS_UNSUPPORTED;
}

dc_status_t ble_sleep(ble_object_t *io, unsigned int milliseconds) {
    // Pump main run loop so CoreBluetooth (main-queue) callbacks still run.
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:milliseconds / 1000.0];
    while ([[NSDate date] compare:end] == NSOrderedAscending) {
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    return DC_STATUS_SUCCESS;
}

dc_status_t ble_read(ble_object_t *io, void *buffer, size_t requested, size_t *actual)
{
    if (!io || !buffer || !actual) {
        return DC_STATUS_INVALIDARGS;
    }

    Class CoreBluetoothManagerClass = NSClassFromString(@"CoreBluetoothManager");
    id<CoreBluetoothManagerProtocol> manager = [CoreBluetoothManagerClass shared];

    // Return one BLE packet at a time to preserve packet boundaries for SLIP framing
    NSData *partialData = [manager readDataPartial:(int)requested];

    if (!partialData || partialData.length == 0) {
        *actual = 0;
        return DC_STATUS_IO;
    }
    memcpy(buffer, partialData.bytes, partialData.length);
    *actual = partialData.length;
    return DC_STATUS_SUCCESS;
}

dc_status_t ble_write(ble_object_t *io, const void *data, size_t size, size_t *actual) {
    Class CoreBluetoothManagerClass = NSClassFromString(@"CoreBluetoothManager");
    id<CoreBluetoothManagerProtocol> manager = [CoreBluetoothManagerClass shared];
    NSData *nsData = [NSData dataWithBytes:data length:size];
    
    if ([manager writeData:nsData]) {
        *actual = size;
        return DC_STATUS_SUCCESS;
    } else {
        *actual = 0;
        return DC_STATUS_IO;
    }
}

dc_status_t ble_close(ble_object_t *io) {
    Class CoreBluetoothManagerClass = NSClassFromString(@"CoreBluetoothManager");
    id<CoreBluetoothManagerProtocol> manager = [CoreBluetoothManagerClass shared];
    [manager close];
    return DC_STATUS_SUCCESS;
}
