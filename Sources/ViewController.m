#import "ViewController.h"
#import <Security/Security.h>
#import <sys/utsname.h>

static NSString *const kTargetBundle = @"com.dfmc.dfpv.sapp";
static NSUInteger const kMaxDisplayLen = 300000;

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
    self.title = @"情报提取器";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.buffer = [NSMutableString string];
    self.bufLock = [[NSLock alloc] init];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;

    UILabel *sl = [[UILabel alloc] init];
    sl.text = @"已启动 · 每个按钮输出 2-4 千字符";
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
        @"①容器",
        @"②密钥关键行",
        @"③AUTO开关",
        @"④偏好键名",
        @"⑤DK关键行",
        @"⑥证书信息"
    ];
    SEL acts[6] = {
        @selector(btnContainer),
        @selector(btnKeyLog),
        @selector(btnAutoPrefs),
        @selector(btnAllKeys),
        @selector(btnDKLog),
        @selector(btnCerts)
    };

    CGFloat x = 4;
    for (NSInteger i = 0; i < 6; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitle:titles[i] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont boldSystemFontOfSize:12];
        [b addTarget:self action:acts[i] forControlEvents:UIControlEventTouchUpInside];
        b.frame = CGRectMake(x, 4, 96, 38);
        b.layer.borderWidth = 1;
        b.layer.borderColor = [UIColor systemBlueColor].CGColor;
        b.layer.cornerRadius = 6;
        [self.buttonScroll addSubview:b];
        x += 100;
    }
    self.buttonScroll.contentSize = CGSizeMake(x, 48);
}

#pragma mark - 基础设施

- (void)say:(NSString *)s {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.text = s;
    });
}

- (void)setContent:(NSString *)s {
    NSString *t = s ?: @"";
    [self.bufLock lock];
    [self.buffer setString:t];
    [self.bufLock unlock];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *show = t;
        if (show.length > kMaxDisplayLen) show = [show substringToIndex:kMaxDisplayLen];
        self.textView.text = show;
        [self.textView setContentOffset:CGPointMake(0, 0) animated:NO];
    });
}

