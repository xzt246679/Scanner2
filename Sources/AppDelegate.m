#import "AppDelegate.h"
#import "ViewController.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {

    // 启动即写日志，验证能走到这里
    NSMutableString *boot = [NSMutableString string];
    [boot appendString:@"BOOT OK\n"];
    [boot appendFormat:@"bundle=%@\n", [[NSBundle mainBundle] bundleIdentifier] ?: @"-"];
    [boot appendFormat:@"ios=%@\n", [[UIDevice currentDevice] systemVersion]];
    [boot appendFormat:@"name=%@\n", [[UIDevice currentDevice] name]];
    [boot appendFormat:@"uid=%d\n", getuid()];

    NSString *logPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/boot.log"];
    [[boot dataUsingEncoding:NSUTF8StringEncoding] writeToFile:logPath atomically:YES];

    UIWindow *w = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    ViewController *vc = [[ViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    w.rootViewController = nav;
    [w makeKeyAndVisible];
    self.window = w;

    return YES;
}

@end
