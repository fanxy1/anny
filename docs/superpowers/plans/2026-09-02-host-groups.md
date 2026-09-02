# Host Groups Implementation Plan

> **For agentic workers:** Implement task-by-task in this session. Verify with `xcodebuild` and a manual sidebar pass. There is no anny test target — do not add one for this feature.

**Goal:** Let the user create/rename groups and drag hosts between groups or out to ungrouped.

**Architecture:** Persist a `Watchlist` document (groups + hosts) in the existing `hosts.json`. Each host has optional `groupID`. Ungrouped hosts have `groupID == nil` and live in a built-in 「未分组」 section that is not a real group. Cross-section moves use SwiftUI `draggable` / `dropDestination`; same-section reorder keeps `onMove` with global-index mapping.

**Tech Stack:** SwiftUI + AppKit (macOS 14), `Codable` file in Application Support, existing `HostStore` file watcher.

---

## Product rules

1. **Groups are user-made.** No auto-group from hostname.
2. **Create + rename.** New group starts empty. Rename from the section header.
3. **Drag host → other group.** Host joins that group (append, or insert if dropped on a row).
4. **Drag host → 未分组 / 分组外.** `groupID = nil`.
5. **Empty groups stay.** They are drop targets. Deleting a group ungroups its hosts, does not delete hosts.
6. **New / imported hosts** stay 未分组.
7. **Search** still matches note + hostname only. While searching: show only groups (and 未分组) that have hits; disable drag and rename.
8. **Old `hosts.json` arrays** load as all-ungrouped; next save writes the boxed document.

Out of scope: pinning, Tailscale online dots, auto-fetch metrics, dragging group headers to reorder (context menu 上移/下移 is enough if needed later).

---

## Files

| File | Role |
|------|------|
| `anny/Models.swift` | `HostGroup`, `Watchlist`, `WatchedHost.groupID`, decode/encode helpers |
| `anny/HostStore.swift` | Load/save `Watchlist`; group CRUD; move host between groups |
| `anny/ContentView.swift` | Sectioned sidebar, header rename, drag/drop, group menus |
| `anny/Theme.swift` | Optional `AnnyIcon.group` if a header icon is needed |

Do not change SSH, Tailscale, or terminal code.

---

### Task 1: Data model and file format

**Files:** `anny/Models.swift`

- [ ] Add types and keep `WatchedHost` backward compatible (`groupID` defaults to `nil`).

```swift
struct HostGroup: Identifiable, Hashable, Codable {
    var id: UUID
    var name: String

    init(id: UUID = UUID(), name: String) {
        self.id = id
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = trimmed.isEmpty ? "未命名分组" : trimmed
    }
}

struct Watchlist: Hashable, Codable {
    var groups: [HostGroup]
    var hosts: [WatchedHost]
}

extension WatchedHost {
    var groupID: UUID? // add property, default nil in init
}
```

- [ ] Add a decoder that accepts both shapes:

```swift
enum WatchlistFile {
    static func decode(_ data: Data) throws -> Watchlist {
        let decoder = JSONDecoder()
        if let box = try? decoder.decode(Watchlist.self, from: data), !box.hosts.isEmpty || data.contains(UInt8(ascii: "{")) {
            // Prefer object if it has "groups" key; see HostStore.load for the robust check.
            return sanitize(box)
        }
        if let hosts = try? decoder.decode([WatchedHost].self, from: data) {
            return Watchlist(groups: [], hosts: hosts)
        }
        throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "hosts.json"))
    }

    static func sanitize(_ list: Watchlist) -> Watchlist {
        let ids = Set(list.groups.map(\.id))
        var hosts = list.hosts
        for i in hosts.indices {
            if let gid = hosts[i].groupID, !ids.contains(gid) {
                hosts[i].groupID = nil
            }
        }
        return Watchlist(groups: list.groups, hosts: hosts)
    }
}
```

In `HostStore.load`, distinguish formats by peeking JSON: if the first non-space is `[`, decode `[WatchedHost]`; if `{`, decode `Watchlist`.

`WatchedHost` `init` and `Codable` must still decode old objects that have no `groupID`.

- [ ] Build: `xcodebuild -project anny.xcodeproj -scheme anny -configuration Debug -derivedDataPath DerivedData build`  
  Expected: ** BUILD SUCCEEDED **

---

### Task 2: HostStore group API

**Files:** `anny/HostStore.swift`

Keep `@Published hosts`. Add `@Published groups: [HostGroup] = []`. `save()` writes:

```swift
JSONEncoder().encode(Watchlist(groups: groups, hosts: hosts))
```

- [ ] Replace `load()` so it uses the peek + `WatchlistFile` rules, then assigns `groups` and `hosts` only when either changed.

- [ ] Add:

```swift
func addGroup(named name: String = "未命名分组") -> HostGroup
func renameGroup(id: UUID, to name: String)
func deleteGroup(id: UUID)           // hosts with that id → groupID nil
func moveGroup(from: IndexSet, to: Int) // optional; skip UI if unused

/// groupID nil = 未分组. before == nil → append inside that bucket.
func moveHost(_ id: UUID, toGroup groupID: UUID?, before neighborID: UUID?)
```