- (void)copyAll {
    [self.bufLock lock];
    NSString *s = [self.buffer copy];
    [self.bufLock unlock];
    if (s.length == 0) { [self say:@"内容为空"]; return; }
    @try {
        [UIPasteboard generalPasteboard].string = s;
        [self say:[NSString stringWithFormat:@"已复制 %lu 字符", (unsigned long)s.length]];
    } @catch (NSException *e) {
        [self say:@"复制失败"];
    }
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

- (NSString *)readText:(NSString *)rel {
    NSString *r = [self targetRoot];
    if (!r) return nil;
    NSString *full = [r stringByAppendingPathComponent:rel];
    NSData *d = [NSData dataWithContentsOfFile:full options:0 error:NULL];
    if (!d) return nil;
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (s) return s;
    // 非 UTF-8：抽取可打印
    NSMutableString *out = [NSMutableString string];
    const unsigned char *b = d.bytes;
    NSMutableString *cur = [NSMutableString string];
    for (NSUInteger i = 0; i < d.length && out.length < 200000; i++) {
        unsigned char c = b[i];
        if (c >= 32 && c < 127) {
            [cur appendFormat:@"%c", c];
        } else {
            if (cur.length > 6) {
                [out appendString:cur];
                [out appendString:@"\n"];
            }
            [cur setString:@""];
        }
    }
    if (cur.length > 6) [out appendString:cur];
    return out;
}

// 按关键词过滤行
- (NSString *)grepLines:(NSString *)text keys:(NSArray *)keys maxLen:(NSUInteger)maxLen {
    if (!text) return @"(读取失败)";
    NSMutableString *out = [NSMutableString string];
    NSArray *lines = [text componentsSeparatedByString:@"\n"];
    NSInteger hit = 0;
    NSInteger total = 0;
    for (NSString *line in lines) {
        if (line.length < 4) continue;
        BOOL m = NO;
        for (NSString *k in keys) {
            if ([line rangeOfString:k options:NSCaseInsensitiveSearch].location != NSNotFound) {
                m = YES; break;
            }
        }
        if (!m) continue;
        total++;
        if (out.length + line.length > maxLen) continue;
        [out appendString:line];
        [out appendString:@"\n"];
        hit++;
    }
    NSString *hdr = [NSString stringWithFormat:@"匹配 %ld / 总 %ld 行（输出 %ld 行）\n\n",
                     (long)total, (long)lines.count, (long)hit];
    return [hdr stringByAppendingString:out];
}

#pragma mark - 按钮

- (void)btnContainer {
    if (self.busy) return;
    self.busy = YES;
    [self say:@"定位中…"];
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSMutableString *o = [NSMutableString string];
        [o appendFormat:@"target=%@\nuid=%d\nios=%@\nmodel=%@\n\n",
            kTargetBundle, getuid(),
            [[UIDevice currentDevice] systemVersion], [self machineModel]];
        NSString *r = [self targetRoot];
        [o appendFormat:@"容器: %@\n\n", r ?: @"未找到"];
        if (r) {
            NSArray *keys = @[
                @"Documents/private",
                @"Documents/private/instance_ca_key.pem",
                @"Documents/certs",
                @"Documents/digitalkeys",
                @"Documents/csr",
                @"Documents/uap",
                @"Documents/dfssp.p12",
                @"Documents/IngeekLogger",
                @"Documents/VCKLog",
                @"Library/PreferencePanes/IVCSBLEKey.plist",
                @"Library/Preferences/IngeekIdentity.plist"
            ];
            for (NSString *k in keys) {
                BOOL e = [[NSFileManager defaultManager] fileExistsAtPath:[r stringByAppendingPathComponent:k]];
                [o appendFormat:@"%@ %@\n", e ? @"✓" : @"✗", k];
            }
        }
        [self setContent:o];
        [self say:@"定位完成"];
        self.busy = NO;
    });
}

- (void)btnKeyLog {
    if (self.busy) return;
    self.busy = YES;
    [self say:@"过滤密钥日志…"];
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSString *t = [self readText:@"Documents/VCKLog/com.ics.secureKeyKit.log1.log"];
        NSArray *keys = @[
            @"signData", @"KeyTag", @"alias", @"SecKey", @"Keychain", @"keychain",
            @"SecureEnclave", @"certificate", @"Certificate", @"digitalKey", @"DigitalKey",
            @"activate", @"Activate", @"unlock", @"Unlock",
            @"hubSecretKey", @"appId", @"Env:", @"authType",
            @"Unexpected key", @"Invalid", @"error", @"Error",
            @"BleService", @"ble", @"BLE", @"uuid", @"UUID",
            @"RKE", @"rke", @"uri", @"service", @"characteristic",
            @"connect", @"Connect", @"disconnect",
            @"activateKey", @"localKey", @"getLocalKey", @"shareKey"
        ];
        NSString *res = [self grepLines:t keys:keys maxLen:5000];
        [self setContent:res];
        [self say:[NSString stringWithFormat:@"密钥日志 %lu 字符", (unsigned long)res.length]];
        self.busy = NO;
    });
}

- (void)btnDKLog {
    if (self.busy) return;
    self.busy = YES;
    [self say:@"过滤 DK 日志…"];
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSString *t = [self readText:@"Documents/IngeekLogger/com.ingeek.dk.1.log"];
        NSArray *keys = @[
            @"Ble", @"BLE", @"ble", @"uuid", @"UUID", @"service", @"characteristic",
            @"RKE", @"rke", @"uri", @"control", @"unlock", @"lock", @"Lock",
            @"connect", @"Connect", @"disconnect", @"didConnect",
            @"key", @"Key", @"alias", @"sign", @"Sign",
            @"error", @"Error", @"code=", @"AUTO", @"insensible",
            @"feature", @"Feature", @"standard", @"Standard", @"mtu", @"MTU",
            @"approaching", @"Approaching", @"beacon", @"Beacon"
        ];
        NSString *res = [self grepLines:t keys:keys maxLen:5000];
        [self setContent:res];
        [self say:[NSString stringWithFormat:@"DK日志 %lu 字符", (unsigned long)res.length]];
        self.busy = NO;
    });
}

