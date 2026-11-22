import UIKit
import Security

// 目标 App 包名
let kTargetBundle = "com.dfmc.dfpv.sapp"

class ViewController: UIViewController {

    let textView = UITextView()
    let button = UIButton(type: .system)
    var buffer = ""

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "沙盒扫描"
        view.backgroundColor = .systemBackground

        button.setTitle("开始扫描", for: .normal)
        button.titleLabel?.font = .boldSystemFont(ofSize: 18)
        button.addTarget(self, action: #selector(runScan), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(button)

        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.isEditable = false
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)

        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            button.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            button.heightAnchor.constraint(equalToConstant: 44),

            textView.topAnchor.constraint(equalTo: button.bottomAnchor, constant: 8),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])

        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "复制", style: .plain, target: self, action: #selector(copyAll))
    }

    @objc func copyAll() {
        UIPasteboard.general.string = buffer
        let a = UIAlertController(title: "已复制", message: "内容已复制到剪贴板", preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "好", style: .default))
        present(a, animated: true)
    }

    func log(_ s: String) {
        buffer += s + "\n"
        DispatchQueue.main.async {
            self.textView.text = self.buffer
            let range = NSRange(location: max(0, (self.buffer as NSString).length - 1), length: 1)
            self.textView.scrollRangeToVisible(range)
        }
    }

    @objc func runScan() {
        buffer = ""
        textView.text = ""
        DispatchQueue.global(qos: .userInitiated).async {
            self.scanAll()
        }
    }

    // MARK: - 主流程

    func scanAll() {
        log("========== 环境信息 ==========")
        log("UID = \(getuid())")
        log("bundle = \(Bundle.main.bundleIdentifier ?? "-")")
        log("iOS = \(UIDevice.current.systemVersion)")
        log("model = \(deviceModel())")

        let testPaths = [
            "/var/mobile/Containers/Data/Application",
            "/var/containers/Bundle/Application",
            "/var/mobile",
            "/private/var/mobile"
        ]
        log("")
        log("========== 权限自检 ==========")
        for p in testPaths {
            let ok = FileManager.default.isReadableFile(atPath: p)
            log("\(ok ? "可读" : "无权限")  \(p)")
        }

        log("")
        log("========== 定位目标 App 沙盒 ==========")
        guard let target = findTargetContainer() else {
            log("未找到 \(kTargetBundle)")
            log("→ 该 App 可能未安装，或本工具无 no-sandbox 权限")
            log("")
            log("========== 列出所有容器（前 50）==========")
            listAllContainers(limit: 50)
            return
        }
        log("找到目标容器: \(target)")
        log("")

        log("========== 目录树 ==========")
        walk(target, depth: 0, maxDepth: 5)

        log("")
        log("========== 关键文件内容 ==========")
        scanKeyFiles(target)

        log("")
        log("========== 协议判定 ==========")
        detectProtocol(target)

        log("")
        log("========== Keychain 探测 ==========")
        dumpKeychain()

        log("")
        log("========== 完成 ==========")
    }

    // MARK: - 定位容器

    func findTargetContainer() -> String? {
        let base = "/var/mobile/Containers/Data/Application"
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: base) else { return nil }
        for d in dirs {
            let meta = base + "/" + d + "/.com.apple.mobile_container_manager.metadata.plist"
            if let dict = NSDictionary(contentsOfFile: meta),
               let ident = dict["MCMMetadataIdentifier"] as? String,
               ident == kTargetBundle {
                return base + "/" + d
            }
        }
        return nil
    }

    func listAllContainers(limit: Int) {
        let base = "/var/mobile/Containers/Data/Application"
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: base) else {
            log("无法列出 \(base)")
            return
        }
        for (i, d) in dirs.prefix(limit).enumerated() {
            let meta = base + "/" + d + "/.com.apple.mobile_container_manager.metadata.plist"
            let ident = (NSDictionary(contentsOfFile: meta)?["MCMMetadataIdentifier"] as? String) ?? "?"
            log(String(format: "%3d. %@  →  %@", i, d, ident))
        }
    }

    // MARK: - 目录遍历

    func walk(_ path: String, depth: Int, maxDepth: Int) {
        if depth > maxDepth { return }
        let indent = String(repeating: "  ", count: depth)
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            log("\(indent)[无法读取]")
            return
        }
        for name in items.sorted() {
            let full = path + "/" + name
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: full, isDirectory: &isDir)
            if isDir.boolValue {
                log("\(indent)📁 \(name)/")
                walk(full, depth: depth + 1, maxDepth: maxDepth)
            } else {
                let attrs = try? FileManager.default.attributesOfItem(atPath: full)
                let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
                log("\(indent)📄 \(name)  (\(size) B)")
            }
        }
    }

    // MARK: - 关键文件

    func scanKeyFiles(_ root: String) {
        let patterns = [".pem", ".der", ".db", ".sqlite", ".db3", ".plist", ".json"]
        var hits: [String] = []
        collectFiles(root, depth: 0, maxDepth: 6, patterns: patterns, into: &hits)

        log("共发现 \(hits.count) 个候选文件")
        for f in hits {
            let size = (try? FileManager.default.attributesOfItem(atPath: f)[.size] as? NSNumber)?.intValue ?? 0
            log("")
            log("---- \(f.replacingOccurrences(of: root, with: ""))  (\(size) B) ----")
            if f.hasSuffix(".pem") || f.hasSuffix(".der") || f.hasSuffix(".json") || f.hasSuffix(".plist") {
                if size < 8192, let data = FileManager.default.contents(atPath: f) {
                    if let s = String(data: data, encoding: .utf8) {
                        log(String(s.prefix(1200)))
                    } else if f.hasSuffix(".pem") || f.hasSuffix(".der") {
                        log("[二进制] hex head: " + data.prefix(48).map { String(format: "%02x", $0) }.joined())
                    }
                }
            } else {
                log("[数据库/其他类型，仅记录路径]")
            }
        }
    }

    func collectFiles(_ path: String, depth: Int, maxDepth: Int, patterns: [String], into out: inout [String]) {
        if depth > maxDepth { return }
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: path) else { return }
        for name in items {
            let full = path + "/" + name
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: full, isDirectory: &isDir)
            if isDir.boolValue {
                collectFiles(full, depth: depth + 1, maxDepth: maxDepth, patterns: patterns, into: &out)
            } else {
                for p in patterns where name.hasSuffix(p) {
                    out.append(full)
                    break
                }
            }
        }
    }

    // MARK: - 协议判定

    func detectProtocol(_ root: String) {
        let base = root + "/Documents/digitalkeys"
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: base) else {
            log("未找到 digitalkeys 目录: \(base)")
            // 尝试其他位置
            for alt in [root + "/Documents", root + "/Library", root + "/Documents/certs"] {
                if let ls = try? FileManager.default.contentsOfDirectory(atPath: alt) {
                    log("\(alt) 内容: \(ls.joined(separator: ", "))")
                }
            }
            return
        }
        var detected: Set<String> = []
        for n in items {
            if n.hasPrefix("c11_dk_") { detected.insert("COT/C11 (CCC)") }
            else if n.hasPrefix("icce10_dk_") { detected.insert("ICCE10") }
            else if n.hasPrefix("icce_dk_") { detected.insert("ICCE") }
            else if n.hasPrefix("pki_dk_") { detected.insert("PKI") }
            else if n.hasPrefix("tdk21_dk_") { detected.insert("TDK21") }
            else if n.hasPrefix("legacy_dk_") { detected.insert("Legacy") }
        }
        log("digitalkeys 下文件: \(items.joined(separator: ", "))")
        log("判定协议: \(detected.isEmpty ? "未识别" : detected.joined(separator: " / "))")
    }

    // MARK: - Keychain

    func dumpKeychain() {
        let classes: [(String, CFString)] = [
            ("GenericPassword", kSecClassGenericPassword),
            ("Key", kSecClassKey),
            ("Certificate", kSecClassCertificate),
            ("Identity", kSecClassIdentity),
            ("InternetPassword", kSecClassInternetPassword)
        ]
        for (label, cls) in classes {
            let q: [String: Any] = [
                kSecClass as String: cls,
                kSecReturnAttributes as String: true,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitAll,
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
            ]
            var r: CFTypeRef?
            let st = SecItemCopyMatching(q as CFDictionary, &r)
            log("")
            log("[\(label)] status=\(st)")
            if st == errSecSuccess, let arr = r as? [[String: Any]] {
                log("  条目数: \(arr.count)")
                for (i, item) in arr.enumerated() {
                    let svc = item[kSecAttrService as String] as? String ?? "-"
                    let acct = item[kSecAttrAccount as String] as? String ?? "-"
                    let ag = item[kSecAttrAccessGroup as String] as? String ?? "-"
                    var dataDesc = "无数据"
                    if let d = item[kSecValueData as String] as? Data {
                        dataDesc = "\(d.count)B " + d.prefix(32).map { String(format: "%02x", $0) }.joined()
                    }
                    log("  [\(i)] service=\(svc) account=\(acct) group=\(ag)")
                    log("       data=\(dataDesc)")
                }
            } else if st != errSecItemNotFound {
                log("  错误码: \(st)  \(SecCopyErrorMessageString(st, nil) as String? ?? "")")
            }
        }
    }

    // MARK: - 设备型号

    func deviceModel() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafeBytes(of: &sysinfo.machine) { raw -> String in
            let bytes = raw.bindMemory(to: CChar.self)
            return String(cString: bytes.baseAddress!)
        }
        return machine
    }
}
