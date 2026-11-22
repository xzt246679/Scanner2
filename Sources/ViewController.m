#import "ViewController.h"
#import <Security/Security.h>
#import <sys/utsname.h>

static NSString *const kTargetBundle = @"com.dfmc.dfpv.sapp";
static NSString *const kPrefRel = @"Library/Preferences/com.dfmc.dfpv.sapp.plist";

@interface ViewController ()
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIScrollView *buttonScroll;
@property (nonatomic, strong) NSMutableString *buffer;
@property (nonatomic, strong) NSLock *bufLock;
@property (nonatomic, strong) NSString *root;
@property (nonatomic, assign) BOOL busy;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"日志切片";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.buffer = [NSMutableString string];
    self.bufLock = [[NSLock alloc] init];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;

    UILabel *sl = [[UILabel alloc] init];
    sl.text = @"已启动 · 每份 ≤2500 字符";
    sl.font = [UIFont systemFontOfSize:11];
    sl.textAlignment = NSTextAlignmentCenter;
    sl.numberOfLines = 2;
    sl.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:sl];
    self.statusLabel = sl;

    UIScrollView *sv = [[UIScrollView alloc] init];
    sv.showsVerticalScrollIndicator = YES;
    sv.showsHorizontalScrollIndicator = NO;
    sv.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:sv];
    self.buttonScroll = sv;

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
        [sv.heightAnchor constraintEqualToConstant:110],
        [tv.topAnchor constraintEqualToAnchor:sv.bottomAnchor constant:6],
        [tv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:4],
        [tv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-4],
        [tv.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-4]
    ];
    [NSLayoutConstraint activateConstraints:c];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"复制" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(copyAll)];

    [self buildButtons];
}

- (void)buildButtons {
    NSArray *titles = @[
        @"①列表",
        @"②BLE连接",
        @"③UUID",
        @"④握手",
        @"⑤命令",
        @"⑥网络",
        @"⑦错误",
        @"⑧密钥",
        @"⑨特征",
        @"⑩PREAUTH",
        @"⑪STATUS",
        @"⑫RKE",
        @"⑬BleKey",
        @"⑭目录",
        @"⑮时间线"
    ];
    SEL acts[15] = {
        @selector(btnList),
        @selector(btnBleConnect),
        @selector(btnUuid),
        @selector(btnHandshake),
        @selector(btnCommand),
        @selector(btnNetwork),
        @selector(btnError),
        @selector(btnKey),
        @selector(btnFeature),
        @selector(btnPreAuth),
        @selector(btnStatus),
        @selector(btnRke),
        @selector(btnBleKey),
        @selector(btnCerts),
        @selector(btnTimeline)
    };

    // 3 列网格
    CGFloat bw = 100, bh = 34, gap = 4;
    NSInteger cols = 3;
    for (NSInteger i = 0; i < 15; i++) {
        NSInteger row = i / cols;
        NSInteger col = i % cols;
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitle:titles[i] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont boldSystemFontOfSize:11];
        b.titleLabel.adjustsFontSizeToFitWidth = YES;
        [b addTarget:self action:acts[i] forControlEvents:UIControlEventTouchUpInside];
        b.frame = CGRectMake(gap + col * (bw + gap), gap + row * (bh + gap), bw, bh);
        b.layer.borderWidth = 1;
        b.layer.borderColor = [UIColor systemBlueColor].CGColor;
        b.layer.cornerRadius = 5;
        [self.buttonScroll addSubview:b];
    }
    CGFloat totalH = gap + 5 * (bh + gap);
    self.buttonScroll.contentSize = CGSizeMake(3 * (bw + gap) + gap, totalH);
}

#pragma mark - 基础

- (void)say:(NSString *)s {
    dispatch_async(dispatch_get_main_queue(), ^{ self.statusLabel.text = s; });
}

