# 单条重新巡查 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-ruby:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. anny 没有测试 target，不要新增；用 `xcodebuild` 和手工对照 spec 验收。

**Goal:** 巡查结果表右键某一行，只重跑这一台，其他结果保留。

**Architecture:** `InspectStore.restart` 走独立的 `runOne`，不调用会整表替换的 `start()`/`run()`。`InspectView` 结果行加一项「重新巡查」菜单；`isRunning` 时禁用。

**Tech Stack:** SwiftUI + existing `InspectStore` / `InspectStore.fetch`，macOS 14。

---

## File map

| File | Responsibility |
|------|----------------|
| `anny/InspectStore.swift` | `restart(_:)` + `runOne(_:)` |
| `anny/InspectView.swift` | 结果行 `.contextMenu` |

Do not change `Models.swift`, `ContentView.swift`, or SSH.

---

### Task 1: InspectStore.restart

**Files:**
- Modify: `anny/InspectStore.swift`

- [x] **Step 1: Add `restart` and `runOne` after `start`**

Insert after `start(hosts:selectedID:)` (before `cancel()`):

```swift
    func restart(_ host: WatchedHost) {
        guard !isRunning else { return }
        guard runIDs.contains(host.id) else { return }
        runTask = Task { await runOne(host) }
    }
```

Insert after `run(_:)` (before `fetch`):

```swift
    private func runOne(_ host: WatchedHost) async {
        runningIDs = [host.id]
        records.removeValue(forKey: host.id)
        let record = await InspectStore.fetch(host)
        if !Task.isCancelled {
            records[host.id] = record
        }
        runningIDs = []
        save()
    }
```

Rules from spec:

- Do not change `runIDs`.
- Do not call `start` or `run`.
- Cancelled fetch does not write a record.
- Always clear `runningIDs` and `save()` at the end.

- [x] **Step 2: Confirm `start` / `cancel` / `run` are unchanged**

`start` still replaces the table. `cancel` still only calls `runTask?.cancel()`.

---

### Task 2: Result row context menu

**Files:**
- Modify: `anny/InspectView.swift` (the `ForEach(rows)` row modifiers)

- [x] **Step 1: Add context menu on each result row**

After `.onTapGesture { ... }`, add:

```swift
                        .contextMenu {
                            Button("重新巡查") {
                                tableSelection = row.id
                                onSelect(row.id)
                                inspect.restart(row.host)
                            }
                            .disabled(inspect.isRunning)
                        }
```

Menu has only this item. No sidebar menu changes.

---

### Task 3: Build

**Files:** none (verify only)

- [x] **Step 1: Compile**

Run:

```bash
xcodebuild -scheme anny -project anny.xcodeproj -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2: Manual checklist (when the app can be clicked)**

1. After a batch finishes, right-click one row → 重新巡查: only that row shows 巡查中; others stay; only that record updates.
2. While a batch is running, the menu item is disabled.
3. During a single restart, 停止 leaves that row not running and with no new record.
4. A host that cannot connect ends as 失败; sidebar dot turns red.

---

## Spec coverage

| Spec | Task |
|------|------|
| In-place update, not `start()` | Task 1 |
| Disabled while running | Task 2 |
| Clear old record, show 巡查中 | Task 1 (`runOne` + existing row UI) |
| Failure record unchanged | Task 1 (reuse `fetch`) |
| Sidebar dots follow `records` | no code (existing) |
| Select row then restart | Task 2 |
| Toolbar progress / 停止 | existing `isRunning` + `cancel` |
| No new test target | Task 3 |
