# dsh-shell

DSH Web GUI 的纯 UI 桌面壳：Edge `--app` 独立窗口 + launchd 服务常驻。**不是 Electron，不是 dsh-desktop 那种全家桶**——只做「脱离浏览器」这一件事。

> **权威设计文档**：`~/shared-memory/private/reba/2026-08-29_dsh_桌面端UI壳技术方案.md`
> （含完整参考实现、前置核查、升级路径、验收清单——开发前必读）

## 状态

- **方案**：渐进路线——①A（Edge `--app` 窗口 + .app 内嵌守护）已完成验收；①B（launchd 常驻）**已于 2026-09 启用**（见下方「进程层」与决策记录）
- **开发**：A 阶段 2026-08-29 完成并真机验收（launcher.sh + build.sh，.app 构建至 `~/Applications/dsh.app`）
- **2026-09-14 改造**：服务已由 launchd（`ai.dsh.web`）托管，因此
  - `dsh-kill` / `dsh-restart` 改为 launchd 感知（`launchctl bootout` / `kickstart -k`），旧的 pkill 路径保留为非托管兜底
  - 非托管分支的进程匹配修正为真实 argv（`node …/dsh/lib/bin.js --profile web`）——旧的 `pkill -f "dsh web"` 一个进程都匹配不到
  - `launcher.sh` 删除自拉段（改为 `launchctl kickstart -k`），就绪判据改用 HTTP 状态码，并支持 401 时用 web.log 里的 token URL 直开
  - launchd plist 纳入仓库（`src/ai.dsh.web.plist`，构建时渲染），`build.sh` 不再无条件覆盖线上脚本
  - plist 里的 node **只取本机独立安装的**（`~/.local/bin` → Homebrew → `/usr/local`，取版本最高者），显式排除 WorkBuddy 内置的 `~/.workbuddy/binaries/node/...`：那是另一个 App 的内部目录，随它升级/清理而变动，常驻服务不该依赖；本机没有独立 node 时 `build.sh` 直接报错退出，不静默回退
- **2026-09-23 改造**：补上「bootout 之后的恢复路径」。原版 `launcher.sh` 只对**已装载**的服务 `kickstart`，而 `dsh-kill` 走的是 `bootout`（把服务从 launchd 卸载）—— 于是**跑过 `dsh-kill` 后双击图标必报「服务未运行，且未找到 launchd 服务 ai.dsh.web」**。现为三级顺序兜底：
  - `launcher.sh`：`kickstart`（已装载）→ `bootstrap plist`（已卸载，从文件重新装载）→ `nohup` 兜底（launchd 两条路都不通时，保证图标永远能用；此分支 launchd 未托管，不存在双实例）
  - `dsh-restart`：同样先 `bootstrap` 再考虑 nohup（原版会静默 nohup 手起，把服务**拖离 launchd 托管**、丢掉 KeepAlive，直到下次登录才回正轨）
  - **关键实据**：`launchctl bootstrap` 在 WorkBuddy 派生的 shell 里必报 `5: Input/output error`（沙箱限制），但 **.app 由 LaunchServices 拉起、不在该沙箱内，实测可用**（2026-09-23：`open ~/Applications/dsh.app` → 8s 后 HTTP 401、`launchctl print` 显示 `state = running`）
  - 附带修正：`launchctl bootout` 刚返回的一瞬 `launchctl print` 仍可能返回成功（残留状态），故两级兜底写成**顺序 if** 而非 `if/elif`
- **起草**：热巴（需求调研 + 方案设计 + 环境核查）

## 架构（三层职责分离）

```
进程层（launchd 常驻）    —— LaunchAgent ai.dsh.web（RunAtLoad + KeepAlive=true）
   ↓ 127.0.0.1:3080
launcher.sh（胶水层）    —— 只做两件事：等服务就绪 → 开 Edge --app 窗口
   ↓
Edge --app 窗口（UI 层） —— 纯渲染，不管进程；兼容性零风险（Edge 内核 = 平时访问 GUI 的内核）
```

纪律：**launchd 是唯一的进程拉起方**，launcher.sh 不允许再拉起（防双实例）。服务没跑时让 launchd 拉（`launchctl kickstart -k`；服务被 bootout 过则先 `bootstrap`），不要 nohup。

> 例外（2026-09-23）：**launchd 两条路都失败**时 launcher.sh 才 nohup 兜底 —— 此时 launchd 根本没托管这个服务，不存在抢 3080 的双实例，兜底只为保证「双击图标一定能用」。

## 目录结构

```
src/
├── launcher.sh                    ← .app 启动入口
└── ai.dsh.web.plist               ← launchd 服务定义（模板，build.sh 渲染 @NODE@/@DSH@/@HOME@）
build.sh                           ← 组装 .app → ~/Applications + 装 launchd + 装 PATH 命令
dsh-restart                        ← 重启服务（launchd: kickstart -k）
dsh-kill                           ← 只停服务（launchd: bootout）
assets/icon_1024.png               ← 应用图标源图
docs/                              ← 单位电脑复刻手册等
```

安装产物位置（Jimmy 已确认的布局约定）：源码进 `~/dev`，构建产物才进 `~/Applications`。

## 常用命令

```bash
dsh-restart        # 插件更新后重启服务（等 PID 换 + HTTP 就绪，最多 30s）
dsh-kill           # 停服务（launchd bootout；下次登录仍会自启）
launchctl print gui/$(id -u)/ai.dsh.web      # 查服务状态
tail -20 ~/.dsh/web.err.log                  # 启动失败看这里
```

**跑过 `dsh-kill` 后想恢复**：双击 `~/Applications/dsh.app`（launcher 会从 plist 重新 bootstrap），或跑 `dsh-restart`。两条路都会回到 launchd 托管态。

## 关键决策记录（详见设计文档 §一）

| 决策 | 结论 |
|---|---|
| dsh-desktop（★21.8k） | ❌ Electron 全家桶过重，进程管理/托盘/市场全是冗余 |
| nativefier | ❌ 2023-09 已归档 |
| Tauri / Swift 自研壳 | ❌ 暂不，收益只是换内核 |
| **Edge --app + 进程层渐进（A→B）** | ✅ 窗口兼容性零风险；A/B 全解耦可逆，按使用频率演化 |
| B 阶段曾暂缓（2026-08-30） | 当时判断「dsh 起步阶段求简单」。**该判断已被推翻**：服务后续实际由 launchd 托管（`ai.dsh.web`，2026-09 启用），仓库随之补齐 plist 与 launchd 感知脚本 |
| Swift WKWebView 壳（②） | ❌ Safari 系内核对 Chromium 生态 GUI 有兼容风险，服务内存才是大头 |
| API key 环境变量 | ✅ 无需注入：provider 的 `apiKeyEnv` 由 `~/.dsh/.credentials.yaml` 的 refs 解析，launchd 进程不依赖 shell 环境变量 |
