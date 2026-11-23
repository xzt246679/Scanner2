#import <UIKit/UIKit.h>
#import <unistd.h>
#import "AppDelegate.h"

int main(int argc, char *argv[]) {
    // TrollStore root elevation
    setuid(0);
    setgid(0);
    seteuid(0);
    setegid(0);
    
    NSString *appDelegateClassName;
    @autoreleasepool {
        appDelegateClassName = NSStringFromClass([AppDelegate class]);
    }
    return UIApplicationMain(argc, argv, nil, appDelegateClassName);
}
