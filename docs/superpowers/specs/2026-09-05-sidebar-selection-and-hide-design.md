# 侧栏选择与隐藏

机器页侧栏只负责点选当前机器；巡查页侧栏只负责勾选。侧栏可隐藏。换台后内存里记住每台已拉过的资源/进程/网络。

## 决定

- 不用 `List(selection:)`，侧栏改成 `ScrollView` 里自己画的行，选中高亮跟手。
- 机器页：无巡查勾选框（行上和分组标题上都不留）。单击选中，双击开终端，拖到分组仍可用。点分组标题只折叠/展开。
- 巡查页：点行或勾选框都是勾/取消，不改 `selectedID`。分组标题仍可「巡查本组」。不画当前机器高亮，避免和勾选抢视觉。
- 巡查结果表点某一行仍设置 `selectedID`（回机器页就是那一台）。
- 隐藏：工具栏按钮 + `⌘⌃S`，状态用 `@AppStorage` 记住。不改 `hosts.json` / `inspect.json`。
- 资源、进程、网络按 `UUID` 缓存在内存。不写盘。探测结果、加载中、杀进程、动态刷新开关不缓存。
- 不改 SSH、巡查存盘、分组文件、单条重新巡查。不加测试 target。不做侧栏键盘上下移动。

## 交互

**机器页行：** 单击 → `selectedID = host.id`，该行用强调色底。双击 → 现有开终端。拖拽、右键菜单不变。

**巡查页行：** 单击行或框 → `inspect.setChecked`。分组标题上的组合勾选保留。

**隐藏：** 工具栏在「添加」左侧放一个侧栏按钮（`sidebar.leading` / 收起时可用 `sidebar.leading` 同一图标，靠 `help` 区分「隐藏侧栏」「显示侧栏」）。`⌘⌃S` 与按钮同一开关。隐藏时不画侧栏和 `SidebarResizeHandle`，详情区占满。宽度仍是会话内的 `sidebarWidth`，不持久化。

## 数据流

`ContentView`：

- `sidebarHidden`：`@AppStorage("anny.sidebarHidden")`。
- `metricsByHost` / `processesByHost` / `networkByHost`：`[UUID: …]`。
- 拉数成功或失败写入当前主机对应缓存，同时更新现有的 `metrics` / `processSnapshot` / `networkSnapshot`（面板仍读这三份）。
- `onChange(selectedID)`：不再清空三份数据。改为从缓存填入（没有则为 `nil`）；关掉动态刷新；清掉 loading / probing / killing。`ensureProcesses` / `ensureNetwork` 仍是「当前值为 nil 才自动拉」，因此有缓存时不重拉，无缓存时照旧。
- 编辑连接且 `connectionChanged`：清该主机缓存和当前面板（若正在看它）。
- `remove` / 移出监控：`inspect.forget` 之外，删掉该主机三份缓存。

侧栏列表：同一套 `sidebarItems` / 分组 / 搜索 / drop。机器页行不渲染 `Toggle`；巡查页行渲染。点击落在行上，不再和 `List` 选中抢手势。

## 文件

| 文件 | 改动 |
|------|------|
| `anny/ContentView.swift` | 侧栏列表、勾选显隐、隐藏、缓存、`onChange` |
| `anny/Theme.swift` | `AnnyIcon.sidebar` |

不改 `InspectStore` / `HostStore` / `Models` / SSH。`InspectView` 结果表 `onSelect` 保持原样。

## 验收

`xcodebuild -scheme anny` 通过，再手工：

1. 机器页点行即选中，高亮跟手；无勾选框；双击开终端；拖到另一组可用。
2. 巡查页点行只勾选；窗口标题和机器详情不换成那一台；回机器页，上次选中还在。
3. 巡查结果表点一行，再回机器页，当前机器是那一台。
4. 工具栏和 `⌘⌃S` 都能隐/显；重启后保持。
5. 机器 A 拉过资源，切 B 再切回 A，先看到 A 上次的数据。
6. 移出后再加入同一主机（新记录），没有旧缓存。
