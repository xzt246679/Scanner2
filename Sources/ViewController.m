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
    self.title = @"密钥 + 日志";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.buffer = [NSMutableString string];
    self.bufLock = [[NSLock alloc] init];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;

    UILabel *sl = [[UILabel alloc] init];
    sl.text = @"已启动";
    sl.font = [UIFont systemFontOfSize:11];
    sl.textAlignment = NSTextAlignmentCenter;
    sl.numberOfLines = 2;
    sl.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:sl];
    self.statusLabel = sl;

    UIScrollView *sv = [[UIScrollView alloc] init];
    sv.showsHorizontalScrollIndicator = YES;
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
        [sv.heightAnchor constraintEqualToConstant:48],
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
        @"①BleKey",
        @"②登录态",
        @"③p12",
        @"④证书目录",
        @"⑤开锁日志",
        @"⑥DK引擎日志",
        @"⑦密钥日志",
        @"⑧GATT对照",
        @"⑨全部日志"
    ];
    SEL acts[9] = {
        @selector(btnBleKey),
        @selector(btnLogin),
        @selector(btnP12),
        @selector(btnCerts),
        @selector(btnUnlockLog),
        @selector(btnDKLog),
        @selector(btnKeyLog),
        @selector(btnGatt),
        @selector(btnAllLogs)
    };
    CGFloat x = 4;
    for (NSInteger i = 0; i < 9; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitle:titles[i] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont boldSystemFontOfSize:11];
        [b addTarget:self action:acts[i] forControlEvents:UIControlEventTouchUpInside];
        b.frame = CGRectMake(x, 4, 86, 38);
        b.layer.borderWidth = 1;
        b.layer.borderColor = [UIColor systemBlueColor].CGColor;
        b.layer.cornerRadius = 5;
        [self.buttonScroll addSubview:b];
        x += 90;
    }
    self.buttonScroll.contentSize = CGSizeMake(x, 48);
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

// 找出 Documents 下所有 .log，按修改时间倒序（最新在前）
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

// 找最大的 .log
- (NSDictionary *)largestLogFile {
    NSArray *arr = [self sortedLogFiles];
    NSDictionary *best = nil;
    unsigned long long bestSize = 0;
    for (NSDictionary *d in arr) {
        unsigned long long s = [d[@"size"] unsignedLongLongValue];
        if (s > bestSize) { bestSize = s; best = d; }
    }
    return best;
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

// ============ 日志过滤核心 ============

// 噪声关键词（分析类、地图、统计 SDK），默认丢弃
- (NSArray *)noiseKeys {
    return @[
        @"Analysys", @"Analytics", @"UMeng", @"UMENG", @"umeng", @"bugly", @"Bugly",
        @"amap", @"AMap", @"AMapLocation", @"MAMap", @"高德",
        @"SensorsAnalytics", @"ingeekanalytics", @"ingzzkanalytics",
        @"WPK", @"Wpk", @"wpk",
        @"xhs", @"xiaohongshu", @"XHS",
        @"X-B3-TraceId", @"tracerent", @"traceparent",
        @"AMapLog", @"LYLogs", @"SYSYLANA",
        @"Reachability", @"networkReachability",
        @"[IG]", @"[IZ]"
    ];
}

- (BOOL)isNoise:(NSString *)line {
    for (NSString *k in [self noiseKeys]) {
        if ([line rangeOfString:k].location != NSNotFound) return YES;
    }
    return NO;
}

// 从行首解析时间戳 "[2026-11-22 14:33:42.237]"
- (NSDate *)parseTimestamp:(NSString *)line {
    if (line.length < 20) return nil;
    if (![line hasPrefix:@"["]) return nil;
    NSRange end = [line rangeOfString:@"]"];
    if (end.location == NSNotFound || end.location > 28) return nil;
    NSString *ts = [line substringWithRange:NSMakeRange(1, end.location - 1)];
    // 格式: "2026-11-22 14:33:42.237" 或 "2026-11-22 10:45:25.894"
    static NSDateFormatter *df1 = nil;
    static NSDateFormatter *df2 = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        df1 = [[NSDateFormatter alloc] init];
        df1.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
        df1.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        df2 = [[NSDateFormatter alloc] init];
        df2.dateFormat = @"yyyy-MM-dd HH:mm:ss";
        df2.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    });
    NSDate *d = [df1 dateFromString:ts];
    if (!d) d = [df2 dateFromString:ts];
    return d;
}

