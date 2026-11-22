#import "ViewController.h"
#import <Security/Security.h>
#import <sys/utsname.h>

static NSString *const kTargetBundle = @"com.dfmc.dfpv.sapp";

@interface ViewController ()
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UIButton *button;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) NSMutableString *buffer;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"沙盒扫描";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.buffer = [NSMutableString string].mutableCopy;

    UILabel *sl = [[UILabel alloc] init];
    sl.text = @"已启动 · 点按钮开始扫描";
    sl.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    sl.textAlignment = NSTextAlignmentCenter;
    sl.numberOfLines = 0;
    sl.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:sl];
    self.statusLabel = sl;

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    [btn setTitle:@"开始扫描" forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    [btn addTarget:self action:@selector(runScan) forControlEvents:UIControlEventTouchUpInside];
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:btn];
    self.button = btn;

    UITextView *tv = [[UITextView alloc] init];
    tv.font = [UIFont fontWithName:@"Menlo" size:10] ?: [UIFont systemFontOfSize:10];
    tv.editable = NO;
    tv.alwaysBounceVertical = YES;
    tv.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:tv];
    self.textView = tv;

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [sl.topAnchor constraintEqualToAnchor:safe.topAnchor constant:6],
        [sl.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [sl.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],

        [btn.topAnchor constraintEqualToAnchor:sl.bottomAnchor constant:8],
        [btn.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [btn.heightAnchor constraintEqualToConstant:40],

        [tv.topAnchor constraintEqualToAnchor:btn.bottomAnchor constant:8],
        [tv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:4],
        [tv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-4],
        [tv.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor]
    ]];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"复制" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(copyAll)];
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"清空" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(clearAll)];
}

- (void)clearAll {
    [self.buffer setString:@""];
    self.textView.text = @"";
    self.statusLabel.text = @"已清空";
}

- (void)copyAll {
    [UIPasteboard generalPasteboard].string = self.buffer;
    self.statusLabel.text = [NSString stringWithFormat:@"已复制 %lu 字符", (unsigned long)self.buffer.length];
}

- (void)log:(NSString *)fmt, ... {
    va_list args;
    va_start(args, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    [self.buffer appendString:s];
    [self.buffer appendString:@"\n"];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self2 = weakSelf;
        if (!self2) return;
        self2.textView.text = self2.buffer;
        NSUInteger len = self2.buffer.length;
        if (len > 0) {
            [self2.textView scrollRangeToVisible:NSMakeRange(len - 1, 1)];
        }
    });
}

- (void)runScan {
    self.statusLabel.text = @"扫描中…";
    self.button.enabled = NO;
    [self.buffer setString:@""];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __strong typeof(weakSelf) self2 = weakSelf;
        if (!self2) return;
        @try {
            [self2 scanAll];
        } @catch (NSException *e) {
            [self2 log:@"!!! 异常: %@ %@", e.name, e.reason];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self3 = weakSelf;
            if (!self3) return;
            self3.button.enabled = YES;
            self3.statusLabel.text = [NSString stringWithFormat:@"完成 · %lu 字符",
                                      (unsigned long)self3.buffer.length];
        });
    });
}

#pragma mark - 扫描

- (void)scanAll {
    [self log:@"========== 环境 =========="];
    [self log:@"uid=%d", getuid()];
    [self log:@"euid=%d", geteuid()];
    [self log:@"bundle=%@", [[NSBundle mainBundle] bundleIdentifier] ?: @"-"];
    [self log:@"ios=%@", [[UIDevice currentDevice] systemVersion]];
    [self log:@"model=%@", [self machineModel]];
    [self log:@"home=%@", NSHomeDirectory()];

    [self log:@""];
    [self log:@"========== 权限自检 =========="];
    NSArray *probes = @[
        @"/var/mobile/Containers/Data/Application",
        @"/var/containers/Bundle/Application",
        @"/var/mobile",
        @"/private/var/mobile",
        @"/var/mobile/Library",
        @"/var/mobile/Media"
    ];
    for (NSString *p in probes) {
        BOOL ok = [self canRead:p];
        [self log:@"%@  %@", ok ? @"可读" : @"无权限", p];
    }

    [self log:@""];
    [self log:@"========== 定位目标容器 =========="];
    NSString *root = [self findAppRoot];
    if (root) {
        [self log:@"找到: %@", root];
        [self log:@""];
        [self log:@"========== 目录树（深度5）=========="];
        [self walk:root depth:0 maxDepth:5];
        [self log:@""];
        [self log:@"========== 关键文件 =========="];
        [self scanKeyFiles:root];
        [self log:@""];
        [self log:@"========== 协议判定 =========="];
        [self detectProtocol:root];
    } else {
        [self log:@"未找到 %@", kTargetBundle];
        [self log:@""];
        [self log:@"========== 可用容器（前40）=========="];
        [self listContainers:40];
    }

    [self log:@""];
    [self log:@"========== Keychain =========="];
    [self dumpKeychain];

    [self log:@""];
    [self log:@"========== 完成 =========="];
}

