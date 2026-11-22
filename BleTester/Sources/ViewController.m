#import "ViewController.h"
#import <CoreBluetooth/CoreBluetooth.h>

static NSString *const kDeviceName = @"东风blekey-044289LE";

// 已抓到的帧
typedef struct {
    const char *label;
    const char *hex;
} FrameDef;

static FrameDef kFrames[] = {
    {"【开锁】21:19:37",
     "5002240100375D198A25F42A1285468C3AC35953385514A5678492C82D9DF4DF6BA870A8DE4DC21B84E0A88E04826BDE01D311F0919782F1"},
    {"【闭锁】21:19:44",
     "5002240100375D191AA88C24CEE66C751E7221DA4DE53D73A6BE39B0E649C4CF1957FB1A4BD5360546BA658557DCBEEC05A5397108C2CAE6"},
    {"【未知】20:49:10",
     "5002240100375D19786683B96AEA6F0793BF5427258A8E5EE38F16C3643CF4C3F1F930E80E453BC1EEEC24A4984CA6E8D720C588676D7009"},
    {"【未知】21:00:02",
     "5002240100375D19296706DA8882FDB6CB2719F2A0D5BDDC4C58E8B85EEBF345661D950B5DE8B047B6D0CD87CE8463D437B2A69218734815"},
    {"【握手】21:19:32",
     "50231001507DF61D10458F9C8C0E201716EC888695A2D4D0BAC33F47A8972134F0B40F93"},
    {"【握手】21:00:01",
     "50231001B4E2BC0155AA8DF3A5D1C4E8CC02C80BD367E6CF395AD20BDF23C04567F1666A"},
};
#define FRAME_COUNT (sizeof(kFrames) / sizeof(kFrames[0]))

@interface ViewController () <CBCentralManagerDelegate, CBPeripheralDelegate>
@property (nonatomic, strong) CBCentralManager *central;
@property (nonatomic, strong) CBPeripheral *peripheral;
@property (nonatomic, strong) CBCharacteristic *notifyChar;
@property (nonatomic, strong) CBCharacteristic *writeChar;
@property (nonatomic, strong) CBService *ff00Service;
@property (nonatomic, strong) CBService *svc1100;
@property (nonatomic, strong) CBCharacteristic *ch1101;
@property (nonatomic, strong) CBCharacteristic *ch1102;
@property (nonatomic, strong) CBCharacteristic *ch1103;
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) NSMutableString *log;
@property (nonatomic, assign) BOOL wantConnect;
@property (nonatomic, assign) BOOL notifyConfirmed;
@property (nonatomic, assign) BOOL autoFired;
@property (nonatomic, assign) NSInteger rxCount;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"BLE 诊断";
    self.log = [NSMutableString string];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;

    UILabel *sl = [[UILabel alloc] init];
    sl.text = @"未启动";
    sl.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    sl.textAlignment = NSTextAlignmentCenter;
    sl.numberOfLines = 2;
    sl.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:sl];
    self.statusLabel = sl;

    UIScrollView *sv = [[UIScrollView alloc] init];
    sv.showsVerticalScrollIndicator = YES;
    sv.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:sv];
    self.scroll = sv;

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
        [sv.topAnchor constraintEqualToAnchor:sl.bottomAnchor constant:6],
        [sv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:4],
        [sv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-4],
        [sv.heightAnchor constraintEqualToConstant:200],
        [tv.topAnchor constraintEqualToAnchor:sv.bottomAnchor constant:6],
        [tv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:4],
        [tv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-4],
        [tv.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-4]
    ];
    [NSLayoutConstraint activateConstraints:c];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"复制" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(copyLog)];

    [self buildButtons];
}

