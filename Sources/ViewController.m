#import "ViewController.h"
#import <Security/Security.h>
#import <sys/utsname.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *const kTargetBundle = @"com.dfmc.dfpv.sapp";
static NSUInteger const kMaxBufferLen = 400000;
static NSUInteger const kMaxDisplayLen = 12000;
static NSTimeInterval const kUIRefreshInterval = 0.25;

@interface ViewController ()
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UIButton *scanButton;
@property (nonatomic, strong) UIButton *clipboardBtn;
@property (nonatomic, strong) UIButton *dumpBtn;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) NSMutableString *buffer;
@property (nonatomic, strong) NSLock *bufLock;
@property (nonatomic, assign) NSTimeInterval lastUIUpdate;
@property (nonatomic, assign) BOOL uiDirty;
@property (nonatomic, assign) NSUInteger fileVisits;
@property (nonatomic, assign) BOOL aborted;
@end

@implementation ViewController

#pragma mark - UI

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"沙盒扫描";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.buffer = [NSMutableString string];
    self.bufLock = [[NSLock alloc] init];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;

    // 状态标签
    UILabel *sl = [[UILabel alloc] init];
    sl.text = @"已启动";
    sl.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    sl.textAlignment = NSTextAlignmentCenter;
    sl.numberOfLines = 2;
    sl.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:sl];
    self.statusLabel = sl;

    // 扫描按钮
    UIButton *scan = [UIButton buttonWithType:UIButtonTypeSystem];
    [scan setTitle:@"开始扫描" forState:UIControlStateNormal];
    scan.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    [scan addTarget:self action:@selector(runScan) forControlEvents:UIControlEventTouchUpInside];
    scan.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scan];
    self.scanButton = scan;

    // 文本区
    UITextView *tv = [[UITextView alloc] init];
    tv.font = [UIFont fontWithName:@"Menlo" size:10] ?: [UIFont systemFontOfSize:10];
    tv.editable = NO;
    tv.alwaysBounceVertical = YES;
    tv.layoutManager.allowsNonContiguousLayout = YES;
    tv.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:tv];
    self.textView = tv;

    // 底部两个按钮
    UIButton *copy = [UIButton buttonWithType:UIButtonTypeSystem];
    [copy setTitle:@"复制全部" forState:UIControlStateNormal];
    [copy addTarget:self action:@selector(copyAll) forControlEvents:UIControlEventTouchUpInside];
    copy.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:copy];
    self.clipboardBtn = copy;

    UIButton *save = [UIButton buttonWithType:UIButtonTypeSystem];
    [save setTitle:@"保存到文件" forState:UIControlStateNormal];
    [save addTarget:self action:@selector(exportFile) forControlEvents:UIControlEventTouchUpInside];
    save.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:save];
    self.dumpBtn = save;

    NSArray *constraints = @[
        [sl.topAnchor constraintEqualToAnchor:safe.topAnchor constant:6],
        [sl.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [sl.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],

        [scan.topAnchor constraintEqualToAnchor:sl.bottomAnchor constant:6],
        [scan.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [scan.heightAnchor constraintEqualToConstant:38],

        [tv.topAnchor constraintEqualToAnchor:scan.bottomAnchor constant:6],
        [tv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:4],
        [tv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-4],

        [copy.topAnchor constraintEqualToAnchor:tv.bottomAnchor constant:4],
        [copy.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [copy.heightAnchor constraintEqualToConstant:36],

        [save.topAnchor constraintEqualToAnchor:tv.bottomAnchor constant:4],
        [save.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],
        [save.heightAnchor constraintEqualToConstant:36],

        [copy.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-4],
        [save.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-4]
    ];
    [NSLayoutConstraint activateConstraints:constraints];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"清空" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(clearAll)];
}

#pragma mark - 按钮

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

    if (snap.length == 0) {
        self.statusLabel.text = @"内容为空，先扫描";
        return;
    }

    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    @try {
        pb.string = snap;
        if ([pb.string isEqualToString:snap]) {
            self.statusLabel.text = [NSString stringWithFormat:@"已复制 %lu 字符", (unsigned long)snap.length];
            return;
        }
    } @catch (NSException *e) { }

    NSUInteger cap = MIN(snap.length, (NSUInteger)80000);
    NSString *part = [snap substringToIndex:cap];
    @try {
        pb.string = part;
        self.statusLabel.text = [NSString stringWithFormat:@"太长，已复制前 %lu 字符（建议保存到文件）", (unsigned long)cap];
    } @catch (NSException *e) {
        self.statusLabel.text = @"复制失败，请用「保存到文件」";
    }
}

