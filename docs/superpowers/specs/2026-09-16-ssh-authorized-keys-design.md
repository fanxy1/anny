# 当前账户的 SSH authorized_keys

机器详情加「密钥」面板：列出、添加、勾选后删除当前 SSH 账户的 `~/.ssh/authorized_keys`。

## 决定

- 只改当前连接账户的 `authorized_keys`，不碰 `authorized_keys2`、别的用户、本机 `~/.ssh`。
- 入口是独立面板，和资源 / 进程 / 网络 / 终端并列。切到这一页若无缓存就自动读；缓存按主机 UUID 放内存，不写盘。不跟「动态」走。
- 添加只支持粘贴一行公钥。删除只弹确认，最后一把也能删。
- 列表一行：勾选、类型、备注、SHA256 指纹。空行和 `#` 注释不显示，写回时保留。选项字段（`from=` 等）不显示，删时整行去掉。解析失败的行标成「无效」，可勾选删除。
- 添加走 stdin 追加；删除用当前快照整文件覆盖。公钥不拼进远端命令。`ProcessRun` 增加可选 stdin。
- 不改巡查和其它 SSH 脚本。不加测试 target。

## 数据

`AuthKeysSnapshot`：`rawLines`、`rows`、`fetchedAt`、`error`。

`AuthKeyRow`：行号、类型、备注、指纹、原文、是否合法。同一把 key 两行算两行，删除按行号。

指纹：对 base64 解码后的 key blob 做 SHA256，格式 `SHA256:` + 无 padding Base64。

添加：一行合法公钥；指纹已在列表里则拒绝。远端 `mkdir -p ~/.ssh`，目录 `700`、文件 `600`，必要时先补文件末尾换行再追加。

删除：去掉勾选行号，其余行原样覆盖写回。拉取和写回之间的并发改动后写覆盖。

## 界面

工具栏：数量 / 已选数量，添加，删除。表头全选。点行勾选。右键复制指纹或整行。添加是表单，错误留在表单里。删除确认带数量。写入中不可再点添加/删除。换台或刷新后清勾选。

## 文件

| 文件 | 改动 |
|------|------|
| `anny/AuthKeys.swift` | 解析、指纹、粘贴校验、按行号重建文件 |
| `anny/KeysView.swift` | 面板、勾选、添加表单、删除确认 |
| `anny/Models.swift` | `AuthKeyRow`、`AuthKeysSnapshot` |
| `anny/ProcessRun.swift` | 可选 stdin |
| `anny/SSHService.swift` | 读、追加、覆盖 |
| `anny/ContentView.swift` | 面板、缓存、刷新、添加/删除 |
| `anny/Theme.swift` | 图标 |
| `anny.xcodeproj/project.pbxproj` | 新文件 |

## 验收

`xcodebuild -scheme anny` 通过，再手工：

1. 密钥页列出当前账户的 key（类型、备注、指纹）。
2. 粘贴新公钥后列表多一行。
3. 勾选删除后远端文件里没有这些行。
4. 无效粘贴、重复指纹留在表单报错，不写文件。
