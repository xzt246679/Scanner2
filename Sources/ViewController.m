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
    self.title = @"密钥提取";
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
        @"④用户缓存",
        @"⑤平台信息",
        @"⑥证书目录"
    ];
    SEL acts[6] = {
        @selector(btnBleKey),
        @selector(btnLogin),
        @selector(btnP12),
        @selector(btnUserCache),
        @selector(btnPlatform),
        @selector(btnCerts)
    };
    CGFloat x = 4;
    for (NSInteger i = 0; i < 6; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitle:titles[i] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont boldSystemFontOfSize:12];
        [b addTarget:self action:acts[i] forControlEvents:UIControlEventTouchUpInside];
        b.frame = CGRectMake(x, 4, 92, 38);
        b.layer.borderWidth = 1;
        b.layer.borderColor = [UIColor systemBlueColor].CGColor;
        b.layer.cornerRadius = 6;
        [self.buttonScroll addSubview:b];
        x += 96;
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

// 把 data 转成 76 列换行的 base64
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

// 把 data 转成 hex，32 字节一行
- (NSString *)hex:(NSData *)d {
    NSMutableString *o = [NSMutableString string];
    const unsigned char *b = d.bytes;
    for (NSUInteger i = 0; i < d.length; i++) {
        [o appendFormat:@"%02x", b[i]];
        if ((i + 1) % 32 == 0) [o appendString:@"\n"];
        else if ((i + 1) % 2 == 0) [o appendString:@" "];
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

#pragma mark - 按钮

- (void)btnBleKey {
    if (self.busy) return;
    self.busy = YES;
    [self say:@"提取 BleKey…"];
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSDictionary *p = [self prefs];
        if (!p) { [self setContent:@"plist 读取失败"]; [self say:@"失败"]; self.busy = NO; return; }

        NSMutableString *o = [NSMutableString string];
        [o appendString:@"===== BLE 密钥缓存 =====\n\n"];

        // 找出所有含 CacheKeyBle 或 CacheKeyParking 的键
        NSMutableArray *targets = [NSMutableArray array];
        for (NSString *k in p.allKeys) {
            if ([k containsString:@"CacheKeyBle"] || [k containsString:@"CacheKeyParking"]) {
                [targets addObject:k];
            }
        }
        if (targets.count == 0) {
            [o appendString:@"未找到 BleKey 缓存键\n"];
        }

        for (NSString *k in [targets sortedArrayUsingSelector:@selector(compare:)]) {
            id v = p[k];
            [o appendFormat:@"\n---------- %@ ----------\n", k];
            [o appendFormat:@"类型: %@\n", [self describe:v]];

            if ([v isKindOfClass:[NSData class]]) {
                NSData *d = v;
                // 判断是否是 plist 归档
                if (d.length > 8) {
                    const unsigned char *b = d.bytes;
                    if (b[0] == 'b' && b[1] == 'p' && b[2] == 'l' && b[3] == 'i') {
                        [o appendString:@"格式: bplist（尝试解归档）\n"];
                        @try {
                            id obj = [NSKeyedUnarchiver unarchivedObjectOfClass:[NSObject class]
                                                                      fromData:d error:NULL];
                            if (obj) {
                                [o appendFormat:@"解归档: %@\n", [obj description]];
                            }
                        } @catch (NSException *ex) { }
                    } else {
                        [o appendFormat:@"头部: %02x%02x%02x%02x\n", b[0], b[1], b[2], b[3]];
                    }
                }
                [o appendString:@"\n[base64]\n"];
                [o appendString:[self b64:d]];
                // 如果不超过 600 字节，加 hex
                if (d.length <= 600) {
                    [o appendString:@"\n[hex]\n"];
                    [o appendString:[self hex:d]];
                }
            } else if ([v isKindOfClass:[NSString class]]) {
                [o appendFormat:@"值: %@\n", v];
            }
        }

        [self setContent:o];
        [self say:[NSString stringWithFormat:@"找到 %lu 个 BleKey 键 · %lu 字符",
                   (unsigned long)targets.count, (unsigned long)o.length]];
        self.busy = NO;
    });
}

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
            @"APPENVIRONMENT_TYPE", @"UMAppVersion",
            @"DFCertApp0ExpDate"
        ];
        for (NSString *k in keys) {
            id v = p[k];
            if (!v) continue;
            [o appendFormat:@"%@ = %@\n", k, [self describe:v]];
            if ([v isKindOfClass:[NSData class]] && [(NSData *)v length] < 400) {
                [o appendFormat:@"   base64: %@\n", [v base64EncodedStringWithOptions:0]];
            }
        }

        [self setContent:o];
        [self say:[NSString stringWithFormat:@"登录态 %lu 字符", (unsigned long)o.length]];
        self.busy = NO;
    });
}

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
        [o appendFormat:@"===== dfssp.p12 (%lu B) =====\n\n", (unsigned long)d.length];
        [o appendString:@"[base64]\n"];
        [o appendString:[self b64:d]];
        [o appendString:@"\n[头部 hex 64B]\n"];
        NSData *head = [d subdataWithRange:NSMakeRange(0, MIN((NSUInteger)64, d.length))];
        [o appendString:[self hex:head]];

        [self setContent:o];
        [self say:[NSString stringWithFormat:@"p12 %lu 字符", (unsigned long)o.length]];
        self.busy = NO;
    });
}

