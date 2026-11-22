#import "ViewController.h"
#import <CoreBluetooth/CoreBluetooth.h>

static NSString *const kDeviceName = @"东风blekey-044289LE";

@interface ViewController () <CBCentralManagerDelegate, CBPeripheralDelegate>
@property (nonatomic, strong) CBCentralManager *central;
@property (nonatomic, strong) CBPeripheral *peripheral;

@property (nonatomic, strong) CBCharacteristic *ff01;
@property (nonatomic, strong) CBCharacteristic *ff02;
@property (nonatomic, strong) CBCharacteristic *c1101;
@property (nonatomic, strong) CBCharacteristic *c1102;
@property (nonatomic, strong) CBCharacteristic *c1103;

@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) NSMutableString *log;
@property (nonatomic, assign) BOOL wantConnect;
@property (nonatomic, assign) NSInteger rxCount;
@property (nonatomic, assign) BOOL fired;
@property (nonatomic, assign) NSTimeInterval tConnect;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"BLE v5";
    self.log = [NSMutableString string];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;

    UILabel *sl = [[UILabel alloc] init];
    sl.text = @"未启动";
    sl.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    sl.textAlignment = NSTextAlignmentCenter;
    sl.numberOfLines = 2;
    sl.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:sl];
    self.statusLabel = sl;

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    [btn setTitle:@"开始测试（自动）" forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [btn addTarget:self action:@selector(start) forControlEvents:UIControlEventTouchUpInside];
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    btn.backgroundColor = [UIColor systemBlueColor];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    btn.layer.cornerRadius = 8;
    [self.view addSubview:btn];

    UITextView *tv = [[UITextView alloc] init];
    tv.font = [UIFont fontWithName:@"Menlo" size:9] ?: [UIFont systemFontOfSize:9];
    tv.editable = NO;
    tv.alwaysBounceVertical = YES;
    tv.layoutManager.allowsNonContiguousLayout = YES;
    tv.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:tv];
    self.textView = tv;

    NSArray *c = @[
        [sl.topAnchor constraintEqualToAnchor:safe.topAnchor constant:4],
        [sl.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [sl.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],
        [btn.topAnchor constraintEqualToAnchor:sl.bottomAnchor constant:6],
        [btn.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [btn.widthAnchor constraintEqualToConstant:220],
        [btn.heightAnchor constraintEqualToConstant:44],
        [tv.topAnchor constraintEqualToAnchor:btn.bottomAnchor constant:8],
        [tv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:4],
        [tv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-4],
        [tv.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-4]
    ];
    [NSLayoutConstraint activateConstraints:c];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"复制" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(copyLog)];
}

- (void)copyLog {
    [UIPasteboard generalPasteboard].string = self.log;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.text = [NSString stringWithFormat:@"已复制 %lu 字符", (unsigned long)self.log.length];
    });
}

- (void)log:(NSString *)fmt, ... {
    va_list a; va_start(a, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:a];
    va_end(a);
    NSTimeInterval el = self.tConnect > 0 ? ([NSDate timeIntervalSinceReferenceDate] - self.tConnect) : 0;
    NSString *line = [NSString stringWithFormat:@"[+%.3fs] %@", el, s];
    [self.log appendString:line];
    [self.log appendString:@"\n"];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.textView.text = self.log;
        NSUInteger n = self.log.length;
        if (n > 0) [self.textView scrollRangeToVisible:NSMakeRange(n - 1, 1)];
    });
}

- (void)say:(NSString *)s {
    dispatch_async(dispatch_get_main_queue(), ^{ self.statusLabel.text = s; });
}

#pragma mark - 启动

- (void)start {
    [self.log setString:@""];
    self.wantConnect = YES;
    self.fired = NO;
    self.rxCount = 0;
    self.tConnect = 0;
    self.ff01 = self.ff02 = self.c1101 = self.c1102 = self.c1103 = nil;
    self.central = [[CBCentralManager alloc] initWithDelegate:self queue:nil
                                                       options:@{CBCentralManagerOptionShowPowerAlertKey: @YES}];
    [self say:@"初始化…"];
}

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    [self log:@"蓝牙状态=%ld", (long)central.state];
    if (central.state == CBManagerStatePoweredOn && self.wantConnect) {
        [central scanForPeripheralsWithServices:nil
                                        options:@{CBCentralManagerScanOptionAllowDuplicatesKey: @NO}];
        [self say:@"扫描中…"];
    }
}

