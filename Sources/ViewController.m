#import "ViewController.h"
#import <Security/Security.h>
#import <sys/utsname.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *const kTargetBundle = @"com.dfmc.dfpv.sapp";

// mobilecontainer 私有 API，用于拿到其他 App 的数据容器路径
typedef NSString *(*MCMAppDataContainerFromIdentifier)(NSString *identifier, NSError **error);

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
    self.buffer = [NSMutableString string];

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
        __strong typeof(weakSelf) s2 = weakSelf;
        if (!s2) return;
        s2.textView.text = s2.buffer;
        NSUInteger len = s2.buffer.length;
        if (len > 0) [s2.textView scrollRangeToVisible:NSMakeRange(len - 1, 1)];
    });
}

- (void)runScan {
    self.statusLabel.text = @"扫描中…";
    self.button.enabled = NO;
    [self.buffer setString:@""];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __strong typeof(weakSelf) s2 = weakSelf;
        if (!s2) return;
        @try { [s2 scanAll]; }
        @catch (NSException *e) { [s2 log:@"!!! %@ %@", e.name, e.reason]; }
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) s3 = weakSelf;
            if (!s3) return;
            s3.button.enabled = YES;
            s3.statusLabel.text = [NSString stringWithFormat:@"完成 · %lu 字符", (unsigned long)s3.buffer.length];
        });
    });
}

