# 资源页显示未分配硬盘

磁盘模块现在只列 `df` 里已挂载的文件系统，空盘、有分区但没挂上的盘都看不见。资源页磁盘卡片里加一张「未分配」表，列出整块还没交给系统用的物理盘。

## 决定

- 已挂载表不动。巡查「磁盘」仍只看已挂载用量，不把空盘算进去。
- 未分配 = `lsblk` 里 `TYPE=disk` 的物理盘，且自身和所有下级都没有挂载点，也不是 LVM / MD RAID / LUKS / swap 成员。
- 有分区或文件系统但没挂载、也没进上述子系统的，算未分配（常见备盘）。状态：无下级且无文件系统为「无分区」，否则「未挂载」。
- 不列已在用磁盘上的分区空隙，不改 SSH 其它脚本，不写盘，不加测试 target。
- 没有未分配盘时不画这一块。`lsblk` 没有或失败时当没有。

## 数据

`HostMetrics.unusedDisks: [UnusedDiskRow]`，刷新资源时和 `df` 一起取。

远程命令：`lsblk -b -P`，列 `NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,PKNAME,MODEL`，缺列则降级。解析 `KEY="VALUE"`。loop / rom / ram / zram / sr 跳过。

## 文件

| 文件 | 改动 |
|------|------|
| `anny/Models.swift` | `UnusedDiskRow`、`unusedDisks` |
| `anny/SSHService.swift` | 指标脚本加 `===LSBLK===`，解析未分配盘 |
| `anny/ContentView.swift` | 磁盘卡片加「未分配」表 |

## 验收

`xcodebuild -scheme anny` 通过，再手工：打开一台有空盘或未挂载盘的机器的资源页，磁盘卡片「未分配」列出设备、容量、型号、状态；系统盘和已挂载盘不出现。