// 通用：取最后 tailLines 行，按关键词过滤 + 时间过滤
- (NSString *)filterLogText:(NSString *)text
                     keys:(NSArray *)keys
                tailLines:(NSUInteger)tailLines
                  minutes:(NSInteger)minutes
                  maxChars:(NSUInteger)maxChars
                 header:(NSString *)header {
    if (!text || text.length == 0) return @"(日志为空或不存在)";

    NSArray *allLines = [text componentsSeparatedByString:@"\n"];
    NSUInteger total = allLines.count;

    NSUInteger startIdx = 0;
    if (total > tailLines) startIdx = total - tailLines;

    NSDate *cut = nil;
    if (minutes > 0) cut = [NSDate dateWithTimeIntervalSinceNow:-60.0 * minutes];

    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"%@\n总行数 %lu，检查尾部 %lu 行\n\n",
        header ?: @"", (unsigned long)total, (unsigned long)(total - startIdx)];

    NSInteger matched = 0;
    NSInteger written = 0;
    NSDate *firstDate = nil;
    NSDate *lastDate = nil;

    for (NSUInteger i = startIdx; i < total; i++) {
        NSString *line = allLines[i];
        if (line.length < 4) continue;

        // 时间过滤
        if (cut) {
            NSDate *d = [self parseTimestamp:line];
            if (d) {
                if (!firstDate) firstDate = d;
                lastDate = d;
                if ([d compare:cut] == NSOrderedAscending) continue;
            }
        }

        // 噪声过滤
        if ([self isNoise:line]) continue;

        // 关键词匹配
        BOOL hit = (keys.count == 0);
        for (NSString *k in keys) {
            if ([line rangeOfString:k].location != NSNotFound) { hit = YES; break; }
        }
        if (!hit) continue;

        matched++;
        if (out.length + line.length + 1 > maxChars) {
            [out appendString:@"\n…(达到字符上限，已截断)\n"];
            break;
        }
        [out appendString:line];
        [out appendString:@"\n"];
        written++;
    }

    NSMutableString *hdr = [NSMutableString string];
    [hdr appendFormat:@"匹配 %ld 行，输出 %ld 行\n", (long)matched, (long)written];
    if (firstDate) {
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"HH:mm:ss";
        [hdr appendFormat:@"时间范围 %@ ~ %@\n", [df stringFromDate:firstDate],
            lastDate ? [df stringFromDate:lastDate] : @"?"];
    }
    [hdr appendString:@"\n"];

    return [NSString stringWithFormat:@"%@%@", hdr, out];
}

#pragma mark - 按钮

// ① BleKey
- (void)btnBleKey {
    if (self.busy) return;
    self.busy = YES;
    [self say:@"提取 BleKey…"];
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSDictionary *p = [self prefs];
        if (!p) { [self setContent:@"plist 读取失败"]; [self say:@"失败"]; self.busy = NO; return; }

        NSMutableString *o = [NSMutableString string];
        [o appendString:@"===== BLE 密钥缓存 =====\n\n"];

        NSMutableArray *targets = [NSMutableArray array];
        for (NSString *k in p.allKeys) {
            if ([k containsString:@"CacheKeyBle"] || [k containsString:@"CacheKeyParking"]) {
                [targets addObject:k];
            }
        }

        for (NSString *k in [targets sortedArrayUsingSelector:@selector(compare:)]) {
            id v = p[k];
            [o appendFormat:@"\n---------- %@ ----------\n", k];
            [o appendFormat:@"类型: %@\n", [self describe:v]];
            if ([v isKindOfClass:[NSData class]]) {
                NSData *d = v;
                if (d.length > 8) {
                    const unsigned char *b = d.bytes;
                    if (b[0] == 'b' && b[1] == 'p' && b[2] == 'l' && b[3] == 'i') {
                        [o appendString:@"格式: bplist 归档\n"];
                    } else {
                        [o appendFormat:@"头部: %02x%02x%02x%02x\n", b[0], b[1], b[2], b[3]];
                    }
                }
                [o appendString:@"\n[base64]\n"];
                [o appendString:[self b64:d]];
            } else {
                [o appendFormat:@"值: %@\n", [self describe:v]];
            }
        }

        [self setContent:o];
        [self say:[NSString stringWithFormat:@"BleKey %lu 字符", (unsigned long)o.length]];
        self.busy = NO;
    });
}

