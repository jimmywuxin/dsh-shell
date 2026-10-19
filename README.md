# dsh-shell

DSH Web GUI 的纯 UI 桌面壳：原生 WKWebView 窗口 + launchd 服务常驻。**不是 Electron，不是 dsh-desktop 那种全家桶**——只做「脱离浏览器」这一件事。

> **v1.1.0 起换壳**：`Edge --app` 已废弃，改为原生 Swift + WKWebView 壳（`src/DshApp.swift`）。
> 改造细节见 `docs/原生WKWebView壳改造指南_2026-10-19.md`，选型过程见 `docs/替代方案调研.md`。

## 状态

- **方案**：渐进路线——①A（Edge `--app` 窗口 + .app 内嵌守护）已完成验收；①B（launchd 常驻）**已于 2026-09 启用**（见下方「进程层」与决策记录）；2026-10-19 壳从 Edge `--app` 换成原生 WKWebView（见下）
- **开发**：A 阶段 2026-08-29 完成并真机验收（launcher.sh + build.sh，.app 构建至 `~/Applications/dsh.app`）
- **2026-09-14 改造**：服务已由 launchd（`ai.dsh.web`）托管，因此
  - `dsh-kill` / `dsh-restart` 改为 launchd 感知（`launchctl bootout` / `kickstart -k`），旧的 pkill 路径保留为非托管兜底
  - 非托管分支的进程匹配修正为真实 argv（`node …/dsh/lib/bin.js --profile web`）——旧的 `pkill -f "dsh web"` 一个进程都匹配不到
  - `launcher.sh` 删除自拉段（改为 `launchctl kickstart -k`），就绪判据改用 HTTP 状态码，并支持 401 时用 web.log 里的 token URL 直开
  - launchd plist 纳入仓库（`src/ai.dsh.web.plist`，构建时渲染），`build.sh` 不再无条件覆盖线上脚本
  - plist 里的 node **只取本机独立安装的**（`~/.local/bin` → Homebrew → `/usr/local`，**按序取第一个可执行的**），显式排除 WorkBuddy 内置的 `~/.workbuddy/binaries/node/...`：那是另一个 App 的内部目录，随它升级/清理而变动，常驻服务不该依赖；本机没有独立 node 时 `build.sh` 直接报错退出，不静默回退
- **2026-09-23 改造**：补上「bootout 之后的恢复路径」。原版 `launcher.sh` 只对**已装载**的服务 `kickstart`，而 `dsh-kill` 走的是 `bootout`（把服务从 launchd 卸载）—— 于是**跑过 `dsh-kill` 后双击图标必报「服务未运行，且未找到 launchd 服务 ai.dsh.web」**。现为三级顺序兜底：
  - `launcher.sh`：`kickstart`（已装载）→ `bootstrap plist`（已卸载，从文件重新装载）→ `nohup` 兜底（launchd 两条路都不通时，保证图标永远能用；此分支 launchd 未托管，不存在双实例）
  - `dsh-restart`：同样先 `bootstrap` 再考虑 nohup（原版会静默 nohup 手起，把服务**拖离 launchd 托管**、丢掉 KeepAlive，直到下次登录才回正轨）
  - **关键实据**：`launchctl bootstrap` 在 WorkBuddy 派生的 shell 里必报 `5: Input/output error`（沙箱限制），但 **.app 由 LaunchServices 拉起、不在该沙箱内，实测可用**（2026-09-23：`open ~/Applications/dsh.app` → 8s 后 HTTP 401、`launchctl print` 显示 `state = running`）
  - 附带修正：`launchctl bootout` 刚返回的一瞬 `launchctl print` 仍可能返回成功（残留状态），故两级兜底写成**顺序 if** 而非 `if/elif`