- (void)buildButtons {
    CGFloat bw = 168, bh = 34, gap = 6;
    CGFloat y = gap;

    // 顶部控制
    NSArray *top = @[@"① 连接", @"② 断开"];
    SEL topActs[2] = {@selector(startScan), @selector(disconnect)};
    for (NSInteger i = 0; i < 2; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitle:top[i] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont boldSystemFontOfSize:12];
        [b addTarget:self action:topActs[i] forControlEvents:UIControlEventTouchUpInside];
        b.frame = CGRectMake(gap + i * (bw + gap), y, bw, bh);
        b.layer.borderWidth = 1.2;
        b.layer.borderColor = [UIColor systemBlueColor].CGColor;
        b.layer.cornerRadius = 6;
        [self.scroll addSubview:b];
    }
    y += bh + gap * 2;

    // 诊断按钮
    NSArray *diag = @[@"③ 读 FF01", @"④ 读 FF02", @"⑤ 重订阅 FF01", @"⑥ 读所有描述符"];
    SEL diagActs[4] = {@selector(readFF01), @selector(readFF02),
                       @selector(resubscribe), @selector(readAllDesc)};
    for (NSInteger i = 0; i < 4; i++) {
        NSInteger row = i / 2;
        NSInteger col = i % 2;
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitle:diag[i] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont boldSystemFontOfSize:11];
        [b addTarget:self action:diagActs[i] forControlEvents:UIControlEventTouchUpInside];
        b.frame = CGRectMake(gap + col * (bw + gap), y + row * (bh + gap), bw, bh);
        b.backgroundColor = [UIColor systemOrangeColor];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        b.layer.cornerRadius = 5;
        [self.scroll addSubview:b];
    }
    y += 2 * (bh + gap) + gap;

    // 帧按钮
    for (NSInteger i = 0; i < FRAME_COUNT; i++) {
        UILabel *lb = [[UILabel alloc] init];
        lb.text = [NSString stringWithUTF8String:kFrames[i].label];
        lb.font = [UIFont boldSystemFontOfSize:11];
        lb.textColor = [UIColor darkGrayColor];
        lb.frame = CGRectMake(gap, y, 340, 15);
        [self.scroll addSubview:lb];
        y += 17;

        UIButton *b1 = [UIButton buttonWithType:UIButtonTypeSystem];
        [b1 setTitle:@"WRITE" forState:UIControlStateNormal];
        b1.titleLabel.font = [UIFont boldSystemFontOfSize:11];
        b1.tag = i * 2;
        [b1 addTarget:self action:@selector(sendFrame:) forControlEvents:UIControlEventTouchUpInside];
        b1.frame = CGRectMake(gap, y, 100, 30);
        b1.backgroundColor = [UIColor systemBlueColor];
        [b1 setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        b1.layer.cornerRadius = 5;
        [self.scroll addSubview:b1];

        UIButton *b2 = [UIButton buttonWithType:UIButtonTypeSystem];
        [b2 setTitle:@"WRITE_NR" forState:UIControlStateNormal];
        b2.titleLabel.font = [UIFont boldSystemFontOfSize:11];
        b2.tag = i * 2 + 1;
        [b2 addTarget:self action:@selector(sendFrame:) forControlEvents:UIControlEventTouchUpInside];
        b2.frame = CGRectMake(gap + 106, y, 110, 30);
        b2.backgroundColor = [UIColor systemGreenColor];
        [b2 setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        b2.layer.cornerRadius = 5;
        [self.scroll addSubview:b2];

        y += 30 + gap * 2;
    }

    self.scroll.contentSize = CGSizeMake(340, y + 20);
}

#pragma mark - 日志

- (void)say:(NSString *)fmt, ... {
    va_list a; va_start(a, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:a];
    va_end(a);
    dispatch_async(dispatch_get_main_queue(), ^{ self.statusLabel.text = s; });
}

- (void)log:(NSString *)fmt, ... {
    va_list a; va_start(a, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:a];
    va_end(a);
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"[%@] %@", [df stringFromDate:[NSDate date]], s];
    [self.log appendString:line];
    [self.log appendString:@"\n"];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.textView.text = self.log;
        NSUInteger n = self.log.length;
        if (n > 0) [self.textView scrollRangeToVisible:NSMakeRange(n - 1, 1)];
    });
}

- (void)copyLog {
    [UIPasteboard generalPasteboard].string = self.log;
    [self say:@"已复制 %lu 字符", (unsigned long)self.log.length];
}

#pragma mark - BLE 控制

- (void)startScan {
    [self.log setString:@""];
    self.wantConnect = YES;
    self.notifyConfirmed = NO;
    self.notifyChar = nil;
    self.writeChar = nil;
    self.ff00Service = nil;
    self.svc1100 = nil;
    self.ch1101 = nil;
    self.ch1102 = nil;
    self.ch1103 = nil;
    self.autoFired = NO;
    self.rxCount = 0;
    self.central = [[CBCentralManager alloc] initWithDelegate:self queue:nil
                                                       options:@{CBCentralManagerOptionShowPowerAlertKey: @YES}];
    [self say:@"初始化中…"];
}

