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

    static func fetchNetwork(_ host: WatchedHost) throws -> NetworkSnapshot {
        parseNetworkSnapshot(try runSSH(host, script: networkScript, timeout: 14))
    }

    static func probeNetwork(_ host: WatchedHost, target: String) throws -> [ProbeRow] {
        let cleaned = sanitizedProbeTarget(target)
        if !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, cleaned == nil {
            throw NSError(domain: "anny", code: 5, userInfo: [NSLocalizedDescriptionKey: "请输入合法的 IP 或域名"])
        }
        return parseProbeRows(try runSSH(host, script: probeScript(target: cleaned), timeout: 16))
    }

    static func sanitizedProbeTarget(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 253 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-:_[]"))
        guard t.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return t
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

    private static let networkScript = """
        echo '===LINK==='
        ip -o link show 2>/dev/null
        echo '===ADDR4==='
        ip -o -4 addr show 2>/dev/null
        echo '===ADDR6==='
        ip -o -6 addr show 2>/dev/null
        echo '===ROUTE==='
        ip -4 route show default 2>/dev/null
        echo '===DNS==='
        grep '^nameserver' /etc/resolv.conf 2>/dev/null
        echo '===DOCKER==='
        if command -v docker >/dev/null 2>&1 && docker network ls >/dev/null 2>&1; then
          echo available
          docker network ls --format '{{.Name}}' 2>/dev/null | head -n 12 | while IFS= read -r n; do
            [ -n "$n" ] || continue
            docker network inspect "$n" --format '{{.Name}}\t{{.Driver}}\t{{range .IPAM.Config}}{{.Gateway}}{{end}}\t{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null
          done
        else
          echo missing
        fi
        echo '===K8S==='
        if command -v kubectl >/dev/null 2>&1; then
          if kubectl get --raw=/readyz --request-timeout=2s >/dev/null 2>&1 || kubectl get ns --request-timeout=2s >/dev/null 2>&1; then
            echo available
            kubectl get svc -A --request-timeout=3s --no-headers 2>/dev/null | awk '{
              ip=$4
              if (ip == "<none>" || ip == "None" || ip == "") next
              score=0
              if ($2 == "kubernetes") score=2
              if ($2 ~ /dns/) score=1
              printf "%d\\t%s\\t%s\\t%s\\t%s\\t%s\\n", score, $1, $2, $3, ip, $5
            }' | sort -nr | head -n 12 | cut -f2-
          else
            echo missing
          fi
        else
          echo missing
        fi
        """

    private static func probeScript(target: String?) -> String {
        let targetLine = target.map { "TARGET='\($0)'" } ?? "TARGET=''"
        return """
        \(targetLine)
        echo '===PROBE==='
        probe() {
          label=$1
          dest=$2
          scope=$3
          [ -n "$dest" ] || return 0
          if out=$(ping -c 1 -W 2 "$dest" 2>&1); then
            ms=$(printf '%s\\n' "$out" | sed -n 's/.*time[=<]\\([0-9.]*\\).*/\\1/p' | head -n1)
            printf '%s\\t%s\\t%s\\tok\\t%s\\tping\\t\\n' "$label" "$dest" "$scope" "${ms:-0}"
            return 0
          fi
          if command -v timeout >/dev/null 2>&1; then
            if timeout 2 bash -c "echo >/dev/tcp/$dest/443" 2>/dev/null; then
              printf '%s\\t%s\\t%s\\tok\\t\\ttcp443\\t\\n' "$label" "$dest" "$scope"
              return 0
            fi
            if timeout 2 bash -c "echo >/dev/tcp/$dest/80" 2>/dev/null; then
              printf '%s\\t%s\\t%s\\tok\\t\\ttcp80\\t\\n' "$label" "$dest" "$scope"
              return 0
            fi
          fi
          printf '%s\\t%s\\t%s\\tfail\\t\\t\\t不通\\n' "$label" "$dest" "$scope"
        }
        gw=$(ip -4 route show default 2>/dev/null | awk '/via/ {print $3; exit}')
        dns=$(grep '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2; exit}')
        [ -n "$TARGET" ] && probe 目标 "$TARGET" host &
        [ -n "$gw" ] && probe 网关 "$gw" host &
        [ -n "$dns" ] && probe DNS "$dns" host &
        if command -v docker >/dev/null 2>&1 && docker network ls >/dev/null 2>&1; then
          docker network ls --format '{{.Name}}' 2>/dev/null | head -n 8 | while IFS= read -r n; do
            [ -n "$n" ] || continue
            g=$(docker network inspect "$n" --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null)
            [ -n "$g" ] && probe "$n" "$g" docker
          done &
        fi
        if command -v kubectl >/dev/null 2>&1; then
          kubectl get svc -A --request-timeout=3s --no-headers 2>/dev/null | awk '{
            ip=$4
            if (ip == "<none>" || ip == "None" || ip == "") next
            score=0
            if ($2 == "kubernetes") score=2
            if ($2 ~ /dns/) score=1
            printf "%d\\t%s\\t%s\\n", score, $2, ip
          }' | sort -nr | head -n 8 | while IFS=$(printf '\\t') read -r _ name ip; do
            [ -n "$ip" ] && probe "$name" "$ip" k8s
          done &
        fi
        wait
        """
    }

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
        echo '===LSBLK==='
        lsblk -b -P -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,PKNAME,MODEL 2>/dev/null || lsblk -b -P -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,PKNAME 2>/dev/null || lsblk -b -P -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null
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
        var lsblkLines: [String] = []
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
            case "===LSBLK===":
                if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lsblkLines.append(line)
                }
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
            unusedDisks: unusedDisks(from: lsblkLines),
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

    static func parseNetworkSnapshot(_ raw: String) -> NetworkSnapshot {
        var nics: [String: NicRow] = [:]
        var gateway: String?
        var gatewayDev: String?
        var dns: [String] = []
        var docker: [OverlayNetwork] = []
        var k8s: [OverlayNetwork] = []
        var dockerAvailable = false
        var k8sAvailable = false
        var section = ""

        for line in raw.split(whereSeparator: \.isNewline).map(String.init) {
            if line.hasPrefix("===") {
                section = line
                continue
            }
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            switch section {
            case "===LINK===":
                if let nic = parseLinkLine(t) {
                    nics[nic.name] = nic
                }
            case "===ADDR4===":
                if let (name, addr) = parseAddrLine(t, family: "inet") {
                    var nic = nics[name] ?? NicRow(name: name, up: true, mac: "", mtu: nil, ipv4: [], ipv6: [])
                    if !nic.ipv4.contains(addr) { nic.ipv4.append(addr) }
                    nics[name] = nic
                }
            case "===ADDR6===":
                if let (name, addr) = parseAddrLine(t, family: "inet6") {
                    var nic = nics[name] ?? NicRow(name: name, up: true, mac: "", mtu: nil, ipv4: [], ipv6: [])
                    if !nic.ipv6.contains(addr) { nic.ipv6.append(addr) }
                    nics[name] = nic
                }
            case "===ROUTE===":
                if let parsed = parseDefaultRoute(t) {
                    if gateway == nil { gateway = parsed.via }
                    if gatewayDev == nil { gatewayDev = parsed.dev }
                }
            case "===DNS===":
                if let ip = parseNameserver(t), !dns.contains(ip) { dns.append(ip) }
            case "===DOCKER===":
                if t == "available" { dockerAvailable = true }
                else if t != "missing", let net = parseOverlayLine(t, scope: "docker") {
                    docker.append(net)
                }
            case "===K8S===":
                if t == "available" { k8sAvailable = true }
                else if t != "missing", let net = parseK8sLine(t) {
                    k8s.append(net)
                }
            default:
                break
            }
        }

        let rows = nics.values
            .filter { $0.up || !$0.ipv4.isEmpty || !$0.ipv6.isEmpty }
            .sorted { lhs, rhs in
                if lhs.up != rhs.up { return lhs.up && !rhs.up }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }

        return NetworkSnapshot(
            nics: rows,
            gateway: gateway,
            gatewayDev: gatewayDev,
            dns: dns,
            docker: docker,
            k8s: k8s,
            dockerAvailable: dockerAvailable,
            k8sAvailable: k8sAvailable,
            fetchedAt: Date(),
            error: rows.isEmpty ? "没有读到网卡" : nil
        )
    }

    static func parseLinkLine(_ line: String) -> NicRow? {
        guard let first = line.firstIndex(of: ":") else { return nil }
        let afterIndex = line[line.index(after: first)...].drop(while: { $0 == " " })
        guard let second = afterIndex.firstIndex(of: ":") else { return nil }
        var name = String(afterIndex[..<second])
        if let at = name.firstIndex(of: "@") {
            name = String(name[..<at])
        }
        guard !name.isEmpty else { return nil }
        let rest = String(afterIndex[second...])
        let up = rest.contains(",UP") || rest.contains("state UP")
        var mtu: Int?
        if let range = rest.range(of: "mtu ") {
            let tail = rest[range.upperBound...]
            mtu = Int(tail.prefix(while: { $0.isNumber }))
        }
        var mac = ""
        if let range = rest.range(of: "link/ether ") {
            let tail = rest[range.upperBound...]
            mac = String(tail.prefix(while: { !$0.isWhitespace }))
        }
        return NicRow(name: name, up: up, mac: mac, mtu: mtu, ipv4: [], ipv6: [])
    }

    static func parseAddrLine(_ line: String, family: String) -> (String, String)? {
        let cols = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let fam = cols.firstIndex(of: family), fam + 1 < cols.count, fam >= 1 else { return nil }
        var name = cols[1]
        if name.hasSuffix(":") { name.removeLast() }
        if let at = name.firstIndex(of: "@") {
            name = String(name[..<at])
        }
        let addr = cols[fam + 1]
        guard !name.isEmpty, !addr.isEmpty else { return nil }
        return (name, addr)
    }

    static func parseDefaultRoute(_ line: String) -> (via: String, dev: String?)? {
        let cols = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard cols.first == "default" else { return nil }
        var via: String?
        var dev: String?
        if let i = cols.firstIndex(of: "via"), i + 1 < cols.count { via = cols[i + 1] }
        if let i = cols.firstIndex(of: "dev"), i + 1 < cols.count { dev = cols[i + 1] }
        guard let via else { return nil }
        return (via, dev)
    }

    static func parseNameserver(_ line: String) -> String? {
        let cols = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard cols.first == "nameserver", cols.count >= 2 else { return nil }
        return cols[1]
    }

    static func parseOverlayLine(_ line: String, scope: String) -> OverlayNetwork? {
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty else { return nil }
        let gateway = parts.count > 2 ? parts[2] : ""
        let subnet = parts.count > 3 ? parts[3] : ""
        return OverlayNetwork(
            name: parts[0],
            scope: scope,
            driver: parts[1],
            address: gateway.isEmpty ? "—" : gateway,
            extra: subnet
        )
    }

    static func parseK8sLine(_ line: String) -> OverlayNetwork? {
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 4 else { return nil }
        let ns = parts[0]
        let name = parts[1]
        let type = parts[2]
        let ip = parts[3]
        let ports = parts.count > 4 ? parts[4] : ""
        guard !name.isEmpty, !ip.isEmpty else { return nil }
        return OverlayNetwork(
            name: name,
            scope: "k8s",
            driver: type,
            address: ip,
            extra: [ns, ports].filter { !$0.isEmpty }.joined(separator: " · ")
        )
    }

    static func parseProbeRows(_ raw: String) -> [ProbeRow] {
        var rows: [ProbeRow] = []
        var section = ""
        for line in raw.split(whereSeparator: \.isNewline).map(String.init) {
            if line.hasPrefix("===") {
                section = line
                continue
            }
            guard section == "===PROBE===" else { continue }
            if let row = parseProbeLine(line) {
                rows.append(row)
            }
        }
        return rows
    }

    static func parseProbeLine(_ line: String) -> ProbeRow? {
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 4 else { return nil }
        let label = parts[0]
        let dest = parts[1]
        let scope = parts[2]
        let ok = parts[3] == "ok"
        let ms = parts.count > 4 ? Double(parts[4]) : nil
        let method = parts.count > 5 ? parts[5] : ""
        let detail = parts.count > 6 ? parts[6] : ""
        guard !label.isEmpty, !dest.isEmpty else { return nil }
        return ProbeRow(
            label: label,
            dest: dest,
            scope: scope,
            ok: ok,
            ms: ms,
            method: method,
            detail: detail
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

    private static let claimedFSTypes: Set<String> = [
        "LVM2_member", "linux_raid_member", "crypto_LUKS", "swap",
        "zfs_member", "VMFS", "ceph_bluestore", "bcache",
    ]

    private static let claimedBlkTypes: Set<String> = [
        "lvm", "crypt", "mpath", "md",
    ]

    static func parseLsblkPairs(_ line: String) -> [String: String] {
        var result: [String: String] = [:]
        var remaining = Substring(line)
        while !remaining.isEmpty {
            while remaining.first == " " {
                remaining.removeFirst()
            }
            guard let eq = remaining.firstIndex(of: "=") else { break }
            let key = String(remaining[..<eq])
            remaining = remaining[remaining.index(after: eq)...]
            guard remaining.first == "\"" else { break }
            remaining.removeFirst()
            var value = ""
            while !remaining.isEmpty {
                let ch = remaining.removeFirst()
                if ch == "\\" {
                    if !remaining.isEmpty {
                        value.append(remaining.removeFirst())
                    }
                    continue
                }
                if ch == "\"" { break }
                value.append(ch)
            }
            if !key.isEmpty {
                result[key] = value
            }
        }
        return result
    }

    static func unusedDisks(from lines: [String]) -> [UnusedDiskRow] {
        struct Blk {
            var name: String
            var size: Int64
            var type: String
            var fstype: String
            var mount: String
            var pkname: String
            var model: String
        }

        var devices: [Blk] = []
        var byName: [String: Blk] = [:]
        for line in lines {
            let pairs = parseLsblkPairs(line)
            guard let name = pairs["NAME"], !name.isEmpty else { continue }
            let type = pairs["TYPE"] ?? ""
            let rawPk = pairs["PKNAME"] ?? ""
            let pkname: String
            if !rawPk.isEmpty {
                pkname = rawPk
            } else if type != "disk" {
                pkname = inferLsblkParent(name) ?? ""
            } else {
                pkname = ""
            }
            let blk = Blk(
                name: name,
                size: Int64(pairs["SIZE"] ?? "") ?? 0,
                type: type,
                fstype: pairs["FSTYPE"] ?? "",
                mount: pairs["MOUNTPOINT"] ?? "",
                pkname: pkname,
                model: (pairs["MODEL"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            )
            devices.append(blk)
            byName[name] = blk
        }

        func diskName(for device: Blk) -> String? {
            var current = device
            var seen = Set<String>()
            for _ in 0..<8 {
                if current.type == "disk" { return current.name }
                let pk = current.pkname
                if pk.isEmpty { return nil }
                if !seen.insert(pk).inserted { return nil }
                if let parent = byName[pk] {
                    current = parent
                } else {
                    return pk
                }
            }
            return nil
        }

        func isClaimed(_ device: Blk) -> Bool {
            if !device.mount.isEmpty { return true }
            if claimedFSTypes.contains(device.fstype) { return true }
            if claimedBlkTypes.contains(device.type) || device.type.hasPrefix("raid") { return true }
            return false
        }

        var used = Set<String>()
        for device in devices {
            guard isClaimed(device), let disk = diskName(for: device) else { continue }
            used.insert(disk)
        }

        return devices
            .filter { device in
                guard device.type == "disk", device.size > 0 else { return false }
                if shouldSkipBlk(name: device.name, type: device.type) { return false }
                return !used.contains(device.name)
            }
            .map { device in
                let hasKids = devices.contains { $0.pkname == device.name }
                let hasFS = !device.fstype.isEmpty || devices.contains { $0.pkname == device.name && !$0.fstype.isEmpty }
                return UnusedDiskRow(
                    name: device.name,
                    size: device.size,
                    model: device.model,
                    status: (!hasKids && !hasFS) ? "无分区" : "未挂载"
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func shouldSkipBlk(name: String, type: String) -> Bool {
        if ["loop", "rom", "ram"].contains(type) { return true }
        return name.hasPrefix("loop")
            || name.hasPrefix("ram")
            || name.hasPrefix("zram")
            || name.hasPrefix("sr")
    }

    static func inferLsblkParent(_ name: String) -> String? {
        if let range = name.range(of: #"p[0-9]+$"#, options: .regularExpression) {
            let parent = String(name[..<range.lowerBound])
            return parent.isEmpty ? nil : parent
        }
        for prefix in ["xvd", "sd", "vd", "hd"] where name.hasPrefix(prefix) {
            var end = name.endIndex
            while end > name.startIndex {
                let prev = name.index(before: end)
                if name[prev].isNumber {
                    end = prev
                } else {
                    break
                }
            }
            let parent = String(name[..<end])
            if parent != name, parent.count >= prefix.count {
                return parent
            }
        }
        return nil
    }
}