- (void)setContent:(NSString *)s {
    NSString *t = s ?: @"";
    [self.bufLock lock];
    [self.buffer setString:t];
    [self.bufLock unlock];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.textView.text = t;
        [self.textView setContentOffset:CGPointMake(0, 0) animated:NO];
    });
}

- (void)copyAll {
    [self.bufLock lock];
    NSString *s = [self.buffer copy];
    [self.bufLock unlock];
    if (s.length == 0) { [self say:@"空"]; return; }
    @try {
        [UIPasteboard generalPasteboard].string = s;
        [self say:[NSString stringWithFormat:@"已复制 %lu 字符", (unsigned long)s.length]];
    } @catch (NSException *e) { [self say:@"复制失败"]; }
}

- (NSString *)targetRoot {
    if (self.root) return self.root;
    NSString *base = @"/var/mobile/Containers/Data/Application";
    NSArray *dirs = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:base error:NULL];
    for (NSString *d in dirs) {
        NSString *meta = [NSString stringWithFormat:@"%@/%@/.com.apple.mobile_container_manager.metadata.plist", base, d];
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:meta];
        if ([dict[@"MCMMetadataIdentifier"] isEqualToString:kTargetBundle]) {
            self.root = [NSString stringWithFormat:@"%@/%@", base, d];
            return self.root;
        }
    }
    return nil;
}

- (NSDictionary *)prefs {
    NSString *r = [self targetRoot];
    if (!r) return nil;
    return [NSDictionary dictionaryWithContentsOfFile:[r stringByAppendingPathComponent:kPrefRel]];
}

- (NSArray *)sortedLogFiles {
    NSString *r = [self targetRoot];
    if (!r) return @[];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *docsDir = [r stringByAppendingPathComponent:@"Documents"];
    NSArray *items = [fm contentsOfDirectoryAtPath:docsDir error:NULL];

    NSMutableArray *arr = [NSMutableArray array];
    for (NSString *n in items) {
        if (![n hasSuffix:@".log"]) continue;
        NSString *full = [docsDir stringByAppendingPathComponent:n];
        NSDictionary *a = [fm attributesOfItemAtPath:full error:NULL];
        NSDate *mtime = a[NSFileModificationDate] ?: [NSDate distantPast];
        unsigned long long sz = [a[NSFileSize] unsignedLongLongValue];
        [arr addObject:@{@"name": n, @"mtime": mtime, @"size": @(sz)}];
    }
    [arr sortUsingComparator:^NSComparisonResult(NSDictionary *x, NSDictionary *y) {
        return [(NSDate *)y[@"mtime"] compare:(NSDate *)x[@"mtime"]];
    }];
    return arr;
}

- (NSString *)readText:(NSString *)rel {
    NSString *r = [self targetRoot];
    if (!r) return nil;
    NSString *full = [r stringByAppendingPathComponent:rel];
    NSData *d = [NSData dataWithContentsOfFile:full options:NSDataReadingMappedIfSafe error:NULL];
    if (!d) return nil;
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (s) return s;
    NSMutableString *out = [NSMutableString string];
    const unsigned char *b = d.bytes;
    NSMutableString *cur = [NSMutableString string];
    for (NSUInteger i = 0; i < d.length && out.length < 500000; i++) {
        unsigned char c = b[i];
        if (c >= 32 && c < 127) {
            [cur appendFormat:@"%c", c];
        } else {
            if (cur.length > 6) { [out appendString:cur]; [out appendString:@"\n"]; }
            [cur setString:@""];
        }
    }
    if (cur.length > 6) [out appendString:cur];
    return out;
}

- (NSString *)b64:(NSData *)d {
    NSString *s = [d base64EncodedStringWithOptions:0];
    NSMutableString *o = [NSMutableString string];
    NSUInteger i = 0;
    while (i < s.length) {
        NSUInteger n = MIN((NSUInteger)76, s.length - i);
        [o appendString:[s substringWithRange:NSMakeRange(i, n)]];
        [o appendString:@"\n"];
        i += n;
    }
    return o;
}

