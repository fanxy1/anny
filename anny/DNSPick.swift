import Foundation

enum DNSPick {
    static let recommendThreshold = 0.98
    static let maxRecommendations = 3
    static let switchLatencyMs = 15.0
    static let switchSuccessMargin = 0.05

    static func score(avgLatencyMs: Double, successRate: Double) -> Double {
        guard avgLatencyMs > 0 else { return 0 }
        let rate = min(max(successRate, 0), 1)
        return (1.0 / (avgLatencyMs / 1000.0)) * rate * rate
    }

    static func isInternalDNS(_ address: String) -> Bool {
        let host = String(address.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first ?? Substring(address))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if host.isEmpty { return false }
        if isPrivateIPv4(host) { return true }
        return isPrivateIPv6(host)
    }

    static func parse(_ raw: String) -> DNSPickSnapshot {
        var error: String?
        var parsed: [DNSPickRow] = []
        var section = ""

        for line in raw.split(whereSeparator: \.isNewline).map(String.init) {
            if line.hasPrefix("===") {
                section = line
                continue
            }
            guard section == "===DNSPICK===" else { continue }
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            let parts = t.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if parts.first == "error" {
                let message = parts.dropFirst().joined(separator: "\t")
                error = message.isEmpty ? "测 DNS 失败" : message
                continue
            }
            if let row = parseRow(parts) {
                parsed.append(row)
            }
        }

        let ranked = parsed
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            .enumerated()
            .map { index, row in
                var copy = row
                copy.rank = index + 1
                return copy
            }

        if error == nil, ranked.isEmpty {
            error = "没有测到结果"
        }

        return snapshot(rows: ranked, error: error)
    }

    static func summary(of snapshot: DNSPickSnapshot) -> String {
        if let error = snapshot.error, snapshot.rows.isEmpty {
            return error
        }
        guard let verdict = snapshot.verdict, let address = snapshot.systemAddress else {
            return snapshot.rows.isEmpty ? "没有测到结果" : "未检测到当前 DNS"
        }
        let privateNote = (snapshot.isInternalDNS && (verdict == .switchDNS || verdict == .allFailed))
            ? " 当前是内网或本机解析器，改成公网 DNS 可能解析不了内网名字。"
            : ""
        let best = snapshot.rows.first
        switch verdict {
        case .best:
            return "当前 DNS（\(address)）已经是最好的，不用改。"
        case .goodEnough:
            let rank = snapshot.systemRank.map(String.init) ?? "—"
            let gap = snapshot.latencyGapMs.map { String(format: "%.2f ms", $0) } ?? "—"
            return "当前 DNS（\(address)）够用（第 \(rank) 名，只慢 \(gap)）；不用改。"
        case .switchDNS:
            let rank = snapshot.systemRank.map(String.init) ?? "—"
            let bestLabel = best.map { "\($0.name)（\($0.address)）" } ?? "更快的公共 DNS"
            return "建议把 DNS 改成 \(bestLabel)。当前（\(address)）排第 \(rank) 名。" + privateNote
        case .allFailed:
            let bestLabel = best.map { "\($0.name)（\($0.address)）" } ?? "其他公共 DNS"
            return "当前 DNS（\(address)）全部失败。可改用 \(bestLabel)。" + privateNote
        }
    }

    static func parseRow(_ parts: [String]) -> DNSPickRow? {
        guard parts.count >= 7 else { return nil }
        let name = parts[0]
        let address = parts[1]
        let protocolName = parts[2].isEmpty ? "udp" : parts[2]
        let isSystem = parts[3] == "1" || parts[3] == "true"
        let avgLatencyMs = Double(parts[4])
        let successes = Int(parts[5]) ?? 0
        let total = Int(parts[6]) ?? 0
        guard !name.isEmpty, !address.isEmpty, total >= 0, successes >= 0 else { return nil }
        let successRate = total > 0 ? Double(successes) / Double(total) : 0
        let score: Double
        if let avgLatencyMs, successes > 0 {
            score = self.score(avgLatencyMs: avgLatencyMs, successRate: successRate)
        } else {
            score = 0
        }
        return DNSPickRow(
            rank: 0,
            name: name,
            address: address,
            protocolName: protocolName,
            isSystem: isSystem,
            avgLatencyMs: successes > 0 ? avgLatencyMs : nil,
            successRate: successRate,
            successes: successes,
            total: total,
            score: score
        )
    }

    private static func snapshot(rows: [DNSPickRow], error: String?) -> DNSPickSnapshot {
        let top = rows.filter { $0.successRate >= recommendThreshold }.prefix(maxRecommendations).map { $0 }
        var verdict: DNSPickVerdict?
        var shouldSwitch = false
        var isInternal = false
        var systemAddress: String?
        var systemRank: Int?
        var latencyGapMs: Double?

        if let sysIndex = rows.firstIndex(where: \.isSystem), let best = rows.first {
            let sys = rows[sysIndex]
            systemAddress = sys.address
            systemRank = sys.rank
            isInternal = isInternalDNS(sys.address)
            let sysAvg = sys.avgLatencyMs ?? 0
            let bestAvg = best.avgLatencyMs ?? 0
            latencyGapMs = sysAvg - bestAvg
            let closeEnough = (latencyGapMs ?? 0) < switchLatencyMs
                && best.successRate - sys.successRate <= switchSuccessMargin
            if sys.successes == 0 {
                verdict = .allFailed
            } else if sysIndex == 0 {
                verdict = .best
            } else if closeEnough {
                verdict = .goodEnough
            } else {
                verdict = .switchDNS
            }
            shouldSwitch = verdict == .switchDNS || verdict == .allFailed
        }

        return DNSPickSnapshot(
            rows: rows,
            top: Array(top),
            verdict: verdict,
            shouldSwitch: shouldSwitch,
            isInternalDNS: isInternal,
            systemAddress: systemAddress,
            systemRank: systemRank,
            latencyGapMs: latencyGapMs,
            error: error,
            fetchedAt: Date()
        )
    }

    private static func isPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        let a = parts[0], b = parts[1]
        if a == 10 { return true }
        if a == 127 { return true }
        if a == 169 && b == 254 { return true }
        if a == 172 && (16...31).contains(b) { return true }
        if a == 192 && b == 168 { return true }
        return false
    }

    private static func isPrivateIPv6(_ host: String) -> Bool {
        let lower = host.lowercased()
        if lower == "::1" { return true }
        if lower.hasPrefix("fe80:") || lower.hasPrefix("fe80::") { return true }
        if lower.hasPrefix("fc") || lower.hasPrefix("fd") { return true }
        return false
    }
}
