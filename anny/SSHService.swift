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

    static func fetchProcesses(_ host: WatchedHost, previous: ProcessSnapshot?) throws -> ProcessSnapshot {
        let raw = try runSSH(host, script: processScript, timeout: 10)
        return parseProcessSnapshot(raw, previous: previous)
    }

    static func killProcess(_ host: WatchedHost, pid: Int) throws {
        guard pid > 1 else {
            throw NSError(domain: "anny", code: 4, userInfo: [NSLocalizedDescriptionKey: "不能结束这个进程"])
        }
        _ = try runSSH(host, script: "kill -TERM \(pid)", timeout: 8)
    }

    static func instantCPUPercent(previous: Int64, current: Int64, clkTck: Double, elapsed: TimeInterval) -> Double? {
        guard clkTck > 0, elapsed > 0.05, current >= previous else { return nil }
        return Double(current - previous) / clkTck / elapsed * 100
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

    /// Prints `===CPUINFO===` then `cores threads`. Cores are unique package+core pairs; threads are logical CPUs.
    private static let cpuinfoBlock = """
        echo '===CPUINFO==='
        threads=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || true)
        cores=$(grep -E '^(physical id|core id)' /proc/cpuinfo 2>/dev/null | paste - - | sort -u | wc -l)
        cores=$(echo $cores)
        if [ -z "$cores" ] || [ "$cores" -lt 1 ]; then
          cores=$(for d in /sys/devices/system/cpu/cpu[0-9]*; do
            [ -r "$d/topology/core_id" ] || continue
            p=0
            [ -r "$d/topology/physical_package_id" ] && p=$(cat "$d/topology/physical_package_id")
            echo "$p $(cat "$d/topology/core_id")"
          done 2>/dev/null | sort -u | wc -l)
          cores=$(echo $cores)
        fi
        if [ -z "$threads" ] || [ "$threads" -lt 1 ]; then
          threads=$(ls -d /sys/devices/system/cpu/cpu[0-9]* 2>/dev/null | wc -l)
          threads=$(echo $threads)
        fi
        if [ -z "$cores" ] || [ "$cores" -lt 1 ]; then cores=$threads; fi
        echo "$cores $threads"
        """

    /// One-shot process table plus CPU ticks. No sleep. Instant % is computed on the Mac from consecutive samples.
    private static let processScript = """
        echo '===CLK==='
        getconf CLK_TCK 2>/dev/null || echo 100
        echo '===MEM==='
        grep MemTotal /proc/meminfo | tr -s ' ' | cut -d' ' -f2
        echo '===PROCS==='
        LC_ALL=C ps -eo pid=,user=,pcpu=,pmem=,rss=,stat=,args= --no-headers 2>/dev/null | awk '{
          pid=$1; user=$2; pcpu=$3; pmem=$4; rss=$5; stat=$6;
          $1=$2=$3=$4=$5=$6="";
          sub(/^[ \\t]+/, "");
          printf "%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n", pid, user, pcpu, pmem, rss, stat, $0
        }'
        echo '===TICKS==='
        { cat /proc/[0-9]*/stat 2>/dev/null || find /proc -maxdepth 1 -type d -name '[0-9]*' -exec cat {}/stat \\; ; } | awk '{
          pid=$1
          end=0
          for (i = length($0); i > 0; i--) {
            if (substr($0, i, 1) == ")") { end=i; break }
          }
          if (end == 0) next
          rest = substr($0, end + 2)
          n = split(rest, f, " ")
          if (n < 13) next
          printf "%s\\t%s\\t%s\\n", pid, f[12], f[13]
        }'
        """

    private static var metricsScript: String {
        """
        echo '===LOAD==='
        cat /proc/loadavg
        \(cpuinfoBlock)
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
        \(cpuinfoBlock)
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
        \(cpuinfoBlock)
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

    static func parseProcessSnapshot(_ raw: String, previous: ProcessSnapshot?) -> ProcessSnapshot {
        var clkTck: Double = 100
        var memTotalKB: Int64?
        var ticks: [Int: Int64] = [:]
        var rows: [ProcessRow] = []
        var section = ""

        for line in raw.split(whereSeparator: \.isNewline).map(String.init) {
            if line.hasPrefix("===") {
                section = line
                continue
            }
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            switch section {
            case "===CLK===":
                if let n = Double(t), n > 0 { clkTck = n }
            case "===MEM===":
                if let n = Int64(t), n > 0 { memTotalKB = n }
            case "===TICKS===":
                if let parsed = parseTickLine(t) {
                    ticks[parsed.pid] = parsed.ticks
                }
            case "===PROCS===":
                if let row = parseProcessLine(t, memTotalKB: memTotalKB, ticks: ticks) {
                    rows.append(row)
                }
            default:
                break
            }
        }

        if !ticks.isEmpty {
            for i in rows.indices {
                if rows[i].ticks == nil, let extra = ticks[rows[i].pid] {
                    rows[i].ticks = extra
                }
            }
        }

        let fetchedAt = Date()
        if let previous, !previous.tickMap.isEmpty {
            let elapsed = fetchedAt.timeIntervalSince(previous.fetchedAt)
            for i in rows.indices {
                if let now = rows[i].ticks,
                   let old = previous.tickMap[rows[i].pid],
                   let instant = instantCPUPercent(previous: old, current: now, clkTck: clkTck, elapsed: elapsed)
                {
                    rows[i].cpuPercent = instant
                }
            }
        }

        return ProcessSnapshot(
            rows: rows,
            clkTck: clkTck,
            memTotalKB: memTotalKB,
            fetchedAt: fetchedAt,
            error: rows.isEmpty ? "没有读到进程" : nil
        )
    }

    static func parseProcessLine(_ line: String, memTotalKB: Int64?, ticks: [Int: Int64]) -> ProcessRow? {
        let parts = line.split(separator: "\t", maxSplits: 6, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 7,
              let pid = Int(parts[0].trimmingCharacters(in: .whitespaces)), pid > 0
        else { return nil }
        let user = parts[1].trimmingCharacters(in: .whitespaces)
        let pcpu = Double(parts[2].trimmingCharacters(in: .whitespaces)) ?? 0
        let pmem = Double(parts[3].trimmingCharacters(in: .whitespaces)) ?? 0
        let rssKB = Int64(parts[4].trimmingCharacters(in: .whitespaces)) ?? 0
        let command = parts[6].trimmingCharacters(in: .whitespacesAndNewlines)
        let rssBytes = max(0, rssKB) * 1024
        let memPercent: Double
        if let total = memTotalKB, total > 0 {
            memPercent = Double(rssKB) / Double(total) * 100
        } else {
            memPercent = pmem
        }
        return ProcessRow(
            pid: pid,
            user: user.isEmpty ? "—" : user,
            cpuPercent: max(0, pcpu),
            memPercent: max(0, memPercent),
            rssBytes: rssBytes,
            command: command.isEmpty ? "—" : command,
            ticks: ticks[pid]
        )
    }

    static func parseTickLine(_ line: String) -> (pid: Int, ticks: Int64)? {
        let parts = line.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 3,
              let pid = Int(parts[0]), pid > 0,
              let utime = Int64(parts[1]),
              let stime = Int64(parts[2])
        else { return nil }
        return (pid, utime + stime)
    }

    static func parseCPUInfo(_ line: String) -> (cores: Int, threads: Int)? {
        let parts = line.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 2,
              let cores = Int(parts[0]), cores > 0,
              let threads = Int(parts[1]), threads > 0
        else { return nil }
        return (cores, threads)
    }

    private static func parseMetrics(_ raw: String) -> HostMetrics {
        var load1: Double?
        var cpuCores: Int?
        var cpuThreads: Int?
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
            case "===CPUINFO===":
                if let parsed = parseCPUInfo(line) {
                    cpuCores = parsed.cores
                    cpuThreads = parsed.threads
                }
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
            cpuCores: cpuCores,
            cpuThreads: cpuThreads,
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
        var cpuCores: Int?
        var cpuThreads: Int?
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
            case "===CPUINFO===":
                if let parsed = parseCPUInfo(line) {
                    cpuCores = parsed.cores
                    cpuThreads = parsed.threads
                }
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
            cpuCores: cpuCores,
            cpuThreads: cpuThreads,
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