- (NSString *)describe:(id)v {
    if (!v) return @"(null)";
    if ([v isKindOfClass:[NSData class]]) return [NSString stringWithFormat:@"<data %lu B>", (unsigned long)[v length]];
    if ([v isKindOfClass:[NSString class]]) return (NSString *)v;
    if ([v isKindOfClass:[NSNumber class]]) return [v stringValue];
    if ([v isKindOfClass:[NSArray class]]) return [NSString stringWithFormat:@"<array %lu>", (unsigned long)[v count]];
    if ([v isKindOfClass:[NSDictionary class]]) return [NSString stringWithFormat:@"<dict %lu>", (unsigned long)[v count]];
    return [v description];
}

// ============ 核心：按关键词切片，智能限长 ============

static NSArray *noiseKeys(void) {
    static NSArray *a = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        a = @[
            @"Analysys", @"Analytics", @"UMeng", @"UMENG", @"umeng", @"bugly", @"Bugly",
            @"AMap", @"MAMap", @"高德", @"MapKit",
            @"SensorsAnalytics", @"ingeekanalytics", @"ingzzkanalytics",
            @"WPK", @"Wpk", @"wpk",
            @"xhs", @"xiaohongshu", @"XHS",
            @"X-B3-TraceId", @"tracerent", @"traceparent",
            @"LYLogs", @"SYSYLANA", @"Reachability",
            @"AMapLocation"
        ];
    });
    return a;
}

// MQTT / 远程控制噪声（专用于 BLE 分析时排除）
static NSArray *mqttNoiseKeys(void) {
    static NSArray *a = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        a = @[
            @"MQTT", @"Mqtt", @"mqtt",
            @"connectWithHandler",
            @"remote code unsupport",
            @"CMD_DOOR", @"CMD_TRUNK", @"CMD_DRS",
            @"remoteCode", @"pushBody", @"controlResult",
            @"NewCarViewController",
            @"saveRelation", @"saveByVin", @"msotasvr",
            @"POST请求:", @"POST返回:", @"statusCode",
            @"获取到的慢充枪", @"开始拼接刷新数据",
            @"预约状态字段值"
        ];
    });
    return a;
}

- (BOOL)isNoise:(NSString *)line {
    for (NSString *k in noiseKeys()) {
        if ([line rangeOfString:k].location != NSNotFound) return YES;
    }
    return NO;
}

- (BOOL)isMqttNoise:(NSString *)line {
    for (NSString *k in mqttNoiseKeys()) {
        if ([line rangeOfString:k].location != NSNotFound) return YES;
    }
    return NO;
}

// 🔑 专用过滤：只保留含 🔑 的行，且排除 MQTT 噪声
- (BOOL)isKeyLine:(NSString *)line {
    if ([line rangeOfString:@"🔑"].location == NSNotFound &&
        [line rangeOfString:@"🔐"].location == NSNotFound) return NO;
    if ([self isMqttNoise:line]) return NO;
    return YES;
}

// 取主日志文本（最大的那个）
- (NSString *)mainLogText {
    NSArray *arr = [self sortedLogFiles];
    NSString *best = nil;
    unsigned long long bestSize = 0;
    for (NSDictionary *d in arr) {
        unsigned long long s = [d[@"size"] unsignedLongLongValue];
        if (s > bestSize) { bestSize = s; best = d[@"name"]; }
    }
    if (!best) return nil;
    return [self readText:[NSString stringWithFormat:@"Documents/%@", best]];
}

