import Cocoa
import WebKit
import CryptoKit

// dsh-shell 的原生壳（2026-10-19 取代 Edge --app 窗口）。
//
// 为什么换成原生壳：Edge --app 窗口的红叉由 Chromium 写死为「关闭窗口」，
// 关闭最后一个窗口即退出浏览器，没有任何开关能改。只有自家 NSWindow
// 才能改掉 windowShouldClose 的默认行为。
//
// 壳只做三件事：
//   1) 调 bundle 里的 launcher.sh --ensure 把 launchd 服务等到就绪；
//   2) 用 ~/.dsh/.credentials.yaml 里的 browser-session 签名密钥现场 mint
//      一个 dsh web 的会话 cookie（服务端规则见 @deepseek-ai/dsh-client-connection）；
//   3) 用 WKWebView 打开 http://127.0.0.1:3080；红叉/⌘W 隐藏窗口（只留 Dock
//      图标，像飞书，不生成缩略图），点 Dock 图标恢复。
//
// 运行时日志（不含 cookie/token）追加到 ~/.dsh/shell.log。

private let dshURL = URL(string: "http://127.0.0.1:3080/")!
private let cookieMaxAgeDays = 30

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func base64URLDecode(_ value: String) -> Data? {
    var string = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while string.count % 4 != 0 { string += "=" }
    return Data(base64Encoded: string)
}

private let logQueue = DispatchQueue(label: "com.jimmy.dsh-shell.log")

private func shellLog(_ message: String) {
    logQueue.async {
        let fileManager = FileManager.default
        let path = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".dsh/shell.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if !fileManager.fileExists(atPath: path.path) {
            fileManager.createFile(atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: path) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}

// 从凭据文件里取 client-connection/browser-session 的签名密钥。
// 只做最小 YAML 扫描：这段结构由 dsh-credentials 固定写出（key 缩进 2、
// secret 缩进 6），不引第三方 YAML 解析器。
private func browserSessionSecret() -> String? {
    let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dsh/.credentials.yaml")
    guard let text = try? String(contentsOf: path, encoding: .utf8) else { return nil }
    var inBlock = false
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(rawLine)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed == "client-connection/browser-session:" {
            inBlock = true
            continue
        }
        guard inBlock else { continue }
        if trimmed.hasPrefix("secret:") {
            let value = trimmed.dropFirst("secret:".count)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        let indent = line.prefix(while: { $0 == " " }).count
        if !trimmed.isEmpty && indent <= 2 { inBlock = false }
    }
    return nil
}

// mint 一个服务端认可的浏览器会话 cookie：
//   name  = dsh-auth-<base64url(sha256(authority))>
//   value = v1.<base64url(JSON payload)>.<base64url(HMAC-SHA256(secret, body))>
// authority 对 http 是 host:port（与 dsh-client-connection 的 requestAudience 一致）。
private func mintAuthCookie(for url: URL) -> HTTPCookie? {
    guard let host = url.host,
          let secretString = browserSessionSecret(),
          let secret = base64URLDecode(secretString),
          secret.count == 32 else { return nil }

    let authority = url.port.map { "\(host):\($0)" } ?? host
    let name = "dsh-auth-" + base64URL(Data(SHA256.hash(data: Data(authority.utf8))))
    let now = Int((Date().timeIntervalSince1970 * 1000).rounded())
    let lifetime = cookieMaxAgeDays * 86_400_000
    let payload: [String: Any] = [
        "version": 1,
        "authority": authority,
        "issuedAt": now,
        "expiresAt": now + lifetime,
    ]
    guard let json = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return nil }
    let body = base64URL(json)
    let mac = HMAC<SHA256>.authenticationCode(for: Data(body.utf8), using: SymmetricKey(data: secret))
    let value = "v1.\(body).\(base64URL(Data(mac)))"
    let properties: [HTTPCookiePropertyKey: Any] = [
        .name: name,
        .value: value,
        .domain: host,
        .path: "/",
        .expires: Date(timeIntervalSince1970: Double(now + lifetime) / 1000),
    ]
    return HTTPCookie(properties: properties)
}

private let appDelegate = AppDelegate()

