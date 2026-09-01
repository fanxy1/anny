import Foundation

enum SSHService {
    static func fetchMetrics(_ host: WatchedHost) throws -> HostMetrics {
        let script = """
        echo '===LOAD==='
        cat /proc/loadavg
        echo '===MEM==='
        awk '/MemTotal:|MemAvailable:/ {print}' /proc/meminfo
        echo '===CPU1==='
        grep '^cpu ' /proc/stat
        sleep 0.4
        echo '===CPU2==='
        grep '^cpu ' /proc/stat
        echo '===DF==='
        df -B1 -P -x tmpfs -x devtmpfs -x overlay -x squashfs 2>/dev/null
        """

        let ssh = "/usr/bin/ssh"
        let result = try ProcessRun.run(
            ssh,
            arguments: [
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=8",
                "-o", "StrictHostKeyChecking=accept-new",
                "-p", "\(host.port)",
                host.sshTarget,
                script,
            ],
            timeout: 18
        )

        guard result.status == 0 else {
            let err = [result.stderr, result.stdout]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "anny",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: err.isEmpty ? "SSH 失败（exit \(result.status)）" : err]
            )
        }

        return parse(result.stdout)
    }

    private static func parse(_ raw: String) -> HostMetrics {
        var load1: Double?
        var memTotal: Int64?
        var memAvail: Int64?
        var cpu1: [Int64] = []
        var cpu2: [Int64] = []
        var disks: [DiskRow] = []
        var section = ""

        for line in raw.split(whereSeparator: \.isNewline).map(String.init) {
            if line.hasPrefix("===") {
                section = line
                continue
            }
            switch section {
            case "===LOAD===":
                load1 = Double(line.split(separator: " ").first.map(String.init) ?? "")
            case "===MEM===":
                let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
                if line.hasPrefix("MemTotal:"), let v = parts.dropFirst().first, let n = Int64(v) {
                    memTotal = n * 1024
                }
                if line.hasPrefix("MemAvailable:"), let v = parts.dropFirst().first, let n = Int64(v) {
                    memAvail = n * 1024
                }
            case "===CPU1===":
                cpu1 = cpuFields(line)
            case "===CPU2===":
                cpu2 = cpuFields(line)
            case "===DF===":
                if line.hasPrefix("Filesystem") { break }
                let cols = line.split(whereSeparator: \.isWhitespace).map(String.init)
                guard cols.count >= 6, let size = Int64(cols[1]), let used = Int64(cols[2]), let avail = Int64(cols[3]) else { break }
                disks.append(
                    DiskRow(
                        source: cols[0],
                        size: size,
                        used: used,
                        avail: avail,
                        percent: cols[4],
                        mount: cols[5]
                    )
                )
            default:
                break
            }
        }

        return HostMetrics(
            cpuPercent: cpuPercent(cpu1, cpu2),
            load1: load1,
            memTotal: memTotal,
            memAvailable: memAvail,
            disks: disks,
            fetchedAt: Date(),
            error: nil
        )
    }

    private static func cpuFields(_ line: String) -> [Int64] {
        line.split(whereSeparator: \.isWhitespace).dropFirst().compactMap { Int64($0) }
    }

    private static func cpuPercent(_ a: [Int64], _ b: [Int64]) -> Double? {
        guard a.count >= 5, b.count >= 5, a.count == b.count else { return nil }
        let idleA = a[3] + (a.count > 4 ? a[4] : 0)
        let idleB = b[3] + (b.count > 4 ? b[4] : 0)
        let totalA = a.reduce(0, +)
        let totalB = b.reduce(0, +)
        let idle = Double(idleB - idleA)
        let total = Double(totalB - totalA)
        guard total > 0 else { return nil }
        return max(0, min(100, (1 - idle / total) * 100))
    }
}
