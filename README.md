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
├── dsh-lib.sh                     ← 三脚本共享库（装到 ~/.dsh/lib/，自带自检）
└── ai.dsh.web.plist               ← launchd 服务定义（模板，build.sh 渲染 @NODE@/@DSH@/@HOME@）
build.sh                ← 组装 .app → ~/Applications + 装 launchd + 装 PATH 命令
dsh-restart                        ← 重启服务（launchd: kickstart -k）
dsh-kill                           ← 只停服务（launchd: bootout）
assets/icon_1024.png               ← 应用图标源图
docs/                              ← 单位电脑复刻手册等
```

> **改任何一处共享逻辑，只改 `src/dsh-lib.sh`**——label、就绪判据、失效锁、启动兜底
> 都在这里。三个脚本 source 它，所以不会再出现「同一个坑只修了两个脚本」。

## 常用命令

```bash
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
| Tauri / Swift 自研壳 | ❌ 暂不，收益只是换内核 |
| **Edge --app + 进程层渐进（A→B）** | ✅ 窗口兼容性零风险；A/B 全解耦可逆，按使用频率演化 |
| B 阶段曾暂缓（2026-08-30） | 当时判断「dsh 起步阶段求简单」。**该判断已被推翻**：服务后续实际由 launchd 托管（`ai.dsh.web`，2026-09 启用），仓库随之补齐 plist 与 launchd 感知脚本 |
| Swift WKWebView 壳（②） | ❌ Safari 系内核对 Chromium 生态 GUI 有兼容风险，服务内存才是大头 |
| API key 环境变量 | ✅ 无需注入：provider 的 `apiKeyEnv` 由 `~/.dsh/.credentials.yaml` 的 refs 解析，launchd 进程不依赖 shell 环境变量 |
