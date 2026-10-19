# CHANGELOG

本项目的版本号按**功能里程碑**给，不按 commit 数给。修 bug 不升版本号。

## v1.1.0 — 2026-10-19

**动机**：Edge `--app` 窗口的红叉由 Chromium 写死为「关闭窗口」，关掉最后一个窗口浏览器即退出，没有开关能改掉「关闭窗口」这个行为。改成原生 NSWindow + WKWebView 后，`windowShouldClose` 改为 `orderOut`：红叉隐藏窗口（飞书式，Dock 只留应用图标、不留缩略图），点 dock 图标恢复，应用与页面状态常驻。

### 改动

- 新增 **`src/DshApp.swift`**（原生壳）：红叉→隐藏窗口（飞书式）、cookie 认证、`<input type=file>` → NSOpenPanel、`target=_blank`/外链 → 默认浏览器、下载 → NSSavePanel、⌘R 重连、缩放/全屏/编辑菜单；`webView.isInspectable = true` 供 Safari 检查
- **认证**：用 `~/.dsh/.credentials.yaml` 的 `client-connection/browser-session` 签名密钥现场 mint cookie（`dsh-auth-<base64url(sha256(authority))>`、`v1.<body>.<base64url(HMAC)>`），不再依赖 web.log 里那批已失效的 token URL（逐条实测全 401）
- **`src/launcher.sh` 收缩**为「只等服务就绪」（`--ensure`，由壳调用）；删掉 Edge 窗口、独立 profile、翻译气泡、zombie 清理、token 兜底
- **`build.sh`**：`swiftc -O -parse-as-library` 编译 → `Contents/MacOS/dsh`；`launcher.sh` 移到 `Contents/Resources/`；Info.plist 补 ATS（loopback）与 LSMinimumSystemVersion 12.0；app 做 ad-hoc 签名
- README 的架构图、目录结构、决策记录同步

### 验证

- 编译无 error，`bash build.sh` 全程通过，app 落在 `~/Applications/dsh.app`
- 启动后 `~/.dsh/shell.log`：`ensure: exit=0` → `loaded: http://127.0.0.1:3080/` → `page title: DeepSeek Harness`
- `WebKit.Networking` 与 3080 建多条 ESTABLISHED；WebKit 数据目录落在 `~/Library/WebKit/com.jimmy.dsh-shell/`
- **红叉行为自测**：用同一份壳代码注入自测分支，`performClose` 后 `visible=false miniaturized=false`，reopen 后 `visible=true`，进程存活
- 窗口首启 1280×860 居中；窗口标题 `DeepSeek Harness`，Dock 图标为 dsh 自己的

### 代价

- 渲染引擎从 Chromium 换成 WebKit（实测页面、会话、WebSocket 均正常）
- 没有 Edge DevTools；需要时用 Safari「开发」菜单检查本 app
- 少数浏览器能力由壳实现（页面内查找等未覆盖的按需再补）

## v1.0.2 — 2026-10-18

配置与流程加固：修 4 处缺陷，无新功能。

### 改动

- **plist 补 `WorkingDirectory`=HOME**：launchd 默认 cwd 是 `/`（`lsof -a -p <pid> -d cwd`
  实测），而 dsh 把 `process.cwd()` 传进 `profileContext` 并 spawn 子进程 —— 相对路径
  会落到只读的根目录。现显式钉在 `@HOME@`
- **plist 补 `Umask`=63（0o077）**：`web.log` 里记录了带 token 的入口 URL（launcher 的
  401 兜底要从这里抓），默认 umask 022 生成 644，同机其他账户可读到 token、进而打开
  loopback 上带认证的完整 GUI。`build.sh` 同时对已有日志 `chmod 600`（plist 的 Umask
  要重启服务才生效）
- **`release.sh` 补 PATH**：`gh` 在 `/opt/homebrew/bin`，精简 PATH 下 `command -v gh`
  失败 → 卡在「tag 已推、Release 未建」再 exit 1（2026-09-14 实踩过）
- **`launcher.sh` 的 token 正则从 `$URL` 派生**：原来写死 `127.0.0.1:3080`，改
  端口/主机要动两处
