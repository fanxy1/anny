# 侧栏选择与隐藏 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-ruby:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. anny 没有测试 target，不要新增；用 `xcodebuild` 和手工对照 spec 验收。

**Goal:** 机器页侧栏只点选，巡查页侧栏只勾选；可隐藏侧栏；换台后内存缓存资源/进程/网络。

**Architecture:** 用 `ScrollView` 自绘行替代 `List(selection:)`。`@AppStorage("anny.sidebarHidden")` 控制侧栏和宽度条。三份 `[UUID: …]` 字典与现有面板状态写穿。

**Tech Stack:** SwiftUI + AppKit（现有 `HostListDoubleClick`），macOS 14。

---

## File map

| File | Responsibility |
|------|----------------|
| `anny/Theme.swift` | `AnnyIcon.sidebar` |
| `anny/ContentView.swift` | 列表、勾选显隐、隐藏、缓存、`onChange` |

Do not change `InspectStore`, `HostStore`, `Models`, SSH. Leave inspect-restart-one code as-is.

---

### Task 1: Sidebar icon

**Files:**
- Modify: `anny/Theme.swift` (`AnnyIcon`)

- [x] **Step 1: Add icon**

After `static let search = "magnifyingglass"`:

```swift
    static let sidebar = "sidebar.leading"
```

---

### Task 2: Hide sidebar

**Files:**
- Modify: `anny/ContentView.swift`

- [x] **Step 1: Storage and layout**

Add:

```swift
    @AppStorage("anny.sidebarHidden") private var sidebarHidden = false
```

Replace the `HStack` body with:

```swift
            HStack(spacing: 0) {
                if !sidebarHidden {
                    sidebar
                        .frame(width: sidebarWidth)
                        .clipped()
                    SidebarResizeHandle(width: $sidebarWidth)
                }
                detailStack
                    .frame(minWidth: 680)
            }
```

- [x] **Step 2: Toolbar button and shortcut**

In `ToolbarItemGroup(placement: .primaryAction)`, insert before 添加:

```swift
                    Button {
                        sidebarHidden.toggle()
                    } label: {
                        Label(sidebarHidden ? "显示侧栏" : "隐藏侧栏", systemImage: AnnyIcon.sidebar)
                    }
                    .help(sidebarHidden ? "显示侧栏" : "隐藏侧栏")
```

In the existing hidden-shortcut `.background`, add:

```swift
            Button("切换侧栏") { sidebarHidden.toggle() }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .hidden()
```

---

### Task 3: Custom sidebar rows

**Files:**
- Modify: `anny/ContentView.swift` (`sidebarList`, row helpers, `hostRow`, `groupHeader`)

- [x] **Step 1: Replace `List(selection:)`**

```swift
    private var sidebarList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(sidebarItems) { item in
                    sidebarRow(item)
                }
            }
            .padding(.top, 2)
        }
        .overlay {
            if store.hosts.isEmpty, store.groups.isEmpty {
                ContentUnavailableView {
                    Label("没有监控项", systemImage: AnnyIcon.host)
                } description: {
                    Text("点工具栏加号加入一台机器。")
                }
                .symbolRenderingMode(.hierarchical)
            }
        }
    }
```

- [x] **Step 2: Rows without List modifiers**

`emptySearchRow`: drop `.listRow*` / `.selectionDisabled()`. Use `.padding(.horizontal, 12)` `.padding(.vertical, 8)`.

`groupListRow`: drop List modifiers. Padding leading 6 trailing 8. Background drop highlight.

`hostListRow`: no `.tag`. Machine: tap sets `selectedID`, accent background when selected. Inspect: tap toggles `inspect.setChecked`, no selected highlight. Double-click only when `workspace == .machine`. Keep context menu, drag, drop.

- [x] **Step 3: Checkboxes only on inspect**

`hostRow` / `groupHeader`: wrap the `Toggle` in `if workspace == .inspect`. Host inspect `Toggle` uses `.allowsHitTesting(false)` so the row tap is the only gesture (avoid double-toggle).

---

### Task 4: Per-host cache

**Files:**
- Modify: `anny/ContentView.swift`

- [x] **Step 1: Dictionaries and helpers**

```swift
    @State private var metricsByHost: [UUID: HostMetrics] = [:]
    @State private var processesByHost: [UUID: ProcessSnapshot] = [:]
    @State private var networkByHost: [UUID: NetworkSnapshot] = [:]

    private func publishMetrics(_ value: HostMetrics?, hostID: UUID) {
        if let value { metricsByHost[hostID] = value } else { metricsByHost.removeValue(forKey: hostID) }
        if selectedID == hostID { metrics = value }
    }

    private func publishProcesses(_ value: ProcessSnapshot?, hostID: UUID) {
        if let value { processesByHost[hostID] = value } else { processesByHost.removeValue(forKey: hostID) }
        if selectedID == hostID { processSnapshot = value }
    }

    private func publishNetwork(_ value: NetworkSnapshot?, hostID: UUID) {
        if let value { networkByHost[hostID] = value } else { networkByHost.removeValue(forKey: hostID) }
        if selectedID == hostID { networkSnapshot = value }
    }

    private func forgetCaches(_ id: UUID) {
        metricsByHost.removeValue(forKey: id)
        processesByHost.removeValue(forKey: id)
        networkByHost.removeValue(forKey: id)
    }
```

- [x] **Step 2: Selection change restores cache**

Replace `onChange(of: selectedID)` so it does **not** nil the three snapshots. Restore from dictionaries (missing → nil). Still clear probes, loading flags, live refresh. Then `ensureProcesses()` / `ensureNetwork()` if that pane is showing.

- [x] **Step 3: Write-through on fetch / live / edit / remove**

Every `metrics =` / `processSnapshot =` / `networkSnapshot =` that represents host data goes through `publish*`.

Edit `connectionChanged`: `forgetCaches(host.id)` then clear current pane if selected.

`remove`: `forgetCaches(host.id)` before dropping the host. Do not force `metrics = nil` after changing `selectedID` (let `onChange` restore the next host).

---

### Task 5: Build

- [x] **Step 1:** `xcodebuild -scheme anny -project anny.xcodeproj -configuration Debug -derivedDataPath DerivedData build`

Expected: `** BUILD SUCCEEDED **`
