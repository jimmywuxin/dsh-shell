import Cocoa
import WebKit
import CryptoKit

// dsh-shell 的原生壳（2026-10-19 取代 Edge --app 窗口）。
//
// 为什么换成原生壳：Edge --app 窗口的红叉由 Chromium 写死为「关闭窗口」，
// 关闭最后一个窗口即退出浏览器，没有任何开关能改。只有自家 NSWindow
// 才能改掉 windowShouldClose 的默认行为。
//
// 壳只做四件事：
//   1) 调 bundle 里的 launcher.sh --ensure 把 launchd 服务等到就绪；
//   2) 用 ~/.dsh/.credentials.yaml 里的 browser-session 签名密钥现场 mint
//      一个 dsh web 的会话 cookie（服务端规则见 @deepseek-ai/dsh-client-connection）；
//   3) 用 WKWebView 打开 http://127.0.0.1:3080；红叉/⌘W 隐藏窗口（只留 Dock
//      图标，像飞书，不生成缩略图），点 Dock 图标恢复；
//   4) 自愈与排障：内容进程崩溃后自动重载、401 自动重铸 cookie、全屏退出的
//      标题栏错位自修，以及「视图」菜单里的重启服务/看日志/查状态。
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

// 让标题栏跟着 dsh 主界面的底色走（2026-10-27 加）。
//
// 为什么不能只设 window.appearance：那只能把标题栏切成系统深色灰（#2C2C2E 一档），
// 和 dsh 自己的 --dsw-alias-bg-base 对不上，深色下仍是一条明显不同的横条。
// 做法是 titlebarAppearsTransparent + window.backgroundColor = 页面实测底色，
// 标题栏区域就露出窗口底色，与内容严丝合缝；appearance 只负责交通灯/标题字明暗。
//
// 怎么知道页面换了颜色 —— 三条路一起上，缺一条就会「页面变了、标题栏不变」：
//   1) MutationObserver 盯 html/body 的 class/style/data-* —— 属性驱动的切换立刻响应；
//   2) 500ms 轮询 getComputedStyle —— 2026-10-27 实测出现过页面已由白转深、属性没动、
//      标题栏一直没跟上的情况（当时只有窗口重新激活时的兜底重采样才发现），轮询是抓
//      这种「静默改色」唯一不依赖页面配合的办法；
//   3) 窗口重新激活时原生喊一次 __dshChromeResample（顺手兜住睡醒/切空间）。
// JS 侧对 rgb 值去重，只有真变了才回传，轮询不会把 IPC 打满。
private let chromeScript = """
(function () {
  if (window.__dshChromeHooked) return;
  window.__dshChromeHooked = true;
  var lastKey = null;
  function rgbOf(el) {
    if (!el) return null;
    var m = (getComputedStyle(el).backgroundColor || '').match(/^rgba?\\(([^)]+)\\)$/);
    if (!m) return null;
    var p = m[1].split(',').map(function (s) { return parseFloat(s); });
    if (p.length < 3 || !isFinite(p[0])) return null;
    var a = p.length > 3 ? p[3] : 1;
    if (!(a > 0.5)) return null;              // 全透明 = 不是真正的底色，往下一层找
    return [Math.round(p[0]), Math.round(p[1]), Math.round(p[2])];
  }
  function current() {
    var html = document.documentElement;
    var dark = !!document.body && (document.body.hasAttribute('data-ds-dark-theme')
      || html.hasAttribute('data-ds-dark-theme'));
    var chain = [document.body, document.getElementById('root'), html];
    var rgb = null;
    for (var i = 0; i < chain.length && !rgb; i++) rgb = rgbOf(chain[i]);
    // 深色主题已生效但底色还没铺上（首帧竞态）：直接用深色兜底，别让标题栏先闪一帧白
    if (dark && rgb && rgb[0] === 255 && rgb[1] === 255 && rgb[2] === 255) rgb = [21, 21, 23];
    if (!rgb) rgb = dark ? [21, 21, 23] : [255, 255, 255];
    return rgb;
  }
  function sample() {
    var rgb = current();
    var key = rgb.join(',');
    if (key === lastKey) return;              // 没变就别打扰原生
    lastKey = key;
    try { window.webkit.messageHandlers.dshChrome.postMessage({ rgb: rgb }); } catch (e) {}
  }
  function force() { lastKey = null; sample(); }
  var pending = null;
  function schedule() {
    if (pending) return;
    pending = setTimeout(function () { pending = null; sample(); }, 120);   // 合并同一帧内的多次突变
  }
  sample();
  window.__dshChromeResample = force;         // 原生在窗口激活时调用，忽略去重强制重读
  try {
    var filter = { attributes: true, attributeFilter: ['class', 'style', 'data-ds-dark-theme', 'data-theme'] };
    new MutationObserver(schedule).observe(document.documentElement, filter);
    if (document.body) new MutationObserver(schedule).observe(document.body, filter);
  } catch (e) {}
  setInterval(function () {
    if (document.visibilityState !== 'visible') return;
    sample();
  }, 500);
})();
"""

