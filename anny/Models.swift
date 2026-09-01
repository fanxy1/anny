import Foundation

struct WatchedHost: Identifiable, Hashable, Codable {
    var id: UUID
    var hostname: String
    var user: String
    var port: Int
    var note: String

    init(
        id: UUID = UUID(),
        hostname: String,
        user: String = "root",
        port: Int = 22,
        note: String = ""
    ) {
        self.id = id
        self.hostname = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        self.user = user.isEmpty ? "root" : user
        self.port = port > 0 ? port : 22
        self.note = note
    }

    var sshTarget: String { "\(user)@\(hostname)" }

    /// 名单只显示备注；没有备注时只显示主机名（user@ 后面那一段）。
    var displayName: String {
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? hostname : n
    }

    /// 不用 LocalizedStringKey，避免端口被格式化成 10,022。
    var endpointLabel: String { "\(sshTarget):\(port)" }
}

struct TailscalePeer: Identifiable, Hashable {
    var id: String { hostname }
    var hostname: String
    var ip: String
    var online: Bool
}

struct DiskRow: Identifiable, Hashable {
    var id: String { "\(mount)-\(source)" }
    var source: String
    var size: Int64
    var used: Int64
    var avail: Int64
    var percent: String
    var mount: String
}

struct HostMetrics: Hashable {
    var cpuPercent: Double?
    var load1: Double?
    var memTotal: Int64?
    var memAvailable: Int64?
    var disks: [DiskRow]
    var osPretty: String? = nil
    var osName: String? = nil
    var osVersion: String? = nil
    var kernel: String? = nil
    var fetchedAt: Date
    var error: String?

    var memUsed: Int64? {
        guard let total = memTotal, let avail = memAvailable else { return nil }
        return max(0, total - avail)
    }
}