- (void)disconnect {
    if (self.peripheral) {
        [self.central cancelPeripheralConnection:self.peripheral];
        [self log:@"主动断开"];
    }
    self.wantConnect = NO;
}

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    [self log:@"蓝牙状态: %ld", (long)central.state];
    if (central.state == CBManagerStatePoweredOn && self.wantConnect) {
        [self log:@"开始扫描（不过滤 service，靠名字匹配）"];
        [central scanForPeripheralsWithServices:nil
                                        options:@{CBCentralManagerScanOptionAllowDuplicatesKey: @NO}];
        [self say:@"扫描中…"];
    } else if (central.state == CBManagerStateUnauthorized) {
        [self log:@"❌ 蓝牙权限被拒绝"];
        [self say:@"蓝牙权限被拒绝"];
    }
}

- (void)centralManager:(CBCentralManager *)central
 didDiscoverPeripheral:(CBPeripheral *)peripheral
     advertisementData:(NSDictionary<NSString *,id> *)advertisementData
                  RSSI:(NSNumber *)RSSI {

    NSString *name = peripheral.name ?: advertisementData[CBAdvertisementDataLocalNameKey] ?: @"(null)";
    NSArray *svc = advertisementData[CBAdvertisementDataServiceUUIDsKey];

    if (![name containsString:@"东风blekey"]) return;

    [self log:@"★ 目标: %@  RSSI=%@  广播SVC=%@", name, RSSI, svc];

    if (peripheral.state == CBPeripheralStateDisconnected && self.wantConnect) {
        self.peripheral = peripheral;
        peripheral.delegate = self;
        [central stopScan];
        [self log:@"连接中…"];
        [self say:@"连接中…"];
        [central connectPeripheral:peripheral options:nil];
    }
}

- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
    [self log:@"✅ 已连接"];
    [self say:@"发现服务"];
    [peripheral discoverServices:nil];
}

- (void)centralManager:(CBCentralManager *)central
didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    [self log:@"❌ 连接失败: %@", error.localizedDescription];
    [self say:@"连接失败"];
}

- (void)centralManager:(CBCentralManager *)central
didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    [self log:@"⚠️ 已断开: %@", error.localizedDescription ?: @"(无)"];
    [self say:@"已断开"];
    self.notifyConfirmed = NO;
    self.notifyChar = nil;
    self.writeChar = nil;
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    if (error) { [self log:@"发现服务失败: %@", error.localizedDescription]; return; }
    for (CBService *s in peripheral.services) {
        [self log:@"  服务 %@", s.UUID.UUIDString];
        NSString *us = [s.UUID.UUIDString uppercaseString];
        if ([us containsString:@"FF00"]) {
            self.ff00Service = s;
        }
        if ([us containsString:@"1100"]) {
            self.svc1100 = s;
        }
    }
    // 两个服务都发现特征
    NSMutableArray *toDiscover = [NSMutableArray array];
    if (self.ff00Service) [toDiscover addObject:self.ff00Service];
    if (self.svc1100) [toDiscover addObject:self.svc1100];

    if (toDiscover.count == 0) {
        [self log:@"❌ 未找到 FF00 或 1100"];
        return;
    }
    for (CBService *s in toDiscover) {
        [self log:@"✓ 发现 %@ 的特征", [s.UUID.UUIDString substringToIndex:4]];
        [peripheral discoverCharacteristics:nil forService:s];
    }
}

