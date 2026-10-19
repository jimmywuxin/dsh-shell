# 从 Edge `--app` 迁到原生 WKWebView 壳

> **读者**：杨杨（WorkBuddy）
> **目标项目**：`~/dev/opencode-shell`（当前 HEAD `bffd82b`，工作区干净）
> **参考实现**：`~/dev/dsh-shell` v1.1.0（commit `c34f67d`），核心文件 `src/DshApp.swift`、`src/launcher.sh`、`build.sh`
> **一句话**：把「启动器 exec Edge `--app`」换成「原生 NSWindow + WKWebView」，红叉改成**隐藏窗口**（飞书式：Dock 只留应用图标、不留窗口缩略图，点图标恢复）。服务层（launchd / supervisor）不动。

---

## 0. 先看结论（TL;DR）

1. **Edge `--app` 窗口的红叉改不了**：窗口按钮归 Chromium 进程，红叉 = 关闭窗口，关掉最后一个窗口 Edge 即退出；没有命令行开关能改。唯一办法是换成自家 `NSWindow`。
2. 原生壳的关键只有一行：`windowShouldClose` 返回 `false`，并调 `window.orderOut(nil)`。**不要用 `performMiniaturize`**——那是黄点的行为，会在 Dock 里留窗口缩略图，与飞书不一致；**也不要用 `NSApp.hide`**，那会把菜单栏一起藏掉。
3. opencode 的认证不要照抄 dsh 的 cookie 铸造逻辑。opencode 走 `opencode pair` 打印的一次性 `/auth/connect/<token>` 链接，浏览器打开后由服务端 `302 + Set-Cookie` 种下 30 天会话 cookie。原生壳只需**启动时向 launcher 要一个目标 URL 并加载它**。
4. **pair token 是凭据**：URL 不能写日志、不能打印、不能进 commit；壳的 `shell.log` 只记「拿到 URL / 页面标题 / cookie 数量」，不记 URL 全文。

---

## 1. 为什么必须换壳（dsh-shell 的实测结论）

在 dsh-shell 上逐项验证过，换到 opencode 同理：

- Edge/Chrome 的 `--app` 窗口由浏览器进程创建，红叉是 `NSWindow` 的标准关闭按钮，点击 → Chromium 关闭窗口 → 最后一个窗口关闭时浏览器退出。没有 `--app-close-hides` 这类开关。
- 外部改不了：窗口按钮的 enabled/action 由浏览器内部设置；用 AppleScript / CGEvent 拦截需要「辅助功能」权限，本机没有（`osascript ... System Events` 报 `-10004`）。
- 换 Electron 能保住 Chromium 渲染，但包体约 200MB，且完全偏离「纯 UI 壳」的定位，不推荐。
- 结论：**只有原生 NSWindow 能定义「红叉做什么」**。WKWebView 只是窗口里的一块渲染视图。

---

## 2. 目标行为（验收定义）

按飞书/Slack 的单窗口习惯：

| 操作 | 期望 |
|---|---|
| 点左上角**红叉** | 窗口从桌面消失；**Dock 里不留窗口缩略图**；应用继续运行、图标留在 Dock；页面状态不丢 |
| 点 Dock 里的 **OpenCode 图标** | 窗口重新出现（`applicationShouldHandleReopen` / `applicationDidBecomeActive`） |
| 再点红叉（窗口已隐藏） | 无操作（窗口本来就不在） |
| `⌘W` | 与红叉一致：隐藏窗口 |
| `⌘Q` | 真正退出应用 |
| 点**黄点** / `⌘M` | 标准最小化：窗口进 Dock 右侧缩略图（与红叉区分开，保留 macOS 原生行为） |
| `⌘R` | 重新连接（重新 ensure 服务、重新取 pair URL、重新加载） |

**错误做法对照**：