// 智能切片：从尾部往前扫，最多 200 行，总长 ≤ maxChars
- (NSString *)sliceLog:(NSString *)text
                 keys:(NSArray *)keys
            scanLines:(NSUInteger)scanLines
              maxChars:(NSUInteger)maxChars
                title:(NSString *)title {

    if (!text || text.length == 0) return [NSString stringWithFormat:@"%@\n(日志为空)", title];

    NSArray *lines = [text componentsSeparatedByString:@"\n"];
    NSUInteger total = lines.count;
    NSUInteger start = (total > scanLines) ? total - scanLines : 0;

    // 先收集命中行
    NSMutableArray *hits = [NSMutableArray array];
    for (NSUInteger i = start; i < total; i++) {
        NSString *line = lines[i];
        if (line.length < 6) continue;
        if ([self isNoise:line]) continue;
        BOOL m = (keys.count == 0);
        for (NSString *k in keys) {
            if ([line rangeOfString:k].location != NSNotFound) { m = YES; break; }
        }
        if (m) [hits addObject:line];
    }

    NSUInteger totalHits = hits.count;

    // 从最新（尾部）往前取，直到 maxChars
    NSMutableArray *picked = [NSMutableArray array];
    NSUInteger acc = 0;
    for (NSInteger i = (NSInteger)hits.count - 1; i >= 0; i--) {
        NSString *line = hits[i];
        if (acc + line.length + 1 > maxChars) break;
        [picked insertObject:line atIndex:0];
        acc += line.length + 1;
    }

    NSMutableString *o = [NSMutableString string];
    [o appendFormat:@"%@\n扫描 %lu 行，命中 %lu 行，输出 %lu 行\n",
        title, (unsigned long)(total - start), (unsigned long)totalHits, (unsigned long)picked.count];
    if (totalHits > picked.count) {
        [o appendFormat:@"（前面还有 %lu 行未显示）\n", (unsigned long)(totalHits - picked.count)];
    }
    [o appendString:@"\n"];
    for (NSString *l in picked) {
        [o appendString:l];
        [o appendString:@"\n"];
    }
    return o;
}

#pragma mark - 按钮

// ① 日志文件列表
- (void)btnList {
    if (self.busy) return;
    self.busy = YES;
    [self say:@"列日志…"];
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSArray *arr = [self sortedLogFiles];
        NSMutableString *o = [NSMutableString string];
        [o appendFormat:@"Documents 下 .log 共 %lu 个\n（按修改时间倒序）\n\n",
            (unsigned long)arr.count];
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"MM-dd HH:mm:ss";
        for (NSDictionary *d in arr) {
            [o appendFormat:@"%-38s\n   %10llu B   %@\n",
                [d[@"name"] UTF8String],
                [d[@"size"] unsignedLongLongValue],
                [df stringFromDate:d[@"mtime"]]];
        }
        [self setContent:o];
        [self say:[NSString stringWithFormat:@"%lu 个日志", (unsigned long)arr.count]];
        self.busy = NO;
    });
}

// ② BLE 连接过程（排除 MQTT）
- (void)btnBleConnect {
    if (self.busy) return;
    self.busy = YES;
    [self say:@"抓 BLE 连接…"];
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSString *t = [self mainLogText];
        if (!t) { [self setContent:@"无主日志"]; self.busy = NO; return; }

        NSArray *lines = [t componentsSeparatedByString:@"\n"];
        NSUInteger total = lines.count;
        NSUInteger start = (total > 40000) ? total - 40000 : 0;

        NSArray *keys = @[@"Connect", @"connect", @"disconnect", @"Disconnect",
                          @"didConnect", @"didDisconnect", @"didFailToConnect",
                          @"peripheral", @"Peripheral", @"central", @"Central",
                          @"startScan", @"stopScan", @"didDiscover", @"discover",
                          @"stateMachine", @"CBPeripheral", @"CBCentral",
                          @"scanForPeripherals", @"连接设备结果", @"扫描设备超时",
                          @"发现设备", @"connectDeviceV1", @"monitorConnectStatus"];
        NSMutableArray *kept = [NSMutableArray array];
        for (NSUInteger i = start; i < total; i++) {
            NSString *line = lines[i];
            if (line.length < 6) continue;
            if ([self isNoise:line]) continue;
            if ([self isMqttNoise:line]) continue;   // 排除 MQTT
            BOOL m = NO;
            for (NSString *k in keys) {
                if ([line rangeOfString:k].location != NSNotFound) { m = YES; break; }
            }
            if (m) [kept addObject:line];
        }

        NSMutableArray *picked = [NSMutableArray array];
        NSUInteger acc = 0;
        for (NSInteger i = (NSInteger)kept.count - 1; i >= 0; i--) {
            NSString *l = kept[i];
            if (acc + l.length + 1 > 2350) break;
            [picked insertObject:l atIndex:0];
            acc += l.length + 1;
        }

        NSMutableString *o = [NSMutableString string];
        [o appendFormat:@"② BLE 连接（已排除 MQTT）\n命中 %lu 行，输出 %lu 行\n",
            (unsigned long)kept.count, (unsigned long)picked.count];
        if (kept.count > picked.count) {
            [o appendFormat:@"（前面还有 %lu 行未显示）\n", (unsigned long)(kept.count - picked.count)];
        }
        [o appendString:@"\n"];
        for (NSString *l in picked) { [o appendString:l]; [o appendString:@"\n"]; }

        [self setContent:o];
        [self say:[NSString stringWithFormat:@"BLE %ld 行", (long)kept.count]];
        self.busy = NO;
    });
}