- (void)peripheral:(CBPeripheral *)peripheral
didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error {
    if (error) { [self log:@"发现特征失败: %@", error.localizedDescription]; return; }

    NSString *svcTag = [service.UUID.UUIDString substringToIndex:MIN((NSUInteger)8, service.UUID.UUIDString.length)];
    [self log:@"--- 服务 %@ 的特征 ---", svcTag];

    for (CBCharacteristic *c in service.characteristics) {
        NSMutableString *props = [NSMutableString string];
        if (c.properties & CBCharacteristicPropertyRead) [props appendString:@"READ "];
        if (c.properties & CBCharacteristicPropertyWrite) [props appendString:@"WRITE "];
        if (c.properties & CBCharacteristicPropertyWriteWithoutResponse) [props appendString:@"WRITE_NR "];
        if (c.properties & CBCharacteristicPropertyNotify) [props appendString:@"NOTIFY "];
        if (c.properties & CBCharacteristicPropertyIndicate) [props appendString:@"INDICATE "];
        [self log:@"    %@ [%@]", c.UUID.UUIDString, props];

        NSString *us = [c.UUID.UUIDString uppercaseString];

        // FF00 服务
        if ([us containsString:@"FF01"]) {
            self.notifyChar = c;
            [peripheral discoverDescriptorsForCharacteristic:c];
        } else if ([us containsString:@"FF02"]) {
            self.writeChar = c;
            [peripheral discoverDescriptorsForCharacteristic:c];
        }
        // 1100 服务（关键：可能有真正的收发通道）
        else if ([us containsString:@"1101"]) {
            self.ch1101 = c;
            [self log:@"      ★ 记录 1101 (WRITE)"];
            [peripheral discoverDescriptorsForCharacteristic:c];
        } else if ([us containsString:@"1102"]) {
            self.ch1102 = c;
            [self log:@"      ★ 记录 1102 (READ+NOTIFY)  ← 可能是真正的接收通道"];
            [peripheral discoverDescriptorsForCharacteristic:c];
            // 立刻订阅 1102 的通知
            if (c.properties & CBCharacteristicPropertyNotify) {
                [self log:@"      → 订阅 1102 通知"];
                [peripheral setNotifyValue:YES forCharacteristic:c];
            }
            // 如果支持 READ，立刻读
            if (c.properties & CBCharacteristicPropertyRead) {
                [self log:@"      → 读 1102 当前值"];
                [peripheral readValueForCharacteristic:c];
            }
        } else if ([us containsString:@"1103"]) {
            self.ch1103 = c;
            [self log:@"      ★ 记录 1103 (READ+WRITE_NR+NOTIFY)"];
            [peripheral discoverDescriptorsForCharacteristic:c];
            if (c.properties & CBCharacteristicPropertyNotify) {
                [self log:@"      → 订阅 1103 通知"];
                [peripheral setNotifyValue:YES forCharacteristic:c];
            }
            if (c.properties & CBCharacteristicPropertyRead) {
                [self log:@"      → 读 1103 当前值"];
                [peripheral readValueForCharacteristic:c];
            }
        }
    }

    // 订阅 FF01
    if (self.notifyChar && !self.autoFired) {
        [self log:@"→ 调用 setNotifyValue:YES (FF01)"];
        [peripheral setNotifyValue:YES forCharacteristic:self.notifyChar];
    }
    [self say:@"等待通知确认…"];
}

- (void)peripheral:(CBPeripheral *)peripheral
didDiscoverDescriptorsForCharacteristic:(CBCharacteristic *)characteristic
             error:(NSError *)error {
    if (error) return;
    for (CBDescriptor *d in characteristic.descriptors) {
        [self log:@"    描述符 %@ (%@)", d.UUID.UUIDString,
            [characteristic.UUID.UUIDString substringToIndex:4]];
        [peripheral readValueForDescriptor:d];
    }
}

- (void)peripheral:(CBPeripheral *)peripheral
didUpdateValueForDescriptor:(CBDescriptor *)descriptor error:(NSError *)error {
    if (error) {
        [self log:@"    描述符 %@ 读取失败: %@", descriptor.UUID.UUIDString, error.localizedDescription];
        return;
    }
    id v = descriptor.value;
    NSString *vs = @"?";
    if ([v isKindOfClass:[NSData class]]) vs = [self hexString:v];
    else if (v) vs = [v description];
    [self log:@"    描述符 %@ = %@", descriptor.UUID.UUIDString, vs];
}

// ===== 关键：通知状态确认回调 =====
- (void)peripheral:(CBPeripheral *)peripheral
didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic
             error:(NSError *)error {
    if (error) {
        [self log:@"❌❌ 通知订阅失败 %@: %@", characteristic.UUID.UUIDString, error.localizedDescription];
        [self say:@"订阅失败"];
        return;
    }
    if (characteristic.isNotifying) {
        self.notifyConfirmed = YES;
        [self log:@"✅✅✅ 通知已确认开启 %@  (isNotifying=YES)", characteristic.UUID.UUIDString];
        [self say:@"✅ 就绪·可发帧"];

        // 顺便读一次 FF01 当前值
        if (self.notifyChar &&
            (self.notifyChar.properties & CBCharacteristicPropertyRead)) {
            [self log:@"→ 读 FF01 当前值"];
            [peripheral readValueForCharacteristic:self.notifyChar];
        }

        // 只有第一次确认时才自动发（避免重订阅时重复触发）
        if (!self.autoFired) {
            self.autoFired = YES;
            [self log:@""];
            [self log:@"===== 开始自动握手序列 ====="];
            [self autoHandshake];
        }
    } else {
        [self log:@"⚠️ 通知被关闭 %@", characteristic.UUID.UUIDString];
    }
}