private let logQueue = DispatchQueue(label: "com.jimmy.dsh-shell.log")

// 写日志前的兜底脱敏（对齐 opencode-shell 的 redactSecrets，模式按 dsh 的凭据面定制）。
// dsh 的凭据面：带 token 的入口 URL（web.log 历史坑，err.log 堆栈里也可能带）、
// 会话 cookie 值（v1.<body>.<mac>）、Authorization 头。任何写日志的路径
// （含 ensure/restart 的脚本输出透传）都不允许原文落盘。
// 抹写格式 = •••• + 尾 4 位指纹（安全铁律口径，指纹仅用于回溯是否同一凭据；
// 值不足 8 字符时不带指纹，避免短值泄露比例过高）。
private let redactPatterns: [NSRegularExpression] = [
    // 1) 查询串/行内的凭据参数：token= secret= api_key= access_token=（含引号包裹值）
    "((?:^|[?&;\\s\"'])(?i:token|secret|api_?key|access_?token)=[\"']?)([^&\\s\"']+)",
    // 2) dsh 会话 cookie 的值
    "((?i:dsh-auth-[A-Za-z0-9_-]+=))(v1\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+)",
    // 3) Bearer 凭据（JWT 或 ≥24 字符的串）
    "((?i:bearer[\"']?\\s*[:=]?\\s*))(eyJ[A-Za-z0-9._-]+|[A-Za-z0-9._-]{24,})",
].compactMap { try? NSRegularExpression(pattern: $0) }

private func redactSecrets(_ text: String) -> String {
    var out = text
    for regex in redactPatterns {
        let ns = out as NSString
        // 从后往前替换：前面的 range 不受影响
        for m in regex.matches(in: out, range: NSRange(location: 0, length: ns.length)).reversed() {
            guard m.numberOfRanges >= 3 else { continue }
            let prefix = ns.substring(with: m.range(at: 1))
            let value = ns.substring(with: m.range(at: 2))
            let fingerprint = value.count >= 8 ? String(value.suffix(4)) : ""
            out = ns.replacingCharacters(in: m.range, with: prefix + "••••" + fingerprint)
        }
    }
    return out
}

