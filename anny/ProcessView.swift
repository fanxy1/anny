import SwiftUI

struct ProcessPane: View {
    let hostID: UUID
    var snapshot: ProcessSnapshot?
    var loading: Bool
    var live: Bool
    var killingPID: Int?
    var searchFocused: FocusState<Bool>.Binding
    var onRefresh: () -> Void
    var onKill: (ProcessRow) -> Void

    @State private var query = ""
    @State private var sortKey = ProcessSort.cpu
    @State private var sortAscending = false
    @State private var hideKernel = true
    @State private var pinned: Set<Int> = []
    @State private var selectedPID: Int?
    @State private var pendingKill: ProcessRow?

    private var rows: [ProcessRow] {
        let q = query
        let filtered = (snapshot?.rows ?? []).filter { row in
            if hideKernel, row.isKernel { return false }
            return row.matches(q)
        }
        return filtered.sorted { lhs, rhs in
            let lp = pinned.contains(lhs.pid)
            let rp = pinned.contains(rhs.pid)
            if lp != rp { return lp && !rp }
            let result = lhs.compare(rhs, by: sortKey)
            if result == .orderedSame { return lhs.pid < rhs.pid }
            return sortAscending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private var selected: ProcessRow? {
        rows.first { $0.pid == selectedPID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            toolbar
            if loading && snapshot == nil {
                loadingCard
            } else if let error = snapshot?.error, snapshot?.rows.isEmpty != false {
                errorCard(error)
            } else if snapshot == nil {
                emptyCard
            } else {
                table
            }
        }
        .onChange(of: hostID) { _, _ in
            query = ""
            pinned = []
            selectedPID = nil
            pendingKill = nil
        }
        .confirmationDialog(
            pendingKill.map { "结束 \($0.command)？" } ?? "结束进程？",
            isPresented: Binding(
                get: { pendingKill != nil },
                set: { if !$0 { pendingKill = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let row = pendingKill {
                Button("结束", role: .destructive) {
                    pendingKill = nil
                    onKill(row)
                }
            }
            Button("取消", role: .cancel) { pendingKill = nil }
        } message: {
            if let row = pendingKill {
                Text("向 PID \(row.pid) 发送 TERM，进程可以自己退出。")
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: AnnyIcon.search)
                    .foregroundStyle(.secondary)
                TextField("搜索进程、用户或 PID", text: $query)
                    .textFieldStyle(.plain)
                    .focused(searchFocused)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .frame(maxWidth: 280)

            Text(statusLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help("逗号表示或，例如 nginx, redis")

            Spacer(minLength: 8)

            Toggle("内核线程", isOn: Binding(
                get: { !hideKernel },
                set: { hideKernel = !$0 }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("打开后显示 [kworker] 这类内核线程")

            Button("结束") {
                if let row = selected { pendingKill = row }
            }
            .disabled(!canKill)
            .help(killHelp)
            .annyGlass()
        }
        .cardBackground()
    }

    private var loadingCard: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(live ? "正在动态读取进程…" : "正在读取进程…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .cardBackground()
    }

    private func errorCard(_ error: String) -> some View {
        ContentUnavailableView {
            Label("读不到进程", systemImage: AnnyIcon.processes)
        } description: {
            Text(error)
        }
        .symbolRenderingMode(.hierarchical)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cardBackground()
    }

    private var emptyCard: some View {
        ContentUnavailableView {
            Label("尚未读取进程", systemImage: AnnyIcon.processes)
        } description: {
            Text("点「刷新」或打开「动态」。切换到这一页会自动读一次。")
        }
        .symbolRenderingMode(.hierarchical)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cardBackground()
    }

    private var table: some View {
        VStack(spacing: 0) {
            processRow(isHeader: true) {
                pinHeader
                sortCell("CPU", .cpu, width: 64)
                sortCell("内存", .memory, width: 64)
                sortCell("PID", .pid, width: 64)
                sortCell("用户", .user, width: 88)
                sortCell("占用", .rss, width: 72)
                sortCell("进程", .command, width: nil)
            }
            .foregroundStyle(.secondary)
            .font(.caption.weight(.medium))
            Divider().opacity(0.55)

            if rows.isEmpty {
                Text(query.isEmpty ? "没有进程" : "没有匹配的进程")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            processRow(selected: selectedPID == row.pid) {
                                pinButton(row)
                                metricText(row.cpuPercent)
                                    .frame(width: 64, alignment: .leading)
                                metricText(row.memPercent)
                                    .frame(width: 64, alignment: .leading)
                                Text("\(row.pid)")
                                    .font(.body.monospacedDigit())
                                    .frame(width: 64, alignment: .leading)
                                Text(row.user)
                                    .lineLimit(1)
                                    .frame(width: 88, alignment: .leading)
                                Text(rssText(row.rssBytes))
                                    .font(.body.monospacedDigit())
                                    .frame(width: 72, alignment: .leading)
                                Text(row.command)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .help(row.command)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { selectedPID = row.pid }
                            .contextMenu {
                                Button(pinned.contains(row.pid) ? "取消固定" : "固定在顶部") {
                                    togglePin(row.pid)
                                }
                                Button("结束进程", role: .destructive) {
                                    selectedPID = row.pid
                                    pendingKill = row
                                }
                                .disabled(row.pid <= 1 || killingPID != nil)
                            }
                            Divider().opacity(0.35)
                        }
                    }
                }
                .transaction { $0.animation = nil }
            }
        }
        .cardBackground()
    }

    private var pinHeader: some View {
        Image(systemName: AnnyIcon.pin)
            .font(.caption2)
            .frame(width: 22)
            .accessibilityHidden(true)
    }

    private func pinButton(_ row: ProcessRow) -> some View {
        let on = pinned.contains(row.pid)
        return Button {
            togglePin(row.pid)
        } label: {
            Image(systemName: on ? AnnyIcon.pinFill : AnnyIcon.pin)
                .font(.caption)
                .foregroundStyle(on ? Color.accentColor : Color.secondary.opacity(0.55))
                .frame(width: 22, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(on ? "取消固定" : "固定在顶部")
    }

    private func processRow<Content: View>(
        isHeader: Bool = false,
        selected: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 8) {
            content()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, isHeader ? 7 : 6)
        .background(selected ? Color.accentColor.opacity(0.16) : Color.clear)
    }

    private func sortCell(_ title: String, _ key: ProcessSort, width: CGFloat?) -> some View {
        Button {
            toggleSort(key)
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if sortKey == key {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
            }
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .frame(width: width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("按\(title)排序")
    }

    private func metricText(_ value: Double) -> some View {
        Text(String(format: "%.1f%%", value))
            .font(.body.monospacedDigit())
            .foregroundStyle(Theme.usageColor(min(value, 100)))
    }

    private var statusLine: String {
        let total = snapshot?.rows.count ?? 0
        if loading {
            return live ? "刷新中 · \(total) 个进程" : "正在读取…"
        }
        if live {
            return "动态 · \(rows.count)/\(total)"
        }
        if total == 0 {
            return "还没有数据"
        }
        if hideKernel, rows.count != total {
            return "\(rows.count)/\(total) 个进程"
        }
        return "\(total) 个进程"
    }

    private var canKill: Bool {
        guard let row = selected, row.pid > 1 else { return false }
        return killingPID == nil
    }

    private var killHelp: String {
        if selected == nil { return "先点一行再结束" }
        if selected?.pid ?? 0 <= 1 { return "不能结束这个进程" }
        return "向选中进程发送 TERM"
    }

    private func toggleSort(_ key: ProcessSort) {
        if sortKey == key {
            sortAscending.toggle()
        } else {
            sortKey = key
            sortAscending = key == .user || key == .command || key == .pid
        }
    }

    private func togglePin(_ pid: Int) {
        if pinned.contains(pid) {
            pinned.remove(pid)
        } else {
            pinned.insert(pid)
        }
    }

    private func rssText(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .memory
        f.includesUnit = true
        f.isAdaptive = true
        return f.string(fromByteCount: bytes)
    }
}

enum ProcessSort {
    case cpu, memory, pid, user, rss, command
}

private extension ProcessRow {
    func compare(_ other: ProcessRow, by key: ProcessSort) -> ComparisonResult {
        switch key {
        case .cpu:
            return compareDouble(cpuPercent, other.cpuPercent)
        case .memory:
            return compareDouble(memPercent, other.memPercent)
        case .rss:
            if rssBytes == other.rssBytes { return .orderedSame }
            return rssBytes < other.rssBytes ? .orderedAscending : .orderedDescending
        case .pid:
            if pid == other.pid { return .orderedSame }
            return pid < other.pid ? .orderedAscending : .orderedDescending
        case .user:
            return compareString(user, other.user)
        case .command:
            return compareString(command, other.command)
        }
    }

    private func compareDouble(_ a: Double, _ b: Double) -> ComparisonResult {
        if a == b { return .orderedSame }
        return a < b ? .orderedAscending : .orderedDescending
    }

    private func compareString(_ a: String, _ b: String) -> ComparisonResult {
        let r = a.localizedCaseInsensitiveCompare(b)
        return r
    }
}