// ③ UUID / 服务 / 特征
- (void)btnUuid {
    [self runSlice:@[@"uuid", @"UUID", @"Uuid",
                     @"service", @"Service", @"characteristic", @"Characteristic",
                     @"FF00", @"ff00", @"FF01", @"FF02",
                     @"0x1100", @"0x1101", @"0x1102", @"0x1103"]
           scan:20000 max:2400 title:@"③ UUID/服务/特征"];
}

// ④ 握手与认证
- (void)btnHandshake {
    [self runSlice:@[@"preAuth", @"PreAuth", @"PREAUTH",
                     @"status", @"Status",
                     @"challenge", @"Challenge",
                     @"handshake", @"Handshake",
                     @"auth", @"Auth", @"authenticate",
                     @"session", @"Session", @"deriveSession",
                     @"pair", @"Pair", @"pairing", @"Pairing"]
           scan:20000 max:2400 title:@"④ 握手与认证"];
}

// ⑤ 命令与动作
- (void)btnCommand {
    [self runSlice:@[@"control", @"Control", @"sendSignal", @"sendRequest",
                     @"writeValue", @"writePreAuth", @"writeData",
                     @"unlock", @"Unlock", @"UNLOCK",
                     @"lock", @"Lock", @"LOCK",
                     @"trunk", @"Trunk", @"window", @"Window",
                     @"perform", @"Perform", @"action", @"Action"]
           scan:20000 max:2400 title:@"⑤ 命令与动作"];
}

// ⑥ 网络请求
- (void)btnNetwork {
    [self runSlice:@[@"[NET] Url", @"Url:", @"http", @"HTTP",
                     @"request", @"Request", @"response", @"Response",
                     @"dk1-api", @"idp-prd", @"fiov", @"dfiov",
                     @"getTicket", @"getToken", @"initializeSdk", @"getSDKPlatform"]
           scan:20000 max:2400 title:@"⑥ 网络请求"];
}

// ⑦ 错误与状态码
- (void)btnError {
    [self runSlice:@[@"error", @"Error", @"ERROR",
                     @"fail", @"Fail", @"FAIL", @"failed",
                     @"code=", @"Code=", @"errorCode", @"statusCode",
                     @"2201", @"201016", @"202201", @"110013", @"331004"]
           scan:20000 max:2400 title:@"⑦ 错误与状态码"];
}

// ⑧ 密钥与签名
- (void)btnKey {
    [self runSlice:@[@"keyIndex", @"keyId", @"keyTag", @"KeyTag",
                     @"signData", @"signature", @"Signature", @"sign",
                     @"alias", @"Alias",
                     @"SecKey", @"Keychain", @"keychain",
                     @"SecureEnclave", @"certificate", @"Certificate",
                     @"hubSecretKey", @"appId", @"privateKey", @"publicKey"]
           scan:20000 max:2400 title:@"⑧ 密钥与签名"];
}

