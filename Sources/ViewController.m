#import "ViewController.h"
#import <Security/Security.h>
#import <sys/utsname.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *const kTargetBundle = @"com.dfmc.dfpv.sapp";
static NSUInteger const kMaxBufferLen = 400000;   // buffer 上限
static NSUInteger const kMaxDisplayLen = 12000;   // 界面只显示尾部
static NSTimeInterval const kUIRefreshInterval = 0.25;

@interface ViewController ()
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UIButton *button;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) NSMutableString *buffer;
@property (nonatomic, strong) NSLock *bufLock;
@property (nonatomic, assign) NSTimeInterval lastUIUpdate;
@property (nonatomic, assign) BOOL uiDirty;
@property (nonatomic, assign) NSUInteger fileVisits;
@property (nonatomic, assign) BOOL aborted;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"沙盒扫描";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.buffer = [NSMutableString string];
    self.bufLock = [[NSLock alloc] init];

    UILabel *sl = [[UILabel alloc] init];
    sl.text = @"已启动";
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
    tv.layoutManager.allowsNonContiguousLayout = YES;
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
    [self.bufLock lock];
    [self.buffer setString:@""];
    [self.bufLock unlock];
    self.textView.text = @"";
    self.statusLabel.text = @"已清空";
}

- (void)copyAll {
    [self.bufLock lock];
    NSString *snap = [self.buffer copy];
    [self.bufLock unlock];
    [UIPasteboard generalPasteboard].string = snap;
    self.statusLabel.text = [NSString stringWithFormat:@"已复制 %lu 字符", (unsigned long)snap.length];
}

// ========== 日志：只 append，节流刷新 UI ==========

- (void)logRaw:(NSString *)s {
    if (self.aborted) return;
    [self.bufLock lock];
    if (self.buffer.length < kMaxBufferLen) {
        [self.buffer appendString:s];
        [self.buffer appendString:@"\n"];
    }
    NSUInteger total = self.buffer.length;
    [self.bufLock unlock];

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - self.lastUIUpdate < kUIRefreshInterval) return;
    if (self.uiDirty) return;
    self.lastUIUpdate = now;
    self.uiDirty = YES;

    dispatch_async(dispatch_get_main_queue(), ^{
        self.uiDirty = NO;
        [self.bufLock lock];
        NSString *snap = [self.buffer copy];
        [self.bufLock unlock];
        if (snap.length > kMaxDisplayLen) {
            snap = [@"…(前面省略)…\n" stringByAppendingString:
                    [snap substringFromIndex:snap.length - kMaxDisplayLen]];
        }
        self.textView.text = snap;
        self.statusLabel.text = [NSString stringWithFormat:@"扫描中 · 已记录 %lu 字符", (unsigned long)total];
    });
}

- (void)log:(NSString *)fmt, ... {
    va_list args;
    va_start(args, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    [self logRaw:s];
}

- (void)runScan {
    self.aborted = NO;
    self.fileVisits = 0;
    self.statusLabel.text = @"扫描中…";
    self.button.enabled = NO;
    [self.bufLock lock];
    [self.buffer setString:@""];
    [self.bufLock unlock];
    self.textView.text = @"";

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __strong typeof(weakSelf) s2 = weakSelf;
        if (!s2) return;
        @try { [s2 scanAll]; }
        @catch (NSException *e) { [s2 log:@"!!! 异常 %@ - %@", e.name, e.reason]; }
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) s3 = weakSelf;
            if (!s3) return;
            s3.lastUIUpdate = 0;
            s3.uiDirty = NO;
            [s3.bufLock lock];
            NSString *snap = [s3.buffer copy];
            [s3.bufLock unlock];
            if (snap.length > kMaxDisplayLen) {
                snap = [@"…(前面省略)…\n" stringByAppendingString:
                        [snap substringFromIndex:snap.length - kMaxDisplayLen]];
            }
            s3.textView.text = snap;
            s3.button.enabled = YES;
            s3.statusLabel.text = [NSString stringWithFormat:@"完成 · %lu 字符", (unsigned long)snap.length];
        });
    });
}

#pragma mark - 主流程

