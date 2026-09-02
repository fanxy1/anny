import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: HostStore
    @State private var selectedID: UUID?
    @State private var metrics: HostMetrics?
    @State private var loading = false
    @State private var actionError: String?
    @State private var showAdd = false
    @State private var editingHost: WatchedHost?
    @State private var detailPane: DetailPane = .metrics
    @State private var openedTerminals: Set<UUID> = []
    @State private var terminalGenerations: [UUID: Int] = [:]
    @State private var terminalRunning: [UUID: Bool] = [:]
    @State private var sidebarWidth: CGFloat = 160
    @State private var hostSearch = ""
    @FocusState private var searchFocused: Bool

    private enum DetailPane: Hashable {
        case metrics
        case terminal
    }

    private var selected: WatchedHost? {
        store.hosts.first { $0.id == selectedID }
    }

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                sidebar
                    .frame(width: sidebarWidth)
                    .clipped()
                SidebarResizeHandle(width: $sidebarWidth)
                detailStack
                    .frame(minWidth: 620)
            }
            .navigationTitle(selected?.displayName ?? "anny")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { showAdd = true } label: {
                        Label("添加", systemImage: AnnyIcon.add)
                    }
                    .help("加入监控名单")

                    Button { editingHost = selected } label: {
                        Label("编辑", systemImage: AnnyIcon.edit)
                    }
                    .disabled(selected == nil)
                    .help("改账户、端口、备注和密码")

                    Button(role: .destructive) {
                        if let host = selected { remove(host) }
                    } label: {
                        Label("移出监控", systemImage: AnnyIcon.remove)
                    }
                    .disabled(selected == nil)
                    .help("只从本软件名单删除，不影响 Tailscale")
                }
            }
        }
        .background {
            AnnyWindowChrome(
                title: selected?.displayName ?? "anny",
                subtitle: selected?.endpointLabel ?? ""
            )
        }
        .sheet(isPresented: $showAdd) {
            AddHostSheet()
                .environmentObject(store)
        }
        .sheet(item: $editingHost) { host in
            EditHostSheet(host: host) { connectionChanged in
                if connectionChanged, selectedID == host.id {
                    metrics = nil
                }
            }
            .environmentObject(store)
        }
        .background {
            Button("搜索") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
        .alert("出错", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("好", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
        .onAppear {
            if selectedID == nil {
                selectedID = store.hosts.first?.id
            }
        }
        .onChange(of: selectedID) { _, newID in
            metrics = nil
            loading = false
            guard detailPane == .terminal,
                  let newID,
                  let host = store.hosts.first(where: { $0.id == newID })
            else { return }
            followTerminal(host)
        }
    }

    private var isSearching: Bool {
        !hostSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var visibleHosts: [WatchedHost] {
        store.hosts.filter { $0.matches(hostSearch) }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("监控名单")
                        .font(.headline)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 6) {
                    AnnySymbol(name: AnnyIcon.search, font: .caption)
                        .foregroundStyle(.secondary)
                    TextField("搜索", text: $hostSearch, prompt: Text("备注或主机名"))
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                    if isSearching {
                        Button {
                            hostSearch = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清除搜索")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            List(selection: $selectedID) {
                if visibleHosts.isEmpty, isSearching {
                    Label("没有匹配", systemImage: AnnyIcon.search)
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                        .selectionDisabled()
                }
                ForEach(visibleHosts) { host in
                    hostRow(host)
                        .tag(host.id)
                        .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
                        .contextMenu { hostMenu(host) }
                        .simultaneousGesture(TapGesture(count: 2).onEnded { openTerminal(host) })
                        .moveDisabled(isSearching)
                }
                .onMove(perform: isSearching ? nil : moveVisibleHosts)
            }
            .listStyle(.sidebar)
            .overlay {
                if store.hosts.isEmpty {
                    ContentUnavailableView {
                        Label("没有监控项", systemImage: AnnyIcon.host)
                    } description: {
                        Text("点工具栏加号加入一台机器。")
                    }
                    .symbolRenderingMode(.hierarchical)
                }
            }
        }
    }

    private func moveVisibleHosts(from source: IndexSet, to destination: Int) {
        store.move(from: source, to: destination)
    }

    @ViewBuilder
    private func hostRow(_ host: WatchedHost) -> some View {
        let state = sessionState(host.id)
        HStack(spacing: 8) {
            Label {
                Text(host.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
            } icon: {
                AnnySymbol(name: AnnyIcon.host)
                    .foregroundStyle(state == .connected ? Color.green : Color.secondary)
            }
            Spacer(minLength: 0)
            if state == .connected {
                AnnySymbol(name: AnnyIcon.status, font: .system(size: 7))
                    .foregroundStyle(.green)
                    .accessibilityLabel("已连接")
            }
        }
    }

    @ViewBuilder
    private func hostMenu(_ host: WatchedHost) -> some View {
        Button("连接", systemImage: AnnyIcon.terminal) { openTerminal(host) }
        if openedTerminals.contains(host.id) {
            Button("断开", systemImage: AnnyIcon.disconnect, role: .destructive) { disconnect(host) }
        }
        Button("编辑", systemImage: AnnyIcon.edit) { editingHost = host }
        Divider()
        Button("移出监控", systemImage: AnnyIcon.remove, role: .destructive) { remove(host) }
    }

    private var liveTerminalIDs: [UUID] {
        store.hosts.map(\.id).filter { openedTerminals.contains($0) }
    }

    @ViewBuilder
    private var detailStack: some View {
        ZStack {
            AnnyAtmosphere()
            VStack(alignment: .leading, spacing: 16) {
                if let host = selected {
                    hostHeader(host)
                    panePicker
                }

                ZStack {
                    if let host = selected {
                        metricsPane(host)
                            .opacity(detailPane == .metrics ? 1 : 0)
                            .allowsHitTesting(detailPane == .metrics)
                    } else {
                        emptySelection
                    }

                    ForEach(liveTerminalIDs, id: \.self) { id in
                        if let host = store.hosts.first(where: { $0.id == id }) {
                            terminalChrome(host)
                                .opacity(detailPane == .terminal && selectedID == id ? 1 : 0)
                                .allowsHitTesting(detailPane == .terminal && selectedID == id)
                        }
                    }

                    if let host = selected, detailPane == .terminal, !openedTerminals.contains(host.id) {
                        emptyTerminal
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(20)
        }
    }

    private var emptySelection: some View {
        ContentUnavailableView {
            Label("选一台服务器", systemImage: AnnyIcon.host)
        } description: {
            Text("从左侧名单选择。移出监控不会注销 Tailscale 节点。")
        }
        .symbolRenderingMode(.hierarchical)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cardBackground()
    }

    private var emptyTerminal: some View {
        ContentUnavailableView {
            Label("尚未连接", systemImage: AnnyIcon.terminal)
        } description: {
            Text("点「连接」或双击左侧名单。在终端页再点其他机器会自动连上。")
        }
        .symbolRenderingMode(.hierarchical)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cardBackground()
    }

    private var panePicker: some View {
        Picker("", selection: $detailPane) {
            Label("资源", systemImage: AnnyIcon.metrics).tag(DetailPane.metrics)
            Label("终端", systemImage: AnnyIcon.terminal).tag(DetailPane.terminal)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.large)
        .frame(maxWidth: 280)
    }

    @ViewBuilder
    private func hostHeader(_ host: WatchedHost) -> some View {
        let state = sessionState(host.id)
        HStack(alignment: .center, spacing: 14) {
            AnnySymbol(name: AnnyIcon.host, font: .title2)
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(host.displayName)
                    .font(.title2.weight(.semibold))
                if !host.note.isEmpty {
                    Text(verbatim: host.hostname)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Label {
                    Text(verbatim: host.endpointLabel)
                        .font(.subheadline.monospaced())
                } icon: {
                    AnnySymbol(name: AnnyIcon.ssh, font: .subheadline)
                }
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            }

            Spacer(minLength: 12)

            AnnyGlassCluster(spacing: 10) {
                HStack(spacing: 10) {
                    if detailPane == .metrics {
                        Button("刷新", systemImage: AnnyIcon.refresh) { refresh() }
                            .disabled(loading)
                            .annyGlass()
                    }
                    sessionButton(host, state: state)
                }
            }
        }
        .cardBackground()
    }

    @ViewBuilder
    private func sessionButton(_ host: WatchedHost, state: SessionState) -> some View {
        switch state {
        case .idle:
            Button("连接", systemImage: AnnyIcon.terminal) { openTerminal(host) }
                .keyboardShortcut("t", modifiers: [.command])
                .annyGlass(prominent: true)
        case .connected:
            Button("断开", systemImage: AnnyIcon.disconnect, role: .destructive) { disconnect(host) }
                .keyboardShortcut("d", modifiers: [.command])
                .help("只断开本窗口 SSH，名单还在")
                .annyGlass()
        case .ended:
            Button("重新连接", systemImage: AnnyIcon.reconnect) { reconnect(host) }
                .keyboardShortcut("t", modifiers: [.command])
                .annyGlass(prominent: true)
        }
    }

    @ViewBuilder
    private func terminalChrome(_ host: WatchedHost) -> some View {
        let running = terminalRunning[host.id] == true
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                AnnySymbol(name: AnnyIcon.status, font: .system(size: 8))
                    .foregroundStyle(running ? Color.green : Color.orange)
                AnnySymbol(name: AnnyIcon.terminal, font: .caption)
                    .foregroundStyle(.white.opacity(0.62))
                Text(verbatim: host.endpointLabel)
                    .font(.caption.monospaced())
                    .foregroundStyle(.white.opacity(0.72))
                Spacer()
                Text(running ? "会话中" : "已结束")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.black.opacity(0.28))

            SSHTerminalView(host: host, running: runningBinding(for: host.id))
                .id("\(host.id.uuidString)-\(terminalGenerations[host.id] ?? 0)")
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func runningBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { terminalRunning[id] ?? false },
            set: { terminalRunning[id] = $0 }
        )
    }

    @ViewBuilder
    private func metricsPane(_ host: WatchedHost) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if loading && metrics == nil {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在读取资源…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardBackground()
                } else if metrics == nil {
                    ContentUnavailableView {
                        Label("尚未读取", systemImage: AnnyIcon.metrics)
                    } description: {
                        Text("点「刷新」读取系统、CPU、内存和磁盘。切换名单不会自动拉取。")
                    }
                    .symbolRenderingMode(.hierarchical)
                    .frame(maxWidth: .infinity, minHeight: 240)
                    .cardBackground()
                }

                if let error = metrics?.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .cardBackground()
                }

                if let m = metrics, m.error == nil {
                    systemCard(m)

                    AnnyGlassCluster(spacing: 12) {
                        HStack(alignment: .top, spacing: 12) {
                            usageCard(
                                title: "CPU",
                                icon: AnnyIcon.cpu,
                                value: m.cpuPercent.map { String(format: "%.0f%%", $0) } ?? "—",
                                percent: m.cpuPercent ?? 0
                            )
                            usageCard(
                                title: "内存",
                                icon: AnnyIcon.memory,
                                value: memoryText(m),
                                percent: memoryPercent(m),
                                subtitle: m.load1.map { String(format: "load %.2f", $0) }
                            )
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            AnnySymbol(name: AnnyIcon.disk)
                            Text("磁盘")
                                .font(.headline)
                            Spacer()
                            if let at = Optional(m.fetchedAt) {
                                Text("更新于 \(at.formatted(date: .omitted, time: .standard))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Table(m.disks) {
                            TableColumn("挂载") { Text(verbatim: $0.mount).font(.body.monospaced()) }
                            TableColumn("容量") { Text(verbatim: byteText($0.size)) }
                            TableColumn("已用") { row in
                                Text(verbatim: "\(row.percent)  \(byteText(row.used))")
                                    .foregroundStyle(Theme.usageColor(Theme.diskLevel(row.percent)))
                            }
                            TableColumn("可用") { Text(verbatim: byteText($0.avail)) }
                        }
                        .frame(minHeight: 200)
                    }
                    .cardBackground()
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func systemCard(_ m: HostMetrics) -> some View {
        let rows: [(icon: String, title: String, value: String)] = [
            (AnnyIcon.distro, "发行版", m.osName ?? "—"),
            (AnnyIcon.version, "版本", m.osVersion ?? "—"),
            (AnnyIcon.kernel, "内核", m.kernel ?? "—"),
        ]
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                AnnySymbol(name: AnnyIcon.system)
                Text("系统")
                    .font(.headline)
                Spacer()
                if let pretty = m.osPretty, !pretty.isEmpty {
                    Text(pretty)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                }
            }
            ForEach(rows, id: \.title) { row in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Label {
                        Text(row.title)
                            .foregroundStyle(.secondary)
                    } icon: {
                        AnnySymbol(name: row.icon, font: .caption)
                    }
                    .frame(width: 88, alignment: .leading)
                    Text(row.value)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private func usageCard(title: String, icon: String, value: String, percent: Double, subtitle: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(title)
                    .font(.caption.weight(.medium))
            } icon: {
                AnnySymbol(name: icon, font: .caption)
            }
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)

            Text(verbatim: value)
                .font(.title2.monospacedDigit().weight(.semibold))
            if let subtitle {
                Text(verbatim: subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: min(max(percent, 0), 100), total: 100)
                .tint(Theme.usageColor(percent))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private func sessionState(_ id: UUID) -> SessionState {
        if terminalRunning[id] == true { return .connected }
        if openedTerminals.contains(id) { return .ended }
        return .idle
    }

    private func refresh() {
        guard let host = selected else { return }
        loading = true
        let snapshot = host
        Task.detached {
            let result: HostMetrics
            do {
                var m = try SSHService.fetchMetrics(snapshot)
                m.error = nil
                result = m
            } catch {
                result = HostMetrics(
                    cpuPercent: nil,
                    load1: nil,
                    memTotal: nil,
                    memAvailable: nil,
                    disks: [],
                    fetchedAt: Date(),
                    error: error.localizedDescription
                )
            }
            await MainActor.run {
                if selectedID == snapshot.id {
                    metrics = result
                    loading = false
                }
            }
        }
    }

    private func followTerminal(_ host: WatchedHost) {
        if terminalRunning[host.id] == true { return }
        if openedTerminals.contains(host.id) {
            reconnect(host)
        } else {
            openTerminal(host)
        }
    }

    private func openTerminal(_ host: WatchedHost) {
        selectedID = host.id
        openedTerminals.insert(host.id)
        detailPane = .terminal
    }

    private func reconnect(_ host: WatchedHost) {
        selectedID = host.id
        terminalRunning[host.id] = false
        terminalGenerations[host.id, default: 0] += 1
        openedTerminals.insert(host.id)
        detailPane = .terminal
    }

    private func closeTerminal(_ id: UUID) {
        openedTerminals.remove(id)
        terminalGenerations.removeValue(forKey: id)
        terminalRunning.removeValue(forKey: id)
    }

    private func disconnect(_ host: WatchedHost) {
        closeTerminal(host.id)
    }

    private func remove(_ host: WatchedHost) {
        closeTerminal(host.id)
        store.removeFromWatchlist(host)
        if selectedID == host.id {
            selectedID = store.hosts.first?.id
            metrics = nil
        }
    }

    private func memoryPercent(_ m: HostMetrics) -> Double {
        guard let total = m.memTotal, let used = m.memUsed, total > 0 else { return 0 }
        return Double(used) / Double(total) * 100
    }

    private func memoryText(_ m: HostMetrics) -> String {
        guard let total = m.memTotal, let used = m.memUsed else { return "—" }
        return "\(byteText(used)) / \(byteText(total))"
    }

    private func byteText(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB, .useMB, .useTB]
        f.countStyle = .file
        f.includesUnit = true
        f.isAdaptive = true
        return f.string(fromByteCount: bytes)
    }
}

struct EditHostSheet: View {
    @EnvironmentObject private var store: HostStore
    @Environment(\.dismiss) private var dismiss
    let hostID: UUID
    let hostname: String
    var onCommit: (Bool) -> Void
    @State private var user: String
    @State private var portText: String
    @State private var note: String
    @State private var password: String = ""
    @State private var hasSavedPassword: Bool

    init(host: WatchedHost, onCommit: @escaping (Bool) -> Void = { _ in }) {
        self.hostID = host.id
        self.hostname = host.hostname
        self.onCommit = onCommit
        _user = State(initialValue: host.user)
        _portText = State(initialValue: Theme.portDigits(host.port))
        _note = State(initialValue: host.note)
        _hasSavedPassword = State(initialValue: HostSecretStore.hasPassword(for: host.id))
    }

    private var parsedPort: Int? { Theme.parsePort(portText) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("主机") {
                        Text(verbatim: hostname)
                            .font(.body.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    TextField("root", text: $user, prompt: Text("登录账户"))
                    LabeledContent("端口") {
                        PortField(text: $portText)
                    }
                    TextField("名单只显示此项", text: $note, prompt: Text("备注"))
                } header: {
                    Label("监控项", systemImage: AnnyIcon.host)
                } footer: {
                    Text(parsedPort == nil ? "端口须为 1–65535" : "没有备注时，名单只显示主机名。")
                }

                Section {
                    SecureField(
                        hasSavedPassword ? "已保存，留空不改" : "没有密钥时填写",
                        text: $password
                    )
                    if hasSavedPassword {
                        Button("清除已存密码", role: .destructive) {
                            store.clearPassword(id: hostID)
                            password = ""
                            hasSavedPassword = false
                        }
                    }
                } header: {
                    Label("密码", systemImage: AnnyIcon.password)
                } footer: {
                    Text("优先用本机 SSH 密钥。没有密钥时用这里的密码，存在钥匙串，不写入名单文件。")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("编辑")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(parsedPort == nil)
                }
            }
        }
        .frame(width: 480, height: 460)
    }

    private func save() {
        guard let port = parsedPort else { return }
        let changed = store.update(id: hostID, user: user, port: port, note: note)
        var passwordChanged = false
        if !password.isEmpty {
            store.setPassword(id: hostID, password: password)
            passwordChanged = true
        }
        onCommit(changed || passwordChanged)
        dismiss()
    }
}

struct AddHostSheet: View {
    @EnvironmentObject private var store: HostStore
    @Environment(\.dismiss) private var dismiss
    @State private var peers: [TailscalePeer] = []
    @State private var selected = Set<String>()
    @State private var manual = ""
    @State private var user = "root"
    @State private var portText = "22"
    @State private var note = ""
    @State private var password = ""
    @State private var loadError: String?
    @State private var loading = false
    @State private var fetched = false

    private var parsedPort: Int? { Theme.parsePort(portText) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        Button(fetched ? "重新获取" : "获取节点", systemImage: fetched ? AnnyIcon.refresh : AnnyIcon.fetch) {
                            loadPeers()
                        }
                        .disabled(loading)
                    }

                    if loading {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text("读取 tailscale status…")
                                .foregroundStyle(.secondary)
                        }
                    } else if let loadError {
                        Label(loadError, systemImage: "exclamationmark.triangle")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.red)
                        Text("可手填主机名，不必先获取。")
                            .foregroundStyle(.secondary)
                    } else if !fetched {
                        ContentUnavailableView {
                            Label("尚未获取", systemImage: AnnyIcon.network)
                        } description: {
                            Text("点「获取节点」读取 tailscale status。也可直接手填主机名。")
                        }
                        .symbolRenderingMode(.hierarchical)
                        .frame(minHeight: 140)
                    } else if peers.isEmpty {
                        ContentUnavailableView {
                            Label("没有节点", systemImage: AnnyIcon.network)
                        } description: {
                            Text("tailscale status 没有可用主机，可手填。")
                        }
                        .symbolRenderingMode(.hierarchical)
                        .frame(minHeight: 140)
                    } else {
                        List(peers, selection: $selected) { peer in
                            Label {
                                HStack {
                                    Text(verbatim: peer.hostname)
                                    Spacer()
                                    Text(verbatim: peer.ip)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                AnnySymbol(name: AnnyIcon.status, font: .system(size: 8))
                                    .foregroundStyle(peer.online ? Color.green : Color.secondary)
                            }
                            .tag(peer.hostname)
                        }
                        .frame(minHeight: 200)
                    }
                } header: {
                    Label("Tailscale 节点", systemImage: AnnyIcon.network)
                } footer: {
                    Text("只写入本软件，不会改 Tailscale / Headscale。")
                }

                Section {
                    TextField("主机名", text: $manual, prompt: Text("如 demo-atlas"))
                        .onSubmit { addManual() }
                    TextField("root", text: $user, prompt: Text("登录账户"))
                    LabeledContent("端口") {
                        PortField(text: $portText)
                    }
                    TextField("名单只显示此项", text: $note, prompt: Text("备注，可选"))
                    SecureField("没有密钥时填写，可选", text: $password)
                } header: {
                    Label("账户", systemImage: AnnyIcon.user)
                } footer: {
                    if parsedPort == nil {
                        Text("端口须为 1–65535")
                    } else {
                        Text("导入选中与手填共用账户、端口、备注和密码。没有备注时名单只显示主机名。")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("添加到监控名单")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", role: .cancel) { dismiss() }
                }
                ToolbarItem {
                    Button("加入手填", systemImage: AnnyIcon.add) { addManual() }
                        .disabled(!canAddManual)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入选中", systemImage: AnnyIcon.fetch) { importSelected() }
                        .disabled(!canImportSelected)
                }
            }
        }
        .frame(width: 580, height: 680)
    }

    private var trimmedNote: String {
        note.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedUser: String {
        let u = user.trimmingCharacters(in: .whitespacesAndNewlines)
        return u.isEmpty ? "root" : u
    }

    private var canAddManual: Bool {
        !manual.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && parsedPort != nil
    }

    private var canImportSelected: Bool {
        !selected.isEmpty && parsedPort != nil
    }

    private func loadPeers() {
        loading = true
        loadError = nil
        Task.detached {
            do {
                let list = try TailscaleService.listPeers()
                await MainActor.run {
                    peers = list
                    fetched = true
                    loading = false
                }
            } catch {
                await MainActor.run {
                    loadError = error.localizedDescription
                    fetched = false
                    loading = false
                }
            }
        }
    }

    private func importSelected() {
        guard let port = parsedPort else { return }
        for name in selected {
            store.add(
                WatchedHost(hostname: name, user: trimmedUser, port: port, note: trimmedNote),
                password: password
            )
        }
        dismiss()
    }

    private func addManual() {
        let name = manual.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let port = parsedPort else { return }
        store.add(
            WatchedHost(hostname: name, user: trimmedUser, port: port, note: trimmedNote),
            password: password
        )
        dismiss()
    }
}