- (void)exportFile {
    [self.bufLock lock];
    NSString *snap = [self.buffer copy];
    [self.bufLock unlock];

    if (snap.length == 0) {
        self.statusLabel.text = @"内容为空，先扫描";
        return;
    }

    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"MMdd_HHmmss";
    NSString *name = [NSString stringWithFormat:@"scan_%@.txt", [df stringFromDate:[NSDate date]]];
    NSString *path = [dir stringByAppendingPathComponent:name];

    NSError *err = nil;
    BOOL ok = [snap writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&err];
    if (ok) {
        self.statusLabel.text = [NSString stringWithFormat:@"已保存 %@", name];
        NSString *msg = [NSString stringWithFormat:
            @"文件名：%@\n\n打开「文件」App → 我的 iPhone → 沙盒扫描 → %@\n\n完整路径：\n%@",
            name, name, path];
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"已保存"
                                                                   message:msg
                                                            preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil];
[ac addAction:okAction];
        [self presentViewController:ac animated:YES completion:nil];
    } else {
        self.statusLabel.text = [NSString stringWithFormat:@"保存失败：%@", err.localizedDescription];
    }
}

#pragma mark - 日志

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
        self.statusLabel.text = [NSString stringWithFormat:@"扫描中 · 已记 %lu 字符", (unsigned long)total];
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
    self.scanButton.enabled = NO;
    [self.bufLock lock];
    [self.buffer setString:@""];
    [self.bufLock unlock];
    self.textView.text = @"";

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __strong typeof(weakSelf) s2 = weakSelf;
        if (!s2) return;
        @try { [s2 scanAll]; }
        @catch (NSException *e) { [s2 log:@"!!! %@ - %@", e.name, e.reason]; }
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
            s3.scanButton.enabled = YES;
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
    [self log:@"========== 定位 =========="];
    NSString *root = [self findContainerDirect];
    if (root) {
        [self log:@"✅ 命中: %@", root];
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
        [self log:@"❌ 未定位到容器"];
    }

    [self log:@""];
    [self log:@"========== Keychain =========="];
    [self dumpKeychain];

    [self log:@""];
    [self log:@"========== 激活诊断 =========="];
    [self diagnoseActivation:root];

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
    return [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:&err] != nil;
}

- (BOOL)bumpVisit {
    self.fileVisits++;
    if (self.fileVisits > 30000) {
        if (!self.aborted) {
            self.aborted = YES;
            [self log:@"!!! 达到遍历上限，停止"];
        }
        return NO;
    }
    return !self.aborted;
}

- (NSString *)findContainerDirect {
    NSString *base = @"/var/mobile/Containers/Data/Application";
    NSError *err = nil;
    NSArray *dirs = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:base error:&err];
    if (!dirs) {
        [self log:@"  不可读: %@", err.localizedDescription];
        return nil;
    }
    [self log:@"  容器数 %lu", (unsigned long)dirs.count];

    for (NSString *d in dirs) {
        if (![self bumpVisit]) return nil;
        NSString *meta = [NSString stringWithFormat:@"%@/%@/.com.apple.mobile_container_manager.metadata.plist", base, d];
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:meta];
        NSString *ident = dict[@"MCMMetadataIdentifier"];
        if (ident && [ident isEqualToString:kTargetBundle]) {
            [self log:@"  [轮1 精确] %@", ident];
            return [NSString stringWithFormat:@"%@/%@", base, d];
        }
    }
    [self log:@"  轮1 未命中，转轮2"];

    for (NSString *d in dirs) {
        if (![self bumpVisit]) return nil;
        NSString *meta = [NSString stringWithFormat:@"%@/%@/.com.apple.mobile_container_manager.metadata.plist", base, d];
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:meta];
        NSString *ident = dict[@"MCMMetadataIdentifier"];
        if (ident && ([ident containsString:@"dfmc"] || [ident containsString:@"dfpv"] ||
                      [ident containsString:@"sapp"] || [ident containsString:@"slyan"])) {
            [self log:@"  [轮2 关键词] %@", ident];
            return [NSString stringWithFormat:@"%@/%@", base, d];
        }
    }
    [self log:@"  轮2 未命中，转轮3"];

    for (NSString *d in dirs) {
        if (![self bumpVisit]) return nil;
        NSString *p = [NSString stringWithFormat:@"%@/%@/Documents", base, d];
        NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:p error:NULL];
        if (!items) continue;
        for (NSString *it in items) {
            if ([it containsString:@"digitalkey"] || [it containsString:@"ingeek"] ||
                [it containsString:@"carkey"] || [it hasPrefix:@"c11_"] ||
                [it hasPrefix:@"icce"] || [it containsString:@"dk_"]) {
                [self log:@"  [轮3 特征] %@ 里有 %@", d, it];
                return [NSString stringWithFormat:@"%@/%@", base, d];
            }
        }
    }
    [self log:@"  轮3 未命中"];

    [self log:@"  容器清单（前40）:"];
    NSInteger i = 0;
    for (NSString *d in dirs) {
        NSString *meta = [NSString stringWithFormat:@"%@/%@/.com.apple.mobile_container_manager.metadata.plist", base, d];
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:meta];
        [self log:@"    %@", dict[@"MCMMetadataIdentifier"] ?: @"(no meta)"];
        if (++i >= 40) break;
    }
    return nil;
}