- (NSString *)machineModel {
    struct utsname si;
    uname(&si);
    return [NSString stringWithUTF8String:si.machine] ?: @"?";
}

- (BOOL)canRead:(NSString *)path {
    NSError *err = nil;
    NSArray *a = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:&err];
    return (a != nil);
}

- (NSString *)findAppRoot {
    NSString *base = @"/var/mobile/Containers/Data/Application";
    NSError *err = nil;
    NSArray *dirs = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:base error:&err];
    if (!dirs) return nil;
    for (NSString *d in dirs) {
        NSString *meta = [NSString stringWithFormat:@"%@/%@/.com.apple.mobile_container_manager.metadata.plist", base, d];
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:meta];
        NSString *ident = dict[@"MCMMetadataIdentifier"];
        if (ident && [ident isEqualToString:kTargetBundle]) {
            return [NSString stringWithFormat:@"%@/%@", base, d];
        }
    }
    return nil;
}

- (void)listContainers:(NSInteger)limit {
    NSString *base = @"/var/mobile/Containers/Data/Application";
    NSError *err = nil;
    NSArray *dirs = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:base error:&err];
    if (!dirs) {
        [self log:@"无法列出 %@ (err=%@)", base, err.localizedDescription];
        return;
    }
    NSInteger i = 0;
    for (NSString *d in dirs) {
        if (i >= limit) break;
        NSString *meta = [NSString stringWithFormat:@"%@/%@/.com.apple.mobile_container_manager.metadata.plist", base, d];
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:meta];
        NSString *ident = dict[@"MCMMetadataIdentifier"] ?: @"?";
        [self log:@"%3ld. %@", (long)i, ident];
        i++;
    }
}

- (void)walk:(NSString *)path depth:(NSInteger)depth maxDepth:(NSInteger)maxDepth {
    if (depth > maxDepth) return;
    NSMutableString *indent = [NSMutableString string];
    for (NSInteger i = 0; i < depth; i++) [indent appendString:@"  "];

    NSError *err = nil;
    NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:&err];
    if (!items) {
        [self log:@"%@[不可读]", indent];
        return;
    }
    NSArray *sorted = [items sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *name in sorted) {
        NSString *full = [path stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:full isDirectory:&isDir]) continue;
        if (isDir) {
            [self log:@"%@[D] %@/", indent, name];
            [self walk:full depth:depth + 1 maxDepth:maxDepth];
        } else {
            NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:full error:NULL];
            unsigned long long sz = [attrs[NSFileSize] unsignedLongLongValue];
            [self log:@"%@[F] %@  (%llu B)", indent, name, sz];
        }
    }
}

- (void)scanKeyFiles:(NSString *)root {
    NSMutableArray *hits = [NSMutableArray array];
    NSArray *exts = @[@".pem", @".der", @".json", @".plist", @".db", @".sqlite", @".db3"];
    [self collect:root depth:0 maxDepth:6 exts:exts into:hits];
    [self log:@"候选文件 %lu 个", (unsigned long)hits.count];

    for (NSString *f in hits) {
        NSString *rel = [f stringByReplacingOccurrencesOfString:root withString:@""];
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:f error:NULL];
        unsigned long long sz = [attrs[NSFileSize] unsignedLongLongValue];
        [self log:@""];
        [self log:@"---- %@  (%llu B) ----", rel, sz];
        if (sz == 0 || sz > 65536) {
            [self log:@"[跳过内容]"];
            continue;
        }
        NSData *data = [NSData dataWithContentsOfFile:f];
        if (!data) { [self log:@"[读取失败]"]; continue; }
        NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (s) {
            NSUInteger n = MIN((NSUInteger)1500, s.length);
            [self log:@"%@", [s substringToIndex:n]];
        } else {
            NSMutableString *hex = [NSMutableString string];
            NSUInteger n = MIN((NSUInteger)40, data.length);
            const unsigned char *bytes = data.bytes;
            for (NSUInteger i = 0; i < n; i++) [hex appendFormat:@"%02x", bytes[i]];
            [self log:@"[二进制] %@", hex];
        }
    }
}