| 写法 | 结果 | 评价 |
|---|---|---|
| `sender.performMiniaturize(nil)` | 窗口缩到 Dock 右侧，有缩略图 | ❌ 不是飞书效果 |
| `NSApp.hide(nil)` | 整个应用隐藏，菜单栏切走 | ❌ 不是飞书效果 |
| `sender.close()`（不拦 delegate） | 窗口被释放；再点图标没有窗口 | ❌ 状态丢失，容易崩 |
| `sender.orderOut(nil)` + 阻止关闭 | 窗口隐藏、应用在 Dock、点图标恢复 | ✅ 采用 |

---

## 3. 改造总览

### 3.1 改造前（opencode-shell 现状）

```
launchd ai.opencode.web
  └─ supervisor.sh（常驻探活，拉起 opencode service）
        └─ http://127.0.0.1:49374

opencode.app
  └─ Contents/MacOS/opencode = src/launcher.sh
        ├─ 探活 → opencode pair 取一次性链接
        └─ exec Edge --app（独立 profile ~/.local/share/opencode/edge-profile）
```

### 3.2 改造后

```
launchd ai.opencode.web            ← 不动
  └─ supervisor.sh                 ← 不动
        └─ http://127.0.0.1:49374

opencode.app
  ├─ Contents/MacOS/opencode = 编译出的 Swift 原生壳
  │     ├─ 调 Contents/Resources/launcher.sh --url 等服务就绪并拿目标 URL
  │     ├─ WKWebView 加载该 URL（pair 链接会种 cookie）
  │     └─ 红叉 = orderOut；Dock 图标 = 恢复
  └─ Contents/Resources/launcher.sh = 只负责 ensure + 打印 URL
```

### 3.3 保留 / 删除 / 新增

| 类别 | 内容 |
|---|---|
| **保留不动** | `src/supervisor.sh`、`src/ai.opencode.web.plist`、launchd label `ai.opencode.web`、端口 49374、`opencode pair` 认证方式、构建产物路径 `~/Applications/opencode.app` |
| **删除** | launcher 里的 `BROWSER` / `BROWSER_PROFILE` / `open_window` / `reap_zombie_browser` / `disable_browser_translate` / Edge 的 `--no-first-run` 等全部浏览器逻辑 |
| **新增** | `src/ShellApp.swift`（或 `OpencodeApp.swift`）；launcher 的 `--url` 模式；`build.sh` 里 `swiftc` 编译 + 资源打包 + ATS + ad-hoc 签名 |
| **迁移后清理** | `~/.local/share/opencode/edge-profile`（确认新壳稳定后删） |

改造后 opencode-shell 的改动文件清单：**新增** `src/ShellApp.swift`；**修改** `src/launcher.sh`、`build.sh`、`src/Info.plist`、`README.md`、`CHANGELOG.md`；**不动** `src/supervisor.sh`、`src/ai.opencode.web.plist`。

---

## 4. 前置核查（先做，别急着改）

1. **读三份文件**：`~/dev/opencode-shell/src/launcher.sh`、`src/supervisor.sh`、`build.sh`，确认：
   - 端口 49374、URL 常量、launchd label；
   - `pair_url()` 怎么取链接、`ready_or_open()` 的就绪判据；
   - `opencode pair` 的输出格式是否稳定（当前正则：`http://127\.0\.0\.1:[0-9]*/auth/connect/[A-Za-z0-9_-]*`）。
2. **确认 opencode Web UI 的登录态**：未登录时 HTTP 仍是 200（README 已写），所以**不能靠状态码判断是否已登录**；验收要看页面内容/是否存在会话 cookie。
3. **先验证 WebKit 能跑 opencode UI**（关键，别等壳写完才发现渲染不兼容）：
   - 用 `opencode pair` 取一个链接；
   - 写一个临时 Swift `.app`（见 §6.3 的探针思路），`WKWebView` 加载该链接；
   - `evaluateJavaScript` 读取 `document.title`、`document.body.innerText.length`、`document.querySelectorAll('*').length`；
   - 若需要看图，用 `webView.takeSnapshot(with:)` 存 PNG（不需要屏幕录制权限；`screencapture` 在本机对 agent 进程会报 `could not create image from display`）。
   - dsh-shell 的基准：`DeepSeek Harness` 标题、808 个元素、点开会话后正文 12,857 字、无 JS 报错。
   - 如果探针里出现白屏/JS 报错：先注入 `window.onerror` 收集错误，确认是 WebKit 兼容性问题再决定退路（继续用 Edge 壳、或换 Electron 保 Chromium）。**不要为了换壳牺牲 UI 可用性。**
