import Darwin
import Foundation

@MainActor
final class HostStore: ObservableObject {
    @Published private(set) var hosts: [WatchedHost] = []

    private var directoryWatcher: DispatchSourceFileSystemObject?
    private var reloadTask: Task<Void, Never>?

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
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([WatchedHost].self, from: data)
        else { return }
        if decoded != hosts {
            hosts = decoded
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

    /// 只删本机监控名单，不调用 tailscale / headscale。
    func removeFromWatchlist(_ host: WatchedHost) {
        HostSecretStore.delete(for: host.id)
        hosts.removeAll { $0.id == host.id }
        save()
    }

    private func save() {
        let data = try? JSONEncoder().encode(hosts)
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