@main
struct DshShell {
    static func main() {
        let app = NSApplication.shared
        app.delegate = appDelegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate,
                         WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var connecting = false

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        connect()
        shellLog("launch: v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        activateApp()
        return true
    }

    // 单窗口应用：点 Dock 图标激活时把隐藏（红叉）或最小化（黄点/⌘M）的窗口拉回来。
    func applicationDidBecomeActive(_ notification: Notification) {
        guard window != nil else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        if !window.isVisible { window.makeKeyAndOrderFront(nil) }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // 红叉 / ⌘W = 隐藏窗口（飞书式）：窗口从桌面消失、Dock 里不留缩略图，
    // 应用继续运行、图标留在 Dock；点图标（reopen/activate）时重新显示。
    // 返回 false 阻止窗口真正关闭，页面状态留在内存里。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    // MARK: - 窗口

    private func buildWindow() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.isElementFullscreenEnabled = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        if #available(macOS 13.3, *) { webView.isInspectable = true }

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "DeepSeek Harness"
        window.minSize = NSSize(width: 900, height: 600)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.delegate = self
        window.contentView = webView
        if !window.setFrameUsingName("dshMainWindow") { window.center() }
        window.setFrameAutosaveName("dshMainWindow")
        window.makeKeyAndOrderFront(nil)
        activateApp()
    }

    private func activateApp() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - 连接

    private func connect() {
        if connecting { return }
        connecting = true
        shellLog("connect: ensuring service")
        loadMessagePage(title: "正在连接 dsh web…", detail: nil)

        ensureService { [weak self] ready in
            guard let self else { return }
            guard ready else {
                self.connecting = false
                self.loadMessagePage(
                    title: "无法连接 dsh web",
                    detail: "服务 30 秒内没有就绪。请查看 ~/.dsh/web.err.log，或按 ⌘R 重试。"
                )
                return
            }
            guard let cookie = mintAuthCookie(for: dshURL) else {
                self.connecting = false
                shellLog("auth: cookie minting failed")
                self.loadMessagePage(
                    title: "无法生成访问凭据",
                    detail: "读取 ~/.dsh/.credentials.yaml 里的 browser-session 密钥失败。请确认 DSH 启动过，然后按 ⌘R 重试。"
                )
                return
            }
            WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie) {
                DispatchQueue.main.async {
                    self.connecting = false
                    shellLog("connect: loading \(dshURL.absoluteString)")
                    self.webView.load(URLRequest(url: dshURL))
                }
            }
        }
    }

    // 让 launchd 把服务拉起来并等到就绪；脚本自带 30s 上限。
    private func ensureService(completion: @escaping (Bool) -> Void) {
        guard let script = Bundle.main.url(forResource: "launcher", withExtension: "sh") else {
            shellLog("ensure: launcher.sh missing from bundle")
            completion(false)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script.path, "--ensure"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            var ready = false
            do {
                try process.run()
                process.waitUntilExit()
                ready = process.terminationStatus == 0
            } catch {
                shellLog("ensure: failed to run: \(error.localizedDescription)")
            }
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            shellLog("ensure: exit=\(process.terminationStatus)\(output.isEmpty ? "" : " output=\(output)")")
            DispatchQueue.main.async { completion(ready) }
        }
    }

