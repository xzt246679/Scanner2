#import "ViewController.h"
#import <Security/Security.h>
#import <sys/utsname.h>
#import <zlib.h>

static NSString *const kTargetBundle = @"com.dfmc.dfpv.sapp";
static NSUInteger const kMaxBufferLen = 400000;
static NSUInteger const kMaxDisplayLen = 12000;
static NSTimeInterval const kUIRefreshInterval = 0.25;
static unsigned long long const kMaxSingleFile = 32ULL * 1024 * 1024;
static unsigned long long const kMaxTotalExport = 200ULL * 1024 * 1024;

#pragma mark - 最小 ZIP 写入器（store 模式，不压缩）

typedef struct {
    uint32_t sig;
    uint16_t ver, flags, method, mtime, mdate;
    uint32_t crc, csize, usize;
    uint16_t nlen, elen;
} ZipLocalHdr;

typedef struct {
    uint32_t sig;
    uint16_t vmade, vneed, flags, method, mtime, mdate;
    uint32_t crc, csize, usize;
    uint16_t nlen, elen, clen;
    uint16_t disk, iattr;
    uint32_t eattr, offset;
} ZipCentralHdr;

typedef struct {
    uint32_t sig;
    uint16_t disk, cddisk, nthis, ntotal;
    uint32_t cdsize, cdoff;
    uint16_t clen;
} ZipEndRec;

@interface SimpleZip : NSObject
@property (nonatomic, strong) NSMutableData *central;
@property (nonatomic, strong) NSFileHandle *fh;
@property (nonatomic, assign) unsigned long long offset;
@property (nonatomic, assign) NSInteger count;
@end

@implementation SimpleZip

- (instancetype)initWithPath:(NSString *)path {
    if ((self = [super init])) {
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        _fh = [NSFileHandle fileHandleForWritingAtPath:path];
        _central = [NSMutableData data];
        _offset = 0;
        _count = 0;
        if (!_fh) return nil;
    }
    return self;
}

- (BOOL)addFile:(NSString *)src name:(NSString *)name {
    NSData *data = [NSData dataWithContentsOfFile:src options:NSDataReadingMappedIfSafe error:NULL];
    if (!data) return NO;
    if (data.length > 0xFFFFFFFFULL) return NO;

    NSData *nameData = [name dataUsingEncoding:NSUTF8StringEncoding];
    uint32_t crc = (uint32_t)crc32(0L, data.bytes, (uInt)data.length);
    uint32_t sz = (uint32_t)data.length;

    ZipLocalHdr h = {0};
    h.sig = 0x04034b50;
    h.ver = 20;
    h.flags = 0x0800;      // UTF-8 文件名
    h.method = 0;          // store
    h.mtime = 0;
    h.mdate = 0x21;        // 1980-01-01 合法值
    h.crc = crc;
    h.csize = sz;
    h.usize = sz;
    h.nlen = (uint16_t)nameData.length;
    h.elen = 0;

    @try {
        [self.fh writeData:[NSData dataWithBytes:&h length:sizeof(h)]];
        [self.fh writeData:nameData];
        if (sz > 0) [self.fh writeData:data];
    } @catch (NSException *e) {
        return NO;
    }

    ZipCentralHdr c = {0};
    c.sig = 0x02014b50;
    c.vmade = 20;
    c.vneed = 20;
    c.flags = 0x0800;
    c.method = 0;
    c.mdate = 0x21;
    c.crc = crc;
    c.csize = sz;
    c.usize = sz;
    c.nlen = (uint16_t)nameData.length;
    c.offset = (uint32_t)self.offset;

    [self.central appendBytes:&c length:sizeof(c)];
    [self.central appendData:nameData];

    self.offset += sizeof(h) + nameData.length + sz;
    self.count++;
    return YES;
}

- (BOOL)finish {
    @try {
        unsigned long long cdOff = self.offset;
        [self.fh writeData:self.central];

        ZipEndRec e = {0};
        e.sig = 0x06054b50;
        e.nthis = (uint16_t)self.count;
        e.ntotal = (uint16_t)self.count;
        e.cdsize = (uint32_t)self.central.length;
        e.cdoff = (uint32_t)cdOff;
        [self.fh writeData:[NSData dataWithBytes:&e length:sizeof(e)]];
        [self.fh closeFile];
        return YES;
    } @catch (NSException *ex) {
        return NO;
    }
}

@end