- (void)centralManager:(CBCentralManager *)central
 didDiscoverPeripheral:(CBPeripheral *)peripheral
     advertisementData:(NSDictionary<NSString *,id> *)advertisementData
                  RSSI:(NSNumber *)RSSI {
    NSString *name = peripheral.name ?: advertisementData[CBAdvertisementDataLocalNameKey] ?: @"";
    if (![name containsString:@"东风blekey"]) return;
    [self log:@"发现目标 RSSI=%@", RSSI];
    if (peripheral.state == CBPeripheralStateDisconnected && self.wantConnect) {
        self.peripheral = peripheral;
        peripheral.delegate = self;
        [central stopScan];
        [self say:@"连接中…"];
        [central connectPeripheral:peripheral options:nil];
    }
}

- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
    self.tConnect = [NSDate timeIntervalSinceReferenceDate];
    [self log:@"✅ 已连接，开始 9 秒倒计时"];
    [self say:@"9 秒窗口"];
    [peripheral discoverServices:nil];
}

- (void)centralManager:(CBCentralManager *)central
didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    NSTimeInterval el = self.tConnect > 0 ? ([NSDate timeIntervalSinceReferenceDate] - self.tConnect) : 0;
    [self log:@"⚠️ 断开 存活 %.2f 秒  收到 %ld 帧", el, (long)self.rxCount];
    [self say:[NSString stringWithFormat:@"断开（存活 %.1fs，收 %ld 帧）", el, (long)self.rxCount]];
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    if (error) { [self log:@"服务失败 %@", error.localizedDescription]; return; }
    for (CBService *s in peripheral.services) {
        [self log:@"服务 %@", [s.UUID.UUIDString substringToIndex:MIN((NSUInteger)8, s.UUID.UUIDString.length)]];
        [peripheral discoverCharacteristics:nil forService:s];  // 全部服务都发现
    }
}

- (void)peripheral:(CBPeripheral *)peripheral
didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error {
    if (error) return;

    for (CBCharacteristic *c in service.characteristics) {
        NSString *us = [c.UUID.UUIDString uppercaseString];
        if ([us containsString:@"FF01"]) self.ff01 = c;
        else if ([us containsString:@"FF02"]) self.ff02 = c;
        else if ([us containsString:@"1101"]) self.c1101 = c;
        else if ([us containsString:@"1102"]) self.c1102 = c;
        else if ([us containsString:@"1103"]) self.c1103 = c;
    }

    // 所有服务发现完后，一次性触发
    if ((self.ff01 || self.c1102) && !self.fired) {
        self.fired = YES;
        [self log:@"=== 特征收集完成，开始全订阅 ==="];
        [self doEverything];
    }
}

// 一次性：订阅所有 notify + 立刻读 + 发握手
- (void)doEverything {
    CBPeripheral *p = self.peripheral;

    // 1. 订阅三个 notify
    if (self.ff01) {
        [self log:@"订阅 FF01"];
        [p setNotifyValue:YES forCharacteristic:self.ff01];
    }
    if (self.c1102) {
        [self log:@"订阅 1102"];
        [p setNotifyValue:YES forCharacteristic:self.c1102];
    }
    if (self.c1103) {
        [self log:@"订阅 1103"];
        [p setNotifyValue:YES forCharacteristic:self.c1103];
    }

    // 2. 立刻读三个 READ 特征（不等订阅确认）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self.c1102) { [self log:@"读 1102"]; [p readValueForCharacteristic:self.c1102]; }
        if (self.c1103) { [self log:@"读 1103"]; [p readValueForCharacteristic:self.c1103]; }
        if (self.ff01)  { [self log:@"读 FF01"]; [p readValueForCharacteristic:self.ff01]; }
    });

    // 3. 300ms 后发握手到 FF02
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self log:@"→ 握手帧 → FF02 (WRITE_NR)"];
        [self write:self.ff02
                hex:@"50231001B4E2BC0155AA8DF3A5D1C4E8CC02C80BD367E6CF395AD20BDF23C04567F1666A"
             noResp:YES];
    });

    // 4. 700ms 后发握手到 1101
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self log:@"→ 握手帧 → 1101 (WRITE)"];
        [self write:self.c1101
                hex:@"50231001B4E2BC0155AA8DF3A5D1C4E8CC02C80BD367E6CF395AD20BDF23C04567F1666A"
             noResp:NO];
    });

    // 5. 1100ms 后发握手到 1103
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self log:@"→ 握手帧 → 1103 (WRITE_NR)"];
        [self write:self.c1103
                hex:@"50231001B4E2BC0155AA8DF3A5D1C4E8CC02C80BD367E6CF395AD20BDF23C04567F1666A"
             noResp:YES];
    });

    // 6. 2.0 秒报告
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self log:@"=== 2 秒：收到 %ld 帧 ===", (long)self.rxCount];
    });

    // 7. 5.0 秒报告
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self log:@"=== 5 秒：收到 %ld 帧 ===", (long)self.rxCount];
    });

    // 8. 8.5 秒报告
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        BOOL alive = (self.peripheral.state == CBPeripheralStateConnected);
        [self log:@"=== 8.5 秒：%@  收到 %ld 帧 ===",
            alive ? @"仍连接 ✓" : @"已断开", (long)self.rxCount];
        [self say:[NSString stringWithFormat:@"%@ 收 %ld 帧",
            alive ? @"撑住 9 秒 ✓" : @"9 秒断开", (long)self.rxCount]];
    });
}

