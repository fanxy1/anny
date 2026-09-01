# anny

macOS 上的 Tailscale 主机监控与 SSH 终端。从本机 `tailscale status` 导入节点（或手填主机名），用 SSH 看 CPU / 内存 / 磁盘，并在窗口里开交互式会话。

## 需要什么

- macOS 14+
- 本机已装 [Tailscale](https://tailscale.com/download)，并已登录（例如 Headscale `hs.fanxy1.cn`）
- 能 `ssh user@hostname` 免密登录目标机（默认用户 `root`，默认端口 `22`）
- Xcode 16+（本地编译）

应用未开 App Sandbox，会调用本机 `tailscale` 和 `/usr/bin/ssh`。

## 做什么

- **监控名单**：从 `tailscale status --json` 勾选导入，或手填主机名；只改本机名单，不改 Tailscale / Headscale
- **资源**：SSH 读 `/proc` 与 `df`，显示 CPU、内存、load、磁盘
- **终端**：内嵌 SwiftTerm，`⌘T` 连接、`⌘D` 断开；双击左侧名单也会连上
- **编辑**：可改 SSH 端口和备注（有备注时名单显示备注）

移出监控只删本软件名单，不会注销节点。

## 怎么跑

```bash
open anny.xcodeproj
```

在 Xcode 里选 anny scheme，Run。或：

```bash
make build
open DerivedData/Build/Products/Debug/anny.app
```

产物名是 anny，bundle id 是 `cn.fanxy.anny`。名单存在 `~/Library/Application Support/anny/hosts.json`（若只有旧版 `FanxyTS` 名单，首次启动会自动拷过去）。

## 目录

```
anny/              应用源码
anny.xcodeproj     Xcode 工程
Vendor/SwiftTerm   内嵌终端（本地 SPM）
```

## 注意

- 资源采集按 Linux `/proc` 写的，目标机应是 Linux
- SSH 用 `BatchMode=yes`，需要密钥或 agent，不会弹密码
- 端口不要带千分位（写 `10022`，不要 `10,022`）