#pragma mark - VC

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
    [exp setTitle:@"② 导出 ZIP" forState:UIControlStateNormal];
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
        @try {
            [s exportAllSafe];
        } @catch (NSException *e) {
            [s log:@"!!! 异常 %@ - %@", e.name, e.reason];
        }
        [s finishUI:[NSString stringWithFormat:@"完成 · %ld 文件", (long)s.exportedCount]];
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
    if ([l hasSuffix:@".png"] || [l hasSuffix:@".jpg"] || [l hasSuffix:@".jpeg"] ||
        [l hasSuffix:@".gif"] || [l hasSuffix:@".svg"] || [l hasSuffix:@".pdf"] ||
        [l hasSuffix:@".ttf"] || [l hasSuffix:@".otf"] || [l hasSuffix:@".car"] ||
        [l hasSuffix:@".mp3"] || [l hasSuffix:@".mp4"] || [l hasSuffix:@".lottie"] ||
        [l hasSuffix:@".ktx"] || [l hasSuffix:@".metallib"] || [l hasSuffix:@".jsbundle"] ||
        [l hasSuffix:@".so"] || [l hasSuffix:@".dylib"] || [l hasSuffix:@".nib"]) {
        return NO;
    }
    NSArray *allow = @[@".log", @".plist", @".sqlite", @".db", @".db3", @".p12", @".der",
                       @".pem", @".json", @".archiver", @".txt", @".xml", @".key",
                       @".cer", @".crt", @".manifest", @".data", @".c11", @".dk"];
    for (NSString *e in allow) {
        if ([l hasSuffix:e]) return YES;
    }
    if ([l hasSuffix:@"-wal"] || [l hasSuffix:@"-shm"]) return YES;
    return NO;
}

- (void)exportAllSafe {
    [self log:@"=== 阶段1: 定位容器 ==="];
    NSString *root = [self targetRoot];
    if (!root) {
        [self log:@"❌ 未找到目标容器"];
        return;
    }
    [self log:@"✅ %@", root];

    [self log:@""];
    [self log:@"=== 阶段2: 收集文件列表 ==="];
    NSMutableArray *files = [NSMutableArray array];   // 存相对路径
    @try {
        [self collectFiles:root base:root rel:@"" depth:0 maxDepth:6 into:files];
    } @catch (NSException *e) {
        [self log:@"收集异常: %@", e.reason];
    }
    [self log:@"收集到 %lu 个候选文件", (unsigned long)files.count];

    if (files.count == 0) {
        [self log:@"❌ 没有可导出文件"];
        return;
    }

    [self log:@""];
    [self log:@"=== 阶段3: 写 ZIP ==="];
    NSString *zipPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/export.zip"];
    [[NSFileManager defaultManager] removeItemAtPath:zipPath error:NULL];

    SimpleZip *z = [[SimpleZip alloc] initWithPath:zipPath];
    if (!z) {
        [self log:@"❌ 无法创建 zip 文件"];
        return;
    }

    NSInteger okCount = 0;
    NSInteger skipCount = 0;
    NSUInteger idx = 0;
    for (NSString *rel in files) {
        if (self.aborted) break;
        idx++;
        NSString *src = [root stringByAppendingPathComponent:rel];
        NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:src error:NULL];
        if (!a) { skipCount++; continue; }
        unsigned long long sz = [a[NSFileSize] unsignedLongLongValue];
        if (sz == 0 || sz > kMaxSingleFile) { skipCount++; continue; }
        if (self.exportedBytes + sz > kMaxTotalExport) {
            [self log:@"已达 200MB 上限"];
            break;
        }

        BOOL ok = NO;
        @try {
            ok = [z addFile:src name:rel];
        } @catch (NSException *e) {
            ok = NO;
        }

        if (ok) {
            okCount++;
            self.exportedBytes += sz;
            [self.exportLog addObject:[NSString stringWithFormat:@"%10llu  %@", sz, rel]];
            if (idx % 5 == 0 || sz > 100000) {
                [self log:@"✓ %@ (%llu B)", rel, sz];
            }
        } else {
            skipCount++;
        }
    }

    // 写入清单
    NSString *misc = [NSString stringWithFormat:
        @"target=%@\nuid=%d\nios=%@\nmodel=%@\nfiles=%ld\nbytes=%llu\n\n%@",
        kTargetBundle, getuid(),
        [[UIDevice currentDevice] systemVersion], [self machineModel],
        (long)okCount, self.exportedBytes,
        [self.exportLog componentsJoinedByString:@"\n"]];
    NSString *idxTmp = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/_index.txt"];
    [misc writeToFile:idxTmp atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    @try {
        [z addFile:idxTmp name:@"_index.txt"];
    } @catch (NSException *e) { }

    BOOL fin = NO;
    @try {
        fin = [z finish];
    } @catch (NSException *e) {
        fin = NO;
    }

    self.exportedCount = okCount;
    [self log:@""];
    [self log:@"=== 阶段4: 完成 ==="];
    [self log:@"写入 %ld 个文件，跳过 %ld 个", (long)okCount, (long)skipCount];
    [self log:@"总大小 %.2f MB", self.exportedBytes / 1048576.0];
    [self log:@"zip 结束: %@", fin ? @"成功" : @"失败"];

    NSDictionary *za = [[NSFileManager defaultManager] attributesOfItemAtPath:zipPath error:NULL];
    unsigned long long zsz = za ? [za[NSFileSize] unsignedLongLongValue] : 0;
    [self log:@"zip 文件: %.2f MB", zsz / 1048576.0];
    [self log:@"路径: %@", zipPath];

    if (zsz == 0) {
        [self log:@"❌ zip 为空"];
        return;
    }

    [self log:@""];
    [self log:@"=== 阶段5: 弹出分享 ==="];
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            [self shareFile:zipPath];
        } @catch (NSException *e) {
            self.statusLabel.text = [NSString stringWithFormat:@"分享异常: %@", e.reason];
        }
    });
}