// ⑨ 特征协商
- (void)btnFeature {
    [self runSlice:@[@"feature", @"Feature", @"FEATURE",
                     @"mtu", @"MTU", @"Mtu",
                     @"standard", @"Standard", @"STANDARD",
                     @"version", @"Version", @"capability", @"Capability",
                     @"defaultFeature", @"matchingPeripheral"]
           scan:20000 max:2400 title:@"⑨ 特征协商"];
}

// ⑩ 只看 PREAUTH 相关
- (void)btnPreAuth {
    [self runSlice:@[@"preAuth", @"PreAuth", @"PREAUTH", @"Preauth"]
           scan:40000 max:2400 title:@"⑩ PREAUTH 专项"];
}

// ⑪ 只看 STATUS 相关
- (void)btnStatus {
    [self runSlice:@[@"statusChar", @"StatusChar", @"statusService", @"StatusService",
                     @"startDiscoverStatus", @"statusWrite", @"parseStatus"]
           scan:40000 max:2400 title:@"⑪ STATUS 专项"];
}

// ⑫ RKE 专项
- (void)btnRke {
    [self runSlice:@[@"RKE", @"rke", @"Rke", @"uri", @"URI",
                     @"functionID", @"actionID", @"functionId", @"actionId",
                     @"payload", @"Payload", @"IngeekRKEAction"]
           scan:40000 max:2400 title:@"⑫ RKE 专项"];
}

// ⑬ BleKey
- (void)btnBleKey {
    if (self.busy) return;
    self.busy = YES;
    [self say:@"提取 BleKey…"];
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSDictionary *p = [self prefs];
        if (!p) { [self setContent:@"plist 读取失败"]; self.busy = NO; return; }

        NSMutableString *o = [NSMutableString string];
        for (NSString *k in p.allKeys) {
            if (![k containsString:@"CacheKeyBle"]) continue;
            id v = p[k];
            [o appendFormat:@"\n---------- %@ ----------\n", k];
            [o appendFormat:@"类型: %@\n\n", [self describe:v]];
            if ([v isKindOfClass:[NSData class]]) {
                NSString *b = [self b64:v];
                if (o.length + b.length + 100 > 2400) {
                    [o appendString:@"（base64 超出 2400 字符，已省略，用③p12 或告诉我需要）\n"];
                } else {
                    [o appendString:b];
                }
            }
        }
        [self setContent:o];
        [self say:[NSString stringWithFormat:@"BleKey %lu 字符", (unsigned long)o.length]];
        self.busy = NO;
    });
}

// ⑭ 目录
- (void)btnCerts {
    if (self.busy) return;
    self.busy = YES;
    [self say:@"检查目录…"];
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSString *r = [self targetRoot];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSMutableString *o = [NSMutableString string];

        NSArray *keys = @[
            @"Documents/private",
            @"Documents/certs",
            @"Documents/digitalkeys",
            @"Documents/csr",
            @"Documents/uap",
            @"Documents/dfssp.p12"
        ];
        for (NSString *k in keys) {
            BOOL e = [fm fileExistsAtPath:[r stringByAppendingPathComponent:k]];
            [o appendFormat:@"%@ %@\n", e ? @"✓" : @"✗", k];
        }
        [o appendString:@"\n--- Documents 顶层 ---\n"];
        NSArray *docs = [fm contentsOfDirectoryAtPath:[r stringByAppendingPathComponent:@"Documents"] error:NULL];
        for (NSString *it in [docs sortedArrayUsingSelector:@selector(compare:)]) {
            [o appendFormat:@" %@\n", it];
        }

        [self setContent:o];
        [self say:@"目录检查完成"];
        self.busy = NO;
    });
}

