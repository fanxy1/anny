import Foundation

struct HostGroup: Identifiable, Hashable, Codable {
    var id: UUID
    var name: String
    var collapsed: Bool

    private enum CodingKeys: String, CodingKey {
        case id, name, collapsed
    }

    init(id: UUID = UUID(), name: String, collapsed: Bool = false) {
        self.id = id
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = trimmed.isEmpty ? "未命名分组" : trimmed
        self.collapsed = collapsed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(collapsed, forKey: .collapsed)
    }
}

struct Watchlist: Hashable, Codable {
    var groups: [HostGroup]
    var hosts: [WatchedHost]
    var ungroupedCollapsed: Bool

    private enum CodingKeys: String, CodingKey {
        case groups, hosts, ungroupedCollapsed
    }

    init(groups: [HostGroup], hosts: [WatchedHost], ungroupedCollapsed: Bool = false) {
        self.groups = groups
        self.hosts = hosts
        self.ungroupedCollapsed = ungroupedCollapsed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groups = try c.decode([HostGroup].self, forKey: .groups)
        hosts = try c.decode([WatchedHost].self, forKey: .hosts)
        ungroupedCollapsed = try c.decodeIfPresent(Bool.self, forKey: .ungroupedCollapsed) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(groups, forKey: .groups)
        try c.encode(hosts, forKey: .hosts)
        try c.encode(ungroupedCollapsed, forKey: .ungroupedCollapsed)
    }
}

enum WatchlistFile {
    static func decode(_ data: Data) throws -> Watchlist {
        let trimmed = data.drop(while: { [0x09, 0x0A, 0x0D, 0x20].contains($0) })
        guard let first = trimmed.first else {
            return Watchlist(groups: [], hosts: [])
        }
        let decoder = JSONDecoder()
        if first == UInt8(ascii: "[") {
            let hosts = try decoder.decode([WatchedHost].self, from: data)
            return Watchlist(groups: [], hosts: hosts)
        }
        return sanitize(try decoder.decode(Watchlist.self, from: data))
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

struct WatchedHost: Identifiable, Hashable, Codable {
    var id: UUID
    var hostname: String
    var user: String
    var port: Int
    var note: String
    var groupID: UUID?

    init(
        id: UUID = UUID(),
        hostname: String,
        user: String = "root",
        port: Int = 22,
        note: String = "",
        groupID: UUID? = nil
    ) {
        self.id = id
        self.hostname = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        self.user = user.isEmpty ? "root" : user
        self.port = port > 0 ? port : 22
        self.note = note
        self.groupID = groupID
    }

    var sshTarget: String { "\(user)@\(hostname)" }

    /// 名单只显示备注；没有备注时只显示主机名（user@ 后面那一段）。
    var displayName: String {
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? hostname : n
    }

    /// 不用 LocalizedStringKey，避免端口被格式化成 10,022。
    var endpointLabel: String { "\(sshTarget):\(port)" }

    /// 只搜备注和主机名，不搜账户、端口。
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return true }
        return note.localizedStandardContains(q)
            || hostname.localizedStandardContains(q)
    }
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

struct UnusedDiskRow: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var size: Int64
    var model: String
    var status: String
}

struct LiveMetrics: Hashable {
    var cpuPercent: Double?
    var cpuTicks: [Int64]
    var cpuCores: Int?
    var cpuThreads: Int?
    var load1: Double?
    var memTotal: Int64?
    var memAvailable: Int64?
    var swapTotal: Int64?
    var swapFree: Int64?
}

struct HostMetrics: Hashable {
    var cpuPercent: Double? = nil
    var cpuTicks: [Int64]? = nil
    var cpuCores: Int? = nil
    var cpuThreads: Int? = nil
    var load1: Double? = nil
    var memTotal: Int64? = nil
    var memAvailable: Int64? = nil
    var swapTotal: Int64? = nil
    var swapFree: Int64? = nil
    var disks: [DiskRow] = []
    var unusedDisks: [UnusedDiskRow] = []
    var osPretty: String? = nil
    var osName: String? = nil
    var osVersion: String? = nil
    var kernel: String? = nil
    var publicIP: String? = nil
    var fetchedAt: Date
    var error: String? = nil

    var memUsed: Int64? {
        guard let total = memTotal, let avail = memAvailable else { return nil }
        return max(0, total - avail)
    }

    var memoryPercent: Double? {
        guard let total = memTotal, let used = memUsed, total > 0 else { return nil }
        return Double(used) / Double(total) * 100
    }

    var swapUsed: Int64? {
        guard let total = swapTotal, let free = swapFree else { return nil }
        return max(0, total - free)
    }

    var swapPercent: Double? {
        guard let total = swapTotal, let used = swapUsed, total > 0 else { return nil }
        return Double(used) / Double(total) * 100
    }

    var worstDiskPercent: Double? {
        let values = disks.compactMap { Double($0.percent.replacingOccurrences(of: "%", with: "")) }
        return values.max()
    }

    var cpuTopologyText: String? {
        switch (cpuCores, cpuThreads) {
        case let (cores?, threads?) where cores > 0 && threads > 0:
            return "\(cores) 核 / \(threads) 线程"
        case let (cores?, _) where cores > 0:
            return "\(cores) 核"
        case let (_, threads?) where threads > 0:
            return "\(threads) 线程"
        default:
            return nil
        }
    }
}

