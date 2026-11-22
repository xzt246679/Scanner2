#import "ViewController.h"
#import <CoreBluetooth/CoreBluetooth.h>

static NSString *const kDeviceName   = @"东风blekey-044289LE";
static NSString *const kServiceUUID  = @"FF00";
static NSString *const kNotifyCharID = @"FF01";
static NSString *const kWriteCharID  = @"FF02";

// 已抓到的帧（按时间顺序）
typedef struct {
    const char *label;
    const char *hex;
    int isCommand;      // 1 = 命令帧（发 FF02），0 = 仅记录
} FrameDef;

static FrameDef kFrames[] = {
    // 21:19:37 开锁（用户标注）
    {"【开锁】21:19:37",
     "5002240100375D198A25F42A1285468C3AC35953385514A5678492C82D9DF4DF6BA870A8DE4DC21B84E0A88E04826BDE01D311F0919782F1", 1},
    // 21:19:44 闭锁（用户标注）
    {"【闭锁】21:19:44",
     "5002240100375D191AA88C24CEE66C751E7221DA4DE53D73A6BE39B0E649C4CF1957FB1A4BD5360546BA658557DCBEEC05A5397108C2CAE6", 1},
    // 20:49:10 未知（可能是解锁）
    {"【未知】20:49:10",
     "5002240100375D19786683B96AEA6F0793BF5427258A8E5EE38F16C3643CF4C3F1F930E80E453BC1EEEC24A4984CA6E8D720C588676D7009", 1},
    // 21:00:02 未知
    {"【未知】21:00:02",
     "5002240100375D19296706DA8882FDB6CB2719F2A0D5BDDC4C58E8B85EEBF345661D950B5DE8B047B6D0CD87CE8463D437B2A69218734815", 1},
    // 握手帧
    {"【握手】21:19:32",
     "50231001507DF61D10458F9C8C0E201716EC888695A2D4D0BAC33F47A8972134F0B40F93", 1},
    {"【握手】21:00:01",
     "50231001B4E2BC0155AA8DF3A5D1C4E8CC02C80BD367E6CF395AD20BDF23C04567F1666A", 1},
};
#define FRAME_COUNT (sizeof(kFrames) / sizeof(kFrames[0]))

@interface ViewController () <CBCentralManagerDelegate, CBPeripheralDelegate>
@property (nonatomic, strong) CBCentralManager *central;
@property (nonatomic, strong) CBPeripheral *peripheral;
@property (nonatomic, strong) CBCharacteristic *notifyChar;
@property (nonatomic, strong) CBCharacteristic *writeChar;
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) NSMutableString *log;
@property (nonatomic, assign) BOOL wantConnect;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"BLE 重放测试";
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
        [sv.heightAnchor constraintEqualToConstant:130],
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
    CGFloat bw = 168, bh = 38, gap = 6;
    CGFloat y = gap;

    // 顶部控制按钮
    NSArray *top = @[@"① 开始扫描连接", @"② 断开"];
    SEL topActs[2] = {@selector(startScan), @selector(disconnect)};
    for (NSInteger i = 0; i < 2; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitle:top[i] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont boldSystemFontOfSize:13];
        [b addTarget:self action:topActs[i] forControlEvents:UIControlEventTouchUpInside];
        b.frame = CGRectMake(gap + i * (bw + gap), y, bw, bh);
        b.layer.borderWidth = 1.2;
        b.layer.borderColor = [UIColor systemBlueColor].CGColor;
        b.layer.cornerRadius = 6;
        [self.scroll addSubview:b];
    }
    y += bh + gap * 2;

    // 帧按钮（每个帧两个按钮：WRITE / WRITE_NO_RESPONSE）
    for (NSInteger i = 0; i < FRAME_COUNT; i++) {
        UILabel *lb = [[UILabel alloc] init];
        lb.text = [NSString stringWithUTF8String:kFrames[i].label];
        lb.font = [UIFont boldSystemFontOfSize:11];
        lb.textColor = [UIColor darkGrayColor];
        lb.frame = CGRectMake(gap, y, 340, 16);
        [self.scroll addSubview:lb];
        y += 18;

        UIButton *b1 = [UIButton buttonWithType:UIButtonTypeSystem];
        [b1 setTitle:@"WRITE" forState:UIControlStateNormal];
        b1.titleLabel.font = [UIFont boldSystemFontOfSize:11];
        b1.tag = i * 2;
        [b1 addTarget:self action:@selector(sendFrame:) forControlEvents:UIControlEventTouchUpInside];
        b1.frame = CGRectMake(gap, y, 100, 32);
        b1.backgroundColor = [UIColor systemBlueColor];
        [b1 setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        b1.layer.cornerRadius = 5;
        [self.scroll addSubview:b1];

        UIButton *b2 = [UIButton buttonWithType:UIButtonTypeSystem];
        [b2 setTitle:@"WRITE_NR" forState:UIControlStateNormal];
        b2.titleLabel.font = [UIFont boldSystemFontOfSize:11];
        b2.tag = i * 2 + 1;
        [b2 addTarget:self action:@selector(sendFrame:) forControlEvents:UIControlEventTouchUpInside];
        b2.frame = CGRectMake(gap + 106, y, 110, 32);
        b2.backgroundColor = [UIColor systemGreenColor];
        [b2 setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        b2.layer.cornerRadius = 5;
        [self.scroll addSubview:b2];

        y += 32 + gap * 2;
    }

    self.scroll.contentSize = CGSizeMake(340, y + 20);
}

#pragma mark - 日志

- (void)say:(NSString *)fmt, ... {
    va_list a;
    va_start(a, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:a];
    va_end(a);
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.text = s;
    });
}

