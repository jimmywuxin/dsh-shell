# CHANGELOG

本项目的版本号按**功能里程碑**给，不按 commit 数给。修 bug 不升版本号。

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
- **dsh-kill 后要重跑 `build.sh` 才能恢复服务**（在非真终端环境下）

### 已知行为（不是 bug）

- **每次点 app 都会新开一个窗口**，已有窗口会被关掉。这是为解决「第二次点 app
  不重跑 launcher」而刻意选的取舍：exec 启动 → 进程被浏览器顶替 → LaunchServices
  认为 app 还在运行 → 只activate 不重跑。所以在 exec 前无条件清掉上次残留。
  想要「已有窗口就切过去」需要能定位窗口 id，而本机没有辅助功能权限
  （osascript 报-10004），做不了
- **`dsh-kill` 后要重跑 `build.sh` 才能恢复服务**（本shell 里bootstrap 必然失败）

### 踩过的坑（写在这里省得后人重踩）

- **`exec` 不能用在 launcher 的最后一步**。exec 把 dsh.app 进程原地替换成浏览器
  进程（pid 不变）→ macOS LaunchServices 认为 app 还在运行 → 第二次点 app 只
  activate、launcher 不重跑。改用 `nohup ... &` + `disown`（裸 `&` 会被 SIGHUP 杀掉）
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
