import UIKit

class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {

        // 第一步：先写一个最简日志，确认 App 能启动到这里
        var boot = "BOOT OK\n"
        boot += "bundle=\(Bundle.main.bundleIdentifier ?? "-")\n"
        boot += "iOS=\(UIDevice.current.systemVersion)\n"
        var si = utsname()
        uname(&si)
        let machine = withUnsafeBytes(of: &si.machine) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        boot += "model=\(machine)\n"
        boot += "uid=\(getuid())\n"

        // 尽早落盘，避免闪退后丢失
        let early = NSHomeDirectory() + "/Documents/boot.log"
        try? boot.write(toFile: early, atomically: true, encoding: .utf8)

        let w = UIWindow(frame: UIScreen.main.bounds)
        let vc = ViewController()
        let nav = UINavigationController(rootViewController: vc)
        nav.navigationBar.prefersLargeTitles = false
        w.rootViewController = nav
        w.makeKeyAndVisible()
        self.window = w
        return true
    }
}
