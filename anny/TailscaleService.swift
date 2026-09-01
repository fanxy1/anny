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
        let result = try ProcessRun.run(bin, arguments: ["status", "--json"], timeout: 20)
        guard result.status == 0 else {
            let msg = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "anny",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: msg.isEmpty ? "tailscale status 失败" : msg]
            )
        }

        let status = try JSONDecoder().decode(Status.self, from: Data(result.stdout.utf8))
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