- **`Info.plist` 版本号改由 `build.sh` 从 git tag 注入**（`v1.0.2` → `1.0.2`，
  `CFBundleVersion` 用 commit 数）。此前写死 `1.0/1`，发了 v1.0.1 后 app 里还显示 1.0

### 验证

- 6 个脚本 `bash -n` 全过；`bash src/dsh-lib.sh` 自检 OK
- 渲染后 plist `plutil -lint` 通过，`WorkingDirectory`/`Umask` 落成绝对路径与整数
- 装配出的 `Info.plist` 读回 `CFBundleShortVersionString = 1.0.2`

### 部署注意

`WorkingDirectory` / `Umask` 要服务重新装载才生效（`bash build.sh --reload`，需真终端；
或重启电脑）。`build.sh` 默认只更新 plist 文件、不 bootout（本 shell 里 bootstrap 必失败）。

## v1.0.1 — 2026-10-06

过设计审查（ponytail）后的维护版：6 处删减 + 1 处抽象回收，**功能与行为等价**，
无新功能（按本文档开头的约定，这类改动本不升版本号；因需独立归档改动集而发 patch 版）。

### 改动

- **就绪判据收回一处**：`app_ready` 改为接受可选状态码 `${1:-$(probe_code)}`，
  `launcher.sh` 的 `ready_or_open` 不再自己抄一份 `000|404|5*`
- **`launchd_start()` 删除、兜底内联回 `launcher.sh`**：它只有 launcher 一个调用方，
  而 `dsh-restart` 把同一条 kickstart→bootstrap 序列自己写了一份 —— 为单调用方的
  抽象留两份拷贝，正是本项目「同一个坑只修了两个脚本」的历史形状。定下的原则：
  **进共享库的是常量与判据，流程不进**
- **`build.sh` 的 node 候选**：25 行「按版本号 `sort -V` 取最高」→ 按序取第一个可执行。
  本机只装了一个 node，择优是投机性通用，还多一个 `sort -V` 的翻车面
- **`launcher.sh` 删掉开窗前的 `command -v node` 检查**：开窗路径一个 node 都不用，
  它只会在「服务好好在跑、但 node 被挪走」时拦住开窗。真正需要 node 的 nohup 兜底
  另有 `$DSH_BIN` 检查
- **`reap_stale_lock` 不再备份锁文件**：锁里只有一个 pid，没有可恢复的内容，而
  `backups/` 目录会无限堆积（`prune_backups` 也不管那个目录）
- **`dsh-kill` 的 4 段同款轮询循环**收成 `wait_stop <轮数> <话术>`
- **`release.sh` 去掉 `/tmp` 中转文件**：改 `gh release create --notes`（gh 2.93 已支持）

### 验证

- 6 个脚本 `bash -n` 全过；`bash ~/.dsh/lib/dsh-lib.sh` 自检 OK
- **`launchd_start` 内联版 vs 改动前版本用假 `launchctl` 跑 7 格决策表对拍**，
  逐格输出相同，含最关键的「`print` 成功但 `kickstart` 失败 → 仍会去试 `bootstrap`」
- `reap_stale_lock` 实测不再创建 `backups/` 目录；`build.sh` 的 node 选择块抽出实跑，
  选中路径与现网 plist 一致 → **部署时 plist 逐字节未变，服务未重启**

### 规模

857 → 838 行；代码行（去注释/空行）491 → 465。

## v1.0.0 — 2026-10-05

首个可用版本。DSH Web GUI 的桌面壳：Edge `--app` 独立窗口 + launchd 服务常驻。

### 功能

- **`dsh.app` 桌面壳**：双击即用。launcher 负责「确保服务在跑 → 等就绪 → 开干净窗口」，
  三层职责分离（launchd 进程层 / launcher 胶水层 / Edge app 窗口 UI 层）
- **launchd 常驻服务**（`ai.dsh.web`，RunAtLoad + KeepAlive）：登录自启、崩了自动重启。
  plist 纳入仓库，`build.sh` 渲染安装