4. **安全边界**：pair URL 里的 token 等同于登录凭据。所有临时探针、日志、截图都要避免把它写进文件；探针结束删掉临时 `.app` 和 URL。

---

## 5. 分步实施

### 5.1 `src/launcher.sh` 收缩为「ensure + 打印 URL」

保留服务拉起逻辑（launchd 两级兜底、失效锁、20s/30s 就绪等待），删掉所有浏览器代码，新增 `--url`：

```bash
#!/bin/bash
# opencode.app 启动检查：确保服务就绪，并把要加载的 URL 打印到 stdout。
# 由原生壳调用：/bin/bash launcher.sh --url
set -u

PORT=49374
URL="http://127.0.0.1:${PORT}"
LABEL="ai.opencode.web"
DOMAIN="gui/$(id -u)"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
OC="$HOME/.npm-global/bin/opencode"
LOG_DIR="$HOME/.local/share/opencode/log"

probe_code() {
  curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 2 "$URL/" 2>/dev/null
}

pair_url() {
  [ -x "$OC" ] || return 1
  local u
  u="$("$OC" pair 2>/dev/null | grep -o 'http://127\.0\.0\.1:[0-9]*/auth/connect/[A-Za-z0-9_-]*' | head -1)"
  [ -n "$u" ] || return 1
  printf '%s' "$u"
}

ensure_ready() {
  case "$(probe_code)" in 200|204|302|401) return 0 ;; esac
  # 这里保留 opencode 现有的 kickstart → bootstrap → 手工兜底逻辑；
  # 注意：本 shell 里 launchctl bootstrap 可能报 error 5，只有 .app 经
  # LaunchServices 启动时可用 —— 所以 ensure 必须由 .app 调，不要在终端里验证 bootstrap。
  ...
}

if [ "${1:-}" = "--url" ]; then
  ensure_ready || exit 1
  pair_url || printf '%s' "$URL"
  exit 0
fi
```

**契约（重要）**：

- `--url` 的 **stdout 只允许出现一个 URL**，不能有 echo/通知/进度；
- 失败时 exit 非 0，stdout 为空；
- `stderr` 可以放诊断信息，由壳决定是否记录（不要记录含 token 的 stdout）；
- 成功后 `pair_url()` 优先，拿不到才回落到裸 `$URL`（此时页面会停在 pairing 页，需要 `opencode pair` 手输一次）。

> 如果希望复用 dsh 的写法：把 `ensure_ready` 保持在 bash 里，只把「开窗」换成 Swift。**服务层一行都不要重写**。

### 5.2 Swift 壳最小骨架

新建 `src/ShellApp.swift`（命名随意，建议 `ShellApp.swift`），核心如下。完整版可直接对照 `~/dev/dsh-shell/src/DshApp.swift` 抄窗口/菜单/下载/文件选择部分。

```swift
import Cocoa
import WebKit

private let appDelegate = AppDelegate()

@main
struct ShellApp {
    static func main() {
        let app = NSApplication.shared
        app.delegate = appDelegate
        app.setActivationPolicy(.regular)   // 保证在 Dock 里有图标
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate,
                         WKNavigationDelegate, WKUIDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()    // cookie 要持久化
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "OpenCode"
        window.minSize = NSSize(width: 900, height: 600)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.delegate = self
        window.contentView = webView
        if !window.setFrameUsingName("shellMainWindow") { window.center() }
        window.setFrameAutosaveName("shellMainWindow")
        window.makeKeyAndOrderFront(nil)

        resolveTargetURL { [weak self] url in
            guard let self, let url else { self?.showError("服务未就绪或取 URL 失败"); return }
            self.webView.load(URLRequest(url: url))
        }
    }

    // 红叉 / ⌘W：隐藏窗口（飞书式），不是最小化
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    // 点 Dock 图标（应用已在运行时）
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    // 从 Cmd+Tab / 点图标激活：窗口被 orderOut 过就拉回来
    func applicationDidBecomeActive(_ notification: Notification) {
        guard window != nil else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        if !window.isVisible { window.makeKeyAndOrderFront(nil) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
```