- (void)peripheral:(CBPeripheral *)peripheral
didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic
             error:(NSError *)error {
    if (error) {
        [self log:@"接收错误: %@", error.localizedDescription];
        return;
    }
    NSData *d = characteristic.value;
    self.rxCount++;
    [self log:@"⬇️⬇️ 收到 %@ %luB: %@",
        characteristic.UUID.UUIDString, (unsigned long)d.length, [self hexString:d]];
}

- (void)peripheral:(CBPeripheral *)peripheral
didWriteValueForCharacteristic:(CBCharacteristic *)characteristic
             error:(NSError *)error {
    if (error) {
        [self log:@"❌ 写入失败: %@", error.localizedDescription];
    } else {
        [self log:@"✅ 写入确认 %@", characteristic.UUID.UUIDString];
    }
}

#pragma mark - 诊断操作

- (void)readFF01 {
    if (!self.notifyChar) { [self say:@"无 FF01"]; return; }
    if (!(self.notifyChar.properties & CBCharacteristicPropertyRead)) {
        [self log:@"FF01 不支持 READ"];
        [self say:@"FF01 不可读"];
        return;
    }
    [self log:@"→ 读 FF01"];
    [self.peripheral readValueForCharacteristic:self.notifyChar];
}

- (void)readFF02 {
    if (!self.writeChar) { [self say:@"无 FF02"]; return; }
    if (!(self.writeChar.properties & CBCharacteristicPropertyRead)) {
        [self log:@"FF02 不支持 READ"];
        [self say:@"FF02 不可读"];
        return;
    }
    [self log:@"→ 读 FF02"];
    [self.peripheral readValueForCharacteristic:self.writeChar];
}

- (void)resubscribe {
    if (!self.notifyChar) { [self say:@"无 FF01"]; return; }
    [self log:@"→ 先关闭通知再开启（重订阅）"];
    [self.peripheral setNotifyValue:NO forCharacteristic:self.notifyChar];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self log:@"→ 重新 setNotifyValue:YES"];
        [self.peripheral setNotifyValue:YES forCharacteristic:self.notifyChar];
    });
}

- (void)readAllDesc {
    if (!self.ff00Service) { [self say:@"无服务"]; return; }
    [self log:@"→ 重新发现所有描述符"];
    for (CBCharacteristic *c in self.ff00Service.characteristics) {
        [self.peripheral discoverDescriptorsForCharacteristic:c];
    }
}

#pragma mark - 发送

#pragma mark - 自动握手序列

// 订阅确认后立刻自动发，抢在 9 秒超时之前
- (void)autoHandshake {
    // 200ms 后发第一条握手
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self log:@"[自动] 第 1 步：发握手帧 21:00:01 (WRITE_NR)"];
        [self rawSend:@"50231001B4E2BC0155AA8DF3A5D1C4E8CC02C80BD367E6CF395AD20BDF23C04567F1666A"
                 noResp:YES];
    });

    // 1.2 秒后：把同样的握手帧发到 1101 和 1103
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self.ch1101) {
            [self log:@"[自动] 第 2a 步：握手帧 → 1101 (WRITE_NR)"];
            [self sendTo:self.ch1101 hex:@"50231001507DF61D10458F9C8C0E201716EC888695A2D4D0BAC33F47A8972134F0B40F93" noResp:YES];
        }
        if (self.ch1103) {
            [self log:@"[自动] 第 2b 步：握手帧 → 1103 (WRITE_NR)"];
            [self sendTo:self.ch1103 hex:@"50231001507DF61D10458F9C8C0E201716EC888695A2D4D0BAC33F47A8972134F0B40F93" noResp:YES];
        }
    });

    // 2.5 秒后：如果还没收到任何数据，试发开锁帧
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self.rxCount == 0) {
            [self log:@"[自动] 第 3 步：仍未收到数据，试发开锁帧 (WRITE_NR)"];
            [self rawSend:@"5002240100375D198A25F42A1285468C3AC35953385514A5678492C82D9DF4DF6BA870A8DE4DC21B84E0A88E04826BDE01D311F0919782F1"
                     noResp:YES];
        } else {
            [self log:@"[自动] 已收到 %ld 帧，跳过开锁测试", (long)self.rxCount];
        }
    });

    // 4.0 秒后：报告状态
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self log:@"[自动] === 4 秒小结：收到 %ld 帧 ===", (long)self.rxCount];
        if (self.rxCount == 0) {
            [self log:@"[自动] 仍未收到任何数据"];
        }
    });

    // 8.0 秒后：如果还活着，报告
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self.peripheral.state == CBPeripheralStateConnected) {
            [self log:@"[自动] 8 秒仍连接中（说明没被踢）收到 %ld 帧", (long)self.rxCount];
        } else {
            [self log:@"[自动] 已在 8 秒前断开，收到 %ld 帧", (long)self.rxCount];
        }
    });
}