private func shellLog(_ message: String) {
    let sanitized = redactSecrets(message)
    logQueue.async {
        let fileManager = FileManager.default
        let path = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".dsh/shell.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(sanitized)\n"
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

// 凭据文件的解析失败原因。
// 为什么要把 nil 拆成五种（2026-11-03）：原来扫描失败只有一句「请确认 DSH 启动过」，
// 而真实情况常常是 dsh 好好跑着、只是文件格式/权限变了 —— 误导诊断比没有诊断更糟。
// 只记原因不记值（secret 本身绝不落日志）。
private enum SecretProblem: String {
    case fileMissing = "file-missing"
    case unreadable = "unreadable"
    case noBlock = "no-block"
    case noSecret = "no-secret"
    case badLength = "bad-length"

    var hint: String {
        switch self {
        case .fileMissing:
            return "~/.dsh/.credentials.yaml 不存在。请确认 DSH 至少启动过一次。"
        case .unreadable:
            return "~/.dsh/.credentials.yaml 存在但读不出来（检查文件权限与编码）。"
        case .noBlock:
            return "文件里找不到 client-connection/browser-session 段，凭据格式可能已变。"
        case .noSecret:
            return "browser-session 段里没有 secret: 一行，凭据文件可能不完整。"
        case .badLength:
            return "secret 解码后不是 32 字节，凭据文件可能被截断。"
        }
    }
}

private struct SecretLookup {
    let value: String?
    let problem: SecretProblem?
}

// 从凭据文件里取 client-connection/browser-session 的签名密钥。
// 只做最小 YAML 扫描：这段结构由 dsh-credentials 固定写出，不引第三方 YAML 解析器。
// secret: 的缩进不参与判定（只按「块内出现 secret:」匹配），块外靠 indent <= 2 收束。
private func browserSessionSecret() -> SecretLookup {
    let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dsh/.credentials.yaml")
    guard let text = try? String(contentsOf: path, encoding: .utf8) else {
        let exists = FileManager.default.fileExists(atPath: path.path)
        return SecretLookup(value: nil, problem: exists ? .unreadable : .fileMissing)
    }
    warnIfSecretPermissionsLoose(path)
    var inBlock = false
    var sawBlock = false
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(rawLine)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed == "client-connection/browser-session:" {
            inBlock = true
            sawBlock = true
            continue
        }
        guard inBlock else { continue }
        if trimmed.hasPrefix("secret:") {
            let value = trimmed.dropFirst("secret:".count)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty
                ? SecretLookup(value: nil, problem: .noSecret)
                : SecretLookup(value: value, problem: nil)
        }
        let indent = line.prefix(while: { $0 == " " }).count
        if !trimmed.isEmpty && indent <= 2 { inBlock = false }
    }
    return SecretLookup(value: nil, problem: sawBlock ? .noSecret : .noBlock)
}

// 密钥文件权限收得太松时警告一次（不阻断）：同机其他账户可读 = 可自行造 cookie。
private var warnedLooseSecretPermissions = false

private func warnIfSecretPermissionsLoose(_ path: URL) {
    guard !warnedLooseSecretPermissions else { return }
    let attrs = try? FileManager.default.attributesOfItem(atPath: path.path)
    let mode = (attrs?[.posixPermissions] as? NSNumber)?.intValue ?? 0
    guard mode & 0o077 != 0 else { return }
    warnedLooseSecretPermissions = true
    shellLog(String(format: "auth: credentials permissions too open (mode=0%o), expect 0600", mode))
}

// mint 失败的两类原因：凭据侧（带具体原因，给用户看）与编码侧（几乎不可能，只记日志）。
private enum MintFailure: Error {
    case secret(SecretProblem)
    case encoding

    var logReason: String {
        switch self {
        case .secret(let problem): return problem.rawValue
        case .encoding: return "encode"
        }
    }

    var hint: String {
        switch self {
        case .secret(let problem): return problem.hint
        case .encoding: return "签名密钥可用，但 cookie 编码失败（少见，多为内存异常）。"
        }
    }
}

// mint 一个服务端认可的浏览器会话 cookie：
//   name  = dsh-auth-<base64url(sha256(authority))>
//   value = v1.<base64url(JSON payload)>.<base64url(HMAC-SHA256(secret, body))>
// authority 对 http 是 host:port（与 dsh-client-connection 的 requestAudience 一致）。
private func mintAuthCookie(for url: URL) -> Result<HTTPCookie, MintFailure> {
    guard let host = url.host else { return .failure(.encoding) }
    let lookup = browserSessionSecret()
    guard let secretString = lookup.value else {
        return .failure(.secret(lookup.problem ?? .noSecret))
    }
    guard let secret = base64URLDecode(secretString) else {
        return .failure(.secret(.badLength))
    }
    guard secret.count == 32 else { return .failure(.secret(.badLength)) }

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
    guard let json = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
        return .failure(.encoding)
    }
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
    guard let cookie = HTTPCookie(properties: properties) else { return .failure(.encoding) }
    return .success(cookie)
}

// 本机等价类（2026-11-03）：loopback 的三个写法必须都认。原来只比字符串
// "127.0.0.1"，服务端任何一次 302 落到 localhost 就会被当外链交给 NSWorkspace
// —— 现场表现是「壳突然空白、浏览器被拉起来」，排障时极易误判成服务挂了。
private let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

private func isLocal(_ url: URL) -> Bool {
    guard let rawHost = url.host?.lowercased() else { return false }
    let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    guard loopbackHosts.contains(host) else { return false }
    return (url.port ?? 80) == (dshURL.port ?? 80)
}

// ── 子进程与探活（启动等待与「视图」菜单的排障入口共用） ───────────
// 同步执行，**只在后台队列调用**：waitUntilExit 会阻塞调用线程。
private func runProcessSync(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
    } catch {
        return (-1, "启动失败：\(error.localizedDescription)")
    }
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return (process.terminationStatus,
            String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
}

private func runScriptSync(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
    runProcessSync("/bin/bash", [path] + arguments)
}

// 与 dsh-lib.sh 的 app_ready 同口径：401（认证墙后面是活服务）/2xx/3xx 就绪，
// 000（没起）/404（半启动）/5xx 都不算。
private func isReadyCode(_ code: String) -> Bool {
    if code.isEmpty || code == "000" || code == "404" { return false }
    if code.hasPrefix("5") { return false }
    return true
}

