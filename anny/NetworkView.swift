import SwiftUI

struct NetworkPane: View {
    let hostID: UUID
    var snapshot: NetworkSnapshot?
    var probes: [ProbeRow]
    var loading: Bool
    var probing: Bool
    var probeFocused: FocusState<Bool>.Binding
    var onRefresh: () -> Void
    var onProbe: (String) -> Void

    @State private var target = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            toolbar
            if loading && snapshot == nil {
                loadingCard
            } else if let error = snapshot?.error, snapshot?.nics.isEmpty != false {
                errorCard(error)
            } else if snapshot == nil {
                emptyCard
            } else if let snapshot {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !probes.isEmpty || probing {
                            probeCard
                        }
                        summaryCard(snapshot)
                        nicCard(snapshot)
                        if snapshot.dockerAvailable {
                            overlayCard(
                                title: "Docker 网络",
                                icon: AnnyIcon.distro,
                                rows: snapshot.docker,
                                empty: "已安装 Docker，但没有读到网络"
                            )
                        }
                        if snapshot.k8sAvailable {
                            overlayCard(
                                title: "Kubernetes 服务",
                                icon: AnnyIcon.system,
                                rows: snapshot.k8s,
                                empty: "已连上集群，但没有可读的 ClusterIP"
                            )
                        }
                    }
                }
            }
        }
        .onChange(of: hostID) { _, _ in
            target = ""
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: AnnyIcon.probe)
                    .foregroundStyle(.secondary)
                TextField("IP 或域名，例如 1.1.1.1", text: $target)
                    .textFieldStyle(.plain)
                    .focused(probeFocused)
                    .onSubmit { onProbe(target) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .frame(maxWidth: 280)

            Button("探活") { onProbe(target) }
                .disabled(probing || loading)
                .help(probeHelp)
                .annyGlass(prominent: true)

            Text(statusLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .cardBackground()
    }

    private var loadingCard: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("正在读取网卡和网络…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .cardBackground()
    }

    private func errorCard(_ error: String) -> some View {
        ContentUnavailableView {
            Label("读不到网络", systemImage: AnnyIcon.network)
        } description: {
            Text(error)
        }
        .symbolRenderingMode(.hierarchical)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cardBackground()
    }

    private var emptyCard: some View {
        ContentUnavailableView {
            Label("尚未读取网络", systemImage: AnnyIcon.network)
        } description: {
            Text("切到这一页会自动读取网卡。输入 IP 或域名后点「探活」。")
        }
        .symbolRenderingMode(.hierarchical)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cardBackground()
    }

    private var probeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AnnySymbol(name: AnnyIcon.probe)
                Text("探活结果")
                    .font(.headline)
                Spacer()
                if probing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(probeSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if probes.isEmpty, probing {
                Text("正在探测目标、网关、DNS，以及 Docker / K8s 网络…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(probes) { row in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(scopeLabel(row.scope))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .leading)
                    Text(row.label)
                        .frame(width: 88, alignment: .leading)
                    Text(row.dest)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .frame(minWidth: 110, alignment: .leading)
                    Spacer(minLength: 8)
                    Text(row.resultText)
                        .font(.body.monospacedDigit())
                        .foregroundStyle(row.ok ? Theme.usageColor(10) : Color.red)
                }
                .padding(.vertical, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private func summaryCard(_ snapshot: NetworkSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AnnySymbol(name: AnnyIcon.network)
                Text("本机网络")
                    .font(.headline)
                Spacer()
                Text("\(snapshot.nics.count) 块网卡")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            summaryLine("网关", snapshot.gateway.map { gw in
                if let dev = snapshot.gatewayDev, !dev.isEmpty {
                    return "\(gw)  ·  \(dev)"
                }
                return gw
            } ?? "—")
            summaryLine("DNS", snapshot.dns.isEmpty ? "—" : snapshot.dns.joined(separator: "  "))
            summaryLine("Docker", snapshot.dockerAvailable ? "已安装 · \(snapshot.docker.count) 个网络" : "未检测到")
            summaryLine("Kubernetes", snapshot.k8sAvailable ? "已连接 · \(snapshot.k8s.count) 个服务" : "未检测到")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private func nicCard(_ snapshot: NetworkSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                AnnySymbol(name: AnnyIcon.ssh)
                Text("网卡")
                    .font(.headline)
                Spacer()
            }
            .padding(.bottom, 8)
            headerRow {
                header("网卡", width: 110)
                header("状态", width: 52)
                header("地址", width: nil)
                header("MAC", width: 140)
            }
            Divider().opacity(0.55)
            ForEach(snapshot.nics) { nic in
                HStack(spacing: 8) {
                    Text(nic.name)
                        .font(.body.monospaced())
                        .frame(width: 110, alignment: .leading)
                    Text(nic.up ? "UP" : "DOWN")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(nic.up ? Theme.usageColor(10) : Color.secondary)
                        .frame(width: 52, alignment: .leading)
                    Text(nic.addressText)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(nic.mac.isEmpty ? "—" : nic.mac)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(width: 140, alignment: .leading)
                }
                .padding(.vertical, 6)
                Divider().opacity(0.35)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private func overlayCard(title: String, icon: String, rows: [OverlayNetwork], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                AnnySymbol(name: icon)
                Text(title)
                    .font(.headline)
                Spacer()
            }
            .padding(.bottom, 8)
            if rows.isEmpty {
                Text(empty)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                headerRow {
                    header("名称", width: 120)
                    header("类型", width: 88)
                    header("地址", width: 140)
                    header("备注", width: nil)
                }
                Divider().opacity(0.55)
                ForEach(rows) { row in
                    HStack(spacing: 8) {
                        Text(row.name)
                            .frame(width: 120, alignment: .leading)
                        Text(row.driver)
                            .foregroundStyle(.secondary)
                            .frame(width: 88, alignment: .leading)
                        Text(row.address)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .frame(width: 140, alignment: .leading)
                        Text(row.extra.isEmpty ? "—" : row.extra)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 6)
                    Divider().opacity(0.35)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private func summaryLine(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .font(.body.monospaced())
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func headerRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            content()
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.vertical, 6)
    }

    private func header(_ title: String, width: CGFloat?) -> some View {
        Text(title)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .frame(width: width, alignment: .leading)
    }

    private var statusLine: String {
        if probing { return "探活中…" }
        if loading { return "正在读取…" }
        guard let snapshot else { return "输入目标后探活" }
        if snapshot.dockerAvailable || snapshot.k8sAvailable {
            return "探活会同时打 Docker / K8s"
        }
        return "留空只探网关和 DNS"
    }

    private var probeHelp: String {
        "从这台机器 ping 目标；有 Docker 或 K8s 时一并探测它们的网络"
    }

    private var probeSummary: String {
        let ok = probes.filter(\.ok).count
        return "\(ok)/\(probes.count) 通"
    }

    private func scopeLabel(_ scope: String) -> String {
        switch scope {
        case "docker": return "Docker"
        case "k8s": return "K8s"
        default: return "本机"
        }
    }
}