`moveHost` algorithm:

1. Find host index `i`.
2. Set `hosts[i].groupID = groupID` (nil if ungrouped).
3. Remove host from array, then insert:
   - if `before` is a host currently in the **same target bucket**, insert at that host’s index;
   - else append after the last host already in that bucket (or at end if none).

Keep existing `move(from:to:)` for same-bucket `onMove`: ContentView will map section-local `IndexSet` to global indices of that bucket, then call `move`.

`add(_:)` leaves `groupID` as provided (default nil).

- [ ] Build succeeds.

---

### Task 3: Sidebar sections

**Files:** `anny/ContentView.swift`

- [ ] Derive rows:

```swift
struct HostBucket: Identifiable {
    var id: UUID?          // nil = 未分组
    var title: String
    var hosts: [WatchedHost]
}

private var buckets: [HostBucket] {
    let shown = visibleHosts
    var result: [HostBucket] = store.groups.map { g in
        HostBucket(id: g.id, title: g.name, hosts: shown.filter { $0.groupID == g.id })
    }
    let loose = shown.filter { $0.groupID == nil }
    let showLoose = !isSearching || !loose.isEmpty
    if showLoose {
        result.append(HostBucket(id: nil, title: "未分组", hosts: loose))
    }
    if isSearching {
        result.removeAll { $0.hosts.isEmpty }
    }
    return result
}
```

- [ ] List body: `ForEach(buckets)` → `Section` with header + `ForEach(bucket.hosts)` rows (same `hostRow` / tag / contextMenu / double-click overlay as today).

- [ ] Header 「监控名单」 trailing `+` button: `store.addGroup()` then start rename on that id (see Task 4).

- [ ] While `isSearching`, `onMove` is nil and drop is disabled (same as today’s search).

- [ ] Build and run. Existing 44 hosts all appear under **未分组**. No groups yet.

---

### Task 4: Create and rename groups

**Files:** `anny/ContentView.swift`

State: `@State private var renamingGroupID: UUID?`

- [ ] Group header (not 未分组):

  - Click title when not renaming → no selection change (`selectionDisabled` on header).
  - Context menu: **重命名**、**删除分组**.
  - Double-click title or 重命名 → `renamingGroupID = id`, `TextField` in place, Enter/blur commits `store.renameGroup`.
  - 删除分组 → `store.deleteGroup` (hosts fall into 未分组).

- [ ] 未分组 header: no rename, no delete, no `+` on the header.

- [ ] New group: `let g = store.addGroup(named: "未命名分组")`; `renamingGroupID = g.id` so the user types immediately.

- [ ] Empty name after trim → keep previous name (or `未命名分组` if it was new and never named). Do not create a second empty-named group from blur-on-empty.

- [ ] Verify: add 高新 / Skylark, rename, delete Skylark, its hosts (if any) sit in 未分组.

---

### Task 5: Drag between groups and out

**Files:** `anny/ContentView.swift`

SwiftUI `List.onMove` cannot move across sections. Use:

- **Same bucket:** `onMove` on that section’s `ForEach`, map local indices → global `store.move`.
- **Across buckets:** `.draggable(host.id.uuidString)` on the row; `.dropDestination(for: String.self)` on:
  - group header (including empty groups),
  - 未分组 header,
  - each host row (insert before that host, adopt that host’s `groupID`).

```swift
store.moveHost(draggedID, toGroup: targetBucket.groupID, before: droppedOnHostID)
```

Drop on header: `before: nil` (append in that bucket).  
Drop on 未分组 header: `toGroup: nil`.  
Drop on a 未分组 row: `toGroup: nil, before: that row`.

Visual: `dropDestination` `isTargeted` dims/highlights the header or row.

Do **not** put `TapGesture(count: 2)` back on rows (selection bug). Double-click to open terminal stays on `HostListDoubleClick`.

- [ ] Manual check:
  1. Drag `合作 skylark` onto 高新 header → it leaves 未分组.
  2. Drag it onto 未分组 header → back out.
  3. Drag onto a row in Skylark → inserted before that row, group = Skylark.
  4. Reorder two hosts inside 高新 via drag handle / onMove.
  5. Search `合作` → only matching sections; cannot drag.
  6. Quit and reopen → groups and membership persist.

- [ ] `xcodebuild` … ** BUILD SUCCEEDED **

---

## Manual test plan

- [ ] Fresh load of current Application Support file: all hosts 未分组, app does not crash.
- [ ] Create two groups, rename both.
- [ ] Drag several hosts in, between, and out.
- [ ] Delete a non-empty group: hosts visible under 未分组, still SSH/selectable.
- [ ] Import / add host: appears in 未分组.
- [ ] File watcher: edit `hosts.json` on disk, switch back to anny, groups still decode.

---

## Spec coverage

| Requirement | Task |
|-------------|------|
| 新增分组 | Task 4 (`addGroup` + header +) |
| 修改分组名称 | Task 4 (inline rename / 重命名) |
| 拖到其他分组 | Task 5 (drop on header or row) |
| 拖到分组外 | Task 5 (未分组 header/row) |
| Old watchlist still opens | Task 1–2 (array peek) |