- (void)btnAutoPrefs {
    if (self.busy) return;
    self.busy = YES;
    [self say:@"读偏好设置…"];
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSString *r = [self targetRoot];
        NSString *full = [r stringByAppendingPathComponent:@"Library/Preferences/com.dfmc.dfpv.sapp.plist"];
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:full];
        if (!d) {
            [self setContent:@"(plist 读取失败)"];
            [self say:@"失败"];
            self.busy = NO;
            return;
        }
        NSMutableString *o = [NSMutableString string];
        [o appendFormat:@"plist 共 %lu 个 key\n\n", (unsigned long)d.count];

        // 先输出所有 AUTO/PE/UNLOCK/LOCK 相关
        [o appendString:@"===== 自动解锁/闭锁相关 =====\n"];
        NSMutableArray *matched = [NSMutableArray array];
        for (NSString *k in d.allKeys) {
            NSString *u = [k uppercaseString];
            if ([u containsString:@"AUTO"] || [u containsString:@"UNLOCK"] ||
                [u containsString:@"LOCK"] || [u containsString:@"PE_"] ||
                [u containsString:@"APPROACH"] || [u containsString:@"INSENSIBLE"] ||
                [u containsString:@"WELCOME"] || [u containsString:@"INTELLIGENT"] ||
                [u containsString:@"DIGITALKEY"] || [u containsString:@"CARKEY"] ||
                [u containsString:@"BLE"] || [u containsString:@"KEY"]) {
                [matched addObject:k];
            }
        }
        for (NSString *k in [matched sortedArrayUsingSelector:@selector(compare:)]) {
            id v = d[k];
            [o appendFormat:@"%@ = %@\n", k, [self shortDesc:v]];
        }

        [o appendString:@"\n===== 全部键名（仅名字）=====\n"];
        NSInteger n = 0;
        for (NSString *k in [[d allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
            [o appendFormat:@"%@\n", k];
            if (++n > 400) { [o appendString:@"…(截断)\n"]; break; }
        }

        [self setContent:o];
        [self say:[NSString stringWithFormat:@"偏好 %lu 键 · %lu 字符", (unsigned long)d.count, (unsigned long)o.length]];
        self.busy = NO;
    });
}

- (void)btnAllKeys {
    if (self.busy) return;
    self.busy = YES;
    [self say:@"扫描 plist 键名…"];
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSString *r = [self targetRoot];
        NSArray *plists = @[
            @"Library/Preferences/com.dfmc.dfpv.sapp.plist",
            @"Library/Preferences/IngeekIdentity.plist",
            @"Library/PreferencePanes/IVCSBLEKey.plist",
            @"Library/PreferencePanes/IVCSDigitalKeyEvents.plist",
            @"Library/PreferencePanes/Account/IvcsAccountInfo.plist"
        ];
        NSMutableString *o = [NSMutableString string];
        for (NSString *rel in plists) {
            [o appendFormat:@"\n##### %@ #####\n", rel];
            NSString *full = [r stringByAppendingPathComponent:rel];
            NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:full];
            if (!d) { [o appendString:@"(不存在或读取失败)\n"]; continue; }
            NSInteger n = 0;
            for (NSString *k in [[d allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
                [o appendFormat:@"%@\n", k];
                if (++n > 150) { [o appendString:@"…\n"]; break; }
            }
        }
        [self setContent:o];
        [self say:[NSString stringWithFormat:@"%lu 字符", (unsigned long)o.length]];
        self.busy = NO;
    });
}