- **`dsh-restart`**：插件更新后重启服务（等PID 换 + HTTP 就绪，最多 30s）
- **`dsh-kill`**：只停服务（`launchctl bootout`，不影响下次登录自启）
- **独立浏览器 profile**（`~/.dsh/edge-profile`）：不往日常 2.2G Edge profile 里塞
  dsh 的 cookie 与历史，也躲开「日常 profile 被占用导致 `--app` 起不来」
- **禁翻译气泡**：每次开窗前幂等写 profile 的 `translate.enabled=false` +
  `blocked_languages=["en"]`
- **关窗残留自愈**：`reap_zombie_browser` 清掉「浏览器进程还在但没窗口」的空壳状态
- **`src/dsh-lib.sh` 共享库**：label /就绪判据 / 失效锁处理 / 启动兜底一处定义，
  三个脚本 source。自检 `bash src/dsh-lib.sh`
- **build.sh 防护**：先装后换（不先拆旧 .app）、备份统一到 `~/.dsh/backups/build/`
  且只留最近 5 份、node 与 dsh 入口都用绝对路径反解（不写死 npm prefix）

### 已知限制

- **浏览器只能是 Edge**。Chrome 154 跑 dsh web 页面 renderer 会崩（Aw Snap 错误码
  10/15，弹「上次打开时意外退出」），重启电脑无效。Safari 无 `--app` /
  无 `--user-data-dir` / AppleScript 控制需额外授权，同样不可用
- **Chromium 单实例绕不掉**：profile 目录里 `SingletonLock` 软链决定谁是新实例，
  第二个进程只送 URL 不执行命令行。所以 launcher 必须自己清空壳
- **WorkBuddy 派生的 shell 里手动 `launchctl bootstrap` 会报 `5: Input/output error`**
  （沙箱限制，2026-10-18 复核仍如此）。恢复服务请跑 `dsh-restart` 或双击 `dsh.app`：
  前者按「未装载 → bootstrap」处理，后者由 LaunchServices 拉起、不在该沙箱内。
  **不需要**像早期文档说的那样重跑 `build.sh`

### 已知行为（不是 bug）

- **每次点 app 都会新开一个窗口**，已有窗口会被关掉。这是为解决「第二次点 app
  不重跑 launcher」而刻意选的取舍：exec 启动 → 进程被浏览器顶替 → LaunchServices
  认为 app 还在运行 → 只activate 不重跑。所以在 exec 前无条件清掉上次残留。
  想要「已有窗口就切过去」需要能定位窗口 id，而本机没有辅助功能权限
  （osascript 报-10004），做不了

### 踩过的坑（写在这里省得后人重踩）

- **`exec` 会让 LaunchServices 认为 app 仍在运行**（dsh.app 进程被浏览器顶替、pid
  不变）→ 第二次点 app 只 activate、launcher 不重跑。**但解法不是换启动方式**：
  改成 `nohup ... &` + `disown` 会让浏览器变孤儿进程、一个窗口都不开（见下条）。
  正解是**保留 `exec` + 每次开窗前无条件清掉上次残留**（`reap_zombie_browser`）
- **「有 `--type=` 子进程」≠「有窗口」**。gpu / network / utility 关窗后依然存在，
  只有 renderer 随窗口消失。判有无窗口只能看 renderer 数
- **`plutil -extract` 判键存在不可靠**（嵌套 dict 报 "No value atthat key path"），
  用 `grep -q`
- **`--disable-features=Translate` 无效**（`Translate` 不是有效 feature 名）
- **参数出现在 cmdline 里 ≠ 参数生效了**。遇「明明有参数却没效果」，先问
  「这条命令行有没有被执行」，看 `ppid`
- **`nohup ... &` + `disown` 不能用**。它让浏览器活过 launcher 退出，但代价是变成
  孤儿子进程（ppid = /sbin/launchd），macOS 上 Chromium 对孤儿的 `--app` 窗口
  不给创建 —— 进程活着、命令行带 --app、renderer=0、一个窗口都不开且无崩溃记录。
  唯一可用的是 `exec`
- **沙箱里测不出的结论不能用来改代码**。本项目的shell 是沙箱进程，Edge/Chrome 在
  里面起不来窗口；「裸 & 会被 SIGHUP 杀掉」这类结论在沙箱里得出的不可靠，
  照着改会让真机更坏
