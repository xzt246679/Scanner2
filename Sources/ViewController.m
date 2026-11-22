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

// 导出限制
static unsigned long long const kMaxSingleFile = 32ULL * 1024 * 1024;   // 单文件 32MB
static unsigned long long const kMaxTotalExport = 200ULL * 1024 * 1024; // 总计 200MB

@interface ViewController ()
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UIButton *scanButton;
@property (nonatomic, strong) UIButton *exportButton;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) NSMutableString *buffer;
@property (nonatomic, strong) NSLock *bufLock;
@property (nonatomic, assign) NSTimeInterval lastUIUpdate;
@property (nonatomic, assign) BOOL uiDirty;
@property (nonatomic, assign) NSUInteger fileVisits;
@property (nonatomic, assign) BOOL aborted;
@property (nonatomic, assign) unsigned long long exportedBytes;
@property (nonatomic, assign) NSInteger exportedCount;
@property (nonatomic, strong) NSMutableArray *exportLog;
@end

@implementation ViewController

#pragma mark - UI

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"沙盒扫描";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.buffer = [NSMutableString string];
    self.bufLock = [[NSLock alloc] init];
    self.exportLog = [NSMutableArray array];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;

    UILabel *sl = [[UILabel alloc] init];
    sl.text = @"已启动";
    sl.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    sl.textAlignment = NSTextAlignmentCenter;
    sl.numberOfLines = 2;
    sl.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:sl];
    self.statusLabel = sl;

    UIButton *scan = [UIButton buttonWithType:UIButtonTypeSystem];
    [scan setTitle:@"① 扫描" forState:UIControlStateNormal];
    scan.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [scan addTarget:self action:@selector(runScan) forControlEvents:UIControlEventTouchUpInside];
    scan.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scan];
    self.scanButton = scan;

    UIButton *exp = [UIButton buttonWithType:UIButtonTypeSystem];
    [exp setTitle:@"② 导出文件" forState:UIControlStateNormal];
    exp.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [exp addTarget:self action:@selector(runExport) forControlEvents:UIControlEventTouchUpInside];
    exp.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:exp];
    self.exportButton = exp;

    UITextView *tv = [[UITextView alloc] init];
    tv.font = [UIFont fontWithName:@"Menlo" size:10] ?: [UIFont systemFontOfSize:10];
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

        [scan.topAnchor constraintEqualToAnchor:sl.bottomAnchor constant:6],
        [scan.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [scan.heightAnchor constraintEqualToConstant:40],

        [exp.topAnchor constraintEqualToAnchor:sl.bottomAnchor constant:6],
        [exp.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [exp.heightAnchor constraintEqualToConstant:40],

        [tv.topAnchor constraintEqualToAnchor:scan.bottomAnchor constant:6],
        [tv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:4],
        [tv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-4],
        [tv.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-4]
    ];
    [NSLayoutConstraint activateConstraints:c];

    self.navigationItem.rightBarButtonItem =
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
            snap = [@"…(前略)…\n" stringByAppendingString:
                    [snap substringFromIndex:snap.length - kMaxDisplayLen]];
        }
        self.textView.text = snap;
        self.statusLabel.text = [NSString stringWithFormat:@"运行中 · %lu 字符", (unsigned long)total];
    });
}

- (void)log:(NSString *)fmt, ... {
    va_list args;
    va_start(args, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    [self logRaw:s];
}

- (void)finishUI:(NSString *)msg {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.lastUIUpdate = 0;
        self.uiDirty = NO;
        [self.bufLock lock];
        NSString *snap = [self.buffer copy];
        [self.bufLock unlock];
        if (snap.length > kMaxDisplayLen) {
            snap = [@"…(前略)…\n" stringByAppendingString:
                    [snap substringFromIndex:snap.length - kMaxDisplayLen]];
        }
        self.textView.text = snap;
        self.scanButton.enabled = YES;
        self.exportButton.enabled = YES;
        self.statusLabel.text = msg;
    });
}