- (void)log:(NSString *)fmt, ... {
    va_list a;
    va_start(a, fmt);
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

#pragma mark - BLE

- (void)startScan {
    [self.log setString:@""];
    self.wantConnect = YES;
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
    if (central.state == CBManagerStatePoweredOn) {
        if (self.wantConnect) {
            [self log:@"开始扫描 name=%@", kDeviceName];
            [central scanForPeripheralsWithServices:nil
                                            options:@{CBCentralManagerScanOptionAllowDuplicatesKey: @NO}];
            [self say:@"扫描中…"];
        }
    } else if (central.state == CBManagerStateUnauthorized) {
        [self log:@"❌ 蓝牙权限被拒绝"];
        [self say:@"蓝牙权限被拒绝"];
    } else if (central.state == CBManagerStatePoweredOff) {
        [self log:@"❌ 蓝牙未开启"];
        [self say:@"蓝牙未开启"];
    }
}

- (void)centralManager:(CBCentralManager *)central
 didDiscoverPeripheral:(CBPeripheral *)peripheral
     advertisementData:(NSDictionary<NSString *,id> *)advertisementData
                  RSSI:(NSNumber *)RSSI {

    NSString *name = peripheral.name ?: advertisementData[CBAdvertisementDataLocalNameKey] ?: @"(null)";
    NSArray *svc = advertisementData[CBAdvertisementDataServiceUUIDsKey];

    // 只打目标车 + 前 5 个其他设备（避免刷屏）
    BOOL isTarget = [name containsString:@"东风blekey"] || [name containsString:@"044289"];
    if (!isTarget) return;

    [self log:@"★ 发现目标: name=%@ RSSI=%@ svc=%@", name, RSSI, svc];
    if (peripheral.state == CBPeripheralStateDisconnected && self.wantConnect) {
        self.peripheral = peripheral;
        peripheral.delegate = self;
        [central stopScan];
        [self log:@"停止扫描，开始连接 %@", name];
        [self say:@"连接中…"];
        [central connectPeripheral:peripheral options:nil];
    }
}

- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
    [self log:@"✅ 已连接 %@", peripheral.name];
    [self say:@"已连接，发现服务"];
    [peripheral discoverServices:nil];
}

- (void)centralManager:(CBCentralManager *)central
didFailToConnectPeripheral:(CBPeripheral *)peripheral
                 error:(NSError *)error {
    [self log:@"❌ 连接失败: %@", error.localizedDescription];
    [self say:@"连接失败"];
}

- (void)centralManager:(CBCentralManager *)central
didDisconnectPeripheral:(CBPeripheral *)peripheral
                 error:(NSError *)error {
    [self log:@"⚠️ 已断开: %@", error.localizedDescription ?: @"(无错误)"];
    [self say:@"已断开"];
    self.notifyChar = nil;
    self.writeChar = nil;
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    if (error) {
        [self log:@"发现服务失败: %@", error.localizedDescription];
        return;
    }
    for (CBService *s in peripheral.services) {
        [self log:@"  服务 %@", s.UUID.UUIDString];
    }
    CBUUID *u = [CBUUID UUIDWithString:kServiceUUID];
    for (CBService *s in peripheral.services) {
        if ([s.UUID isEqual:u]) {
            [self log:@"✓ 找到服务 FF00，发现特征"];
            [peripheral discoverCharacteristics:nil forService:s];
            return;
        }
    }
    // FF00 可能是短 UUID
    for (CBService *s in peripheral.services) {
        if ([[s.UUID.UUIDString uppercaseString] containsString:@"FF00"]) {
            [self log:@"✓ 找到服务 %@，发现特征", s.UUID.UUIDString];
            [peripheral discoverCharacteristics:nil forService:s];
            return;
        }
    }
    [self log:@"❌ 未找到 FF00"];
}