- (void)walk:(NSString *)path depth:(NSInteger)depth maxDepth:(NSInteger)maxDepth {
    if (depth > maxDepth || self.aborted) return;
    NSMutableString *indent = [NSMutableString string];
    for (NSInteger i = 0; i < depth; i++) [indent appendString:@"  "];
    NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:NULL];
    if (!items) { [self log:@"%@[不可读]", indent]; return; }

    NSInteger n = 0;
    NSInteger skipped = 0;
    for (NSString *name in [items sortedArrayUsingSelector:@selector(compare:)]) {
        if (![self bumpVisit]) return;
        NSString *lower = [name lowercaseString];
        BOOL isAsset = [lower hasSuffix:@".png"] || [lower hasSuffix:@".jpg"] ||
                       [lower hasSuffix:@".jpeg"] || [lower hasSuffix:@".gif"] ||
                       [lower hasSuffix:@".svg"] || [lower hasSuffix:@".pdf"] ||
                       [lower hasSuffix:@".ttf"] || [lower hasSuffix:@".otf"] ||
                       [lower hasSuffix:@".car"] || [lower hasSuffix:@".mp3"] ||
                       [lower hasSuffix:@".mp4"] || [lower hasSuffix:@".lottie"] ||
                       [lower hasSuffix:@".jsbundle"] || [lower hasSuffix:@".bundle"];
        if (isAsset) { skipped++; continue; }
        if (++n > 200) {
            [self log:@"%@…(超200项，已跳过资源 %ld 个)", indent, (long)skipped];
            return;
        }
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
    if (skipped > 0) {
        [self log:@"%@  (跳过 %ld 个资源文件)", indent, (long)skipped];
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
        if (self.aborted || ++i > 200) { [self log:@"…超200个，停"]; break; }
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
                id svcObj = it[(__bridge id)kSecAttrService];
                id acctObj = it[(__bridge id)kSecAttrAccount];
                NSString *svc = [svcObj isKindOfClass:[NSString class]] ? svcObj : @"-";
                NSString *acct = [acctObj isKindOfClass:[NSString class]] ? acctObj : [acctObj description];
                if (!acct) acct = @"-";
                [self log:@"   svc=%@ acct=%@", svc, acct];
            }
        } else if (r) {
            CFRelease(r);
        }
    }
}

- (void)diagnoseActivation:(NSString *)root {
    if (!root) { [self log:@"无容器路径"]; return; }
    NSFileManager *fm = [NSFileManager defaultManager];

    NSArray *keyPaths = @[
        @"Documents",
        @"Library",
        @"Documents/private",
        @"Documents/private/instance_ca_key.pem",
        @"Documents/certs",
        @"Documents/digitalkeys",
        @"Documents/csr",
        @"Documents/uap",
        @"Library/Preferences/com.dfmc.dfpv.sapp.plist"
    ];
    NSInteger exist = 0;
    for (NSString *rel in keyPaths) {
        NSString *p = [root stringByAppendingPathComponent:rel];
        BOOL e = [fm fileExistsAtPath:p];
        if (e && ![rel isEqualToString:@"Documents"] && ![rel isEqualToString:@"Library"]) exist++;
        [self log:@"%@ %@", e ? @"✓" : @"✗", rel];
    }

    [self log:@""];
    if (exist == 0) {
        [self log:@"⚠️ 结论：没有任何密钥材料"];
        [self log:@"   → 这个 App 从未激活过蓝牙钥匙"];
        [self log:@"   → 需要先激活（坐进车内 + 车辆通电）"];
    } else {
        [self log:@"✅ 结论：存在密钥相关数据（%ld 项）", (long)exist];
    }

    [self log:@""];
    [self log:@"容器顶层条目："];
    for (NSString *t in [fm contentsOfDirectoryAtPath:root error:NULL]) {
        [self log:@"  %@", t];
    }
}

@end