#pragma mark - 动作

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
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        @try { [s scanAll]; }
        @catch (NSException *e) { [s log:@"!!! %@ - %@", e.name, e.reason]; }
        [s finishUI:@"扫描完成"];
    });
}

- (void)runExport {
    self.aborted = NO;
    self.fileVisits = 0;
    self.exportedBytes = 0;
    self.exportedCount = 0;
    [self.exportLog removeAllObjects];
    self.statusLabel.text = @"导出中…";
    self.scanButton.enabled = NO;
    self.exportButton.enabled = NO;
    [self.bufLock lock];
    [self.buffer setString:@""];
    [self.bufLock unlock];
    self.textView.text = @"";

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        @try { [s exportAll]; }
        @catch (NSException *e) { [s log:@"!!! %@ - %@", e.name, e.reason]; }
        NSString *msg = [NSString stringWithFormat:@"导出 %ld 个文件 / %.1f MB",
                         (long)s.exportedCount, s.exportedBytes / 1048576.0];
        [s finishUI:msg];
    });
}

#pragma mark - 导出

- (NSString *)targetRoot {
    NSString *base = @"/var/mobile/Containers/Data/Application";
    NSArray *dirs = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:base error:NULL];
    for (NSString *d in dirs) {
        NSString *meta = [NSString stringWithFormat:@"%@/%@/.com.apple.mobile_container_manager.metadata.plist", base, d];
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:meta];
        if ([dict[@"MCMMetadataIdentifier"] isEqualToString:kTargetBundle]) {
            return [NSString stringWithFormat:@"%@/%@", base, d];
        }
    }
    return nil;
}

- (BOOL)shouldExport:(NSString *)name {
    NSString *l = [name lowercaseString];
    // 排除资源
    if ([l hasSuffix:@".png"] || [l hasSuffix:@".jpg"] || [l hasSuffix:@".jpeg"] ||
        [l hasSuffix:@".gif"] || [l hasSuffix:@".svg"] || [l hasSuffix:@".pdf"] ||
        [l hasSuffix:@".ttf"] || [l hasSuffix:@".otf"] || [l hasSuffix:@".car"] ||
        [l hasSuffix:@".mp3"] || [l hasSuffix:@".mp4"] || [l hasSuffix:@".lottie"] ||
        [l hasSuffix:@".ktx"] || [l hasSuffix:@".metallib"] || [l hasSuffix:@".jsbundle"]) {
        return NO;
    }
    // 包含这些扩展：日志/配置/数据库/证书/归档
    NSArray *allow = @[@".log", @".plist", @".sqlite", @".db", @".db3", @".p12", @".der",
                       @".pem", @".json", @".archiver", @".txt", @".xml", @".key",
                       @".cer", @".crt", @".-wal", @".-shm", @".manifest", @".data"];
    for (NSString *e in allow) {
        if ([l hasSuffix:e]) return YES;
    }
    // wal/shm 特判
    if ([l hasSuffix:@"-wal"] || [l hasSuffix:@"-shm"]) return YES;
    return NO;
}