- (void)scanAll {
    [self log:@"========== 环境 =========="];
    [self log:@"uid=%d euid=%d", getuid(), geteuid()];
    [self log:@"ios=%@ model=%@", [[UIDevice currentDevice] systemVersion], [self machineModel]];

    [self log:@""];
    [self log:@"========== 权限 =========="];
    NSArray *probes = @[
        @"/var/mobile/Containers/Data/Application",
        @"/var/containers/Bundle/Application",
        @"/var/mobile/Library"
    ];
    for (NSString *p in probes) {
        [self log:@"%@  %@", [self canRead:p] ? @"可读" : @"无权限", p];
    }

    [self log:@""];
    [self log:@"========== 定位目标 =========="];
    NSString *root = nil;

    // 方式A：直接列容器（最快）
    root = [self findContainerDirect];
    if (root) {
        [self log:@"[A 直接列容器] 成功"];
    } else {
        [self log:@"[A 直接列容器] 失败"];
        // 方式B：MCM 私有 API
        root = [self tryMCM];
        if (root) {
            [self log:@"[B MCM API] 成功"];
        } else {
            [self log:@"[B MCM API] 失败"];
            // 方式C：Bundle 反查
            root = [self tryBundleScan];
            if (root) {
                [self log:@"[C Bundle反查] 成功"];
            } else {
                [self log:@"[C Bundle反查] 失败"];
            }
        }
    }

    if (root) {
        [self log:@"路径: %@", root];
        [self log:@""];
        [self log:@"========== 目录树 =========="];
        [self walk:root depth:0 maxDepth:4];
        [self log:@""];
        [self log:@"========== 关键文件 =========="];
        [self scanKeyFiles:root];
        [self log:@""];
        [self log:@"========== 协议 =========="];
        [self detectProtocol:root];
    } else {
        [self log:@"全部方式失败，导出 Bundle 清单供诊断"];
        [self dumpBundleList];
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
    return a != nil;
}

- (BOOL)bumpVisit {
    self.fileVisits++;
    if (self.fileVisits > 30000) {
        if (!self.aborted) {
            self.aborted = YES;
            [self log:@"!!! 达到遍历上限 30000，已停止后续递归"];
        }
        return NO;
    }
    return !self.aborted;
}

// A：直接列容器目录
- (NSString *)findContainerDirect {
    NSString *base = @"/var/mobile/Containers/Data/Application";
    NSError *err = nil;
    NSArray *dirs = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:base error:&err];
    if (!dirs) {
        [self log:@"  目录不可读"];
        return nil;
    }
    [self log:@"  容器数 %lu", (unsigned long)dirs.count];
    for (NSString *d in dirs) {
        if (![self bumpVisit]) return nil;
        NSString *meta = [NSString stringWithFormat:@"%@/%@/.com.apple.mobile_container_manager.metadata.plist", base, d];
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:meta];
        NSString *ident = dict[@"MCMMetadataIdentifier"];
        if (ident && [ident isEqualToString:kTargetBundle]) {
            return [NSString stringWithFormat:@"%@/%@", base, d];
        }
    }
    [self log:@"  未命中 %@", kTargetBundle];
    return nil;
}

// B：MCM 私有 API（安全版：先检查 selector）
- (NSString *)tryMCM {
    void *h = dlopen("/System/Library/PrivateFrameworks/MobileContainerManager.framework/MobileContainerManager", RTLD_LAZY);
    if (!h) {
        [self log:@"  dlopen 失败"];
        return nil;
    }
    Class cls = NSClassFromString(@"MCMAppDataContainer");
    if (!cls) {
        [self log:@"  无 MCMAppDataContainer"];
        dlclose(h);
        return nil;
    }
    SEL sel = NSSelectorFromString(@"containerWithIdentifier:createIfNecessary:existed:error:");
    if (![cls respondsToSelector:sel]) {
        [self log:@"  无该 selector"];
        dlclose(h);
        return nil;
    }
    NSString *result = nil;
    @try {
        id (*fn)(id, SEL, NSString *, BOOL, BOOL *, NSError **) =
            (id (*)(id, SEL, NSString *, BOOL, BOOL *, NSError **))objc_msgSend;
        id c = fn(cls, sel, kTargetBundle, NO, NULL, NULL);
        if (c) {
            SEL psel = NSSelectorFromString(@"containerPath");
            if ([c respondsToSelector:psel]) {
                result = [c performSelector:psel];
            }
        }
    } @catch (NSException *e) {
        [self log:@"  异常 %@", e.reason];
    }
    dlclose(h);
    return result;
}