private func probeHTTPCode() -> String {
    let result = runProcessSync("/usr/bin/curl", [
        "-s", "-o", "/dev/null", "-w", "%{http_code}",
        "--noproxy", "*", "--max-time", "2", dshURL.absoluteString,
    ])
    let code = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    return code.isEmpty ? "000" : code
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
                         WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate,
                         WKScriptMessageHandler {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var connecting = false
    private var chromeColor: NSColor?

    // 基础样式掩码：全屏自愈时按它复位（WebKit 全屏常残留 .fullSizeContentView）
    private let baseStyleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
    // 标题栏自愈用：健康基线、待执行的修复、冷却与重试计数
    private var healthyCloseCenter: NSPoint?
    private var pendingRepair: DispatchWorkItem?
    private var repairing = false
    private var repairAttempts = 0
    private var lastRepairAt = Date.distantPast
    private var savedFrameBeforeFullScreen: NSRect?
    // 内容进程崩溃重载的冷却窗口（5s 内最多 2 次，防止必崩页面无限刷）
    private var crashReloadCount = 0
    private var lastCrashReloadAt = Date.distantPast
    // 401 重铸配额：一次导航只重铸一次，避免凭证真失效时死循环
    private var authRepairAttempted = false

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
        resampleChrome()   // 系统外观可能在这期间变过，页面不会主动通知
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
        // 页面底色回传通道：脚本实测底色 → 原生给标题栏上色（见 chromeScript 注释）
        configuration.userContentController.addUserScript(
            WKUserScript(source: chromeScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
        configuration.userContentController.add(self, name: "dshChrome")
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        if #available(macOS 13.3, *) { webView.isInspectable = true }

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
            styleMask: baseStyleMask,
            backing: .buffered,
            defer: false
        )
        window.title = "DeepSeek Harness"
        window.minSize = NSSize(width: 900, height: 600)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.delegate = self
        // 标题栏透明 + 窗口底色 = 页面底色：页面加载前先用与连接页一致的深色，
        // 加载完由 chromeScript 回传的真实底色覆盖。
        window.titlebarAppearsTransparent = true
        applyChrome(NSColor(srgbRed: 0.09, green: 0.094, blue: 0.11, alpha: 1))
        // 用普通容器承载 WKWebView，而不是让 webView 直接当 contentView（2026-11-03）：
        // 直接当的话，WebKit 元素全屏进出后窗口/contentView 的 frame 账容易算错，
        // 标题栏会变成浮在内容上的透明层、交通灯掉进内容区。
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 860))
        container.autoresizesSubviews = true
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        window.contentView = container
        if !window.setFrameUsingName("dshMainWindow") { window.center() }
        window.setFrameAutosaveName("dshMainWindow")
        window.makeKeyAndOrderFront(nil)
        activateApp()

        // 启动稳定后记一次正常几何，后面靠它判断标题栏是否被全屏搞乱
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.captureHealthyBaseline()
        }
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
        authRepairAttempted = false
        shellLog("connect: ensuring service")
        loadMessagePage(title: "正在连接 dsh web…", detail: nil)

        ensureService { [weak self] ready in
            guard let self else { return }
            guard ready else {
                self.connecting = false
                self.loadMessagePage(
                    title: "无法连接 dsh web",
                    detail: "服务 30 秒内没有就绪。请查看 ~/.dsh/web.err.log，或按 ⇧⌘R 重试；"
                        + "「视图」菜单里也有「重启服务」与「服务状态」。"
                )
                return
            }
            switch mintAuthCookie(for: dshURL) {
            case .success(let cookie):
                self.setCookie(cookie) {
                    self.connecting = false
                    shellLog("connect: loading \(dshURL.absoluteString)")
                    self.webView.load(URLRequest(url: dshURL))
                }
            case .failure(let failure):
                // 具体原因写进错误页与日志（只记 reason，不记值）——笼统提示会把
                // 「格式变了」误报成「DSH 没启动过」，排障走错方向。
                self.connecting = false
                shellLog("auth: cookie minting failed (reason=\(failure.logReason))")
                self.loadMessagePage(
                    title: "无法生成访问凭据",
                    detail: "\(failure.hint)\n按 ⇧⌘R 重试。"
                )
            }
        }
    }

    private func setCookie(_ cookie: HTTPCookie, then completion: @escaping () -> Void) {
        WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie) {
            DispatchQueue.main.async(execute: completion)
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
            let result = runScriptSync(script.path, ["--ensure"])
            shellLog("ensure: exit=\(result.status)\(result.output.isEmpty ? "" : " output=\(result.output)")")
            DispatchQueue.main.async { completion(result.status == 0) }
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
        </style></head><body data-ds-dark-theme><div><h1>\(escapedTitle)</h1>\(detailBlock)</div></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    private func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - 标题栏跟随页面底色

    // 底色 → 标题栏。window.backgroundColor 负责「颜色」，appearance 负责「交通灯和
    // 标题字的明暗」，两件事必须一起改：深底 + 浅色 appearance 会出现一排看不清的浅灰按钮。
    //
    // **appearance 只许设在标题栏容器上，不许设 window.appearance**：NSWindow 的
    // appearance 会下传到 WKWebView，把页面的 prefers-color-scheme 锁死。2026-10-27
    // 实测：设成 .aqua 后页面 matchMedia 从 dark 变 light（系统当时是深色）——dsh 的
    // 主题来自 data-ds-theme-source，这种「壳反过来改页面」的污染比标题栏色差危险得多。
    private func applyChrome(_ color: NSColor) {
        guard let srgb = color.usingColorSpace(.sRGB), window != nil else { return }
        if let current = chromeColor, current == srgb { return }
        chromeColor = srgb
        window.backgroundColor = srgb
        let luma = 0.2126 * srgb.redComponent + 0.7152 * srgb.greenComponent + 0.0722 * srgb.blueComponent
        // closeButton.superview² = NSTitlebarContainerView，只覆盖标题栏那一条
        if let titlebar = window.standardWindowButton(.closeButton)?.superview?.superview {
            titlebar.appearance = NSAppearance(named: luma < 0.5 ? .darkAqua : .aqua)
        }
        shellLog(String(format: "chrome: #%02X%02X%02X", Int(srgb.redComponent * 255),
                        Int(srgb.greenComponent * 255), Int(srgb.blueComponent * 255)))
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "dshChrome",
              let body = message.body as? [String: Any],
              let rgb = body["rgb"] as? [Any], rgb.count == 3,
              let r = (rgb[0] as? NSNumber)?.doubleValue,
              let g = (rgb[1] as? NSNumber)?.doubleValue,
              let b = (rgb[2] as? NSNumber)?.doubleValue else { return }
        applyChrome(NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1))
    }

    private func resampleChrome() {
        webView.evaluateJavaScript("window.__dshChromeResample && window.__dshChromeResample()") { _, _ in }
    }

    // 强制重贴一次标题栏底色：修复动作会冲掉透明标题栏下的 appearance，
    // 而 applyChrome 按 chromeColor 去重 —— 先把缓存清掉再贴。
    private func reapplyChrome() {
        guard let color = chromeColor else { return }
        chromeColor = nil
        applyChrome(color)
    }

    // MARK: - 标题栏自愈（全屏退出后标题栏/交通灯错位）

    // 为什么要这一整套（2026-11-03）：WebKit 元素全屏（isElementFullscreenEnabled）
    // 进出后，窗口常残留 .fullSizeContentView —— 标题栏变成浮在内容上的透明层，
    // 红黄绿三个按钮位置错乱甚至掉进内容区。这是 WebKit 通用坑，不是 dsh 特有；
    // LibreTV-shell 已踩过并给出「几何判据 + 四步递进修复」，这里照搬并保留 dsh 的
    // 透明标题栏（修复第 ④ 步会把 titlebarAppearsTransparent 拨回去，必须重贴底色）。
    //
    // 判据全部相对窗口自身几何，不依赖绝对坐标（窗口尺寸可变）。

    private func fmt(_ r: NSRect) -> String {
        String(format: "%.0f,%.0f %.0fx%.0f", r.minX, r.minY, r.width, r.height)
    }

    private func fmt(_ p: NSPoint) -> String {
        String(format: "%.1f,%.1f", p.x, p.y)
    }

    /// 红绿灯（关闭按钮）中心点，换算到窗口坐标系
    private func closeButtonCenterInWindow() -> NSPoint? {
        guard let button = window.standardWindowButton(.closeButton),
              let superview = button.superview else { return nil }
        return superview.convert(NSPoint(x: button.frame.midX, y: button.frame.midY), to: nil)
    }

    /// 标题栏高度 = 窗口高 - 内容布局区高。正常约 28；被 .fullSizeContentView 吃掉时变 0
    private var titleBarHeight: CGFloat {
        max(0, window.frame.height - window.contentLayoutRect.height)
    }

    private func captureHealthyBaseline() {
        guard let center = closeButtonCenterInWindow() else { return }
        healthyCloseCenter = center
        shellLog("baseline: close=\(fmt(center)) barH=\(titleBarHeight) mask=\(window.styleMask.rawValue) frame=\(fmt(window.frame))")
    }

    /// 标题栏是否被搞乱：按钮相对左边距应与基准一致、应垂直居中于标题栏、标题栏高度应正常
    private func titleBarIsBroken() -> Bool {
        guard !window.styleMask.contains(.fullScreen) else { return false }
        guard let baseline = healthyCloseCenter else { return false }
        guard let center = closeButtonCenterInWindow() else {
            return window.styleMask.contains(.titled)   // 该有按钮却没有 = 已坏
        }
        if abs(center.x - baseline.x) > 3 { return true }
        let bar = titleBarHeight
        if bar < 20 { return true }                                    // 标题栏被内容吃掉
        if center.y < window.contentLayoutRect.height { return true }   // 按钮掉进内容区
        if center.y > window.frame.height { return true }               // 按钮顶出窗口
        let expectedY = window.frame.height - bar / 2
        if abs(center.y - expectedY) > 6 { return true }                // 未垂直居中
        return false
    }

    private func scheduleTitleBarRepair(_ reason: String, delay: TimeInterval) {
        pendingRepair?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRepair = nil
            self.repairTitleBarIfNeeded(reason)
        }
        pendingRepair = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func repairTitleBarIfNeeded(_ reason: String) {
        guard window != nil, !window.styleMask.contains(.fullScreen) else { return }
        guard !repairing else { return }
        guard titleBarIsBroken() else {
            repairAttempts = 0
            return
        }
        // 冷却（自愈动作会自身触发 resize/becomeKey）：被挡下就排一次重试，
        // 但不无限重排——最多 6 次仍修不好就记日志收手。
        if Date().timeIntervalSince(lastRepairAt) < 1.0 {
            guard repairAttempts < 6 else { return }
            repairAttempts += 1
            scheduleTitleBarRepair("\(reason) retry", delay: 1.2)
            return
        }

        repairing = true
        lastRepairAt = Date()
        defer { repairing = false }

        shellLog("titlebar broken (\(reason)): close=\(closeButtonCenterInWindow().map { fmt($0) } ?? "nil") barH=\(titleBarHeight) mask=\(window.styleMask.rawValue) frame=\(fmt(window.frame))")

        // ① 复位样式掩码：WebKit 全屏常残留 .fullSizeContentView，标题栏会变成浮层
        if window.styleMask != baseStyleMask {
            window.styleMask = baseStyleMask
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            if !titleBarIsBroken() { shellLog("repair ok: styleMask reset"); return }
        }

        // ② 尺寸微调 1pt 再还原，逼 AppKit 按新宽度重排标题栏与交通灯
        let frame = window.frame
        window.setFrame(NSRect(x: frame.minX, y: frame.minY, width: frame.width + 1, height: frame.height),
                        display: true)
        window.setFrame(frame, display: true)
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        if !titleBarIsBroken() { shellLog("repair ok: frame nudge"); return }

        // ③ 翻转 .titled 位，让 AppKit 重建标题栏容器
        window.styleMask = baseStyleMask.subtracting(.titled)
        window.styleMask = baseStyleMask
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        if !titleBarIsBroken() { shellLog("repair ok: titled toggle"); return }

        // ④ 刷新透明标题栏状态（会连带重算交通灯位置）。
        //    dsh 的设计是「标题栏透明 + 窗口底色 = 页面底色」，所以这里必须落回
        //    true，并把底色/appearance 重贴一次，否则标题栏会退回系统灰。
        window.titlebarAppearsTransparent = false
        window.titlebarAppearsTransparent = true
        reapplyChrome()
        shellLog(titleBarIsBroken() ? "repair failed: still broken" : "repair ok: titlebar refresh")
    }

    // MARK: - 全屏与窗口几何事件

    func windowWillEnterFullScreen(_ notification: Notification) {
        savedFrameBeforeFullScreen = window.frame
        shellLog("enter fullscreen: saved=\(fmt(window.frame))")
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        shellLog("did enter fullscreen: frame=\(fmt(window.frame))")
        scheduleTitleBarRepair("didEnterFullScreen", delay: 0.3)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        shellLog("did exit fullscreen: frame=\(fmt(window.frame))")
        // WebKit 元素全屏常把窗口撑到整屏却不缩回：恢复到进全屏前的尺寸
        if let saved = savedFrameBeforeFullScreen {
            savedFrameBeforeFullScreen = nil
            let screenHeight = window.screen?.visibleFrame.height ?? 0
            if saved.width > 0, window.frame.height >= screenHeight - 2 {
                window.setFrame(saved, display: true)
                shellLog("restored frame: \(fmt(saved))")
            }
        }
        scheduleTitleBarRepair("didExitFullScreen", delay: 0.25)
    }

    func windowDidResize(_ notification: Notification) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        scheduleTitleBarRepair("resize", delay: 0.3)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        scheduleTitleBarRepair("becomeKey", delay: 0.2)
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
        // ⌘R = 刷页面（快路径，保 cookie 与会话）；⇧⌘R = 重跑 ensure + 重铸 cookie。
        // 原来只有一项、且执行的是 connect()，于是「想刷一下」要等探测最多 30s（P1-1）。
        let reloadItem = NSMenuItem(title: "重新载入", action: #selector(reloadPage(_:)), keyEquivalent: "r")
        reloadItem.target = self
        viewMenu.addItem(reloadItem)
        let reconnectItem = NSMenuItem(title: "重新连接", action: #selector(reconnectService(_:)), keyEquivalent: "r")
        reconnectItem.keyEquivalentModifierMask = [.command, .shift]
        reconnectItem.target = self
        viewMenu.addItem(reconnectItem)
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
        viewMenu.addItem(.separator())
        // 排障入口（P1-2）：服务卡住时不必开终端跑 dsh-restart / tail 日志。
        let restartItem = NSMenuItem(title: "重启服务", action: #selector(restartService(_:)), keyEquivalent: "")
        restartItem.target = self
        viewMenu.addItem(restartItem)
        let shellLogItem = NSMenuItem(title: "打开壳日志", action: #selector(openShellLog(_:)), keyEquivalent: "")
        shellLogItem.target = self
        viewMenu.addItem(shellLogItem)
        let serviceLogItem = NSMenuItem(title: "打开服务日志", action: #selector(openServiceLog(_:)), keyEquivalent: "")
        serviceLogItem.target = self
        viewMenu.addItem(serviceLogItem)
        let statusItem = NSMenuItem(title: "服务状态", action: #selector(showServiceStatus(_:)), keyEquivalent: "")
        statusItem.target = self
        viewMenu.addItem(statusItem)

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

    // ⌘R：快路径，只刷当前页（保 cookie 与页面会话）。若当前是错误占位页
    // （loadHTMLString，非 http 页），刷新没有意义，退回完整重连。
    @objc private func reloadPage(_ sender: Any?) {
        let live = webView.url?.absoluteString.hasPrefix("http") == true
        guard live else {
            shellLog("reload: no live page, falling back to connect")
            connect()
            return
        }
        shellLog("reload: \(webView.url?.absoluteString ?? "?")")
        webView.reload()
    }

    // ⇧⌘R：慢路径，重跑 ensure + 重铸 cookie。
    @objc private func reconnectService(_ sender: Any?) { connect() }

    @objc private func showMainWindow(_ sender: Any?) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        activateApp()
    }
    @objc private func zoomIn(_ sender: Any?) { webView.pageZoom = min(webView.pageZoom + 0.1, 3.0) }
    @objc private func zoomOut(_ sender: Any?) { webView.pageZoom = max(webView.pageZoom - 0.1, 0.5) }
    @objc private func zoomReset(_ sender: Any?) { webView.pageZoom = 1.0 }

    // MARK: - 排障入口（P1-2）

    private func homePath(_ relative: String) -> String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(relative).path
    }

    private func alert(_ title: String, _ detail: String) {
        let panel = NSAlert()
        panel.messageText = title
        panel.informativeText = detail
        panel.alertStyle = .informational
        panel.runModal()
    }

    @objc private func restartService(_ sender: Any?) {
        let script = homePath(".npm-global/bin/dsh-restart")
        guard FileManager.default.fileExists(atPath: script) else {
            alert("找不到 dsh-restart", "\(script) 不存在，先跑一次 bash build.sh 安装命令行工具。")
            return
        }
        shellLog("menu: restart service")
        loadMessagePage(title: "正在重启 dsh web…", detail: "通常几秒即可，完成后会自动重新连接。")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = runScriptSync(script, [])
            guard let self else { return }
            DispatchQueue.main.async {
                shellLog("restart: exit=\(result.status)\(result.output.isEmpty ? "" : " output=\(result.output)")")
                if result.status == 0 {
                    self.connect()
                } else {
                    self.alert("重启服务失败", result.output.isEmpty
                        ? "dsh-restart 退出码 \(result.status)。详情见 ~/.dsh/web.err.log。"
                        : result.output)
                }
            }
        }
    }

    @objc private func openShellLog(_ sender: Any?) { openLog(homePath(".dsh/shell.log")) }
    @objc private func openServiceLog(_ sender: Any?) { openLog(homePath(".dsh/web.err.log")) }

    // 日志没有关联的默认程序时 open 会返回 false，退回「在访达中显示」，
    // 至少让用户能拿到文件而不是点了没反应。
    private func openLog(_ path: String) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            alert("日志还不存在", url.path)
            return
        }
        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    // 状态判据全部来自既有脚本/服务，壳自己不另立一套：ensure 退出码 + HTTP 码。
    @objc private func showServiceStatus(_ sender: Any?) {
        guard let script = Bundle.main.url(forResource: "launcher", withExtension: "sh") else {
            alert("服务状态", "bundle 里缺少 launcher.sh，请重跑 bash build.sh。")
            return
        }
        shellLog("menu: service status")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = runScriptSync(script.path, ["--ensure"])
            let code = probeHTTPCode()
            guard let self else { return }
            DispatchQueue.main.async {
                shellLog("status: ensure=\(result.status) http=\(code)")
                let ready = result.status == 0 && isReadyCode(code)
                var lines = [
                    "HTTP \(code)（401/2xx/3xx 视为就绪）",
                    "launcher.sh --ensure 退出码 \(result.status)",
                ]
                if !ready { lines.append("最近错误见 ~/.dsh/web.err.log。") }
                self.alert(ready ? "dsh web 就绪" : "dsh web 未就绪", lines.joined(separator: "\n"))
            }
        }
    }

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
        if !isLocal(url) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    // 主框架 401 = cookie 过期（有效期 30 天）或已丢失。原来只会在 connect() 里 mint，
    // 于是过期后页面永远停在认证墙，只能靠「重连」这一路手动补救（P1-3）。
    // 这里拦一次、重铸一次再 reload；配额用尽就放行，让服务端的认证页正常显示，
    // 避免凭证真失效时无限 reload。
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard navigationResponse.isForMainFrame,
              let http = navigationResponse.response as? HTTPURLResponse else {
            decisionHandler(.allow)
            return
        }
        guard http.statusCode == 401 else {
            authRepairAttempted = false   // 正常响应：重置重铸配额
            decisionHandler(.allow)
            return
        }
        guard !authRepairAttempted else {
            authRepairAttempted = false
            shellLog("auth: still 401 after re-mint, showing server page")
            decisionHandler(.allow)
            return
        }
        switch mintAuthCookie(for: dshURL) {
        case .success(let cookie):
            authRepairAttempted = true
            shellLog("auth: re-minted after 401")
            setCookie(cookie) { webView.reload() }
            decisionHandler(.cancel)
        case .failure(let failure):
            // 重铸失败与「过期重铸」必须能分开看，否则日志会把格式问题误读成过期
            shellLog("auth: 401 and re-mint failed (reason=\(failure.logReason))")
            decisionHandler(.allow)
        }
    }

    // WebKit 的内容进程被系统回收（内存压力、页面 OOM）时，窗口会停在纯灰底、
    // 页面无响应，只有 reload 才重新拉起进程（保 cookie、等价于刷页面）。
    // 冷却：必崩的页面无限重载只会刷日志，5s 内超过 2 次就转错误页（P0-1）。
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        shellLog("web content process terminated: reloading")
        let now = Date()
        if now.timeIntervalSince(lastCrashReloadAt) > 5 { crashReloadCount = 0 }
        lastCrashReloadAt = now
        crashReloadCount += 1
        guard crashReloadCount <= 2 else {
            shellLog("web content process terminated: too frequent, stopping auto-reload")
            loadMessagePage(
                title: "页面进程反复崩溃",
                detail: "已暂停自动刷新（5 秒内第 \(crashReloadCount) 次）。按 ⇧⌘R 重新连接。"
            )
            return
        }
        webView.reload()
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
        loadMessagePage(title: "页面加载失败", detail: "\(error.localizedDescription)\n按 ⇧⌘R 重新连接。")
    }

    // MARK: - WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { openExternallyOrInPlace(url) }
        return nil
    }

    private func openExternallyOrInPlace(_ url: URL) {
        guard let scheme = url.scheme?.lowercased() else { return }
        if (scheme == "http" || scheme == "https"), isLocal(url) {
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
