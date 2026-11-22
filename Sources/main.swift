import UIKit

// main.swift 必须用顶层代码，不能用 @main（否则与文件名冲突编译报错）
let delegateClass: AnyClass = AppDelegate.self
UIApplicationMain(
    CommandLine.argc,
    CommandLine.unsafeArgv,
    nil,
    NSStringFromClass(delegateClass)
)