struct ProcessRow: Identifiable, Hashable {
    var pid: Int
    var user: String
    var cpuPercent: Double
    var memPercent: Double
    var rssBytes: Int64
    var command: String
    var ticks: Int64?

    var id: Int { pid }

    var isKernel: Bool {
        command.hasPrefix("[") && command.hasSuffix("]")
    }

    func matches(_ query: String) -> Bool {
        let terms = query
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        if terms.isEmpty { return true }
        let hay = "\(pid) \(user) \(command)".lowercased()
        return terms.contains { hay.contains($0) }
    }
}

struct ProcessSnapshot: Hashable {
    var rows: [ProcessRow] = []
    var clkTck: Double = 100
    var memTotalKB: Int64? = nil
    var fetchedAt: Date
    var error: String? = nil

    var tickMap: [Int: Int64] {
        Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            row.ticks.map { (row.pid, $0) }
        })
    }
}

struct NicRow: Identifiable, Hashable {
    var name: String
    var up: Bool
    var mac: String
    var mtu: Int?
    var ipv4: [String]
    var ipv6: [String]

    var id: String { name }

    var addressText: String {
        let v4 = ipv4
        let v6 = ipv6.filter { !$0.hasPrefix("fe80:") && !$0.hasPrefix("fe80/") }
        let parts = v4 + v6
        return parts.isEmpty ? "—" : parts.joined(separator: "  ")
    }
}

struct OverlayNetwork: Identifiable, Hashable {
    var name: String
    var scope: String
    var driver: String
    var address: String
    var extra: String

    var id: String { "\(scope)-\(name)-\(address)-\(extra)" }

    var dest: String? {
        let t = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t == "—" ? nil : t
    }
}

struct ProbeRow: Identifiable, Hashable {
    var label: String
    var dest: String
    var scope: String
    var ok: Bool
    var ms: Double?
    var method: String
    var detail: String

    var id: String { "\(scope)-\(label)-\(dest)" }

    var resultText: String {
        if ok {
            if let ms {
                return String(format: "通  %.1f ms", ms)
            }
            return method.isEmpty ? "通" : "通  \(method)"
        }
        return detail.isEmpty ? "不通" : detail
    }
}

struct NetworkSnapshot: Hashable {
    var nics: [NicRow] = []
    var gateway: String? = nil
    var gatewayDev: String? = nil
    var dns: [String] = []
    var docker: [OverlayNetwork] = []
    var k8s: [OverlayNetwork] = []
    var dockerAvailable: Bool = false
    var k8sAvailable: Bool = false
    var fetchedAt: Date
    var error: String? = nil
}

enum InspectSeverity: String, Codable {
    case ok
    case warning
    case danger

    static func of(cpu: Double?, memory: Double?, disk: Double?, error: String?) -> InspectSeverity {
        if error != nil { return .danger }
        let peak = max(cpu ?? 0, memory ?? 0, disk ?? 0)
        if peak >= 90 { return .danger }
        if peak >= 75 { return .warning }
        return .ok
    }
}

struct InspectRecord: Identifiable, Hashable, Codable {
    var id: UUID
    var fetchedAt: Date
    var cpuPercent: Double?
    var memoryPercent: Double?
    var diskPercent: Double?
    var publicIP: String?
    var error: String?

    var severity: InspectSeverity {
        InspectSeverity.of(cpu: cpuPercent, memory: memoryPercent, disk: diskPercent, error: error)
    }

    static func from(hostID: UUID, metrics: HostMetrics) -> InspectRecord {
        InspectRecord(
            id: hostID,
            fetchedAt: metrics.fetchedAt,
            cpuPercent: metrics.cpuPercent,
            memoryPercent: metrics.memoryPercent,
            diskPercent: metrics.worstDiskPercent,
            publicIP: metrics.publicIP,
            error: metrics.error
        )
    }

    static func failure(hostID: UUID, message: String) -> InspectRecord {
        InspectRecord(
            id: hostID,
            fetchedAt: Date(),
            cpuPercent: nil,
            memoryPercent: nil,
            diskPercent: nil,
            publicIP: nil,
            error: message
        )
    }
}

struct InspectFile: Hashable, Codable {
    var records: [InspectRecord]
    var lastRunIDs: [UUID]
    var concurrency: Int

    private enum CodingKeys: String, CodingKey {
        case records, lastRunIDs, concurrency
    }

    init(records: [InspectRecord], lastRunIDs: [UUID], concurrency: Int = 4) {
        self.records = records
        self.lastRunIDs = lastRunIDs
        self.concurrency = InspectFile.clampedConcurrency(concurrency)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        records = try c.decode([InspectRecord].self, forKey: .records)
        lastRunIDs = try c.decode([UUID].self, forKey: .lastRunIDs)
        concurrency = InspectFile.clampedConcurrency(
            try c.decodeIfPresent(Int.self, forKey: .concurrency) ?? 4
        )
    }

    static func clampedConcurrency(_ n: Int) -> Int {
        min(16, max(1, n))
    }
}