- (void)write:(CBCharacteristic *)ch hex:(NSString *)hex noResp:(BOOL)noResp {
    if (!ch) { [self log:@"  目标特征 nil，跳过"]; return; }
    NSData *d = [self dataFromHex:hex];
    if (!d) return;
    CBCharacteristicWriteType t = noResp
        ? CBCharacteristicWriteWithoutResponse : CBCharacteristicWriteWithResponse;
    [self.peripheral writeValue:d forCharacteristic:ch type:t];
}

#pragma mark - 回调

- (void)peripheral:(CBPeripheral *)peripheral
didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic
             error:(NSError *)error {
    if (error) {
        [self log:@"订阅失败 %@: %@",
            [characteristic.UUID.UUIDString substringToIndex:4], error.localizedDescription];
        return;
    }
    [self log:@"订阅确认 %@ notifying=%d",
        [characteristic.UUID.UUIDString substringToIndex:4], characteristic.isNotifying];
}

- (void)peripheral:(CBPeripheral *)peripheral
didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic
             error:(NSError *)error {
    if (error) { [self log:@"读取错误 %@", error.localizedDescription]; return; }
    NSData *d = characteristic.value;
    if (d.length == 0) {
        [self log:@"⬇️ %@ 空", [characteristic.UUID.UUIDString substringToIndex:4]];
        return;
    }
    self.rxCount++;
    [self log:@"⬇️⬇️ 收到 [%@] %luB: %@",
        [characteristic.UUID.UUIDString substringToIndex:4],
        (unsigned long)d.length, [self hexString:d]];
}

- (void)peripheral:(CBPeripheral *)peripheral
didWriteValueForCharacteristic:(CBCharacteristic *)characteristic
             error:(NSError *)error {
    if (error) {
        [self log:@"写入失败 %@: %@",
            [characteristic.UUID.UUIDString substringToIndex:4], error.localizedDescription];
    } else {
        [self log:@"写入确认 %@", [characteristic.UUID.UUIDString substringToIndex:4]];
    }
}

- (NSData *)dataFromHex:(NSString *)hex {
    NSString *s = [[hex stringByReplacingOccurrencesOfString:@" " withString:@""] uppercaseString];
    if (s.length % 2) return nil;
    NSMutableData *d = [NSMutableData data];
    for (NSUInteger i = 0; i < s.length; i += 2) {
        unsigned int v = 0;
        if (![[NSScanner scannerWithString:[s substringWithRange:NSMakeRange(i, 2)]] scanHexInt:&v]) return nil;
        uint8_t b = (uint8_t)v;
        [d appendBytes:&b length:1];
    }
    return d;
}

- (NSString *)hexString:(NSData *)d {
    const uint8_t *b = d.bytes;
    NSMutableString *s = [NSMutableString string];
    for (NSUInteger i = 0; i < d.length; i++) [s appendFormat:@"%02X", b[i]];
    return s;
}

@end
