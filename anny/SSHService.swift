import Foundation

enum SSHService {
    static func fetchMetrics(_ host: WatchedHost) throws -> HostMetrics {
        parseMetrics(try runSSH(host, script: metricsScript, timeout: 18))
    }

    static func fetchLive(_ host: WatchedHost, sampleCPU: Bool) throws -> LiveMetrics {
        let script = sampleCPU ? liveSampleScript : liveScript
        let timeout: TimeInterval = sampleCPU ? 10 : 8
        return parseLive(try runSSH(host, script: script, timeout: timeout))
    }

    static func cpuPercent(_ a: [Int64], _ b: [Int64]) -> Double? {
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

    private static let meminfoKeys = "MemTotal:|MemAvailable:|SwapTotal:|SwapFree:"

    private static var metricsScript: String {
        """
        echo '===LOAD==='
        cat /proc/loadavg
        echo '===MEM==='
        awk '/\(meminfoKeys)/ {print}' /proc/meminfo
        echo '===CPU1==='
        grep '^cpu ' /proc/stat
        sleep 0.4
        echo '===CPU2==='
        grep '^cpu ' /proc/stat
        echo '===DF==='
        df -B1 -P -x tmpfs -x devtmpfs -x overlay -x squashfs 2>/dev/null
        echo '===OS==='
        if [ -r /etc/os-release ]; then
          grep -E '^(NAME|PRETTY_NAME|VERSION|VERSION_ID|ID)=' /etc/os-release
        elif [ -r /etc/redhat-release ]; then
          printf 'PRETTY_NAME=%s\\n' "$(cat /etc/redhat-release)"
        fi
        echo '===UNAME==='
        uname -srm
        echo '===WAN==='
        if command -v timeout >/dev/null 2>&1; then
          timeout 3 sh -c 'curl -4 -fsS --max-time 2 https://4.ipw.cn || curl -4 -fsS --max-time 2 https://ip.3322.net'
        else
          curl -4 -fsS --max-time 2 https://4.ipw.cn
        fi 2>/dev/null | tr -d '\\r' | grep -Eo '([0-9]{1,3}\\.){3}[0-9]{1,3}' | head -n1
        """
    }

    private static var liveScript: String {
        """
        echo '===LOAD==='
        cat /proc/loadavg
        echo '===MEM==='
        awk '/\(meminfoKeys)/ {print}' /proc/meminfo
        echo '===CPU==='
        grep '^cpu ' /proc/stat
        """
    }

    private static var liveSampleScript: String {
        """
        echo '===LOAD==='
        cat /proc/loadavg
        echo '===MEM==='
        awk '/\(meminfoKeys)/ {print}' /proc/meminfo
        echo '===CPU1==='
        grep '^cpu ' /proc/stat
        sleep 0.3
        echo '===CPU2==='
        grep '^cpu ' /proc/stat
        """
    }

    private static func runSSH(_ host: WatchedHost, script: String, timeout: TimeInterval) throws -> String {
        let hasPassword = HostSecretStore.hasPassword(for: host.id)
        var arguments = [
            "-o", "ConnectTimeout=8",
            "-p", "\(host.port)",
        ]
        arguments += SSHAuth.sshFlags(hasPassword: hasPassword)
        arguments += [host.sshTarget, script]

        let result = try ProcessRun.run(
            "/usr/bin/ssh",
            arguments: arguments,
            environment: SSHAuth.processEnvironment(hostID: host.id),
            timeout: timeout
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

        return result.stdout
    }

    private static func parseMetrics(_ raw: String) -> HostMetrics {
        var load1: Double?
        var memTotal: Int64?
        var memAvail: Int64?
        var swapTotal: Int64?
        var swapFree: Int64?
        var cpu1: [Int64] = []
        var cpu2: [Int64] = []
        var disks: [DiskRow] = []
        var osPretty: String?
        var osName: String?
        var osVersion: String?
        var osVersionId: String?
        var kernel: String?
        var publicIP: String?
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
                applyMeminfo(line, total: &memTotal, avail: &memAvail, swapTotal: &swapTotal, swapFree: &swapFree)
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
            case "===OS===":
                guard let (key, value) = osReleaseField(line) else { break }
                switch key {
                case "PRETTY_NAME": osPretty = value
                case "NAME": osName = value
                case "VERSION": osVersion = value
                case "VERSION_ID": osVersionId = value
                case "ID":
                    if osName == nil { osName = value }
                default:
                    break
                }
            case "===UNAME===":
                let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { kernel = t }
            case "===WAN===":
                if publicIP == nil { publicIP = Self.parsePublicIP(line) }
            default:
                break
            }
        }

        return HostMetrics(
            cpuPercent: cpuPercent(cpu1, cpu2),
            cpuTicks: cpu2.isEmpty ? nil : cpu2,
            load1: load1,
            memTotal: memTotal,
            memAvailable: memAvail,
            swapTotal: swapTotal,
            swapFree: swapFree,
            disks: disks,
            osPretty: osPretty,
            osName: osName,
            osVersion: osVersion ?? osVersionId,
            kernel: kernel,
            publicIP: publicIP,
            fetchedAt: Date(),
            error: nil
        )
    }

    private static func parseLive(_ raw: String) -> LiveMetrics {
        var load1: Double?
        var memTotal: Int64?
        var memAvail: Int64?
        var swapTotal: Int64?
        var swapFree: Int64?
        var cpu1: [Int64] = []
        var cpu2: [Int64] = []
        var cpu: [Int64] = []
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
                applyMeminfo(line, total: &memTotal, avail: &memAvail, swapTotal: &swapTotal, swapFree: &swapFree)
            case "===CPU===":
                cpu = cpuFields(line)
            case "===CPU1===":
                cpu1 = cpuFields(line)
            case "===CPU2===":
                cpu2 = cpuFields(line)
            default:
                break
            }
        }

        let ticks = cpu2.isEmpty ? cpu : cpu2
        return LiveMetrics(
            cpuPercent: cpu2.isEmpty ? nil : cpuPercent(cpu1, cpu2),
            cpuTicks: ticks,
            load1: load1,
            memTotal: memTotal,
            memAvailable: memAvail,
            swapTotal: swapTotal,
            swapFree: swapFree
        )
    }

    private static func applyMeminfo(
        _ line: String,
        total: inout Int64?,
        avail: inout Int64?,
        swapTotal: inout Int64?,
        swapFree: inout Int64?
    ) {
        if let n = memBytes(line, key: "MemTotal:") { total = n }
        if let n = memBytes(line, key: "MemAvailable:") { avail = n }
        if let n = memBytes(line, key: "SwapTotal:") { swapTotal = n }
        if let n = memBytes(line, key: "SwapFree:") { swapFree = n }
    }

    private static func memBytes(_ line: String, key: String) -> Int64? {
        guard line.hasPrefix(key) else { return nil }
        let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let v = parts.dropFirst().first, let n = Int64(v) else { return nil }
        return n * 1024
    }

    private static func parsePublicIP(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = t.split(separator: ".")
        guard parts.count == 4,
              parts.allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false })
        else { return nil }
        return t
    }

    private static func osReleaseField(_ line: String) -> (String, String)? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let key = String(line[..<eq])
        var value = String(line[line.index(after: eq)...])
        if value.count >= 2, value.first == "\"", value.last == "\"" {
            value = String(value.dropFirst().dropLast())
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : (key, value)
    }

    private static func cpuFields(_ line: String) -> [Int64] {
        line.split(whereSeparator: \.isWhitespace).dropFirst().compactMap { Int64($0) }
    }
}