- **2026-10-05 改造**：抽 `src/dsh-lib.sh` 共享库 + 修5 处逻辑缺陷
  - **共享库**：`LABEL/DOMAIN/URL/LOG_DIR/LOCK/PLIST/DSH_BIN/PROC_PATTERN/probe_code/app_ready/pid_of/reap_stale_lock/launchd_managed/wait_ready` 三脚本共用（装到 `~/.dsh/lib/dsh-lib.sh`）。起因是同一个坑只修了两个脚本——`launcher.sh` 从来没有 `reap_stale_lock`。**常量与判据必须进库；流程不要**——`launchd_start`（kickstart→bootstrap 两级兜底）原先也在库里，但它只有 `launcher.sh` 一个调用方，而 `dsh-restart` 把同一条序列自己写了一遍，为单调用方的抽象留两份拷贝不划算，2026-10-06 搬回 `launcher.sh`
  - **`launcher.sh` 补失效锁清理**：开机后 launchd 拉起服务要加载插件树（10–30s），此窗口内双击图标 → probe 返 `000` → 被判「没跑」→ `kickstart -k` **强杀半启动实例** → 留下 credentials writer lock → 后续崩溃循环
  - **`dsh-restart` 不再误杀托管中的实例**：kickstart 瞬时失败时原版会一路走到 nohup 分支，pkill 掉健康的实例、手起一个脱离 KeepAlive 的野实例。现在两级都失败后先问`launchd_managed`，仍托管就报错退出、不接管
  - **`reap_stale_lock` 判据换成 `kill -0` 探活**：原 `reap_stale_lock ""`（空串）语义是「无条件删锁」，若 pkill 没匹配到、持锁者还活着就会删掉活锁，让两实例并发写 credentials
  - **`build.sh` 死代码**：`if plist 无变化 → 跳过` 在前，导致「plist 没变 + 服务被 bootout 卸载」被直接吃掉（刚跑完 dsh-kill 再 build.sh 什么也不发生），下面的「未装载就 bootstrap」分支从未执行过。现改为**先判服务是否装载**
  - **`build.sh` 先装后换**：原来先 `mv` 旧 .app 进废纸篓再组装，中途失败会留下「已拆掉、没装回来」的空档。现先在 `build/dsh.app.new` 组装好再换
  - **`build.sh` 从 `command -v dsh` 反解真实路径**（`realpathSync` 跟软链），不再写死 `.npm-global/lib/node_modules/...`；npm prefix 一变时不会装出起不来的 plist
  - **备份统一到 `~/.dsh/backups/build/`**并只留最近 5 份；旧版把备份丢在 `~/.npm-global/bin/*.bak-*`（污染 PATH 目录，已积 6 份）和 `LaunchAgents/*.plist.bak-*`
  - token 正则放宽到非空白/引号/`&`（窄集合会匹配出被截断的无效 token）
  - lib 自检：`bash src/dsh-lib.sh`（断言空响应兜底 000、无服务不判就绪、空锁不误删、死 pid 锁会清、活 pid 锁不删）
- **2026-10-18 加固**：三处配置/流程缺陷（审查发现，均有实测证据）
  - **plist 补 `WorkingDirectory`**：launchd 默认 cwd 是 `/`（`lsof -d cwd` 实测），而 dsh 把 `process.cwd()` 传进 `profileContext` 并 spawn 子进程 —— 相对路径会落到只读的根目录。现钉在 `@HOME@`
  - **plist 补 `Umask`=63（0o077）**：`web.log` 里记录了带 token 的入口 URL（launcher 的 401 兜底要从这里抓），默认 644 让同机其他账户可读到 token、进而打开 loopback 上的完整 GUI。`build.sh` 顺手把已有日志 `chmod 600`
  - **`release.sh` 补 PATH**：`gh` 装在 `/opt/homebrew/bin`，精简 PATH 下 `command -v gh` 失败 → 卡在「tag 已推、Release 未建」；`Info.plist` 的版本号改由 `build.sh` 从 git tag 注入（此前写死 1.0）
- **2026-10-19 换壳（Edge `--app` → 原生 WKWebView）**：红叉在 Edge `--app` 窗口里由 Chromium 写死为「关闭窗口」，关掉最后一个窗口浏览器即退出，没有任何开关能改掉「关闭窗口」这个行为。现换成原生壳 `src/DshApp.swift`（NSWindow + WKWebView）：
  - **红叉 = 隐藏窗口（飞书式）**：`windowShouldClose` 返回 false 并 `orderOut`——窗口从桌面消失、Dock 里**不留缩略图**，应用继续运行、图标留在 Dock；点 Dock 图标（`applicationShouldHandleReopen` / `applicationDidBecomeActive`）重新显示。已自测：关闭后 `visible=false miniaturized=false`，reopen 后 `visible=true`。
  - **认证**：不再依赖 `web.log` 里的 token URL（实测 124 条历史 token 与当前进程不匹配，全是 401）。壳用 `~/.dsh/.credentials.yaml` 的 `client-connection/browser-session` 签名密钥现场 mint cookie（`dsh-auth-<sha256(authority)>` + `v1.<body>.<HMAC>`），实测 200；cookie 过期时 ⌘R 会重新 mint。
  - **WebKit 实测**：页面标题、会话列表、点开会话正文（1.2 万字）、输入框/文件输入均正常；没有 Chromium 那类 renderer 崩溃。
  - **补的浏览器能力**：`<input type=file>` → NSOpenPanel、`target=_blank`/外链 → 默认浏览器、下载 → NSSavePanel、`⌘R` 重连、缩放/全屏菜单。
  - **代价**：没有 Edge DevTools；壳已开 `webView.isInspectable = true`，需要时在 Safari「设置 → 高级 → 显示网页开发者功能」后用「开发」菜单检查本 app。
  - **服务层不变**：launchd plist、`dsh-lib.sh`、`dsh-restart`、`dsh-kill` 全保留；`launcher.sh` 收缩为 `--ensure`（只等服务就绪），由壳在开窗前调用。旧 Edge 壳的 app 已进废纸篓，`~/.dsh/edge-profile` 不再使用（可删）。