- (void)btnCerts {
    if (self.busy) return;
    self.busy = YES;
    [self say:@"检查证书…"];
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSString *r = [self targetRoot];
        NSMutableString *o = [NSMutableString string];
        NSArray *files = @[
            @"Documents/dfssp.p12",
            @"Documents/certs",
            @"Documents/private",
            @"Documents/digitalkeys"
        ];
        for (NSString *rel in files) {
            NSString *full = [r stringByAppendingPathComponent:rel];
            BOOL isDir = NO;
            BOOL e = [[NSFileManager defaultManager] fileExistsAtPath:full isDirectory:&isDir];
            [o appendFormat:@"\n%@ %@ (%@)\n", e ? @"✓" : @"✗", rel, isDir ? @"目录" : @"文件"];
            if (!e) continue;
            if (isDir) {
                NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:full error:NULL];
                for (NSString *it in items) {
                    NSDictionary *a = [[NSFileManager defaultManager]
                        attributesOfItemAtPath:[full stringByAppendingPathComponent:it] error:NULL];
                    [o appendFormat:@"   %@ (%llu B)\n", it, [a[NSFileSize] unsignedLongLongValue]];
                }
            } else {
                NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:full error:NULL];
                [o appendFormat:@"   大小 %llu B\n", [a[NSFileSize] unsignedLongLongValue]];
                NSData *d = [NSData dataWithContentsOfFile:full options:0 error:NULL];
                if (d && d.length > 0) {
                    NSMutableString *hex = [NSMutableString string];
                    NSUInteger n = MIN((NSUInteger)32, d.length);
                    const unsigned char *b = d.bytes;
                    for (NSUInteger i = 0; i < n; i++) [hex appendFormat:@"%02x", b[i]];
                    [o appendFormat:@"   头部: %@\n", hex];
                    if (d.length > 4) {
                        const unsigned char *bb = d.bytes;
                        [o appendFormat:@"   魔数: %02x%02x%02x%02x\n", bb[0], bb[1], bb[2], bb[3]];
                    }
                }
            }
        }

        // Keychain
        [o appendString:@"\n##### Keychain #####\n"];
        NSDictionary *q = @{
            (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecReturnAttributes: @YES,
            (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll
        };
        CFTypeRef res = NULL;
        OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)q, &res);
        [o appendFormat:@"status=%d\n", (int)st];
        if (st == errSecSuccess && res) {
            NSArray *arr = (__bridge_transfer NSArray *)res;
            for (NSDictionary *it in arr) {
                [o appendFormat:@"  svc=%@ acct=%@\n",
                    it[(__bridge id)kSecAttrService] ?: @"-",
                    it[(__bridge id)kSecAttrAccount] ?: @"-"];
            }
        } else if (res) {
            CFRelease(res);
        }

        [self setContent:o];
        [self say:[NSString stringWithFormat:@"证书 %lu 字符", (unsigned long)o.length]];
        self.busy = NO;
    });
}

- (NSString *)shortDesc:(id)v {
    if (!v) return @"(null)";
    if ([v isKindOfClass:[NSString class]]) {
        NSString *s = v;
        return s.length > 120 ? [NSString stringWithFormat:@"%@…(%lu字符)", [s substringToIndex:120], (unsigned long)s.length] : s;
    }
    if ([v isKindOfClass:[NSNumber class]]) return [v stringValue];
    if ([v isKindOfClass:[NSData class]]) return [NSString stringWithFormat:@"<data %lu B>", (unsigned long)[v length]];
    if ([v isKindOfClass:[NSArray class]]) return [NSString stringWithFormat:@"<array %lu>", (unsigned long)[v count]];
    if ([v isKindOfClass:[NSDictionary class]]) return [NSString stringWithFormat:@"<dict %lu>", (unsigned long)[v count]];
    return [v description];
}

- (NSString *)machineModel {
    struct utsname si;
    uname(&si);
    return [NSString stringWithUTF8String:si.machine] ?: @"?";
}

@end