- (void)exportAll {
    NSString *root = [self targetRoot];
    if (!root) {
        [self log:@"❌ 未找到目标容器"];
        return;
    }
    [self log:@"目标: %@", root];
    [self log:@"App 沙盒: %@", NSHomeDirectory()];

    NSString *destRoot = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/export"];
    NSFileManager *fm = [NSFileManager defaultManager];

    if ([fm fileExistsAtPath:destRoot]) {
        [fm removeItemAtPath:destRoot error:NULL];
    }
    [fm createDirectoryAtPath:destRoot withIntermediateDirectories:YES attributes:nil error:NULL];

    [self log:@"输出: %@", destRoot];
    [self log:@""];

    [self copyTree:root dest:destRoot rel:@"" depth:0 maxDepth:6];

    [self log:@""];
    [self log:@"========== 导出完成 =========="];
    [self log:@"文件数: %ld", (long)self.exportedCount];
    [self log:@"总大小: %.2f MB", self.exportedBytes / 1048576.0];

    // 写清单
    NSString *idx = [destRoot stringByAppendingPathComponent:@"_index.txt"];
    NSString *misc = [NSString stringWithFormat:
        @"target=%s\nuid=%d\nios=%@\nmodel=%@\nfiles=%ld\nbytes=%llu\n\n%@",
        kTargetBundle.UTF8String, getuid(),
        [[UIDevice currentDevice] systemVersion], [self machineModel],
        (long)self.exportedCount, self.exportedBytes,
        [self.exportLog componentsJoinedByString:@"\n"]];
    [misc writeToFile:idx atomically:YES encoding:NSUTF8StringEncoding error:NULL];

    [self log:@""];
    [self log:@"正在打包 zip…"];
    NSString *zipPath = [self makeZipFrom:destRoot];
    if (zipPath) {
        NSDictionary *za = [fm attributesOfItemAtPath:zipPath error:NULL];
        unsigned long long zsz = [za[NSFileSize] unsignedLongLongValue];
        [self log:@"✅ zip: %@ (%.2f MB)", [zipPath lastPathComponent], zsz / 1048576.0];
        [self log:@""];
        [self log:@"即将弹出分享菜单 → 选「微信」发给文件传输助手"];

        dispatch_async(dispatch_get_main_queue(), ^{
            [self shareFile:zipPath];
        });
    } else {
        [self log:@"❌ zip 打包失败"];
        [self log:@"改为：打开「文件」App → 我的 iPhone → 沙盒扫描 → export"];
    }
}

- (NSString *)makeZipFrom:(NSString *)dir {
    NSURL *dirURL = [NSURL fileURLWithPath:dir];
    NSFileCoordinator *coord = [[NSFileCoordinator alloc] init];
    NSError *err = nil;
    __block BOOL ok = NO;
    NSString *dst = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/export.zip"];
    [[NSFileManager defaultManager] removeItemAtPath:dst error:NULL];

    [coord coordinateReadingItemAtURL:dirURL
                              options:NSFileCoordinatorReadingForUploading
                                error:&err
                           byAccessor:^(NSURL *newURL) {
        NSError *e2 = nil;
        ok = [[NSFileManager defaultManager] copyItemAtURL:newURL
                                                     toURL:[NSURL fileURLWithPath:dst]
                                                     error:&e2];
        if (!ok) {
            [self log:@"copy zip 失败: %@", e2.localizedDescription];
        }
    }];

    if (err) {
        [self log:@"coordinator 错误: %@", err.localizedDescription];
    }
    return ok ? dst : nil;
}

- (void)shareFile:(NSString *)path {
    NSURL *url = [NSURL fileURLWithPath:path];
    UIActivityViewController *avc =
        [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];

    // iPad 需要 popover
    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) {
        avc.popoverPresentationController.sourceView = self.view;
        avc.popoverPresentationController.sourceRect =
            CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    }
    avc.completionWithItemsHandler = ^(UIActivityType t, BOOL done, NSArray *items, NSError *e) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (done) {
                self.statusLabel.text = @"已分享";
            } else {
                self.statusLabel.text = @"已取消分享（文件仍在 Documents/export.zip）";
            }
        });
    };
    [self presentViewController:avc animated:YES completion:nil];
}