- **起草**：热巴（需求调研 + 方案设计 + 环境核查）

## 架构（三层职责分离）

```
进程层（launchd 常驻）    —— LaunchAgent ai.dsh.web（RunAtLoad + KeepAlive=true）
   ↓ 127.0.0.1:3080
launcher.sh（服务层）    —— 只做一件事：把服务等到就绪（壳调用 --ensure）
   ↓
原生壳（UI 层）          —— NSWindow + WKWebView；红叉=隐藏窗口（飞书式）、cookie 认证、文件选择/外链/下载
```

纪律：**launchd 是唯一的进程拉起方**，launcher.sh 不允许再拉起（防双实例）。服务没跑时让 launchd 拉（`launchctl kickstart -k`；服务被 bootout 过则先 `bootstrap`），不要 nohup。

> 例外（2026-09-23）：**launchd 两条路都失败**时 launcher.sh 才 nohup 兜底 —— 此时 launchd 根本没托管这个服务，不存在抢 3080 的双实例，兜底只为保证「双击图标一定能用」。

## 目录结构

```
src/
├── DshApp.swift                   ← 原生壳（NSWindow + WKWebView；红叉→隐藏窗口、cookie、菜单）
├── launcher.sh                    ← 服务就绪检查（.app 资源，壳调用 --ensure）
├── dsh-lib.sh                     ← 三脚本共享库（装到 ~/.dsh/lib/，自带自检）
└── ai.dsh.web.plist               ← launchd 服务定义（模板，build.sh 渲染 @NODE@/@DSH@/@HOME@）
build.sh                ← 组装 .app → ~/Applications + 装 launchd + 装 PATH 命令
dsh-restart                        ← 重启服务（launchd: kickstart -k）
dsh-kill                           ← 只停服务（launchd: bootout）
assets/icon_1024.png               ← 应用图标源图
docs/                              ← 复刻手册、原生 WKWebView 壳改造指南（opencode-shell 参考）
```

> **改任何一处共享逻辑，只改 `src/dsh-lib.sh`**——label、就绪判据、失效锁、启动兜底
> 都在这里。三个脚本 source 它，所以不会再出现「同一个坑只修了两个脚本」。

## 常用命令

```bash
open ~/Applications/dsh.app    # 打开原生窗口（服务没跑会自动拉起）
tail -20 ~/.dsh/shell.log      # 壳自己的启动/连接日志（不含 cookie）
dsh-restart        # 插件更新后重启服务（等 PID 换 + HTTP 就绪，最多 30s）
dsh-kill           # 停服务（launchd bootout；下次登录仍会自启）
bash src/dsh-lib.sh    # 共享库自检（不碰线上服务）
launchctl print gui/$(id -u)/ai.dsh.web      # 查服务状态
tail -20 ~/.dsh/web.err.log                  # 启动失败看这里
```

安装产物位置（Jimmy 已确认的布局约定）：源码进 `~/dev`，构建产物才进 `~/Applications`。

**跑过 `dsh-kill` 后想恢复**：双击 `~/Applications/dsh.app`（launcher 会从 plist 重新 bootstrap），或跑 `dsh-restart`。两条路都会回到 launchd 托管态。

## 关键决策记录（详见设计文档 §一）

| 决策 | 结论 |
|---|---|
| dsh-desktop（★21.8k） | ❌ Electron 全家桶过重，进程管理/托盘/市场全是冗余 |
| nativefier | ❌ 2023-09 已归档 |
| Tauri / Swift 自研壳 | ✅ 2026-10-19 采用 Swift + WKWebView：不是为了换内核，而是**只有自家 NSWindow 能把红叉改成「隐藏窗口」（飞书式）**；WebKit 渲染已实测 |
| **Edge --app + 进程层渐进（A→B）** | ✅ 2026-08～10 使用；**2026-10-19 被原生壳取代**（红叉行为由 Chromium 写死，无法改） |
| B 阶段曾暂缓（2026-08-30） | 当时判断「dsh 起步阶段求简单」。**该判断已被推翻**：服务后续实际由 launchd 托管（`ai.dsh.web`，2026-09 启用），仓库随之补齐 plist 与 launchd 感知脚本 |
| Swift WKWebView 壳（②） | ✅ 2026-10-19 采用。原判「兼容风险」被实测推翻（页面/会话/WebSocket 正常）；「服务内存才是大头」仍成立——壳本体 <1MB |
| API key 环境变量 | ✅ 无需注入：provider 的 `apiKeyEnv` 由 `~/.dsh/.credentials.yaml` 的 refs 解析，launchd 进程不依赖 shell 环境变量 |