`resolveTargetURL` 由壳执行 `launcher.sh --url` 并读 stdout：

```swift
private func resolveTargetURL(completion: @escaping (URL?) -> Void) {
    guard let script = Bundle.main.url(forResource: "launcher", withExtension: "sh") else {
        completion(nil); return
    }
    DispatchQueue.global(qos: .userInitiated).async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, "--url"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { completion(nil); return }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // ⚠️ 不要 log text：pair URL 里带 token；只 log 长度/成败
        let url = process.terminationStatus == 0 ? URL(string: text) : nil
        DispatchQueue.main.async { completion(url) }
    }
}
```

### 5.3 认证：opencode 用 pair URL，不要照抄 dsh 的 cookie

- opencode：`opencode pair` 打印 `http://127.0.0.1:49374/auth/connect/<token>`；用 WKWebView 加载后，服务端 `302 + Set-Cookie`，cookie 默认 30 天。
- 每次启动都取一个新 pair URL 最简单，也避免「cookie 过期后页面停在登录页」；代价是多一次 `opencode pair`（本地命令，几百毫秒）。
- 如果希望减少 pair：先加载裸 URL，检测到 pairing 页/无会话 cookie 再取 pair URL。**但不要用 HTTP 200 判断登录态**。
- pair token 可能一次性：**只加载一次**；加载失败就重新取，不要重放旧 URL。
- 服务端要靠 `Accept: text/html` 才回 302 + `Set-Cookie`（opencode-shell README 已记录）；WKWebView 主框架导航默认带这个头，若拿到的是非 302 页面，先查请求头。
- 不要复用 dsh 的「从 credentials 里 HMAC 铸 cookie」代码 —— 那是 dsh 服务端的内部协议，opencode 完全是另一套。

**日志纪律**：

- `~/.local/share/opencode/log/shell.log`（0600）只记：`ensure exit=`、`url acquired (len=…)`、`page title`、`cookie count`、错误信息；
- 不记完整 URL、不记 cookie 值、不记 pair token；
- 临时探针/自测日志也要遵守。

### 5.4 补齐浏览器能力（WKWebView 不会自动给）

按 opencode UI 的实际功能逐项补，最小集合：

```swift
// 1) <input type=file>：不实现这个，点「上传/附件」不会有任何反应
func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
             initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = parameters.allowsMultipleSelection
    panel.canChooseDirectories = parameters.allowsDirectories
    panel.canChooseFiles = true
    panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
}

// 2) target=_blank / window.open：外链交给默认浏览器，同源在本窗口加载
func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
             for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    if let url = navigationAction.request.url { openExternallyOrInPlace(url) }
    return nil
}

// 3) 主框架跳转到外部站点：别让壳变成浏览器，直接开系统浏览器并取消
func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
             decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard let url = navigationAction.request.url,
          navigationAction.targetFrame?.isMainFrame == true,
          let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
        decisionHandler(.allow); return
    }
    if url.host != "127.0.0.1" || (url.port ?? 80) != 49374 {
        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
        return
    }
    decisionHandler(.allow)
}
```

还需要：

- **下载**：`WKDownloadDelegate` + `NSSavePanel`（参考 dsh 的 `download(_:decideDestinationUsing:)`）。
- **媒体权限**：`requestMediaCapturePermissionFor` 决定 `.prompt`/`.deny`（opencode 用不到麦克风就 `.deny`）。
- **调试**：`webView.isInspectable = true`（macOS 13.3+），Safari「开发」菜单可查。
- **持久化**：`WKWebsiteDataStore.default()`，否则每次启动都掉登录态。

### 5.5 构建、打包、签名、ATS

照 dsh-shell 的 `build.sh` 改：