// C：Bundle 反查（限制数量）
- (NSString *)tryBundleScan {
    NSString *base = @"/var/containers/Bundle/Application";
    NSError *err = nil;
    NSArray *uuids = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:base error:&err];
    if (!uuids) {
        [self log:@"  Bundle 不可读"];
        return nil;
    }
    [self log:@"  Bundle 下 %lu 个 UUID", (unsigned long)uuids.count];
    NSUInteger checked = 0;
    for (NSString *u in uuids) {
        if (![self bumpVisit]) return nil;
        NSString *appDir = [NSString stringWithFormat:@"%@/%@", base, u];
        NSArray *apps = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:appDir error:NULL];
        for (NSString *app in apps) {
            if (![app hasSuffix:@".app"]) continue;
            checked++;
            if (checked > 500) {
                [self log:@"  已检查 500 个 App，停止"];
                return nil;
            }
            NSString *infoPlist = [NSString stringWithFormat:@"%@/%@/Info.plist", appDir, app];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPlist];
            NSString *bid = info[@"CFBundleIdentifier"];
            if ([bid isEqualToString:kTargetBundle]) {
                [self log:@"  命中 bundle: %@", app];
                NSString *guess = [NSString stringWithFormat:@"/var/mobile/Containers/Data/Application/%@", u];
                if ([self canRead:guess]) {
                    [self log:@"  Data UUID 相同"];
                    return guess;
                }
                [self log:@"  Data UUID 不同，返回 bundle 路径"];
                return [NSString stringWithFormat:@"%@/%@", appDir, app];
            }
        }
    }
    [self log:@"  已检查 %lu 个 App，未命中", (unsigned long)checked];
    return nil;
}

- (void)dumpBundleList {
    NSString *base = @"/var/containers/Bundle/Application";
    NSArray *uuids = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:base error:NULL];
    if (!uuids) { [self log:@"Bundle 不可读"]; return; }
    NSUInteger shown = 0;
    for (NSString *u in uuids) {
        if (![self bumpVisit]) return;
        NSString *appDir = [NSString stringWithFormat:@"%@/%@", base, u];
        NSArray *apps = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:appDir error:NULL];
        for (NSString *app in apps) {
            if (![app hasSuffix:@".app"]) continue;
            NSString *ip = [NSString stringWithFormat:@"%@/%@/Info.plist", appDir, app];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:ip];
            [self log:@"  %@", info[@"CFBundleIdentifier"] ?: @"?"];
            if (++shown >= 80) return;
        }
    }
}

- (void)walk:(NSString *)path depth:(NSInteger)depth maxDepth:(NSInteger)maxDepth {
    if (depth > maxDepth || self.aborted) return;
    NSMutableString *indent = [NSMutableString string];
    for (NSInteger i = 0; i < depth; i++) [indent appendString:@"  "];
    NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:NULL];
    if (!items) { [self log:@"%@[不可读]", indent]; return; }
    NSInteger n = 0;
    for (NSString *name in [items sortedArrayUsingSelector:@selector(compare:)]) {
        if (![self bumpVisit]) return;
        if (++n > 400) { [self log:@"%@…(超过400项，略)", indent]; return; }
        NSString *full = [path stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:full isDirectory:&isDir]) continue;
        if (isDir) {
            [self log:@"%@[D] %@/", indent, name];
            [self walk:full depth:depth + 1 maxDepth:maxDepth];
        } else {
            NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:full error:NULL];
            [self log:@"%@[F] %@ (%lluB)", indent, name, [attrs[NSFileSize] unsignedLongLongValue]];
        }
    }
}