// ⑮ 蓝牙时间线（只抓 🔑 行，排除 MQTT/远程控制噪声）
- (void)btnTimeline {
    if (self.busy) return;
    self.busy = YES;
    [self say:@"抓蓝牙时间线…"];
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSString *t = [self mainLogText];
        if (!t) { [self setContent:@"无主日志"]; [self say:@"无日志"]; self.busy = NO; return; }

        NSArray *lines = [t componentsSeparatedByString:@"\n"];
        NSUInteger total = lines.count;
        // 扫全部行（不用只扫尾部，因为蓝牙事件可能在任何位置）
        NSUInteger start = 0;
        if (total > 40000) start = total - 40000;

        NSMutableArray *kept = [NSMutableArray array];
        for (NSUInteger i = start; i < total; i++) {
            NSString *line = lines[i];
            if (line.length < 6) continue;
            if (![self isKeyLine:line]) continue;
            [kept addObject:line];
        }

        // 从尾部往前累加到 2400
        NSMutableArray *picked = [NSMutableArray array];
        NSUInteger acc = 0;
        for (NSInteger i = (NSInteger)kept.count - 1; i >= 0; i--) {
            NSString *line = kept[i];
            if (acc + line.length + 1 > 2350) break;
            [picked insertObject:line atIndex:0];
            acc += line.length + 1;
        }

        NSMutableString *o = [NSMutableString string];
        [o appendFormat:@"⑮ 蓝牙时间线（只抓 🔑 行）\n扫描 %lu 行，命中 %lu 行，输出 %lu 行\n",
            (unsigned long)(total - start), (unsigned long)kept.count, (unsigned long)picked.count];
        if (kept.count > picked.count) {
            [o appendFormat:@"（前面还有 %lu 行未显示）\n", (unsigned long)(kept.count - picked.count)];
        }

        // 统计埋点
        NSInteger foundDev = 0, foundCar = 0, scanTimeout = 0, connResult = 0, connV1 = 0;
        for (NSString *l in kept) {
            if ([l rangeOfString:@"发现设备"].location != NSNotFound) foundDev++;
            if ([l rangeOfString:@"东风blekey"].location != NSNotFound) foundCar++;
            if ([l rangeOfString:@"扫描设备超时"].location != NSNotFound) scanTimeout++;
            if ([l rangeOfString:@"连接设备结果"].location != NSNotFound) connResult++;
            if ([l rangeOfString:@"connectDeviceV1"].location != NSNotFound) connV1++;
        }
        [o appendFormat:@"统计：发现设备 %ld 次 / 发现目标车 %ld 次 / 扫描超时 %ld 次 / 连接结果 %ld 次 / connectDeviceV1 %ld 次\n",
            (long)foundDev, (long)foundCar, (long)scanTimeout, (long)connResult, (long)connV1];

        if (foundCar > 0) {
            [o appendString:@"★★★ 目标车已发现！\n"];
        } else if (foundDev > 0) {
            [o appendString:@"⚠️ 有扫描但未发现目标车（东风blekey-044289LE）\n"];
        }
        [o appendString:@"\n"];

        for (NSString *l in picked) { [o appendString:l]; [o appendString:@"\n"]; }

        [self setContent:o];
        [self say:[NSString stringWithFormat:@"🔑 %ld 行 · 车 %ld 次", (long)kept.count, (long)foundCar]];
        self.busy = NO;
    });
}

// 通用切片执行器
- (void)runSlice:(NSArray *)keys scan:(NSUInteger)scan max:(NSUInteger)max title:(NSString *)title {
    if (self.busy) return;
    self.busy = YES;
    [self say:[NSString stringWithFormat:@"%@…", title]];
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSString *t = [self mainLogText];
        NSString *res = [self sliceLog:t keys:keys scanLines:scan maxChars:max title:title];
        [self setContent:res];
        [self say:[NSString stringWithFormat:@"%@ · %lu 字符", title, (unsigned long)res.length]];
        self.busy = NO;
    });
}

@end
