# SandboxScanner — iOS 沙盒扫描工具

TrollStore 专用。用于读取其他 App 的沙盒目录、私钥文件、数据库，并探测 Keychain。

## 输出内容

1. 环境信息（UID、bundle、iOS 版本、设备型号）
2. 权限自检（能否读 /var/mobile/Containers）
3. 目标 App 沙盒定位（com.dfmc.dfpv.sapp）
4. 完整目录树（深度 5）
5. 关键文件内容（.pem / .der / .plist / .json 直接打印，.db 只记路径）
6. 协议判定（digitalkeys 目录前缀 → c11/icce/pki/tdk21/legacy）
7. Keychain 全量 dump（含 kSecValueData）

## 编译（GitHub Actions）

1. 新建 GitHub 仓库（Public 或 Private 均可）
2. 把本目录所有文件推上去
3. Actions 自动触发 → Artifacts 下载 `SandboxScanner-ipa`
4. 解压得到 `SandboxScanner.ipa`

## 安装（TrollStore）

TrollStore → 右上角 + → 选 ipa → Install

## 使用

打开 App → 点「开始扫描」→ 等 5-20 秒 → 结果全屏显示
右上角「复制」→ 粘贴到备忘录/发给我

## 关键：为什么能读别人沙盒

本工具的 entitlements 包含：

```xml
<key>platform-application</key><true/>
<key>com.apple.private.security.no-sandbox</key><true/>
<key>com.apple.private.security.container-required</key><false/>
<key>com.apple.private.security.storage.AppDataContainers</key><true/>
```

TrollStore 通过 CoreTrust 漏洞安装时不校验签名，因此这些 entitlement 生效。
普通自签（AltStore/爱思）**不行**，必须 TrollStore。

## 如果扫描结果是「无权限」

说明当前不是 TrollStore 安装，或者 iOS 版本不在 CoreTrust 影响范围内。
请确认：设置 → 通用 → 关于本机 → iOS 15.6（或 14.0b1-15.4.1 等范围）
