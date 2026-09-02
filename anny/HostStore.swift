import Darwin
import Foundation

@MainActor
final class HostStore: ObservableObject {
    @Published private(set) var hosts: [WatchedHost] = []
    @Published private(set) var groups: [HostGroup] = []
    @Published private(set) var ungroupedCollapsed = false

    private var directoryWatcher: DispatchSourceFileSystemObject?
    private var reloadTask: Task<Void, Never>?
    private var ignoreReloadUntil: Date?

    private var fileURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = root.appendingPathComponent("anny", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("hosts.json")
    }

    init() {
        migrateLegacyWatchlistIfNeeded()
        load()
        startWatching()
    }

    /// 旧版名单在 Application Support/FanxyTS，只搬一次。
    private func migrateLegacyWatchlistIfNeeded() {
        let fm = FileManager.default
        guard let root = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let next = fileURL
        let previous = root.appendingPathComponent("FanxyTS", isDirectory: true).appendingPathComponent("hosts.json")
        guard !fm.fileExists(atPath: next.path), fm.fileExists(atPath: previous.path) else { return }
        try? fm.copyItem(at: previous, to: next)
    }

    func load() {
        if let until = ignoreReloadUntil, Date() < until { return }
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? WatchlistFile.decode(data)
        else { return }
        if decoded.hosts != hosts {
            hosts = decoded.hosts
        }
        if decoded.groups != groups {
            groups = decoded.groups
        }
        if decoded.ungroupedCollapsed != ungroupedCollapsed {
            ungroupedCollapsed = decoded.ungroupedCollapsed
        }
    }

    func add(_ host: WatchedHost, password: String? = nil) {
        let name = host.hostname.lowercased()
        guard !name.isEmpty else { return }
        if hosts.contains(where: { $0.hostname.lowercased() == name && $0.port == host.port && $0.user == host.user }) {
            return
        }
        hosts.append(host)
        if let password, !password.isEmpty {
            HostSecretStore.save(password, for: host.id)
        }
        save()
    }

    /// 只改本机名单字段，不调用 tailscale / headscale。
    @discardableResult
    func update(id: UUID, user: String? = nil, port: Int? = nil, note: String? = nil) -> Bool {
        guard let i = hosts.firstIndex(where: { $0.id == id }) else { return false }
        var changed = false
        if let user {
            let next = user.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = next.isEmpty ? "root" : next
            if hosts[i].user != name {
                hosts[i].user = name
                changed = true
            }
        }
        if let port {
            let next = (1...65535).contains(port) ? port : 22
            if hosts[i].port != next {
                hosts[i].port = next
                changed = true
            }
        }
        if let note {
            let next = note.trimmingCharacters(in: .whitespacesAndNewlines)
            if hosts[i].note != next {
                hosts[i].note = next
                changed = true
            }
        }
        if changed { save() }
        return changed
    }

    func setPassword(id: UUID, password: String) {
        let next = password.trimmingCharacters(in: .whitespacesAndNewlines)
        if next.isEmpty {
            HostSecretStore.delete(for: id)
        } else {
            HostSecretStore.save(next, for: id)
        }
    }

    func clearPassword(id: UUID) {
        HostSecretStore.delete(for: id)
    }

    func move(from source: IndexSet, to destination: Int) {
        hosts.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func moveInBucket(groupID: UUID?, from source: IndexSet, to destination: Int) {
        let idxs = hosts.indices.filter { hosts[$0].groupID == groupID }
        guard !idxs.isEmpty else { return }
        var values = idxs.map { hosts[$0] }
        values.move(fromOffsets: source, toOffset: destination)
        var next = hosts
        for (i, idx) in idxs.enumerated() {
            next[idx] = values[i]
        }
        if next != hosts {
            hosts = next
            save()
        }
    }

    @discardableResult
    func addGroup(named name: String = "未命名分组") -> HostGroup {
        let group = HostGroup(name: name)
        groups.append(group)
        save()
        return group
    }

    func renameGroup(id: UUID, to name: String) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, groups[i].name != trimmed else { return }
        groups[i].name = trimmed
        save()
    }

    func setCollapsed(groupID: UUID?, collapsed: Bool) {
        if let groupID {
            guard let i = groups.firstIndex(where: { $0.id == groupID }) else { return }
            guard groups[i].collapsed != collapsed else { return }
            groups[i].collapsed = collapsed
            save()
            return
        }
        guard ungroupedCollapsed != collapsed else { return }
        ungroupedCollapsed = collapsed
        save()
    }

    func toggleCollapsed(groupID: UUID?) {
        if let groupID {
            guard let group = groups.first(where: { $0.id == groupID }) else { return }
            setCollapsed(groupID: groupID, collapsed: !group.collapsed)
        } else {
            setCollapsed(groupID: nil, collapsed: !ungroupedCollapsed)
        }
    }

    func deleteGroup(id: UUID) {
        guard groups.contains(where: { $0.id == id }) else { return }
        for i in hosts.indices where hosts[i].groupID == id {
            hosts[i].groupID = nil
        }
        groups.removeAll { $0.id == id }
        save()
    }

    /// `groupID` 为 nil 表示未分组。`before` 为 nil 时加到该组末尾。
    func moveHost(_ id: UUID, toGroup groupID: UUID?, before neighborID: UUID?) {
        guard let from = hosts.firstIndex(where: { $0.id == id }) else { return }
        if let groupID, !groups.contains(where: { $0.id == groupID }) { return }
        if let neighborID, neighborID == id { return }

        var host = hosts[from]
        if host.groupID == groupID, neighborID == nil { return }

        host.groupID = groupID
        hosts.remove(at: from)

        if let neighborID,
           let insertAt = hosts.firstIndex(where: { $0.id == neighborID }),
           hosts[insertAt].groupID == groupID {
            hosts.insert(host, at: insertAt)
        } else if let last = hosts.lastIndex(where: { $0.groupID == groupID }) {
            hosts.insert(host, at: hosts.index(after: last))
        } else {
            hosts.append(host)
        }
        save()
    }

    /// 只删本机监控名单，不调用 tailscale / headscale。
    func removeFromWatchlist(_ host: WatchedHost) {
        HostSecretStore.delete(for: host.id)
        hosts.removeAll { $0.id == host.id }
        save()
    }

    private func save() {
        // 原子写入会触发目录监视；忽略随后这次重读，避免读到旧文件把折叠打回去。
        ignoreReloadUntil = Date().addingTimeInterval(0.4)
        let data = try? JSONEncoder().encode(
            Watchlist(groups: groups, hosts: hosts, ungroupedCollapsed: ungroupedCollapsed)
        )
        try? data?.write(to: fileURL, options: .atomic)
    }

    /// 监视目录而不是文件：原子写入会换 inode，盯着旧文件会丢事件。
    private func startWatching() {
        let dir = fileURL.deletingLastPathComponent()
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleReload()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        directoryWatcher = source
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            load()
        }
    }
}