- (void)collectFiles:(NSString *)path base:(NSString *)base rel:(NSString *)rel
               depth:(NSInteger)depth maxDepth:(NSInteger)maxDepth into:(NSMutableArray *)out {
    if (depth > maxDepth || self.aborted) return;
    if (++self.fileVisits > 20000) return;

    NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:NULL];
    if (!items) return;

    for (NSString *name in items) {
        NSString *full = [path stringByAppendingPathComponent:name];
        NSString *relFull = rel.length ? [rel stringByAppendingPathComponent:name] : name;

        BOOL isDir = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:full isDirectory:&isDir]) continue;

        if (isDir) {
            [self collectFiles:full base:base rel:relFull depth:depth + 1 maxDepth:maxDepth into:out];
        } else if ([self shouldExport:name]) {
            [out addObject:relFull];
        }
    }
}

- (void)shareFile:(NSString *)path {
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        self.statusLabel.text = @"zip 不存在";
        return;
    }
    NSURL *url = [NSURL fileURLWithPath:path];
    UIActivityViewController *avc =
        [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];

    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        avc.popoverPresentationController.sourceView = self.view;
        avc.popoverPresentationController.sourceRect =
            CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    }
    avc.completionWithItemsHandler = ^(UIActivityType t, BOOL done, NSArray *items, NSError *e) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.statusLabel.text = done ? @"已分享" : @"已取消（zip 仍在 Documents/）";
        });
    };
    [self presentViewController:avc animated:YES completion:nil];
}

#pragma mark - 扫描

- (void)scanAll {
    [self log:@"========== 环境 =========="];
    [self log:@"uid=%d euid=%d", getuid(), geteuid()];
    [self log:@"ios=%@ model=%@", [[UIDevice currentDevice] systemVersion], [self machineModel]];
    [self log:@"home=%@", NSHomeDirectory()];

    [self log:@""];
    [self log:@"========== 定位 =========="];
    NSString *root = [self targetRoot];
    if (!root) {
        [self log:@"❌ 未找到"];
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
        BOOL e = [[NSFileManager defaultManager] fileExistsAtPath:[root stringByAppendingPathComponent:k]];
        [self log:@"%@ %@", e ? @"✓" : @"✗", k];
    }

    [self log:@""];
    [self log:@"========== 日志大小 =========="];
    NSArray *logs = @[
        @"Documents/IngeekLogger/com.ingeek.dk.1.log",
        @"Documents/VCKLog/com.ics.secureKeyKit.log1.log",
        @"Documents/2026-11-22.log"
    ];
    for (NSString *l in logs) {
        NSDictionary *a = [[NSFileManager defaultManager]
            attributesOfItemAtPath:[root stringByAppendingPathComponent:l] error:NULL];
        [self log:@"  %@ : %@", l, a ? [NSString stringWithFormat:@"%llu B", [a[NSFileSize] unsignedLongLongValue]] : @"不存在"];
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
    [self log:@"下一步：点「② 导出 ZIP」"];
}

- (NSString *)machineModel {
    struct utsname si;
    uname(&si);
    return [NSString stringWithUTF8String:si.machine] ?: @"?";
}

@end
