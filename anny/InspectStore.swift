import Foundation

@MainActor
final class InspectStore: ObservableObject {
    @Published var checked: Set<UUID> = []
    @Published var concurrency = 4
    @Published private(set) var records: [UUID: InspectRecord] = [:]
    @Published private(set) var runIDs: [UUID] = []
    @Published private(set) var runningIDs: Set<UUID> = []

    private var runTask: Task<Void, Never>?

    var isRunning: Bool { !runningIDs.isEmpty }

    var finishedCount: Int {
        runIDs.filter { records[$0] != nil && !runningIDs.contains($0) }.count
    }

    var dangerCount: Int {
        runIDs.compactMap { records[$0] }.filter { $0.severity == .danger }.count
    }

    private var fileURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = root.appendingPathComponent("anny", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("inspect.json")
    }

    init() {
        load()
    }

    func record(for id: UUID) -> InspectRecord? {
        records[id]
    }

    func isChecked(_ id: UUID) -> Bool {
        checked.contains(id)
    }

    func setChecked(_ id: UUID, _ on: Bool) {
        if on {
            checked.insert(id)
        } else {
            checked.remove(id)
        }
    }

    func setChecked(_ ids: [UUID], _ on: Bool) {
        if on {
            checked.formUnion(ids)
        } else {
            checked.subtract(ids)
        }
    }

    func clearChecked() {
        checked.removeAll()
    }

    func setConcurrency(_ n: Int) {
        let next = InspectFile.clampedConcurrency(n)
        guard next != concurrency else { return }
        concurrency = next
        save()
    }

    func forget(_ id: UUID) {
        checked.remove(id)
        records.removeValue(forKey: id)
        runIDs.removeAll { $0 == id }
        save()
    }

    func start(hosts: [WatchedHost], selectedID: UUID?) {
        guard !isRunning else { return }
        var targets = hosts.filter { checked.contains($0.id) }
        if targets.isEmpty, let selectedID, let host = hosts.first(where: { $0.id == selectedID }) {
            checked.insert(host.id)
            targets = [host]
        }
        guard !targets.isEmpty else { return }
        runTask?.cancel()
        runTask = Task { await run(targets) }
    }

    func restart(_ host: WatchedHost) {
        guard !isRunning else { return }
        guard runIDs.contains(host.id) else { return }
        runTask = Task { await runOne(host) }
    }

    func cancel() {
        runTask?.cancel()
    }

    private func run(_ hosts: [WatchedHost]) async {
        runIDs = hosts.map(\.id)
        runningIDs = Set(hosts.map(\.id))
        for host in hosts {
            records.removeValue(forKey: host.id)
        }

        await withTaskGroup(of: (UUID, InspectRecord).self) { group in
            var iterator = hosts.makeIterator()
            for _ in 0..<min(concurrency, hosts.count) {
                if let host = iterator.next() {
                    group.addTask {
                        (host.id, await InspectStore.fetch(host))
                    }
                }
            }
            for await (id, record) in group {
                if !Task.isCancelled {
                    records[id] = record
                }
                runningIDs.remove(id)
                if !Task.isCancelled, let host = iterator.next() {
                    group.addTask {
                        (host.id, await InspectStore.fetch(host))
                    }
                }
            }
        }

        runningIDs = []
        save()
    }

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

    nonisolated private static func fetch(_ host: WatchedHost) async -> InspectRecord {
        do {
            let metrics = try await Task.detached {
                try SSHService.fetchMetrics(host)
            }.value
            return InspectRecord.from(hostID: host.id, metrics: metrics)
        } catch {
            return InspectRecord.failure(hostID: host.id, message: error.localizedDescription)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(InspectFile.self, from: data)
        else { return }
        records = Dictionary(uniqueKeysWithValues: file.records.map { ($0.id, $0) })
        runIDs = file.lastRunIDs
        concurrency = file.concurrency
    }

    private func save() {
        let file = InspectFile(
            records: Array(records.values),
            lastRunIDs: runIDs,
            concurrency: concurrency
        )
        try? JSONEncoder().encode(file).write(to: fileURL, options: .atomic)
    }
}