- (void)peripheral:(CBPeripheral *)peripheral
didDiscoverCharacteristicsForService:(CBService *)service
             error:(NSError *)error {
    if (error) {
        [self log:@"发现特征失败: %@", error.localizedDescription];
        return;
    }
    for (CBCharacteristic *c in service.characteristics) {
        NSString *props = @"";
        if (c.properties & CBCharacteristicPropertyNotify) props = [props stringByAppendingString:@"NOTIFY "];
        if (c.properties & CBCharacteristicPropertyWrite) props = [props stringByAppendingString:@"WRITE "];
        if (c.properties & CBCharacteristicPropertyWriteWithoutResponse) props = [props stringByAppendingString:@"WRITE_NR "];
        if (c.properties & CBCharacteristicPropertyRead) props = [props stringByAppendingString:@"READ "];
        [self log:@"  特征 %@ [%@]", c.UUID.UUIDString, props];

        NSString *us = [c.UUID.UUIDString uppercaseString];
        if ([us containsString:@"FF01"]) {
            self.notifyChar = c;
            [peripheral setNotifyValue:YES forCharacteristic:c];
            [self log:@"  → 订阅 FF01 通知"];
        } else if ([us containsString:@"FF02"]) {
            self.writeChar = c;
            [self log:@"  → 记录 FF02 写入特征"];
        }
    }
    if (self.notifyChar && self.writeChar) {
        [self say:@"✅ 就绪，可以发帧"];
        [self log:@"\n===== 就绪 ====="];
        [self log:@"正确顺序：先发【握手】帧，等 1 秒，再发【开锁/闭锁】帧"];
        [self log:@"每帧都有 WRITE 和 WRITE_NR 两种模式，各试一次"];
        [self log:@""];
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
    [self log:@"⬇️ 收到 %luB: %@", (unsigned long)d.length, [self hexString:d]];
}

- (void)peripheral:(CBPeripheral *)peripheral
didWriteValueForCharacteristic:(CBCharacteristic *)characteristic
             error:(NSError *)error {
    if (error) {
        [self log:@"❌ 写入失败: %@", error.localizedDescription];
    } else {
        [self log:@"✅ 写入确认"];
    }
}

#pragma mark - 发送

- (void)sendFrame:(UIButton *)btn {
    if (!self.writeChar) {
        [self say:@"未就绪：特征未找到"];
        return;
    }
    NSInteger idx = btn.tag / 2;
    BOOL noResponse = (btn.tag % 2) == 1;
    if (idx < 0 || idx >= FRAME_COUNT) return;

    const char *hexc = kFrames[idx].hex;
    NSData *data = [self dataFromHex:[NSString stringWithUTF8String:hexc]];
    if (!data) {
        [self say:@"hex 解析失败"];
        return;
    }

    CBCharacteristicWriteType type = noResponse
        ? CBCharacteristicWriteWithoutResponse
        : CBCharacteristicWriteWithResponse;

    [self log:@"⬆️ 发送 %@ (%luB) 模式=%@",
        [NSString stringWithUTF8String:kFrames[idx].label],
        (unsigned long)data.length,
        noResponse ? @"WRITE_NR" : @"WRITE"];
    [self log:@"   hex: %@", [self hexString:data]];

    [self.peripheral writeValue:data forCharacteristic:self.writeChar type:type];
    [self say:@"已发送，看车门"];
}

- (NSData *)dataFromHex:(NSString *)hex {
    NSString *s = [[hex stringByReplacingOccurrencesOfString:@" " withString:@""]
                   stringByReplacingOccurrencesOfString:@"\n" withString:@""];
    s = [s uppercaseString];
    if (s.length % 2 != 0) return nil;
    NSMutableData *d = [NSMutableData data];
    for (NSUInteger i = 0; i < s.length; i += 2) {
        NSString *pair = [s substringWithRange:NSMakeRange(i, 2)];
        unsigned int v = 0;
        if (![[NSScanner scannerWithString:pair] scanHexInt:&v]) return nil;
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