#pragma mark - 扫描

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
    [self log:@"========== 路径探测（5 种方式）=========="];

    // 方式1: MCMAppDataContainerFromIdentifier
    NSString *root = [self tryMCMAPI];
    if (root) {
        [self log:@"[方式1 MCM API] 成功: %@", root];
    } else {
        [self log:@"[方式1 MCM API] 失败"];

        // 方式2: LSApplicationWorkspace
        root = [self tryLSWorkspace];
        if (root) {
            [self log:@"[方式2 LSWorkspace] 成功: %@", root];
        } else {
            [self log:@"[方式2 LSWorkspace] 失败"];

            // 方式3: 遍历 Bundle 目录反查
            root = [self tryBundleScan];
            if (root) {
                [self log:@"[方式3 Bundle扫描] 成功: %@", root];
            } else {
                [self log:@"[方式3 Bundle扫描] 失败"];

                // 方式4: 从 /var/mobile/Library 找
                root = [self tryLibraryScan];
                if (root) {
                    [self log:@"[方式4 Library扫描] 成功: %@", root];
                } else {
                    [self log:@"[方式4 Library扫描] 失败"];
                }
            }
        }
    }

    [self log:@""];
    if (root) {
        [self log:@"========== 目录树 =========="];
        [self walk:root depth:0 maxDepth:4];
        [self log:@""];
        [self log:@"========== 关键文件 =========="];
        [self scanKeyFiles:root];
        [self log:@""];
        [self log:@"========== 协议 =========="];
        [self detectProtocol:root];
    } else {
        [self log:@"所有路径探测均失败"];
        [self log:@""];
        [self log:@"========== 诊断：Bundle 目录内容 =========="];
        [self dumpBundleDir];
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

// ============ 方式1：私有 framework MCM ============
- (NSString *)tryMCMAPI {
    void *h = dlopen("/System/Library/PrivateFrameworks/MobileContainerManager.framework/MobileContainerManager", RTLD_LAZY);
    if (!h) {
        [self log:@"  dlopen MobileContainerManager 失败: %s", dlerror()];
        return nil;
    }
    Class MCMAppContainer = NSClassFromString(@"MCMAppDataContainer");
    if (!MCMAppContainer) {
        [self log:@"  找不到 MCMAppDataContainer 类"];
        dlclose(h);
        return nil;
    }
    @try {
        id container = [MCMAppContainer performSelector:NSSelectorFromString(@"containerWithIdentifier:createIfNecessary:existed:error:")
                                            withObject:kTargetBundle
                                            withObject:@NO];
        (void)container;
        SEL sel = NSSelectorFromString(@"containerWithIdentifier:createIfNecessary:existed:error:");
        if ([MCMAppContainer respondsToSelector:sel]) {
            id c = ((id (*)(id, SEL, NSString *, BOOL, BOOL *, NSError **))objc_msgSend)(
                MCMAppContainer, sel, kTargetBundle, NO, NULL, NULL);
            if (c) {
                NSString *p = [c performSelector:NSSelectorFromString(@"containerPath")];
                if (p) { dlclose(h); return p; }
            }
        }
    } @catch (NSException *e) {
        [self log:@"  MCM 异常: %@", e.reason];
    }
    dlclose(h);
    return nil;
}

// ============ 方式2：LSApplicationWorkspace ============
- (NSString *)tryLSWorkspace {
    void *h = dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY);
    if (!h) h = dlopen("/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY);
    @try {
        Class WS = NSClassFromString(@"LSApplicationWorkspace");
        if (!WS) { [self log:@"  找不到 LSApplicationWorkspace"]; return nil; }
        id ws = [WS performSelector:NSSelectorFromString(@"defaultWorkspace")];
        if (!ws) { [self log:@"  defaultWorkspace 为 nil"]; return nil; }
        id proxy = [ws performSelector:NSSelectorFromString(@"applicationProxyForIdentifier:")
                            withObject:kTargetBundle];
        if (!proxy) { [self log:@"  applicationProxy 为 nil"]; return nil; }
        NSString *dataPath = [proxy performSelector:NSSelectorFromString(@"dataContainerURL")];
        if ([dataPath isKindOfClass:[NSURL class]]) {
            dataPath = [(NSURL *)dataPath path];
        }
        if (dataPath) return dataPath;
        NSString *bundlePath = [proxy performSelector:NSSelectorFromString(@"bundleURL")];
        [self log:@"  dataContainerURL 为 nil, bundleURL=%@", bundlePath];
    } @catch (NSException *e) {
        [self log:@"  LS 异常: %@", e.reason];
    }
    return nil;
}

// ============ 方式3：Bundle 目录反查 ============
- (NSString *)tryBundleScan {
    NSString *base = @"/var/containers/Bundle/Application";
    NSError *err = nil;
    NSArray *uuids = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:base error:&err];
    if (!uuids) {
        [self log:@"  Bundle 目录不可读"];
        return nil;
    }
    [self log:@"  Bundle 下 %lu 个 UUID", (unsigned long)uuids.count];
    for (NSString *u in uuids) {
        NSString *appDir = [NSString stringWithFormat:@"%@/%@", base, u];
        NSArray *apps = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:appDir error:NULL];
        for (NSString *app in apps) {
            if (![app hasSuffix:@".app"]) continue;
            NSString *infoPlist = [NSString stringWithFormat:@"%@/%@/Info.plist", appDir, app];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPlist];
            NSString *bid = info[@"CFBundleIdentifier"];
            if ([bid isEqualToString:kTargetBundle]) {
                [self log:@"  找到 bundle: %@/%@", u, app];
                // 尝试用同一个 UUID 找 Data 容器
                NSString *guess = [NSString stringWithFormat:@"/var/mobile/Containers/Data/Application/%@", u];
                if ([self canRead:guess]) {
                    [self log:@"  Data 容器 UUID 相同: %@", guess];
                    return guess;
                }
                [self log:@"  Data 容器 UUID 不同或不可读"];
                // 退一步：用 bundle 路径
                return appDir;
            }
        }
    }
    return nil;
}

// ============ 方式4：从 Library 找 ============
- (NSString *)tryLibraryScan {
    NSArray *dirs = @[
        @"/var/mobile/Library/Preferences",
        @"/var/mobile/Library/Caches",
        @"/var/mobile/Library/SplashBoard/Snapshots",
        @"/var/mobile/Library/FrontBoard/applicationPlaceholder"
    ];
    for (NSString *d in dirs) {
        NSError *err = nil;
        NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:d error:&err];
        if (!items) continue;
        for (NSString *it in items) {
            if ([it containsString:@"dfmc"] || [it containsString:@"dfpv"]) {
                [self log:@"  %@ 下找到: %@", d, it];
            }
        }
    }
    return nil;
}

- (void)dumpBundleDir {
    NSString *base = @"/var/containers/Bundle/Application";
    NSError *err = nil;
    NSArray *uuids = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:base error:&err];
    if (!uuids) {
        [self log:@"Bundle 目录不可读: %@", err.localizedDescription];
        return;
    }
    [self log:@"Bundle 下 %lu 项：", (unsigned long)uuids.count];
    NSInteger shown = 0;
    for (NSString *u in uuids) {
        NSString *appDir = [NSString stringWithFormat:@"%@/%@", base, u];
        NSArray *apps = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:appDir error:NULL];
        for (NSString *app in apps) {
            if (![app hasSuffix:@".app"]) continue;
            NSString *infoPlist = [NSString stringWithFormat:@"%@/%@/Info.plist", appDir, app];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPlist];
            NSString *bid = info[@"CFBundleIdentifier"] ?: @"?";
            [self log:@"  %@  (%@)", bid, u];
            shown++;
            if (shown >= 60) return;
        }
    }
}