// ② 登录态
- (void)btnLogin {
    if (self.busy) return;
    self.busy = YES;
    [self say:@"提取登录态…"];
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSDictionary *p = [self prefs];
        if (!p) { [self setContent:@"plist 读取失败"]; self.busy = NO; return; }

        NSMutableString *o = [NSMutableString string];
        [o appendString:@"===== 登录态与标识 =====\n\n"];

        NSArray *keys = @[
            @"EP_token", @"EP_userId", @"EP_userPhone",
            @"DFIOV_TSP_LOGIN", @"FT_USER_INFO",
            @"com.dfmc.dfpv.sapp.uuid", @"userUuid", @"4651320",
            @"OpenUDID", @"UMENGIDFV", @"UMIDFA", @"UTDID", @"UMUTOKEN",
            @"IngeekDk.deviceID", @"currentSingNoncestr",
            @"appkey", @"AnalysysAppKey",
            @"APPENVIRONMENT_TYPE", @"UMAppVersion", @"DFCertApp0ExpDate"
        ];
        for (NSString *k in keys) {
            id v = p[k];
            if (!v) continue;
            [o appendFormat:@"%@ = %@\n", k, [self describe:v]];
            if ([v isKindOfClass:[NSData class]] && [(NSData *)v length] < 400) {
                [o appendFormat:@"   b64: %@\n", [v base64EncodedStringWithOptions:0]];
            }
        }

        [self setContent:o];
        [self say:[NSString stringWithFormat:@"登录态 %lu 字符", (unsigned long)o.length]];
        self.busy = NO;
    });
}

// ③ p12
- (void)btnP12 {
    if (self.busy) return;
    self.busy = YES;
    [self say:@"读 p12…"];
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSString *r = [self targetRoot];
        NSString *full = [r stringByAppendingPathComponent:@"Documents/dfssp.p12"];
        NSData *d = [NSData dataWithContentsOfFile:full options:0 error:NULL];
        if (!d) { [self setContent:@"p12 不存在"]; [self say:@"不存在"]; self.busy = NO; return; }

        NSMutableString *o = [NSMutableString string];
        [o appendFormat:@"===== dfssp.p12 (%lu B) =====\n\n[base64]\n", (unsigned long)d.length];
        [o appendString:[self b64:d]];

        [self setContent:o];
        [self say:[NSString stringWithFormat:@"p12 %lu 字符", (unsigned long)o.length]];
        self.busy = NO;
    });
}

// ④ 证书目录
- (void)btnCerts {
    if (self.busy) return;
    self.busy = YES;
    [self say:@"检查目录…"];
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSString *r = [self targetRoot];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSMutableString *o = [NSMutableString string];
        [o appendFormat:@"容器: %@\n\n", r];

        NSArray *keys = @[
            @"Documents/private",
            @"Documents/private/instance_ca_key.pem",
            @"Documents/certs",
            @"Documents/digitalkeys",
            @"Documents/csr",
            @"Documents/uap",
            @"Documents/dfssp.p12"
        ];
        [o appendString:@"===== 关键路径 =====\n"];
        for (NSString *k in keys) {
            BOOL isDir = NO;
            BOOL e = [fm fileExistsAtPath:[r stringByAppendingPathComponent:k] isDirectory:&isDir];
            [o appendFormat:@"%@ %@ (%@)\n", e ? @"✓" : @"✗", k, isDir ? @"目录" : @"文件"];
            if (e && isDir) {
                NSArray *items = [fm contentsOfDirectoryAtPath:[r stringByAppendingPathComponent:k] error:NULL];
                for (NSString *it in items) {
                    [o appendFormat:@"     %@\n", it];
                }
            }
        }

        [o appendString:@"\n===== Documents 顶层 =====\n"];
        NSArray *docs = [fm contentsOfDirectoryAtPath:[r stringByAppendingPathComponent:@"Documents"] error:NULL];
        for (NSString *it in [docs sortedArrayUsingSelector:@selector(compare:)]) {
            [o appendFormat:@"  %@\n", it];
        }

        [o appendString:@"\n===== PreferencePanes =====\n"];
        NSArray *pps = [fm contentsOfDirectoryAtPath:[r stringByAppendingPathComponent:@"Library/PreferencePanes"] error:NULL];
        for (NSString *it in pps) [o appendFormat:@"  %@\n", it];

        [self setContent:o];
        [self say:[NSString stringWithFormat:@"目录 %lu 字符", (unsigned long)o.length]];
        self.busy = NO;
    });
}

