import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: HostStore
    @EnvironmentObject private var inspect: InspectStore
    @State private var selectedID: UUID?
    @State private var workspace: Workspace = .machine
    @State private var metrics: HostMetrics?
    @State private var loading = false
    @State private var actionError: String?
    @State private var showAdd = false
    @State private var editingHost: WatchedHost?
    @State private var detailPane: DetailPane = .metrics
    @State private var openedTerminals: Set<UUID> = []
    @State private var terminalGenerations: [UUID: Int] = [:]
    @State private var terminalRunning: [UUID: Bool] = [:]
    @State private var sidebarWidth: CGFloat = 220
    @State private var hostSearch = ""
    @FocusState private var searchFocused: Bool
    @State private var renamingGroupID: UUID?
    @State private var renameDraft = ""
    @FocusState private var renameFocused: Bool
    @State private var dropTarget: String?
    @State private var collapseTapLock: Date?

    private enum Workspace: Hashable {
        case machine
        case inspect
    }

    private enum DetailPane: Hashable {
        case metrics
        case terminal
    }

    private var selected: WatchedHost? {
        store.hosts.first { $0.id == selectedID }
    }

    private var machineSubtitle: String {
        guard let host = selected else { return "" }
        if let ip = metrics?.publicIP, !ip.isEmpty {
            return "\(host.endpointLabel) · \(ip)"
        }
        return host.endpointLabel
    }

    private var inspectSubtitle: String {
        if inspect.isRunning {
            return "\(inspect.finishedCount)/\(inspect.runIDs.count)"
        }
        if inspect.dangerCount > 0 {
            return "\(inspect.dangerCount) 台危险"
        }
        if inspect.runIDs.isEmpty {
            return inspect.checked.isEmpty ? "" : "已勾选 \(inspect.checked.count) 台"
        }
        return "\(inspect.runIDs.count) 台"
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
            .navigationTitle(workspace == .inspect ? "巡查" : (selected?.displayName ?? "anny"))
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("工作区", selection: $workspace) {
                        Text("机器").tag(Workspace.machine)
                        Text("巡查").tag(Workspace.inspect)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 148)
                    .help("切换单机查看和批量巡查")
                }
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
                title: workspace == .inspect ? "巡查" : (selected?.displayName ?? "anny"),
                subtitle: workspace == .inspect
                    ? inspectSubtitle
                    : machineSubtitle
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
        .onChange(of: selectedID) { _, _ in
            searchFocused = false
            metrics = nil
            loading = false
        }
    }

    private var isSearching: Bool {
        !hostSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var visibleHosts: [WatchedHost] {
        store.hosts.filter { $0.matches(hostSearch) }
    }

    private var buckets: [HostBucket] {
        let shown = visibleHosts
        var result = store.groups.map { group in
            HostBucket(
                groupID: group.id,
                title: group.name,
                hosts: shown.filter { $0.groupID == group.id },
                collapsed: isSearching ? false : group.collapsed
            )
        }
        let loose = shown.filter { $0.groupID == nil }
        if !isSearching || !loose.isEmpty {
            result.append(
                HostBucket(
                    groupID: nil,
                    title: "未分组",
                    hosts: loose,
                    collapsed: isSearching ? false : store.ungroupedCollapsed
                )
            )
        }
        if isSearching {
            result.removeAll { $0.hosts.isEmpty }
        }
        return result
    }

    private var sidebarItems: [SidebarItem] {
        if visibleHosts.isEmpty, isSearching {
            return [.emptySearch]
        }
        return buckets.flatMap { bucket in
            var items: [SidebarItem] = [.group(bucket)]
            if !bucket.collapsed {
                items += bucket.hosts.map { .host(bucketID: bucket.id, host: $0) }
            }
            return items
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            sidebarChrome
            sidebarList
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var sidebarList: some View {
        List(selection: $selectedID) {
            ForEach(sidebarItems) { item in
                sidebarRow(item)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 18)
        .contentMargins(.top, 2, for: .scrollContent)
        .overlay {
            if store.hosts.isEmpty, store.groups.isEmpty {
                ContentUnavailableView {
                    Label("没有监控项", systemImage: AnnyIcon.host)
                } description: {
                    Text("点工具栏加号加入一台机器。")
                }
                .symbolRenderingMode(.hierarchical)
            }
        }
    }

    @ViewBuilder
    private func sidebarRow(_ item: SidebarItem) -> some View {
        switch item {
        case .emptySearch:
            emptySearchRow
        case .group(let bucket):
            groupListRow(bucket)
        case .host(let bucketID, let host):
            hostListRow(bucketID: bucketID, host: host)
        }
    }

    private var emptySearchRow: some View {
        Text("没有匹配")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 8))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .selectionDisabled()
    }

    private func groupListRow(_ bucket: HostBucket) -> some View {
        groupHeader(bucket)
            .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 8))
            .listRowSeparator(.hidden)
            .listRowBackground(dropTarget == bucket.id ? Color.accentColor.opacity(0.14) : Color.clear)
            .selectionDisabled()
    }

    private func hostListRow(bucketID: String, host: WatchedHost) -> some View {
        hostRow(host)
            .tag(host.id)
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
            .listRowSeparator(.hidden)
            .listRowBackground(dropTarget == "host-\(host.id.uuidString)" ? Color.accentColor.opacity(0.14) : Color.clear)
            .background {
                HostListDoubleClick {
                    openTerminal(host)
                    searchFocused = false
                }
                .allowsHitTesting(false)
            }
            .contextMenu { hostMenu(host) }
            .draggable(host.id.uuidString)
            .dropDestination(for: String.self) { items, _ in
                guard let bucket = buckets.first(where: { $0.id == bucketID }) else { return false }
                return dropHost(items, onto: bucket, before: host.id)
            } isTargeted: { hovering in
                dropTarget = hovering && !isSearching ? "host-\(host.id.uuidString)" : nil
            }
    }

    private var sidebarChrome: some View {
        HStack(spacing: 6) {
            Image(systemName: AnnyIcon.search)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
            TextField("搜索", text: $hostSearch, prompt: Text("备注或主机名"))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
            if isSearching {
                Button {
                    hostSearch = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
            Button {
                commitRename()
                beginRename(store.addGroup())
            } label: {
                Image(systemName: AnnyIcon.add)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("新增分组")
            .disabled(isSearching)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.6)
        }
    }

    @ViewBuilder
    private func groupHeader(_ bucket: HostBucket) -> some View {
        let renaming = bucket.groupID != nil && renamingGroupID == bucket.groupID
        HStack(spacing: 5) {
            let ids = bucket.hosts.map(\.id)
            Toggle("", isOn: Binding(
                get: { !ids.isEmpty && ids.allSatisfy { inspect.checked.contains($0) } },
                set: { inspect.setChecked(ids, $0) }
            ))
            .toggleStyle(.checkbox)
            .controlSize(.mini)
            .labelsHidden()
            .disabled(ids.isEmpty)
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(bucket.collapsed ? 0 : 90))
                .frame(width: 10, height: 10)
            if let groupID = bucket.groupID, renamingGroupID == groupID {
                TextField("分组名", text: $renameDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .focused($renameFocused)
                    .onSubmit { commitRename() }
                    .onChange(of: renameFocused) { _, focused in
                        if !focused { commitRename() }
                    }
            } else {
                Text(bucket.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(bucket.hosts.count)")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 20, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !renaming else { return }
            let now = Date()
            if let lock = collapseTapLock, now.timeIntervalSince(lock) < 0.35 { return }
            collapseTapLock = now
            store.setCollapsed(groupID: bucket.groupID, collapsed: !bucket.collapsed)
        }
        .dropDestination(for: String.self) { items, _ in
            dropHost(items, onto: bucket, before: nil)
        } isTargeted: { hovering in
            dropTarget = hovering ? bucket.id : nil
        }
        .contextMenu {
            Button(bucket.collapsed ? "展开" : "折叠") {
                store.toggleCollapsed(groupID: bucket.groupID)
            }
            Button("巡查本组") {
                inspect.setChecked(bucket.hosts.map(\.id), true)
                workspace = .inspect
                inspect.start(hosts: store.hosts, selectedID: selectedID)
            }
            .disabled(bucket.hosts.isEmpty || inspect.isRunning)
            if let groupID = bucket.groupID, let group = store.groups.first(where: { $0.id == groupID }) {
                Button("重命名") { beginRename(group) }
                    .disabled(isSearching)
                Button("删除分组", role: .destructive) { store.deleteGroup(id: groupID) }
                    .disabled(isSearching)
            }
        }
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel("\(bucket.title)，\(bucket.hosts.count) 台")
        .accessibilityHint(bucket.collapsed ? "展开分组" : "折叠分组")
    }

    private func beginRename(_ group: HostGroup) {
        renameDraft = group.name
        renamingGroupID = group.id
        renameFocused = true
    }

    private func commitRename() {
        guard let id = renamingGroupID else { return }
        store.renameGroup(id: id, to: renameDraft)
        renamingGroupID = nil
    }

    @discardableResult
    private func dropHost(_ items: [String], onto bucket: HostBucket, before neighborID: UUID?) -> Bool {
        guard !isSearching, let raw = items.first, let id = UUID(uuidString: raw) else { return false }
        store.moveHost(id, toGroup: bucket.groupID, before: neighborID)
        if bucket.collapsed {
            store.setCollapsed(groupID: bucket.groupID, collapsed: false)
        }
        return true
    }

    @ViewBuilder
    private func hostRow(_ host: WatchedHost) -> some View {
        let state = sessionState(host.id)
        HStack(spacing: 6) {
            Toggle("", isOn: Binding(
                get: { inspect.isChecked(host.id) },
                set: { inspect.setChecked(host.id, $0) }
            ))
            .toggleStyle(.checkbox)
            .controlSize(.mini)
            .labelsHidden()
            Image(systemName: AnnyIcon.host)
                .font(.system(size: 10))
                .foregroundStyle(state == .connected ? Color.green : Color.secondary.opacity(0.7))
                .frame(width: 12)
            Text(host.displayName)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer(minLength: 0)
            if let record = inspect.record(for: host.id) {
                Circle()
                    .fill(Theme.inspectColor(record.severity))
                    .frame(width: 6, height: 6)
                    .help(record.error ?? "上次巡查 \(Theme.percentText(max(record.cpuPercent ?? 0, record.memoryPercent ?? 0, record.diskPercent ?? 0)))")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 20, alignment: .leading)
        .contentShape(Rectangle())
        .help(host.endpointLabel)
    }

    @ViewBuilder
    private func hostMenu(_ host: WatchedHost) -> some View {
        Button("连接", systemImage: AnnyIcon.terminal) { openTerminal(host) }
        if openedTerminals.contains(host.id) {
            Button("断开", systemImage: AnnyIcon.disconnect, role: .destructive) { disconnect(host) }
        }
        Button("编辑", systemImage: AnnyIcon.edit) { editingHost = host }
        Button(inspect.isChecked(host.id) ? "移出巡查" : "加入巡查") {
            inspect.setChecked(host.id, !inspect.isChecked(host.id))
            workspace = .inspect
        }
        Menu("移到分组") {
            Button("未分组") { store.moveHost(host.id, toGroup: nil, before: nil) }
            ForEach(store.groups) { group in
                Button(group.name) { store.moveHost(host.id, toGroup: group.id, before: nil) }
            }
        }
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
            machineWorkspace
                .padding(20)
                .opacity(workspace == .machine ? 1 : 0)
                .allowsHitTesting(workspace == .machine)
            InspectView(selectedID: selectedID) { id in
                selectedID = id
            }
            .padding(20)
            .opacity(workspace == .inspect ? 1 : 0)
            .allowsHitTesting(workspace == .inspect)
        }
        .transaction { $0.animation = nil }
    }

    private var machineWorkspace: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let host = selected {
                hostHeader(host)
            }

            machineBody
        }
    }

    private var machineBody: some View {
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
            Text("点「连接」或双击左侧名单。切换机器不会自动连接。")
        }
        .symbolRenderingMode(.hierarchical)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cardBackground()
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
                if let ip = metrics?.publicIP, !ip.isEmpty {
                    Label {
                        Text(verbatim: ip)
                            .font(.subheadline.monospaced())
                            .textSelection(.enabled)
                    } icon: {
                        AnnySymbol(name: AnnyIcon.network, font: .subheadline)
                    }
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                    .help("外网出口")
                }
            }

            Spacer(minLength: 12)

            Picker("面板", selection: $detailPane) {
                Text("资源").tag(DetailPane.metrics)
                Text("终端").tag(DetailPane.terminal)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 148)
            .help("查看资源或打开终端")

            AnnyGlassCluster(spacing: 10) {
                HStack(spacing: 10) {
                    Button("刷新", systemImage: AnnyIcon.refresh) { refresh() }
                        .disabled(loading)
                        .help("读取 CPU、内存和磁盘")
                        .annyGlass()
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
            (AnnyIcon.network, "出口", m.publicIP ?? "—"),
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
        inspect.forget(host.id)
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

private struct HostBucket: Identifiable {
    var id: String { groupID?.uuidString ?? "ungrouped" }
    var groupID: UUID?
    var title: String
    var hosts: [WatchedHost]
    var collapsed: Bool
}

private enum SidebarItem: Identifiable {
    case emptySearch
    case group(HostBucket)
    case host(bucketID: String, host: WatchedHost)

    var id: String {
        switch self {
        case .emptySearch:
            return "empty-search"
        case .group(let bucket):
            return "g-\(bucket.id)"
        case .host(_, let host):
            return "h-\(host.id.uuidString)"
        }
    }
}

/// 只在主机行范围内认双击，组头不会开终端。事件原样下放。
private struct HostListDoubleClick: NSViewRepresentable {
    var action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.attach()
        return context.coordinator.view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.action = action
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        var action: () -> Void
        let view = PassThroughView()
        private var monitor: Any?

        init(action: @escaping () -> Void) {
            self.action = action
        }

        func attach() {
            detach()
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, event.clickCount == 2 else { return event }
                let loc = self.view.convert(event.locationInWindow, from: nil)
                if self.view.window != nil, self.view.bounds.contains(loc) {
                    DispatchQueue.main.async { self.action() }
                }
                return event
            }
        }

        func detach() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit { detach() }
    }

    final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