- (void)copyTree:(NSString *)src dest:(NSString *)dest rel:(NSString *)rel
           depth:(NSInteger)depth maxDepth:(NSInteger)maxDepth {
    if (depth > maxDepth || self.aborted) return;
    if (self.exportedBytes > kMaxTotalExport) {
        if (!self.aborted) {
            [self log:@"!!! 已达 200MB 上限，停止"];
        }
        return;
    }

    NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:src error:NULL];
    if (!items) {
        [self log:@"[不可读] %@", rel];
        return;
    }

    for (NSString *name in items) {
        if (self.aborted) return;
        if (++self.fileVisits > 20000) {
            [self log:@"!!! 遍历上限"];
            return;
        }
        NSString *srcFull = [src stringByAppendingPathComponent:name];
        NSString *relFull = rel.length ? [rel stringByAppendingPathComponent:name] : name;

        BOOL isDir = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:srcFull isDirectory:&isDir]) continue;

        if (isDir) {
            [self copyTree:srcFull dest:dest rel:relFull depth:depth + 1 maxDepth:maxDepth];
            continue;
        }

        if (![self shouldExport:name]) continue;

        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:srcFull error:NULL];
        unsigned long long sz = [attrs[NSFileSize] unsignedLongLongValue];
        if (sz == 0 || sz > kMaxSingleFile) {
            [self log:@"[跳过 %@] %llu B", relFull, sz];
            continue;
        }

        NSString *destFull = [dest stringByAppendingPathComponent:relFull];
        NSString *destDir = [destFull stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:destDir
                                  withIntermediateDirectories:YES attributes:nil error:NULL];

        NSError *err = nil;
        BOOL ok = [[NSFileManager defaultManager] copyItemAtPath:srcFull toPath:destFull error:&err];
        if (ok) {
            self.exportedCount++;
            self.exportedBytes += sz;
            [self.exportLog addObject:[NSString stringWithFormat:@"%10llu  %@", sz, relFull]];
            [self log:@"✓ %@ (%llu B)", relFull, sz];
        } else {
            [self log:@"✗ %@ : %@", relFull, err.localizedDescription];
        }
    }
}

#pragma mark - 扫描（保留）

- (void)scanAll {
    [self log:@"========== 环境 =========="];
    [self log:@"uid=%d euid=%d", getuid(), geteuid()];
    [self log:@"ios=%@ model=%@", [[UIDevice currentDevice] systemVersion], [self machineModel]];

    [self log:@""];
    [self log:@"========== 定位 =========="];
    NSString *root = [self targetRoot];
    if (!root) {
        [self log:@"❌ 未找到 %@", kTargetBundle];
        return;
    }
    [self log:@"✅ %@", root];

    [self log:@""];
    [self log:@"========== 关键路径 =========="];
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
        @"Documents/IngeekCaches",
        @"Documents/ICSCaches",
        @"Library/PreferencePanes/IVCSBLEKey.plist",
        @"Library/Preferences/IngeekIdentity.plist",
        @"Library/Preferences/com.dfmc.dfpv.sapp.plist"
    ];
    for (NSString *k in keys) {
        NSString *p = [root stringByAppendingPathComponent:k];
        BOOL e = [[NSFileManager defaultManager] fileExistsAtPath:p];
        [self log:@"%@ %@", e ? @"✓" : @"✗", k];
    }

    [self log:@""];
    [self log:@"========== 日志文件大小 =========="];
    NSArray *logs = @[
        @"Documents/IngeekLogger/com.ingeek.dk.1.log",
        @"Documents/VCKLog/com.ics.secureKeyKit.log1.log",
        @"Documents/IVCS/IVCS-2026-11-22.log",
        @"Documents/2026-11-22.log"
    ];
    for (NSString *l in logs) {
        NSString *p = [root stringByAppendingPathComponent:l];
        NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:NULL];
        if (a) {
            [self log:@"  %@ : %llu B", l, [a[NSFileSize] unsignedLongLongValue]];
        } else {
            [self log:@"  %@ : 不存在", l];
        }
    }

    [self log:@""];
    [self log:@"========== Keychain =========="];
    NSDictionary *q = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecReturnAttributes: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll
    };
    CFTypeRef r = NULL;
    OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)q, &r);
    [self log:@"status=%d", (int)st];
    if (st == errSecSuccess && r) {
        NSArray *arr = (__bridge_transfer NSArray *)r;
        for (NSDictionary *it in arr) {
            [self log:@"  svc=%@", it[(__bridge id)kSecAttrService] ?: @"-"];
        }
    } else if (r) {
        CFRelease(r);
    }

    [self log:@""];
    [self log:@"========== 完成 =========="];
    [self log:@"下一步：点「② 导出文件」"];
}

- (NSString *)machineModel {
    struct utsname si;
    uname(&si);
    return [NSString stringWithUTF8String:si.machine] ?: @"?";
}

@end
