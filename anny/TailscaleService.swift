import Foundation

enum TailscaleService {
    private struct Status: Decodable {
        struct Node: Decodable {
            var HostName: String?
            var DNSName: String?
            var Online: Bool?
            var TailscaleIPs: [String]?
        }

        var selfNode: Node?
        var Peer: [String: Node]?

        enum CodingKeys: String, CodingKey {
            case selfNode = "Self"
            case Peer
        }
    }

    static func listPeers() throws -> [TailscalePeer] {
        guard let bin = ProcessRun.which("tailscale") else {
            throw NSError(
                domain: "anny",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "找不到 tailscale。本机需已安装 Tailscale.app（菜单栏那个），应用会调用 /Applications/Tailscale.app/Contents/MacOS/Tailscale。"]
            )
        }
        // Tailscale.app 是 CLI/GUI 双模。从 GUI 进程拉起时环境里没有 TERM，
        // 它会当成图形界面启动，stdout 变成 CLIError 3，不是 JSON。
        var env = ProcessInfo.processInfo.environment
        if (env["TERM"] ?? "").isEmpty {
            env["TERM"] = "dumb"
        }
        let result = try ProcessRun.run(bin, arguments: ["status", "--json"], environment: env, timeout: 20)
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, stdout.first == "{" else {
            let msg = [stderr, stdout].first { !$0.isEmpty } ?? ""
            throw NSError(
                domain: "anny",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: msg.isEmpty ? "tailscale status 失败" : msg]
            )
        }

        let status = try JSONDecoder().decode(Status.self, from: Data(stdout.utf8))
        var nodes: [Status.Node] = []
        if let selfNode = status.selfNode { nodes.append(selfNode) }
        if let peers = status.Peer { nodes.append(contentsOf: peers.values) }

        return nodes.compactMap { node in
            let host = (node.HostName?.isEmpty == false ? node.HostName : node.DNSName?.split(separator: ".").first.map(String.init)) ?? ""
            guard !host.isEmpty else { return nil }
            return TailscalePeer(
                hostname: host,
                ip: node.TailscaleIPs?.first ?? "",
                online: node.Online ?? false
            )
        }
        .uniqued(by: \.hostname)
        .sorted { $0.hostname.localizedCaseInsensitiveCompare($1.hostname) == .orderedAscending }
    }
}

private extension Array {
    func uniqued<T: Hashable>(by key: KeyPath<Element, T>) -> [Element] {
        var seen = Set<T>()
        return filter { seen.insert($0[keyPath: key]).inserted }
    }
}
