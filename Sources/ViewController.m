#import "ViewController.h"
#import <Security/Security.h>
#import <sys/utsname.h>

static NSString *const kTargetBundle = @"com.dfmc.dfpv.sapp";
static NSUInteger const kMaxDisplayLen = 200000;

@interface ViewController ()
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIScrollView *buttonScroll;
@property (nonatomic, strong) NSMutableString *buffer;
@property (nonatomic, strong) NSLock *bufLock;
@property (nonatomic, strong) NSString *root;
@property (nonatomic, strong) NSString *currentFile;
@property (nonatomic, assign) BOOL busy;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"文件读取器";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.buffer = [NSMutableString string];
    self.bufLock = [[NSLock alloc] init];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;

    UILabel *sl = [[UILabel alloc] init];
    sl.text = @"已启动";
    sl.font = [UIFont systemFontOfSize:12];
    sl.textAlignment = NSTextAlignmentCenter;
    sl.numberOfLines = 2;
    sl.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:sl];
    self.statusLabel = sl;

    UIScrollView *sv = [[UIScrollView alloc] init];
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
        [sv.heightAnchor constraintEqualToConstant:44],

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
    // 5 个按钮，横排
    NSArray *titles = @[
        @"① DK日志",
        @"② 密钥日志",
        @"③ 偏好设置",
        @"④ 定位容器",
        @"⑤ 全部"
    ];
    SEL actions[5] = {
        @selector(loadDKLog),
        @selector(loadKeyLog),
        @selector(loadPrefs),
        @selector(findContainer),
        @selector(loadAll)
    };

    CGFloat x = 4;
    for (NSInteger i = 0; i < 5; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitle:titles[i] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont boldSystemFontOfSize:13];
        b.tag = i;
        [b addTarget:self action:actions[i] forControlEvents:UIControlEventTouchUpInside];
        b.frame = CGRectMake(x, 4, 84, 36);
        b.layer.borderWidth = 1;
        b.layer.borderColor = [UIColor systemBlueColor].CGColor;
        b.layer.cornerRadius = 6;
        [self.buttonScroll addSubview:b];
        x += 88;
    }
    self.buttonScroll.contentSize = CGSizeMake(x, 44);
}

#pragma mark - 工具

- (void)say:(NSString *)s {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.text = s;
    });
}

- (void)setContent:(NSString *)s {
    [self.bufLock lock];
    [self.buffer setString:s ?: @""];
    [self.bufLock unlock];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *show = s ?: @"";
        if (show.length > kMaxDisplayLen) {
            show = [show substringToIndex:kMaxDisplayLen];
            show = [show stringByAppendingString:@"\n…(显示截断)"];
        }
        self.textView.text = show;
        [self.textView setContentOffset:CGPointMake(0, 0) animated:NO];
    });
}

- (void)copyAll {
    [self.bufLock lock];
    NSString *s = [self.buffer copy];
    [self.bufLock unlock];
    if (s.length == 0) {
        [self say:@"内容为空"];
        return;
    }
    @try {
        [UIPasteboard generalPasteboard].string = s;
        [self say:[NSString stringWithFormat:@"已复制 %lu 字符 · 发给我", (unsigned long)s.length]];
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

#pragma mark - 按钮动作

- (void)findContainer {
    if (self.busy) return;
    self.busy = YES;
    [self say:@"定位中…"];
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSString *r = [self targetRoot];
        NSMutableString *out = [NSMutableString string];
        [out appendFormat:@"target = %@\n", kTargetBundle];
        [out appendFormat:@"uid    = %d\n", getuid()];
        [out appendFormat:@"ios    = %@\n", [[UIDevice currentDevice] systemVersion]];
        [out appendFormat:@"model  = %@\n", [self machineModel]];
        [out appendFormat:@"home   = %@\n", NSHomeDirectory()];
        [out appendString:@"\n"];
        if (r) {
            [out appendFormat:@"✅ 容器: %@\n\n", r];
            [out appendString:@"关键路径:\n"];
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
                @"Library/PreferencePanes/IVCSBLEKey.plist"
            ];
            for (NSString *k in keys) {
                BOOL e = [[NSFileManager defaultManager]
                    fileExistsAtPath:[r stringByAppendingPathComponent:k]];
                [out appendFormat:@"  %@ %@\n", e ? @"✓" : @"✗", k];
            }
        } else {
            [out appendString:@"❌ 未找到容器\n"];
        }
        [self setContent:out];
        [self say:@"定位完成"];
        self.busy = NO;
    });
}

- (void)loadDKLog {
    [self loadFile:@"Documents/IngeekLogger/com.ingeek.dk.1.log" label:@"DK 日志"];
}