- (void)sendTo:(CBCharacteristic *)ch hex:(NSString *)hex noResp:(BOOL)noResp {
    if (!ch) { [self log:@"  目标特征为 nil，跳过"]; return; }
    NSData *d = [self dataFromHex:hex];
    if (!d) { [self log:@"  hex 解析失败"]; return; }
    CBCharacteristicWriteType t = noResp
        ? CBCharacteristicWriteWithoutResponse : CBCharacteristicWriteWithResponse;
    [self log:@"  ⬆️→%@ %luB %@", ch.UUID.UUIDString, (unsigned long)d.length,
        noResp ? @"WRITE_NR" : @"WRITE"];
    [self.peripheral writeValue:d forCharacteristic:ch type:t];
}

- (void)rawSend:(NSString *)hex noResp:(BOOL)noResp {
    if (!self.writeChar) { [self log:@"  无 FF02，跳过"]; return; }
    NSData *d = [self dataFromHex:hex];
    if (!d) { [self log:@"  hex 解析失败"]; return; }
    CBCharacteristicWriteType t = noResp
        ? CBCharacteristicWriteWithoutResponse : CBCharacteristicWriteWithResponse;
    [self log:@"  ⬆️ %luB %@ hex=%@",
        (unsigned long)d.length, noResp ? @"WRITE_NR" : @"WRITE",
        [hex substringToIndex:MIN((NSUInteger)24, hex.length)]];
    [self.peripheral writeValue:d forCharacteristic:self.writeChar type:t];
}

- (void)sendFrame:(UIButton *)btn {
    if (!self.writeChar) { [self say:@"无 FF02"]; return; }
    if (!self.notifyConfirmed) {
        [self log:@"⚠️ 通知尚未确认，仍尝试发送"];
    }
    NSInteger idx = btn.tag / 2;
    BOOL noResponse = (btn.tag % 2) == 1;
    if (idx < 0 || idx >= FRAME_COUNT) return;

    NSData *data = [self dataFromHex:[NSString stringWithUTF8String:kFrames[idx].hex]];
    if (!data) { [self say:@"hex 解析失败"]; return; }

    CBCharacteristicWriteType type = noResponse
        ? CBCharacteristicWriteWithoutResponse : CBCharacteristicWriteWithResponse;

    [self log:@"⬆️ 发送 %@ %luB 模式=%@",
        [NSString stringWithUTF8String:kFrames[idx].label],
        (unsigned long)data.length, noResponse ? @"WRITE_NR" : @"WRITE"];
    [self.peripheral writeValue:data forCharacteristic:self.writeChar type:type];
    [self say:@"已发送"];
}

- (NSData *)dataFromHex:(NSString *)hex {
    NSString *s = [[hex stringByReplacingOccurrencesOfString:@" " withString:@""] uppercaseString];
    if (s.length % 2) return nil;
    NSMutableData *d = [NSMutableData data];
    for (NSUInteger i = 0; i < s.length; i += 2) {
        unsigned int v = 0;
        if (![[NSScanner scannerWithString:[s substringWithRange:NSMakeRange(i, 2)]] scanHexInt:&v])
            return nil;
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



