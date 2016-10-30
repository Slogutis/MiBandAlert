#import "MBALCentralManager.h"
#import <CoreBluetooth/CoreBluetooth.h>
#import "MBALPeripheral.h"

static char *const kQueueLabel = "com.julioverne.miband";

@interface MBALCentralManager ()<CBCentralManagerDelegate>

@property (nonatomic, strong) CBCentralManager *cbCentralManager;
@property (nonatomic, strong) NSMutableArray *discoveredPeripherals;
@property (nonatomic, copy) MBDiscoverPeripheralBlock discoverPeripheralBlock;
@property (nonatomic, copy) MBConnectResultBlock connectResultBlock;

@end

@implementation MBALCentralManager

+ (instancetype)sharedCentralManager {
    static MBALCentralManager *sharedCentralManager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedCentralManager = [[MBALCentralManager alloc] init];
    });
    return sharedCentralManager;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        self.discoveredPeripherals = [[NSMutableArray alloc] init];
        dispatch_queue_t queue = dispatch_queue_create(kQueueLabel, DISPATCH_QUEUE_SERIAL);
        self.cbCentralManager = [[CBCentralManager alloc] initWithDelegate:self queue:queue];
    }
    return self;
}

- (void)scanForMiBandWithBlock:(void (^)(MBALPeripheral *, NSNumber *, NSError *))discoverPeripheralBlock {
    NSString *serviceAddress = [NSString stringWithFormat:@"%x", MBServiceTypeDefault];
    CBUUID *serviceUUID = [CBUUID UUIDWithString:serviceAddress];
    if ([self.cbCentralManager respondsToSelector:@selector(retrieveConnectedPeripheralsWithServices:)]) {  //iOS 7+
        NSArray *connectedPeripherals = [self.cbCentralManager retrieveConnectedPeripheralsWithServices:@[ serviceUUID ]];
        for (CBPeripheral *cbPeripheral in connectedPeripherals) {
            [self onDiscoverPeripheral:cbPeripheral RSSI:nil];
        }
    }
    
    self.discoverPeripheralBlock = discoverPeripheralBlock;
    [self.cbCentralManager scanForPeripheralsWithServices:@[ serviceUUID ]
                                                  options:@{ CBCentralManagerScanOptionAllowDuplicatesKey: @YES }];
    _scanning = YES;
}

- (void)connectPeripheral:(MBALPeripheral *)peripheral withResultBlock:(MBConnectResultBlock)resultBlock {
    self.connectResultBlock = resultBlock;
    [self.cbCentralManager connectPeripheral:[peripheral cbPeripheral]
                                     options:@{ CBConnectPeripheralOptionNotifyOnConnectionKey: @YES,
                                                CBConnectPeripheralOptionNotifyOnDisconnectionKey: @YES,
                                                CBConnectPeripheralOptionNotifyOnNotificationKey: @YES }];
}

- (void)stopScan {
    [self.cbCentralManager stopScan];
    _scanning = NO;
}

#pragma mark - Private Methods
- (NSArray *)peripherals {
    return [self.discoveredPeripherals copy];
}

- (void)onDiscoverPeripheral:(CBPeripheral *)cbPeripheral RSSI:(NSNumber *)RSSI {
    __weak __typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        MBALPeripheral *peripheral = [weakSelf findPeripheral:cbPeripheral];
        if (!peripheral) {
            peripheral = [[MBALPeripheral alloc] initWithPeripheral:cbPeripheral centralManager:weakSelf];
            if (![weakSelf.discoveredPeripherals containsObject:peripheral]) {
                [weakSelf.discoveredPeripherals addObject:peripheral];
            }
        }
        if (weakSelf.discoverPeripheralBlock) {
            weakSelf.discoverPeripheralBlock(peripheral, RSSI, nil);
        }
    });
}