- (void)loadKeyLog {
    [self loadFile:@"Documents/VCKLog/com.ics.secureKeyKit.log1.log" label:@"密钥日志"];
}

- (void)loadPrefs {
    [self loadFile:@"Library/Preferences/com.dfmc.dfpv.sapp.plist" label:@"偏好设置"];
}

- (void)loadFile:(NSString *)rel label:(NSString *)label {
    if (self.busy) return;
    NSString *root = [self targetRoot];
    if (!root) {
        [self say:@"先点④定位"];
        return;
    }
    self.busy = YES;
    [self say:[NSString stringWithFormat:@"读取 %@…", label]];

    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSString *full = [root stringByAppendingPathComponent:rel];
        NSMutableString *out = [NSMutableString string];
        [out appendFormat:@"===== %@ =====\n", rel];

        NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:full error:NULL];
        if (!a) {
            [out appendString:@"❌ 文件不存在\n"];
            [self setContent:out];
            [self say:@"不存在"];
            self.busy = NO;
            return;
        }
        unsigned long long sz = [a[NSFileSize] unsignedLongLongValue];
        [out appendFormat:@"大小: %llu B\n\n", sz];

        NSData *d = [NSData dataWithContentsOfFile:full options:0 error:NULL];
        if (!d) {
            [out appendString:@"❌ 读取失败\n"];
            [self setContent:out];
            [self say:@"读取失败"];
            self.busy = NO;
            return;
        }

        NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        if (s) {
            [out appendString:s];
        } else {
            // 不是 UTF-8，输出可打印片段
            [out appendString:@"[非 UTF-8，提取可打印片段]\n\n"];
            const unsigned char *b = d.bytes;
            NSMutableString *cur = [NSMutableString string];
            NSUInteger maxOut = 150000;
            for (NSUInteger i = 0; i < d.length && out.length < maxOut; i++) {
                unsigned char c = b[i];
                if (c >= 32 && c < 127) {
                    [cur appendFormat:@"%c", c];
                } else if (c == '\n' || c == '\r') {
                    if (cur.length > 4) {
                        [out appendString:cur];
                        [out appendString:@"\n"];
                    }
                    [cur setString:@""];
                } else {
                    if (cur.length > 4) {
                        [out appendString:cur];
                        [out appendString:@"\n"];
                    }
                    [cur setString:@""];
                }
            }
            if (cur.length > 4) [out appendString:cur];
        }

        [self setContent:out];
        [self say:[NSString stringWithFormat:@"%@ · %lu 字符 · 点复制", label, (unsigned long)out.length]];
        self.busy = NO;
    });
}

- (void)loadAll {
    if (self.busy) return;
    NSString *root = [self targetRoot];
    if (!root) {
        [self say:@"先点④定位"];
        return;
    }
    self.busy = YES;
    [self say:@"读取全部关键文件…"];

    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSMutableString *out = [NSMutableString string];
        [out appendFormat:@"target=%@\nuid=%d\nios=%@\nmodel=%@\n\n",
            kTargetBundle, getuid(),
            [[UIDevice currentDevice] systemVersion], [self machineModel]];

        NSArray *files = @[
            @"Library/PreferencePanes/IVCSBLEKey.plist",
            @"Library/Preferences/IngeekIdentity.plist",
            @"Documents/IngeekLogger/com.ingeek.dk.1.log",
            @"Documents/VCKLog/com.ics.secureKeyKit.log1.log"
        ];

        for (NSString *rel in files) {
            [out appendFormat:@"\n\n########## %@ ##########\n", rel];
            NSString *full = [root stringByAppendingPathComponent:rel];
            NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:full error:NULL];
            if (!a) {
                [out appendString:@"(不存在)\n"];
                continue;
            }
            unsigned long long sz = [a[NSFileSize] unsignedLongLongValue];
            if (sz > 60000) {
                [out appendFormat:@"(跳过: %llu B 太大，请单独点按钮)\n", sz];
                continue;
            }
            NSData *d = [NSData dataWithContentsOfFile:full options:0 error:NULL];
            if (!d) { [out appendString:@"(读取失败)\n"]; continue; }
            NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
            if (s) {
                [out appendString:s];
            } else {
                [out appendFormat:@"(二进制 %llu B)\n", sz];
            }
            [self setContent:out];
        }

        [self setContent:out];
        [self say:[NSString stringWithFormat:@"共 %lu 字符 · 点复制", (unsigned long)out.length]];
        self.busy = NO;
    });
}

- (NSString *)machineModel {
    struct utsname si;
    uname(&si);
    return [NSString stringWithUTF8String:si.machine] ?: @"?";
}

@end