// ⑤ 开锁日志（核心）—— 取最新 + 最大的 log
- (void)btnUnlockLog {
    if (self.busy) return;
    self.busy = YES;
    [self say:@"抓开锁日志…"];
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSMutableString *all = [NSMutableString string];

        // 先列出所有 log
        NSArray *arr = [self sortedLogFiles];
        [all appendString:@"===== Documents 下所有 .log =====\n"];
        for (NSDictionary *d in arr) {
            [all appendFormat:@"  %-40s %10llu B\n", [d[@"name"] UTF8String],
                [d[@"size"] unsignedLongLongValue]];
        }
        [all appendString:@"\n"];

        NSArray *keys = @[
            @"Ble", @"BLE", @"ble", @"BleService", @"IngeekBle", @"ICSBle",
            @"uuid", @"UUID", @"service", @"characteristic",
            @"connect", @"Connect", @"disconnect", @"Disconnect",
            @"didConnect", @"didDisconnect", @"didReceiveData",
            @"RKE", @"rke", @"uri", @"control", @"Control",
            @"unlock", @"Unlock", @"lock", @"Lock",
            @"sendSignal", @"sendRequest", @"writePreAuth", @"writeValue",
            @"preAuth", @"PreAuth", @"status", @"Status",
            @"challenge", @"Challenge", @"session", @"Session",
            @"feature", @"Feature", @"mtu", @"MTU",
            @"[NET] Url", @"error", @"Error", @"code=",
            @"keyIndex", @"keyId", @"keyTag", @"alias",
            @"signData", @"insensible", @"approaching", @"beacon"
        ];

        // 抓前 3 个最新的 log（通常主日志 + IVCS 日志 + ads 日志）
        NSInteger n = MIN((NSInteger)arr.count, 3);
        for (NSInteger i = 0; i < n; i++) {
            NSString *name = arr[i][@"name"];
            NSString *t = [self readText:[NSString stringWithFormat:@"Documents/%@", name]];
            NSString *f = [self filterLogText:t keys:keys tailLines:3000 minutes:0
                                     maxChars:4000
                                       header:[NSString stringWithFormat:@"##### %@ #####", name]];
            [all appendString:f];
            [all appendString:@"\n\n"];
            if (all.length > 11000) break;
        }

        [self setContent:all];
        [self say:[NSString stringWithFormat:@"%lu 个日志 · %lu 字符",
                   (unsigned long)arr.count, (unsigned long)all.length]];
        self.busy = NO;
    });
}

// ⑥ DK 引擎日志
- (void)btnDKLog {
    if (self.busy) return;
    self.busy = YES;
    [self say:@"读 DK 日志…"];
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSString *t = [self readText:@"Documents/IngeekLogger/com.ingeek.dk.1.log"];
        NSArray *keys = @[
            @"Ble", @"BLE", @"ble", @"uuid", @"UUID", @"service", @"Service",
            @"characteristic", @"RKE", @"rke", @"uri", @"control", @"unlock", @"lock",
            @"connect", @"Connect", @"didConnect", @"disconnect",
            @"preAuth", @"status", @"challenge", @"session",
            @"feature", @"Feature", @"standard", @"Standard", @"mtu", @"MTU",
            @"keyIndex", @"keyId", @"sign", @"Sign",
            @"error", @"Error", @"code=", @"insensible", @"approaching", @"beacon"
        ];
        NSString *f = [self filterLogText:t keys:keys tailLines:3000 minutes:0
                                 maxChars:9000 header:@"##### com.ingeek.dk.1.log #####"];
        [self setContent:f];
        [self say:[NSString stringWithFormat:@"DK日志 %lu 字符", (unsigned long)f.length]];
        self.busy = NO;
    });
}

