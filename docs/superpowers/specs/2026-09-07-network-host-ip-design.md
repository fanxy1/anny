# 网络页显示本机 IP

网络摘要只标了默认网关（`via`），容易和本机地址搞混。在「本机网络」摘要里，网关下面加一行本机 IPv4。

## 决定

- 只改网络页摘要，不改巡查「出口」、资源页、侧栏。
- 本机 IP = 默认路由那块网卡的第一个 IPv4。用已有 `gatewayDev` + `nics`，不改 SSH 脚本。
- 显示格式和网关一样：`172.24.137.161  ·  eth0`。地址去掉 CIDR（`/27`）。
- 没有默认路由网卡、或那块卡没有 IPv4：显示 `—`。
- 不写盘，不加测试 target。

## 数据

`NetworkSnapshot` 增加只读 `hostIPv4`：在 `nics` 里找 `name == gatewayDev` 的卡，取 `ipv4.first`，去掉 `/` 及后面的前缀长度。

## 文件

| 文件 | 改动 |
|------|------|
| `anny/Models.swift` | `hostIPv4` |
| `anny/NetworkView.swift` | 摘要加「本机」 |

不改 SSH、巡查、存盘。

## 验收

`xcodebuild -scheme anny` 通过，再手工：打开一台有默认路由的机器的网络页，摘要「本机」是该网卡 IPv4，不是网关。
