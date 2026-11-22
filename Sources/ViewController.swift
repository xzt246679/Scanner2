import UIKit

class ViewController: UIViewController {

    private let textView = UITextView()
    private let button = UIButton(type: .system)
    private let statusLabel = UILabel()
    private var buffer = ""

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "沙盒扫描"
        view.backgroundColor = .systemBackground

        statusLabel.text = "已启动 · 点按钮开始扫描"
        statusLabel.font = .systemFont(ofSize: 15, weight: .medium)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        button.setTitle("开始扫描", for: .normal)
        button.titleLabel?.font = .boldSystemFont(ofSize: 18)
        button.addTarget(self, action: #selector(runScan), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(button)

        textView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        textView.isEditable = false
        textView.alwaysBounceVertical = true
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),

            button.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            button.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            button.heightAnchor.constraint(equalToConstant: 40),

            textView.topAnchor.constraint(equalTo: button.bottomAnchor, constant: 8),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])

        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "复制", style: .plain,
                                                            target: self, action: #selector(copyAll))
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "清空", style: .plain,
                                                           target: self, action: #selector(clearAll))
    }

    @objc private func clearAll() {
        buffer = ""
        textView.text = ""
        statusLabel.text = "已清空"
    }

    @objc private func copyAll() {
        UIPasteboard.general.string = buffer
        statusLabel.text = "已复制 \(buffer.count) 字符到剪贴板"
    }

    private func log(_ s: String) {
        buffer += s + "\n"
        let snapshot = buffer
        DispatchQueue.main.async {
            self.textView.text = snapshot
            if snapshot.count > 0 {
                let r = NSRange(location: (snapshot as NSString).length - 1, length: 1)
                self.textView.scrollRangeToVisible(r)
            }
        }
    }

    @objc private func runScan() {
        statusLabel.text = "扫描中…"
        button.isEnabled = false
        buffer = ""
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            self.scanAll()
            DispatchQueue.main.async {
                self.button.isEnabled = true
                self.statusLabel.text = "扫描完成 · 共 \(self.buffer.count) 字符"
            }
        }
    }

    // MARK: - 扫描主体（全部容错，不 force unwrap）

    private func scanAll() {
        log("========== 环境 ==========")
        log("uid=\(getuid())")
        log("euid=\(geteuid())")
        log("bundle=\(Bundle.main.bundleIdentifier ?? "-")")
        log("iOS=\(UIDevice.current.systemVersion)")
        log("model=\(machineModel())")
        log("home=\(NSHomeDirectory())")

        log("")
        log("========== 权限自检 ==========")
        let probes = [
            "/var/mobile/Containers/Data/Application",
            "/var/containers/Bundle/Application",
            "/var/mobile",
            "/private/var/mobile",
            "/var/mobile/Library",
            "/var/mobile/Media"
        ]
        for p in probes {
            log("\(canRead(p) ? "可读" : "无权限")  \(p)")
        }

        log("")
        log("========== 定位目标容器 ==========")
        if let root = findAppRoot() {
            log("找到: \(root)")
            log("")
            log("========== 目录树（深度 5）==========")
            walk(root, depth: 0, maxDepth: 5)
            log("")
            log("========== 关键文件 ==========")
            scanKeyFiles(root)
            log("")
            log("========== 协议判定 ==========")
            detectProtocol(root)
        } else {
            log("未找到 com.dfmc.dfpv.sapp")
            log("")
            log("========== 列出可用容器（前 40）==========")
            listContainers(limit: 40)
        }

        log("")
        log("========== Keychain ==========")
        dumpKeychain()

        log("")
        log("========== 完成 ==========")
    }

    private func canRead(_ p: String) -> Bool {
        return (try? FileManager.default.contentsOfDirectory(atPath: p)) != nil
    }

    private func machineModel() -> String {
        var si = utsname()
        uname(&si)
        return withUnsafeBytes(of: &si.machine) { raw -> String in
            guard let base = raw.baseAddress else { return "?" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }

    private func findAppRoot() -> String? {
        let base = "/var/mobile/Containers/Data/Application"
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: base) else { return nil }
        for d in dirs {
            let meta = base + "/" + d + "/.com.apple.mobile_container_manager.metadata.plist"
            if let dict = NSDictionary(contentsOfFile: meta),
               let ident = dict["MCMMetadataIdentifier"] as? String,
               ident == "com.dfmc.dfpv.sapp" {
                return base + "/" + d
            }
        }
        return nil
    }

    private func listContainers(limit: Int) {
        let base = "/var/mobile/Containers/Data/Application"
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: base) else {
            log("无法列出 \(base)")
            return
        }
        for (i, d) in dirs.prefix(limit).enumerated() {
            let meta = base + "/" + d + "/.com.apple.mobile_container_manager.metadata.plist"
            let ident = (NSDictionary(contentsOfFile: meta)?["MCMMetadataIdentifier"] as? String) ?? "?"
            log(String(format: "%3d. %@", i, ident))
        }
    }

    private func walk(_ path: String, depth: Int, maxDepth: Int) {
        guard depth <= maxDepth else { return }
        let indent = String(repeating: "  ", count: depth)
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            log("\(indent)[不可读]")
            return
        }
        for name in items.sorted() {
            let full = path + "/" + name
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                log("\(indent)📁 \(name)/")
                walk(full, depth: depth + 1, maxDepth: maxDepth)
            } else {
                let sz = (try? FileManager.default.attributesOfItem(atPath: full)[.size] as? NSNumber)?.intValue ?? 0
                log("\(indent)📄 \(name)  (\(sz) B)")
            }
        }
    }

    private func scanKeyFiles(_ root: String) {
        var hits: [String] = []
        collect(root, depth: 0, maxDepth: 6, exts: [".pem", ".der", ".json", ".plist", ".db", ".sqlite", ".db3"], into: &hits)
        log("候选文件 \(hits.count) 个")
        for f in hits {
            let rel = f.replacingOccurrences(of: root, with: "")
            let sz = (try? FileManager.default.attributesOfItem(atPath: f)[.size] as? NSNumber)?.intValue ?? 0
            log("")
            log("---- \(rel)  (\(sz) B) ----")
            guard sz > 0, sz < 65536 else {
                log("[跳过内容]")
                continue
            }
            guard let data = FileManager.default.contents(atPath: f) else {
                log("[读取失败]")
                continue
            }
            if let s = String(data: data, encoding: .utf8) {
                log(String(s.prefix(1500)))
            } else {
                log("[二进制] \(data.prefix(40).map { String(format: "%02x", $0) }.joined())")
            }
        }
    }

    private func collect(_ path: String, depth: Int, maxDepth: Int, exts: [String], into out: inout [String]) {
        guard depth <= maxDepth else { return }
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: path) else { return }
        for name in items {
            let full = path + "/" + name
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                collect(full, depth: depth + 1, maxDepth: maxDepth, exts: exts, into: &out)
            } else {
                for e in exts where name.hasSuffix(e) {
                    out.append(full)
                    break
                }
            }
        }
    }

    private func detectProtocol(_ root: String) {
        let candidates = [
            root + "/Documents/digitalkeys",
            root + "/Documents",
            root + "/Library"
        ]
        for base in candidates {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: base) else { continue }
            let hit = items.filter { $0.contains("_dk_") || $0.hasPrefix("digital_key") }
            if !hit.isEmpty {
                log("\(base):")
                for h in hit { log("   \(h)") }
                var protos = Set<String>()
                for h in hit {
                    if h.hasPrefix("c11_dk_") { protos.insert("COT/C11") }
                    if h.hasPrefix("icce10_dk_") { protos.insert("ICCE10") }
                    else if h.hasPrefix("icce_dk_") { protos.insert("ICCE") }
                    if h.hasPrefix("pki_dk_") { protos.insert("PKI") }
                    if h.hasPrefix("tdk21_dk_") { protos.insert("TDK21") }
                    if h.hasPrefix("legacy_dk_") { protos.insert("Legacy") }
                }
                log("判定协议: \(protos.isEmpty ? "未识别" : protos.sorted().joined(separator: " / "))")
            }
        }
    }

    private func dumpKeychain() {
        let classes: [(String, CFString)] = [
            ("GenericPassword", kSecClassGenericPassword),
            ("Key", kSecClassKey),
            ("Certificate", kSecClassCertificate),
            ("Identity", kSecClassIdentity)
        ]
        for (label, cls) in classes {
            let q: [String: Any] = [
                kSecClass as String: cls,
                kSecReturnAttributes as String: true,
                kSecReturnData as String: false,
                kSecMatchLimit as String: kSecMatchLimitAll
            ]
            var r: CFTypeRef?
            let st = SecItemCopyMatching(q as CFDictionary, &r)
            log("")
            log("[\(label)] status=\(st)")
            guard st == errSecSuccess, let arr = r as? [[String: Any]] else { continue }
            log("  条目数: \(arr.count)")
            for (i, item) in arr.prefix(30).enumerated() {
                let svc = item[kSecAttrService as String] as? String ?? "-"
                let acct = item[kSecAttrAccount as String] as? String ?? "-"
                let ag = item[kSecAttrAccessGroup as String] as? String ?? "-"
                log("  [\(i)] svc=\(svc) acct=\(acct) group=\(ag)")
            }
        }
    }
}