- (void)walk:(NSString *)path depth:(NSInteger)depth maxDepth:(NSInteger)maxDepth {
    if (depth > maxDepth) return;
    NSMutableString *indent = [NSMutableString string];
    for (NSInteger i = 0; i < depth; i++) [indent appendString:@"  "];
    NSError *err = nil;
    NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:&err];
    if (!items) { [self log:@"%@[不可读]", indent]; return; }
    for (NSString *name in [items sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *full = [path stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:full isDirectory:&isDir]) continue;
        if (isDir) {
            [self log:@"%@[D] %@/", indent, name];
            [self walk:full depth:depth + 1 maxDepth:maxDepth];
        } else {
            NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:full error:NULL];
            [self log:@"%@[F] %@  (%llu B)", indent, name, [attrs[NSFileSize] unsignedLongLongValue]];
        }
    }
}

- (void)scanKeyFiles:(NSString *)root {
    NSMutableArray *hits = [NSMutableArray array];
    [self collect:root depth:0 maxDepth:6
             exts:@[@".pem", @".der", @".json", @".plist", @".db", @".sqlite"]
             into:hits];
    [self log:@"候选 %lu 个", (unsigned long)hits.count];
    for (NSString *f in hits) {
        NSString *rel = [f stringByReplacingOccurrencesOfString:root withString:@""];
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:f error:NULL];
        unsigned long long sz = [attrs[NSFileSize] unsignedLongLongValue];
        [self log:@""];
        [self log:@"---- %@  (%llu B) ----", rel, sz];
        if (sz == 0 || sz > 65536) { [self log:@"[跳过]"]; continue; }
        NSData *data = [NSData dataWithContentsOfFile:f];
        if (!data) { [self log:@"[读失败]"]; continue; }
        NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (s) {
            [self log:@"%@", [s substringToIndex:MIN((NSUInteger)1500, s.length)]];
        } else {
            NSMutableString *hex = [NSMutableString string];
            const unsigned char *b = data.bytes;
            for (NSUInteger i = 0; i < MIN((NSUInteger)40, data.length); i++)
                [hex appendFormat:@"%02x", b[i]];
            [self log:@"[bin] %@", hex];
        }
    }
}

- (void)collect:(NSString *)path depth:(NSInteger)depth maxDepth:(NSInteger)maxDepth
           exts:(NSArray *)exts into:(NSMutableArray *)out {
    if (depth > maxDepth) return;
    NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:NULL];
    if (!items) return;
    for (NSString *name in items) {
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
        NSMutableSet *protos = [NSMutableSet set];
        for (NSString *h in hit) {
            if ([h hasPrefix:@"c11_dk_"]) [protos addObject:@"COT/C11"];
            if ([h hasPrefix:@"icce10_dk_"]) [protos addObject:@"ICCE10"];
            else if ([h hasPrefix:@"icce_dk_"]) [protos addObject:@"ICCE"];
            if ([h hasPrefix:@"pki_dk_"]) [protos addObject:@"PKI"];
            if ([h hasPrefix:@"tdk21_dk_"]) [protos addObject:@"TDK21"];
            if ([h hasPrefix:@"legacy_dk_"]) [protos addObject:@"Legacy"];
        }
        [self log:@"判定: %@", protos.count ? [[protos allObjects] componentsJoinedByString:@" / "] : @"未识别"];
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
        CFTypeRef result = NULL;
        OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)q, &result);
        [self log:@"[%@] status=%d", pair[0], (int)st];
        if (st == errSecSuccess && result) {
            NSArray *arr = (__bridge_transfer NSArray *)result;
            [self log:@"  条目 %lu", (unsigned long)arr.count];
            for (NSDictionary *it in arr) {
                [self log:@"   svc=%@ acct=%@", it[(__bridge id)kSecAttrService] ?: @"-",
                       it[(__bridge id)kSecAttrAccount] ?: @"-"];
            }
        } else if (result) {
            CFRelease(result);
        }
    }
}

@end