- (void)collect:(NSString *)path depth:(NSInteger)depth maxDepth:(NSInteger)maxDepth
           exts:(NSArray *)exts into:(NSMutableArray *)out {
    if (depth > maxDepth) return;
    NSError *err = nil;
    NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:&err];
    if (!items) return;
    for (NSString *name in items) {
        NSString *full = [path stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:full isDirectory:&isDir]) continue;
        if (isDir) {
            [self collect:full depth:depth + 1 maxDepth:maxDepth exts:exts into:out];
        } else {
            for (NSString *e in exts) {
                if ([name hasSuffix:e]) { [out addObject:full]; break; }
            }
        }
    }
}

- (void)detectProtocol:(NSString *)root {
    NSArray *candidates = @[
        [root stringByAppendingPathComponent:@"Documents/digitalkeys"],
        [root stringByAppendingPathComponent:@"Documents"],
        [root stringByAppendingPathComponent:@"Library"]
    ];
    for (NSString *base in candidates) {
        NSError *err = nil;
        NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:base error:&err];
        if (!items) continue;
        NSMutableArray *hit = [NSMutableArray array];
        for (NSString *n in items) {
            if ([n containsString:@"_dk_"] || [n hasPrefix:@"digital_key"]) [hit addObject:n];
        }
        if (hit.count == 0) continue;
        [self log:@"%@:", base];
        for (NSString *h in hit) [self log:@"   %@", h];

        NSMutableSet *protos = [NSMutableSet set];
        for (NSString *h in hit) {
            if ([h hasPrefix:@"c11_dk_"]) [protos addObject:@"COT/C11"];
            if ([h hasPrefix:@"icce10_dk_"]) [protos addObject:@"ICCE10"];
            else if ([h hasPrefix:@"icce_dk_"]) [protos addObject:@"ICCE"];
            if ([h hasPrefix:@"pki_dk_"]) [protos addObject:@"PKI"];
            if ([h hasPrefix:@"tdk21_dk_"]) [protos addObject:@"TDK21"];
            if ([h hasPrefix:@"legacy_dk_"]) [protos addObject:@"Legacy"];
        }
        NSString *desc = protos.count ? [[protos allObjects] componentsJoinedByString:@" / "] : @"未识别";
        [self log:@"判定协议: %@", desc];
    }
}

- (void)dumpKeychain {
    NSArray *classes = @[
        @[@"GenericPassword", (__bridge id)kSecClassGenericPassword],
        @[@"Key", (__bridge id)kSecClassKey],
        @[@"Certificate", (__bridge id)kSecClassCertificate],
        @[@"Identity", (__bridge id)kSecClassIdentity]
    ];
    for (NSArray *pair in classes) {
        NSString *label = pair[0];
        id cls = pair[1];
        NSDictionary *q = @{
            (__bridge id)kSecClass: cls,
            (__bridge id)kSecReturnAttributes: @YES,
            (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll
        };
        CFTypeRef result = NULL;
        OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)q, &result);
        [self log:@""];
        [self log:@"[%@] status=%d", label, (int)st];
        if (st == errSecSuccess && result) {
            NSArray *arr = (__bridge_transfer NSArray *)result;
            [self log:@"  条目数: %lu", (unsigned long)arr.count];
            NSInteger i = 0;
            for (NSDictionary *item in arr) {
                if (i >= 30) break;
                NSString *svc = item[(__bridge id)kSecAttrService] ?: @"-";
                NSString *acct = item[(__bridge id)kSecAttrAccount] ?: @"-";
                NSString *ag = item[(__bridge id)kSecAttrAccessGroup] ?: @"-";
                [self log:@"  [%ld] svc=%@ acct=%@ group=%@", (long)i, svc, acct, ag];
                i++;
            }
        } else if (result) {
            CFRelease(result);
        }
    }
}

@end