- (void)scanKeyFiles:(NSString *)root {
    NSMutableArray *hits = [NSMutableArray array];
    [self collect:root depth:0 maxDepth:5
             exts:@[@".pem", @".der", @".json", @".plist", @".db", @".sqlite"]
             into:hits];
    [self log:@"候选 %lu 个", (unsigned long)hits.count];
    NSUInteger i = 0;
    for (NSString *f in hits) {
        if (self.aborted || ++i > 200) { [self log:@"…超过200个，停止"]; break; }
        NSString *rel = [f stringByReplacingOccurrencesOfString:root withString:@""];
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:f error:NULL];
        unsigned long long sz = [attrs[NSFileSize] unsignedLongLongValue];
        [self log:@""];
        [self log:@"---- %@ (%lluB) ----", rel, sz];
        if (sz == 0 || sz > 65536) { [self log:@"[跳过]"]; continue; }
        NSData *data = [NSData dataWithContentsOfFile:f];
        if (!data) { [self log:@"[读失败]"]; continue; }
        NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (s) {
            [self log:@"%@", [s substringToIndex:MIN((NSUInteger)1200, s.length)]];
        } else {
            NSMutableString *hex = [NSMutableString string];
            const unsigned char *b = data.bytes;
            for (NSUInteger k = 0; k < MIN((NSUInteger)32, data.length); k++)
                [hex appendFormat:@"%02x", b[k]];
            [self log:@"[bin] %@", hex];
        }
    }
}

- (void)collect:(NSString *)path depth:(NSInteger)depth maxDepth:(NSInteger)maxDepth
           exts:(NSArray *)exts into:(NSMutableArray *)out {
    if (depth > maxDepth || self.aborted) return;
    NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:NULL];
    if (!items) return;
    for (NSString *name in items) {
        if (![self bumpVisit]) return;
        NSString *full = [path stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:full isDirectory:&isDir]) continue;
        if (isDir) {
            [self collect:full depth:depth+1 maxDepth:maxDepth exts:exts into:out];
        } else {
            for (NSString *e in exts) {
                if ([name hasSuffix:e]) { [out addObject:full]; break; }
            }
        }
    }
}

- (void)detectProtocol:(NSString *)root {
    NSArray *cands = @[
        [root stringByAppendingPathComponent:@"Documents/digitalkeys"],
        [root stringByAppendingPathComponent:@"Documents"],
        [root stringByAppendingPathComponent:@"Library"]
    ];
    for (NSString *base in cands) {
        NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:base error:NULL];
        if (!items) continue;
        NSMutableArray *hit = [NSMutableArray array];
        for (NSString *n in items) {
            if ([n containsString:@"_dk_"] || [n hasPrefix:@"digital_key"]) [hit addObject:n];
        }
        if (!hit.count) continue;
        [self log:@"%@:", base];
        for (NSString *h in hit) [self log:@"   %@", h];
        NSMutableSet *p = [NSMutableSet set];
        for (NSString *h in hit) {
            if ([h hasPrefix:@"c11_dk_"]) [p addObject:@"COT/C11"];
            if ([h hasPrefix:@"icce10_dk_"]) [p addObject:@"ICCE10"];
            else if ([h hasPrefix:@"icce_dk_"]) [p addObject:@"ICCE"];
            if ([h hasPrefix:@"pki_dk_"]) [p addObject:@"PKI"];
            if ([h hasPrefix:@"tdk21_dk_"]) [p addObject:@"TDK21"];
            if ([h hasPrefix:@"legacy_dk_"]) [p addObject:@"Legacy"];
        }
        [self log:@"判定: %@", p.count ? [[p allObjects] componentsJoinedByString:@" / "] : @"未识别"];
    }
}

- (void)dumpKeychain {
    NSArray *classes = @[
        @[@"GenericPassword", (__bridge id)kSecClassGenericPassword],
        @[@"Key", (__bridge id)kSecClassKey],
    ];
    for (NSArray *pair in classes) {
        NSDictionary *q = @{
            (__bridge id)kSecClass: pair[1],
            (__bridge id)kSecReturnAttributes: @YES,
            (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll
        };
        CFTypeRef r = NULL;
        OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)q, &r);
        [self log:@"[%@] status=%d", pair[0], (int)st];
        if (st == errSecSuccess && r) {
            NSArray *arr = (__bridge_transfer NSArray *)r;
            [self log:@"  条目 %lu", (unsigned long)arr.count];
            NSInteger i = 0;
            for (NSDictionary *it in arr) {
                if (i++ >= 30) break;
                [self log:@"   svc=%@ acct=%@", it[(__bridge id)kSecAttrService] ?: @"-",
                       it[(__bridge id)kSecAttrAccount] ?: @"-"];
            }
        } else if (r) {
            CFRelease(r);
        }
    }
}

@end