```bash
# 1) 编译原生壳（-parse-as-library 必须有：源文件用 @main，且文件里有全局 appDelegate）
/usr/bin/swiftc -O -parse-as-library src/ShellApp.swift \
  -o "$APP/Contents/MacOS/opencode"
# -parse-as-library 必须有：源文件里有 @main，单文件编译默认按脚本模式处理会冲突

# 2) launcher 从 MacOS 挪到 Resources
install -m 755 src/launcher.sh "$APP/Contents/Resources/launcher.sh"

# 3) Info.plist 追加 ATS（页面是 http://127.0.0.1:49374）
#    LSMinimumSystemVersion 提到 12.0（WKWebView/API 下限）
#    CFBundleExecutable 仍是 opencode，不必改

# 4) 全部资源就位后再 ad-hoc 签名
codesign --force --sign - "$APP"
```

> 发版顺序：先提交代码 → 打 tag → **再跑一次 `build.sh`**（`APP_VERSION` 来自 `git describe --tags`；dsh 实测发版后不重跑，app 里还是旧版本号）→ 最后发 Release。

`src/Info.plist` 追加：

```xml
<key>NSAppTransportSecurity</key>
<dict>
  <key>NSAllowsLocalNetworking</key><true/>
  <key>NSAllowsArbitraryLoads</key><true/>
</dict>
```

> 构建顺序建议沿用 dsh 的「先组装 `build/opencode.app.new`，成功后再换旧产物」；opencode 现在先 `mv` 旧 app 再组装，中途失败会留下空档。

### 5.6 菜单与快捷键

最小菜单（dsh 的 `buildMenu()` 可整段抄）：

- App 菜单：关于 / 隐藏 / 退出（`⌘Q`）
- 编辑：撤销/重做/剪切/拷贝/粘贴/全选（走 first responder，WKWebView 能接）
- 视图：`⌘R` 重新连接、`⌘+`/`⌘-`/`⌘0` 缩放、`⌃⌘F` 全屏
- 窗口：**显示主窗口**（隐藏后的兜底入口）、最小化（`⌘M`）、前置全部窗口

「显示主窗口」这一项很重要：万一某台 macOS 上 `applicationShouldHandleReopen` 没按预期触发，用户还能从菜单把窗口找回来。

---

## 6. 验收清单

### 6.1 静态与构建

```bash
cd ~/dev/opencode-shell
/usr/bin/swiftc -typecheck -parse-as-library src/ShellApp.swift
bash -n src/launcher.sh
bash build.sh                      # 不应再依赖 Edge；产物 ~/Applications/opencode.app
codesign -dv ~/Applications/opencode.app 2>&1 | head -3
plutil -p ~/Applications/opencode.app/Contents/Info.plist | grep -E 'CFBundleShortVersionString|NSAppTransportSecurity'
```

### 6.2 启动与页面

```bash
rm -f ~/.local/share/opencode/log/shell.log
open ~/Applications/opencode.app
sleep 5
tail -20 ~/.local/share/opencode/log/shell.log
pgrep -fl "opencode.app/Contents/MacOS/opencode"
lsof -nP -iTCP:49374 | grep ESTABLISHED
```

期望：

- 日志出现 `ensure exit=0`、`loaded`（**不含 URL/token**）、`page title: OpenCode`（或实际标题）；
- 进程存活；
- 有到 49374 的 ESTABLISHED（页面/WS）。

### 6.3 红叉行为自测（不需要点鼠标）

本机没有辅助功能权限，合成点击不可用。用一个**临时自测副本**验证 delegate 逻辑（不要 ship 这段）：

```swift
// 在 didFinish 后注入：
if ProcessInfo.processInfo.environment["SHELL_SELFTEST"] == "1" {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        self.window.performClose(nil)          // 等价于点红叉
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            shellLog("after close: visible=\(self.window.isVisible) miniaturized=\(self.window.isMiniaturized)")
            _ = self.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                shellLog("after reopen: visible=\(self.window.isVisible)")
                NSApp.terminate(nil)
            }
        }
    }
}
```

期望日志：

```
selftest after close: visible=false miniaturized=false
selftest after reopen: visible=true
```

