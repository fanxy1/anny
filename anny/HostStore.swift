import Foundation

@MainActor
final class HostStore: ObservableObject {
    @Published private(set) var hosts: [WatchedHost] = []

    private var fileURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = root.appendingPathComponent("anny", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("hosts.json")
    }

    init() {
        migrateLegacyWatchlistIfNeeded()
        load()
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
        guard let data = try? Data(contentsOf: fileURL) else { return }
        hosts = (try? JSONDecoder().decode([WatchedHost].self, from: data)) ?? []
    }

    func add(_ host: WatchedHost, password: String? = nil) {
        let name = host.hostname.lowercased()
        guard !name.isEmpty else { return }
        if hosts.contains(where: { $0.hostname.lowercased() == name && $0.port == host.port && $0.user == host.user }) {
            return
        }
        hosts.append(host)
        hosts.sort { $0.hostname.localizedCaseInsensitiveCompare($1.hostname) == .orderedAscending }
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
}