- (void)btnUserCache {
    if (self.busy) return;
    self.busy = YES;
    [self say:@"读用户缓存…"];
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSDictionary *p = [self prefs];
        if (!p) { [self setContent:@"plist 读取失败"]; self.busy = NO; return; }

        NSMutableString *o = [NSMutableString string];
        [o appendString:@"===== 用户缓存与车辆信息 =====\n\n"];

        for (NSString *k in p.allKeys) {
            if ([k containsString:@"kUserInfoCacheKey"] || [k containsString:@"kDFDH-"] ||
                [k containsString:@"dks_platform"] || [k containsString:@"PNSLoginCacheKey"]) {
                id v = p[k];
                [o appendFormat:@"\n---------- %@ ----------\n", k];
                if ([v isKindOfClass:[NSDictionary class]]) {
                    NSDictionary *dd = v;
                    for (NSString *kk in [dd.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
                        [o appendFormat:@"  %@ = %@\n", kk, [self describe:dd[kk]]];
                    }
                } else {
                    [o appendFormat:@"%@\n", [self describe:v]];
                    if ([v isKindOfClass:[NSData class]] && [(NSData *)v length] < 800) {
                        [o appendString:[self b64:v]];
                    }
                }
            }
        }

        [self setContent:o];
        [self say:[NSString stringWithFormat:@"用户缓存 %lu 字符", (unsigned long)o.length]];
        self.busy = NO;
    });
}

- (void)btnPlatform {
    if (self.busy) return;
    self.busy = YES;
    [self say:@"读平台信息…"];
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSString *r = [self targetRoot];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSMutableString *o = [NSMutableString string];

        // dks_platform 在 plist
        NSDictionary *p = [self prefs];
        if (p) {
            for (NSString *k in p.allKeys) {
                if ([k containsString:@"dks_platform"] || [k containsString:@"IGSDKConfig"] ||
                    [k containsString:@"EACCOUNT_DS_CCC"] || [k containsString:@"NO_PKI"]) {
                    id v = p[k];
                    [o appendFormat:@"%@ = %@\n", k, [self describe:v]];
                    if ([v isKindOfClass:[NSData class]] && [(NSData *)v length] < 2000) {
                        [o appendString:[self b64:v]];
                    }
                    [o appendString:@"\n"];
                }
            }
        }

        // ICSCaches / IngeekCaches 目录
        [o appendString:@"\n===== 缓存目录 =====\n"];
        NSArray *dirs = @[
            @"Documents/ICSCaches/ics.cache/data",
            @"Documents/IngeekCaches/ingeek.cache/data"
        ];
        for (NSString *rel in dirs) {
            NSString *full = [r stringByAppendingPathComponent:rel];
            [o appendFormat:@"\n--- %@ ---\n", rel];
            NSArray *items = [fm contentsOfDirectoryAtPath:full error:NULL];
            if (!items) { [o appendString:@"(不可读或不存在)\n"]; continue; }
            for (NSString *it in items) {
                NSDictionary *a = [fm attributesOfItemAtPath:[full stringByAppendingPathComponent:it] error:NULL];
                [o appendFormat:@"  %@ (%llu B)\n", it, [a[NSFileSize] unsignedLongLongValue]];
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
    [self say:@"检查目录…"];
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSString *r = [self targetRoot];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSMutableString *o = [NSMutableString string];

        [o appendFormat:@"容器: %@\n\n", r];

        // Documents 顶层
        [o appendString:@"===== Documents 顶层 =====\n"];
        NSArray *docs = [fm contentsOfDirectoryAtPath:[r stringByAppendingPathComponent:@"Documents"] error:NULL];
        for (NSString *it in [docs sortedArrayUsingSelector:@selector(compare:)]) {
            BOOL isDir = NO;
            [fm fileExistsAtPath:[r stringByAppendingPathComponent:[NSString stringWithFormat:@"Documents/%@", it]]
                     isDirectory:&isDir];
            [o appendFormat:@"%@ %@\n", isDir ? @"[D]" : @"[F]", it];
        }

        // Library 顶层
        [o appendString:@"\n===== Library 顶层 =====\n"];
        NSArray *libs = [fm contentsOfDirectoryAtPath:[r stringByAppendingPathComponent:@"Library"] error:NULL];
        for (NSString *it in [libs sortedArrayUsingSelector:@selector(compare:)]) {
            [o appendFormat:@"  %@\n", it];
        }

        // PreferencePanes 全部
        [o appendString:@"\n===== PreferencePanes =====\n"];
        NSString *pp = [r stringByAppendingPathComponent:@"Library/PreferencePanes"];
        NSArray *pps = [fm contentsOfDirectoryAtPath:pp error:NULL];
        for (NSString *it in pps) {
            [o appendFormat:@"  %@\n", it];
        }

        [self setContent:o];
        [self say:[NSString stringWithFormat:@"%lu 字符", (unsigned long)o.length]];
        self.busy = NO;
    });
}

@end