做法：复制源码到 `/tmp/selftest/main.swift`，把 `selftest` 段注进去（`shellLog` 换成你的日志函数或 `print`）；临时 bundle 里放 `Contents/MacOS/opencode` + `Contents/Resources/launcher.sh` + Info.plist（bundle id 改成 `local.selftest`），直接执行二进制，设 `SHELL_SELFTEST=1`。跑完删掉临时 bundle。

### 6.4 人工验收（必须做一次）

1. 点红叉 → 窗口消失，**Dock 里不出现窗口缩略图**，OpenCode 图标还在；
2. 点 Dock 图标 → 窗口恢复，页面状态还在；
3. `⌘W` → 同红叉；
4. `⌘Q` → 退出；
5. 黄点/`⌘M` → 标准最小化（缩略图），说明两种行为都在；
6. 点一下附件/上传按钮 → 弹出 NSOpenPanel（不弹就是 5.4 未接）；
7. 点页面里的外链 → 默认浏览器打开，壳不跳到别的站点；
8. 点下载 → 弹 NSSavePanel（如果 UI 有下载功能）；
9. 关掉窗口后再点图标，确认登录态没丢（cookie 持久化）。

### 6.5 窗口/进程辅助检查

```swift
// CGWindowList：确认窗口属于 opencode.app 的 pid，标题正确
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w[kCGWindowOwnerName as String] as? String) == "OpenCode" {
    print(w[kCGWindowOwnerPID as String] ?? "", w[kCGWindowName as String] ?? "", w[kCGWindowBounds as String] ?? "")
}
```

---

## 7. 踩坑清单（dsh-shell 实测）

1. **`performMiniaturize` ≠ 飞书**：会留 Dock 缩略图。红叉用 `orderOut`。
2. **`NSApp.hide` 也不对**：菜单栏一起消失。窗口级隐藏只用 `orderOut`。
3. **`windowShouldClose` 必须返回 `false`**：否则窗口被关闭，隐藏后点图标没有窗口，`isReleasedWhenClosed` 设了也可能状态异常。
4. **`applicationShouldTerminateAfterLastWindowClosed` 要返回 false**：否则关闭窗口（即使被拦）或某些路径下应用会退出。
5. **`window.delegate = self`**：忘了设，`windowShouldClose` 根本不会被调用。
6. **`@main` + 全局 delegate**：单文件编译必须加 `-parse-as-library`，否则报「main attribute cannot be used in a module that contains top-level code」。
7. **ATS**：WKWebView 访问 `http://127.0.0.1` 需要在 Info.plist 放行；不加可能直接 `NSURLError`。
8. **`<input type=file>` 需要 `runOpenPanelWith`**：不实现，附件按钮静默无反应。
9. **`window.open` 需要 `createWebViewWith`**：不实现，页面里的新窗口链接没反应。
10. **外部链接要拦**：`decidePolicyFor` 里把非 `127.0.0.1:49374` 的主框架跳转交给 `NSWorkspace`，否则壳会被导航到外部站点，用户回不来。
11. **cookie 要持久化**：用 `.default()` data store；`nonPersistent()` 会让每次启动都掉登录。
12. **pair URL 只加载一次**：token 可能一次性；失败重新 `opencode pair`，不要重放。
13. **不要 log pair URL / cookie**：URL 里就是登录凭据；日志只记长度、状态码、页面标题。
14. **签名顺序**：先放二进制、launcher、Info.plist、图标，最后 `codesign`；反过来签名会失效。
15. **Dock 图标来自 app bundle**：确保 `Contents/Resources/AppIcon.icns`、`CFBundleIconFile`、`CFBundleName` 正确；否则 dock 里是白纸。
16. **菜单兜底**：加「窗口 → 显示主窗口」，防止某些激活路径不触发 reopen。
17. **不要同时开旧 Edge 壳和新壳**：两个客户端同时连服务（opencode/dsh 都允许），但用户会看到两个窗口；验收时先关旧 Edge 窗口。
18. **迁移后删 edge-profile**：`~/.local/share/opencode/edge-profile` 不再使用，确认稳定后删除可省几百 MB。
19. **本机环境限制**：`screencapture` 对 agent 进程无屏幕录制权限；用 `WKWebView.takeSnapshot` 或 DOM 读取。`osascript` 操作 System Events 需要辅助功能权限（没有），无法合成点击，所以红叉行为用 `performClose` 自测 + 人工点一次。
20. **launchctl 沙箱**：`launchctl bootstrap` 在 WorkBuddy/IDE shell 里可能报 `5: Input/output error`，只有 LaunchServices 启动的 `.app` 里可用；`ensure` 由壳（.app）调，别在终端里下结论。

