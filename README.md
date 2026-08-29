# dsh-shell

DSH Web GUI 的纯 UI 桌面壳：Edge `--app` 独立窗口 + launchd 服务常驻。**不是 Electron，不是 dsh-desktop 那种全家桶**——只做「脱离浏览器」这一件事。

> **权威设计文档**：`~/shared-memory/private/reba/2026-08-29_dsh_桌面端UI壳技术方案.md`
> （含完整参考实现、前置核查、升级路径、验收清单——开发前必读）

## 状态

- **方案**：已与 Jimmy 逐项确认定稿（2026-08-29）——① Edge `--app` 窗口 + B launchd 常驻
- **开发**：待开发（开发者：杨杨）
- **起草**：热巴（需求调研 + 方案设计 + 环境核查）

## 架构（三层职责分离）

```
launchd（服务层）        —— 唯一拉起方：RunAtLoad + KeepAlive 管 dsh web 生死
   ↓ 127.0.0.1:3080
launcher.sh（胶水层）    —— 只做两件事：等端口就绪 → 开 Edge --app 窗口
   ↓
Edge --app 窗口（UI 层） —— 纯渲染，不管进程
```

纪律：launchd 是唯一的进程拉起方，launcher.sh 不允许再拉起（防双实例）。

## 规划目录结构（开发时创建）

```
src/
├── launcher.sh                    ← .app 启动入口（参考实现见设计文档 §4.1）
└── com.jimmy.dsh-web.plist        ← launchd 服务定义（§4.2）
build.sh                           ← 组装 .app → ~/Applications + 装 launchd（§4.3）
dsh-restart                        ← 升级后重启服务，装进 PATH（§4.4）
uninstall.sh                       ← 完整卸载（产物 + 服务 + PATH 命令）
```

安装产物位置（ Jimmy 已确认的布局约定）：源码进 `~/dev`，构建产物才进 `~/Applications`。

## 关键决策记录（详见设计文档 §一）

| 决策 | 结论 |
|---|---|
| dsh-desktop（★21.8k） | ❌ Electron 全家桶过重，进程管理/托盘/市场全是冗余 |
| nativefier | ❌ 2023-09 已归档 |
| Tauri / Swift 自研壳 | ❌ 暂不，收益只是换内核 |
| **Edge --app + launchd** | ✅ 零依赖零打包，组件全稳定契约 |
| API key 环境变量 | ✅ 五个 key 已在 launchctl 全局，LaunchAgent 可继承（2026-08-29 已核） |