// ⑦ 密钥系统日志
- (void)btnKeyLog {
    if (self.busy) return;
    self.busy = YES;
    [self say:@"读密钥日志…"];
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSString *t = [self readText:@"Documents/VCKLog/com.ics.secureKeyKit.log1.log"];
        NSArray *keys = @[
            @"signData", @"KeyTag", @"keyTag", @"alias", @"SecKey", @"Keychain", @"keychain",
            @"SecureEnclave", @"certificate", @"Certificate",
            @"digitalKey", @"DigitalKey", @"activate", @"Activate",
            @"keyIndex", @"keyId", @"localKey", @"getLocalKey",
            @"hubSecretKey", @"appId", @"Env:", @"authType",
            @"Unexpected key", @"Invalid", @"error", @"Error",
            @"Ble", @"ble", @"BLE", @"uuid", @"UUID",
            @"service", @"characteristic", @"RKE", @"rke", @"uri",
            @"connect", @"Connect", @"disconnect"
        ];
        NSString *f = [self filterLogText:t keys:keys tailLines:3000 minutes:0
                                 maxChars:9000 header:@"##### com.ics.secureKeyKit.log1.log #####"];
        [self setContent:f];
        [self say:[NSString stringWithFormat:@"密钥日志 %lu 字符", (unsigned long)f.length]];
        self.busy = NO;
    });
}

// ⑧ GATT 对照（静态知识，便于你核对）
- (void)btnGatt {
    NSString *s =
    @"===== 车端 GATT 结构（nRF Connect 实测）=====\n"
    "设备名: 东风blekey-044289LE\n"
    "MAC:    10:23:81:19:76:60\n"
    "广播:   Legacy, LE General Discoverable\n"
    "广播 UUID: 0xFF00   ← advertisingServiceUuid\n\n"

    "【服务 A】0xFF00\n"
    "  FF01  NOTIFY\n"
    "  FF02  WRITE + WRITE_NO_RESPONSE\n\n"

    "【服务 B】00001100-d102-11e1-9b23-00025b00a5a5\n"
    "  00001101-...  WRITE\n"
    "  00001102-...  READ + NOTIFY\n"
    "  00001103-...  READ + WRITE_NO_RESPONSE + NOTIFY\n\n"

    "【系统】0x1800 Generic Access\n"
    "  2A00 Device Name  READ\n"
    "  2A01 Appearance   READ\n"
    "  2AA6 Central Addr Resolution  READ\n\n"

    "【系统】0x1801 Generic Attribute\n"
    "  2A05 Service Changed  INDICATE\n\n"

    "===== SDK 字段推测映射 =====\n"
    "advertisingServiceUuid = 0xFF00        ✅ 已确认\n"
    "preAuthServiceUuid     = ?\n"
    "preAuthWriteCharUuid   = ?\n"
    "preAuthNotifyCharUuid  = ?\n"
    "statusServiceUuid      = ?\n"
    "statusWriteCharUuid    = ?\n"
    "statusCharUuid         = ?\n\n"

    "===== 待日志确认 =====\n"
    "看 5️⃣ 输出里出现：\n"
    "  startDiscoverPreAuthCharacteristics\n"
    "  startDiscoverStatusCharacteristics\n"
    "这两行前后的 uuid 就是答案。\n";
    [self setContent:s];
    [self say:@"GATT 对照"];
}

// ⑨ 全部日志（取最大的 log，因为主日志 811KB）
- (void)btnAllLogs {
    if (self.busy) return;
    self.busy = YES;
    [self say:@"读主日志…"];
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSDictionary *big = [self largestLogFile];
        if (!big) { [self setContent:@"无 .log"]; [self say:@"无日志"]; self.busy = NO; return; }

        NSString *name = big[@"name"];
        unsigned long long sz = [big[@"size"] unsignedLongLongValue];

        NSMutableString *o = [NSMutableString string];
        [o appendFormat:@"===== 主日志: %@ (%llu B) =====\n\n", name, sz];

        NSString *t = [self readText:[NSString stringWithFormat:@"Documents/%@", name]];
        NSString *f = [self filterLogText:t keys:@[] tailLines:3000 minutes:0
                                 maxChars:9000 header:@"(仅滤噪，最近 3000 行)"];
        [o appendString:f];

        [self setContent:o];
        [self say:[NSString stringWithFormat:@"%@ · %llu B · %lu 字符",
                   name, sz, (unsigned long)o.length]];
        self.busy = NO;
    });
}

@end