---

## 8. 与 dsh-shell 的对照：哪些能抄，哪些不能

| 内容 | dsh-shell | opencode-shell 怎么处理 |
|---|---|---|
| 窗口/红叉/恢复/菜单 | `src/DshApp.swift` 可整段参考 | ✅ 直接抄窗口层 |
| 服务 ensure（launchd 兜底、失效锁） | `src/launcher.sh` + `dsh-lib.sh` | ⚠️ 照结构改，但 opencode 的 supervisor/plist 不同，**不要**引入 dsh 的 lib |
| 认证 | 从 `~/.dsh/.credentials.yaml` 的 `client-connection/browser-session` 密钥铸 HMAC cookie | ❌ **不要抄**；opencode 用 `opencode pair` 一次性链接 |
| URL/端口 | `127.0.0.1:3080` | `127.0.0.1:49374` |
| 构建/ATS/签名 | `build.sh` | ✅ 照改（Swift 编译 + Resources + ATS + ad-hoc） |
| 日志路径 | `~/.dsh/shell.log` | 建议 `~/.local/share/opencode/log/shell.log`（0600） |
| 旧 profile | `~/.dsh/edge-profile` | `~/.local/share/opencode/edge-profile` |

**不可照抄的根因**：dsh 的 cookie 是服务端内部协议（authority-bound HMAC，`v1.<body>.<sig>`），opencode 没有这套；opencode 的配对链接由 `opencode pair` 提供，走服务端 `Set-Cookie`，是更简单也更稳的路径。

---

## 9. 回滚

- 代码：opencode-shell 当前 HEAD `bffd82b` 是 Edge 壳版本，`git revert` 或 `git checkout bffd82b -- .` 即可回到旧实现。
- 产物：`build.sh` 会把旧 `~/Applications/opencode.app` 移到废纸篓（`opencode.app.bak-*`），随时可恢复。
- 服务层：`supervisor.sh` / launchd plist 不动，回滚不影响服务。
- 旧 Edge profile 在 `~/.local/share/opencode/edge-profile`，回滚后继续可用（别急着删，验收稳定再删）。

---

## 10. 参考索引

- dsh-shell 参考实现（v1.1.0，commit `c34f67d`）：
  - `~/dev/dsh-shell/src/DshApp.swift`：窗口 + 红叉隐藏 + 恢复 + 文件选择/外链/下载/菜单/认证
  - `~/dev/dsh-shell/src/launcher.sh`：`--ensure` 只等服务就绪（对比你的 `--url`）
  - `~/dev/dsh-shell/build.sh`：Swift 编译、launcher 放 Resources、ATS、ad-hoc 签名
  - `~/dev/dsh-shell/README.md` 的「2026-10-19 换壳」段、`CHANGELOG.md` 的 v1.1.0 段
- dsh-shell 的实测数据（可作为 WebKit 兼容性基准）：
  - 页面标题 `DeepSeek Harness`、808 个元素、点开会话后正文 12,857 字、无 JS 报错
  - 自测：`performClose` 后 `visible=false miniaturized=false`，`reopen` 后 `visible=true`
- opencode-shell 现状（改造前）：`~/dev/opencode-shell` HEAD `bffd82b`，端口 49374，`opencode pair` + Edge `--app`

---

**给杨杨的执行顺序**：先做 §4.3 的 WebKit 探针（半小时内能确认渲染是否可行）→ 改 launcher 的 `--url` → 写壳（先只做窗口 + 红叉）→ 接 pair URL → 补文件选择/外链/下载 → 改 build → §6 全量验收 → 更新 README/CHANGELOG → 发版。
