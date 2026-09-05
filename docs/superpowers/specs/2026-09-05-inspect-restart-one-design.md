# 单条重新巡查

巡查结果表里，对某一行右键，只重跑这一台。整表其他结果保留。

## 决定

- 就地更新这一行，不走现有 `start()`（`start()` 会整表换成新一批目标）。
- 整批或任一台正在跑时，「重新巡查」禁用。
- 重跑中：这一行显示「巡查中」和「…」，旧记录先清掉，和整批一致。
- 失败仍写成带 `error` 的 `InspectRecord`，状态「失败」。
- 侧栏状态点读同一份 `records`，跟着变。
- 不改 `inspect.json` 格式，不改勾选语义，不加侧栏「重新巡查」，不加测试 target。

## 交互

结果行增加 `.contextMenu`，只有一项「重新巡查」。

- 启用：`!inspect.isRunning`。
- 点了：选中这一行（`tableSelection` + `onSelect`），再 `restart`。
- 顶栏切到进行中：进度、`finishedCount / runIDs.count`、「停止」。分母仍是整表台数；这一台记录被清掉后，分子暂时少 1。
- 「停止」调用现有 `cancel()`，只取消这一次任务。取消后不写回新记录（旧的已被清掉，该行状态为「—」），和整批取消一致。

## 数据流

`InspectStore` 新增：

```swift
func restart(_ host: WatchedHost) {
    guard !isRunning else { return }
    guard runIDs.contains(host.id) else { return }
    runTask = Task { await runOne(host) }
}
```

`runOne`：

1. 不改 `runIDs`。
2. `runningIDs = [host.id]`，`records.removeValue(forKey: host.id)`。
3. `await InspectStore.fetch(host)`。
4. 未取消则写入 `records[id]`。
5. `runningIDs = []`，`save()`。

不在结果表里（或不在主机名单、行已滤掉）时，菜单不会出现；`runIDs` 守卫防止误调。

`fetch`、失败记录、存盘路径都不改。

## 文件

| 文件 | 改动 |
|------|------|
| `anny/InspectStore.swift` | `restart` + `runOne` |
| `anny/InspectView.swift` | 结果行 `.contextMenu` |

不改 `Models.swift`、`ContentView.swift`、SSH。

## 验收

anny 没有测试 target，不为此功能新增。用 `xcodebuild` 编译，再手工过一遍：

1. 整批跑完后，右键某一行 →「重新巡查」：只有这一行变「巡查中」，其他行数字不动；完成后只覆盖这一条。
2. 整批进行中：菜单项禁用。
3. 单台重跑时点「停止」：该行不再「巡查中」，没有新记录。
4. 连不上的机器重跑后状态为「失败」，侧栏点变红。