- (MBALPeripheral *)findPeripheral:(CBPeripheral *)cbPeripheral {
    MBALPeripheral *result = nil;
    
    NSArray *cachedPeripherals = [self.discoveredPeripherals copy];
    for (MBALPeripheral *peripheral in cachedPeripherals) {
        if (peripheral.cbPeripheral == cbPeripheral) {
            result = peripheral;
            break;
        }
    }
    return result;
}

- (void)executeConnectResultBlockInMainThread:(MBALPeripheral *)peripheral withError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.connectResultBlock(peripheral, error);
    });
}

#pragma mark - CBCentralManagerDelegate Methods
- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    __weak __typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        switch (central.state) {
            case CBCentralManagerStatePoweredOn:
                if (self.poweredOnBlock) {
                    self.poweredOnBlock(weakSelf);
                }
                break;
            case CBCentralManagerStatePoweredOff: {
                [self.discoveredPeripherals removeAllObjects];
                if (self.poweredOffBlock) {
                    self.poweredOffBlock(weakSelf);
                }
                break;
            }
            case CBCentralManagerStateResetting:
                NSLog(@"CBCentralManagerDidUpdateState -> Resetting");
                break;
            case CBCentralManagerStateUnauthorized:
                NSLog(@"CBCentralManagerDidUpdateState -> Unauthorized");
                break;
            case CBCentralManagerStateUnsupported:
                NSLog(@"CBCentralManagerDidUpdateState -> Unsupported");
                break;
            case CBCentralManagerStateUnknown:
                NSLog(@"CBCentralManagerDidUpdateState -> Unknow");
                break;
            default:
                break;
        }
    });
}

- (void)centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)cbPeripheral advertisementData:(NSDictionary *)advertisementData RSSI:(NSNumber *)RSSI {
    [self onDiscoverPeripheral:cbPeripheral RSSI:RSSI];
}

- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)cbPeripheral {
    if (self.connectResultBlock) {
        MBALPeripheral *peripheral = [self findPeripheral:cbPeripheral];
        NSString *serviceAddress = [NSString stringWithFormat:@"%x", MBServiceTypeDefault];
        CBUUID *serviceUUID = [CBUUID UUIDWithString:serviceAddress];
        [peripheral discoverServices:@[ serviceUUID ] withBlock:^(NSArray *services, NSError *error) {
            __weak __typeof(self) weakSelf = self;
            if (error || [services count] == 0) {   //found services error.
                if (error == nil) {
                    error = [NSError errorWithDomain:NSCocoaErrorDomain
                                                code:0
                                            userInfo:@{ NSLocalizedDescriptionKey: @"No services found." }];
                }
                [weakSelf executeConnectResultBlockInMainThread:peripheral withError:error];
            } else {
                [peripheral discoverCharacteristics:nil
                    forService:peripheral.service
                    withBlock:^(NSArray *characteristics, NSError *error) {
                        if (error == nil && [characteristics count] == 0) {
                            error = [NSError errorWithDomain:NSCocoaErrorDomain
                                                        code:0
                                                    userInfo:@{ NSLocalizedDescriptionKey: @"No characteristics found." }];
                        }
                        [weakSelf executeConnectResultBlockInMainThread:peripheral withError:error];
                    }];
            }
        }];
    }
}

- (void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    if (self.connectResultBlock) {
        __weak __typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.connectResultBlock([self findPeripheral:peripheral], error);
        });
    }
}

- (void)centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)cbPeripheral error:(NSError *)error {
    if (self.disconnectedBlock) {
        __weak __typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            MBALPeripheral *peripheral = [weakSelf findPeripheral:cbPeripheral];
            weakSelf.disconnectedBlock(peripheral, error);
        });
    }
}

- (void)centralManager:(CBCentralManager *)central didRetrieveConnectedPeripherals:(NSArray *)peripherals {
    for (CBPeripheral *cbPeripheral in peripherals) {
        [self onDiscoverPeripheral:cbPeripheral RSSI:nil];
    }
}

@end