    private func loadMessagePage(title: String, detail: String?) {
        let escapedTitle = escapeHTML(title)
        let detailBlock = detail.map { "<p>\(escapeHTML($0))</p>" } ?? ""
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><style>
        html,body{height:100%;margin:0}
        body{background:#17181c;color:#c8c9cc;font:14px -apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif;
             display:flex;align-items:center;justify-content:center;text-align:center}
        div{max-width:560px;line-height:1.6}
        h1{font-size:16px;font-weight:600;margin:0 0 8px;color:#e6e7e9}
        p{margin:0;color:#9a9ba1}
        </style></head><body><div><h1>\(escapedTitle)</h1>\(detailBlock)</div></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    private func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - 菜单

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        let aboutItem = NSMenuItem(
            title: "关于 dsh",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = NSApp
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())
        let hideItem = NSMenuItem(title: "隐藏 dsh", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hideItem.target = NSApp
        appMenu.addItem(hideItem)
        let hideOthersItem = NSMenuItem(
            title: "隐藏其他",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        hideOthersItem.target = NSApp
        appMenu.addItem(hideOthersItem)
        let showAllItem = NSMenuItem(
            title: "全部显示",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        showAllItem.target = NSApp
        appMenu.addItem(showAllItem)
        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 dsh", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        appMenu.addItem(quitItem)

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "撤销", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "重做", action: NSSelectorFromString("redo:"), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: NSSelectorFromString("cut:"), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: NSSelectorFromString("copy:"), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: NSSelectorFromString("paste:"), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: NSSelectorFromString("selectAll:"), keyEquivalent: "a")

        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "视图")
        viewItem.submenu = viewMenu
        let reloadItem = NSMenuItem(title: "重新载入", action: #selector(reloadPage(_:)), keyEquivalent: "r")
        reloadItem.target = self
        viewMenu.addItem(reloadItem)
        viewMenu.addItem(.separator())
        let zoomInItem = NSMenuItem(title: "放大", action: #selector(zoomIn(_:)), keyEquivalent: "=")
        zoomInItem.target = self
        viewMenu.addItem(zoomInItem)
        let zoomOutItem = NSMenuItem(title: "缩小", action: #selector(zoomOut(_:)), keyEquivalent: "-")
        zoomOutItem.target = self
        viewMenu.addItem(zoomOutItem)
        let zoomResetItem = NSMenuItem(title: "实际大小", action: #selector(zoomReset(_:)), keyEquivalent: "0")
        zoomResetItem.target = self
        viewMenu.addItem(zoomResetItem)
        viewMenu.addItem(.separator())
        let fullScreenItem = NSMenuItem(
            title: "进入全屏幕",
            action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f"
        )
        fullScreenItem.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(fullScreenItem)

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "窗口")
        windowItem.submenu = windowMenu
        // 隐藏窗口后的兜底入口：万一点 Dock 图标没触发 reopen，菜单里也能找回来。
        let showItem = NSMenuItem(title: "显示主窗口", action: #selector(showMainWindow(_:)), keyEquivalent: "")
        showItem.target = self
        windowMenu.addItem(showItem)
        windowMenu.addItem(.separator())
        let minimizeItem = NSMenuItem(
            title: "最小化",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        windowMenu.addItem(minimizeItem)
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        let frontItem = NSMenuItem(
            title: "前置全部窗口",
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        )
        frontItem.target = NSApp
        windowMenu.addItem(frontItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    @objc private func reloadPage(_ sender: Any?) { connect() }
    @objc private func showMainWindow(_ sender: Any?) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        activateApp()
    }
    @objc private func zoomIn(_ sender: Any?) { webView.pageZoom = min(webView.pageZoom + 0.1, 3.0) }
    @objc private func zoomOut(_ sender: Any?) { webView.pageZoom = max(webView.pageZoom - 0.1, 0.5) }
    @objc private func zoomReset(_ sender: Any?) { webView.pageZoom = 1.0 }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url,
              navigationAction.targetFrame?.isMainFrame == true,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            decisionHandler(.allow)
            return
        }
        let sameHost = url.host == dshURL.host
        let samePort = (url.port ?? 80) == (dshURL.port ?? 80)
        if !(sameHost && samePort) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        shellLog("loaded: \(webView.url?.absoluteString ?? "?")")
        // 记一下页面标题：真页是 "DeepSeek Harness"；占位/错误页标题为空，
        // 出问题时 shell.log 能一眼区分「加载了」和「加载到了什么」。
        webView.evaluateJavaScript("document.title") { value, _ in
            shellLog("page title: \(value as? String ?? "")")
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failPage(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failPage(error)
    }

    private func failPage(_ error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        shellLog("load failed: \(error.localizedDescription)")
        loadMessagePage(title: "页面加载失败", detail: "\(error.localizedDescription)\n按 ⌘R 重试。")
    }

    // MARK: - WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { openExternallyOrInPlace(url) }
        return nil
    }

    private func openExternallyOrInPlace(_ url: URL) {
        guard let scheme = url.scheme?.lowercased() else { return }
        if (scheme == "http" || scheme == "https"),
           url.host == dshURL.host,
           (url.port ?? 80) == (dshURL.port ?? 80) {
            webView.load(URLRequest(url: url))
        } else if scheme == "http" || scheme == "https" || scheme == "mailto" || scheme == "tel" {
            NSWorkspace.shared.open(url)
        }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.beginSheetModal(for: window) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.prompt)
    }

    // MARK: - 下载

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.beginSheetModal(for: window) { result in
            completionHandler(result == .OK ? panel.url : nil)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        shellLog("download finished")
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        shellLog("download failed: \(error.localizedDescription)")
    }
}
