import SwiftUI

struct InspectView: View {
    @EnvironmentObject private var store: HostStore
    @EnvironmentObject private var inspect: InspectStore
    var selectedID: UUID?
    var onSelect: (UUID) -> Void

    @State private var tableSelection: UUID?
    @State private var sortKey: InspectSort?
    @State private var sortAscending = true

    private var rows: [InspectRow] {
        let raw = inspect.runIDs.compactMap { id -> InspectRow? in
            guard let host = store.hosts.first(where: { $0.id == id }) else { return nil }
            return InspectRow(
                id: id,
                host: host,
                record: inspect.record(for: id),
                running: inspect.runningIDs.contains(id)
            )
        }
        guard let sortKey else { return raw }
        return raw.sorted { lhs, rhs in
            let result = lhs.compare(rhs, by: sortKey)
            return sortAscending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            toolbar
            if rows.isEmpty {
                empty
            } else {
                table
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text(statusLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 12)
            if inspect.isRunning {
                ProgressView()
                    .controlSize(.small)
                Text("\(inspect.finishedCount)/\(inspect.runIDs.count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("停止") { inspect.cancel() }
                    .annyGlass()
            } else {
                HStack(spacing: 6) {
                    Text("线程")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Stepper(value: concurrencyBinding, in: 1...16) {
                        Text("\(inspect.concurrency)")
                            .font(.body.monospacedDigit())
                            .frame(minWidth: 20, alignment: .trailing)
                    }
                    .controlSize(.small)
                    .help("同时巡查几台，1 到 16")
                }
                Button("清除勾选") { inspect.clearChecked() }
                    .disabled(inspect.checked.isEmpty)
                    .annyGlass()
                Button("开始巡查", systemImage: AnnyIcon.inspect) {
                    inspect.start(hosts: store.hosts, selectedID: selectedID)
                }
                .disabled(store.hosts.isEmpty)
                .help("巡查勾选的机器；未勾选则巡查当前这一台")
                .annyGlass(prominent: true)
            }
        }
        .cardBackground()
    }

    private var statusLine: String {
        if inspect.isRunning {
            return "正在读取 CPU、内存和磁盘…"
        }
        if rows.isEmpty {
            let n = inspect.checked.count
            if n == 0 {
                return "勾选左侧机器，或直接巡查当前选中的一台。"
            }
            return "已勾选 \(n) 台。"
        }
        if inspect.dangerCount > 0 {
            return "上次 \(rows.count) 台，其中 \(inspect.dangerCount) 台危险。"
        }
        return "上次 \(rows.count) 台，没有危险项。"
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("还没有巡查结果", systemImage: AnnyIcon.inspect)
        } description: {
            Text("勾选左侧机器后点「开始巡查」。未勾选时会巡查当前选中的一台。≥75% 标橙，≥90% 或连不上标红。")
        }
        .symbolRenderingMode(.hierarchical)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cardBackground()
    }

    private var table: some View {
        VStack(spacing: 0) {
            inspectRow(isHeader: true) {
                headerCell("机器")
                headerCell("出口", width: 128)
                sortCell("CPU", .cpu, width: 72)
                sortCell("内存", .memory, width: 72)
                sortCell("磁盘", .disk, width: 72)
                sortCell("状态", .status, width: 80)
                headerCell("时间", width: 88)
            }
            .foregroundStyle(.secondary)
            .font(.caption.weight(.medium))
            Divider().opacity(0.55)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        inspectRow(selected: tableSelection == row.id) {
                            Text(row.host.displayName)
                                .foregroundStyle(nameColor(row))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            egressText(row)
                                .frame(width: 128, alignment: .leading)
                            metricText(row.record?.cpuPercent, running: row.running)
                                .frame(width: 72, alignment: .leading)
                            metricText(row.record?.memoryPercent, running: row.running)
                                .frame(width: 72, alignment: .leading)
                            metricText(row.record?.diskPercent, running: row.running)
                                .frame(width: 72, alignment: .leading)
                            Text(statusText(row))
                                .foregroundStyle(statusColor(row))
                                .help(row.record?.error ?? "")
                                .frame(width: 80, alignment: .leading)
                            timeText(row)
                                .frame(width: 88, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            tableSelection = row.id
                            onSelect(row.id)
                        }
                        .contextMenu {
                            Button("重新巡查") {
                                tableSelection = row.id
                                onSelect(row.id)
                                inspect.restart(row.host)
                            }
                            .disabled(inspect.isRunning)
                        }
                        Divider().opacity(0.35)
                    }
                }
            }
        }
        .cardBackground()
    }

    private func inspectRow<Content: View>(
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

    private func headerCell(_ title: String, width: CGFloat? = nil) -> some View {
        Text(title)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .frame(width: width, alignment: .leading)
    }

    private func sortCell(_ title: String, _ key: InspectSort, width: CGFloat) -> some View {
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
            .frame(width: width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("按\(title)排序")
    }

    private var concurrencyBinding: Binding<Int> {
        Binding(
            get: { inspect.concurrency },
            set: { inspect.setConcurrency($0) }
        )
    }

    private func toggleSort(_ key: InspectSort) {
        if sortKey == key {
            sortAscending.toggle()
        } else {
            sortKey = key
            sortAscending = true
        }
    }

    @ViewBuilder
    private func egressText(_ row: InspectRow) -> some View {
        if row.running {
            Text("…")
                .foregroundStyle(.secondary)
        } else {
            Text(row.record?.publicIP ?? "—")
                .foregroundStyle(row.record?.publicIP == nil ? Color.secondary : Color.primary)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func timeText(_ row: InspectRow) -> some View {
        if let at = row.record?.fetchedAt, !row.running {
            Text(at.formatted(date: .omitted, time: .standard))
                .foregroundStyle(.secondary)
        } else {
            Text("—")
                .foregroundStyle(.tertiary)
        }
    }

    private func metricText(_ value: Double?, running: Bool) -> some View {
        Group {
            if running {
                Text("…")
                    .foregroundStyle(.secondary)
            } else {
                Text(Theme.percentText(value))
                    .foregroundStyle(value.map(Theme.usageColor) ?? Color.secondary)
            }
        }
        .font(.body.monospacedDigit())
    }

    private func statusText(_ row: InspectRow) -> String {
        if row.running { return "巡查中" }
        guard let record = row.record else { return "—" }
        if record.error != nil { return "失败" }
        switch record.severity {
        case .danger: return "危险"
        case .warning: return "告警"
        case .ok: return "正常"
        }
    }

    private func statusColor(_ row: InspectRow) -> Color {
        if row.running { return .secondary }
        guard let record = row.record else { return .secondary }
        if record.error != nil { return .red }
        return Theme.inspectColor(record.severity)
    }

    private func nameColor(_ row: InspectRow) -> Color {
        if row.running { return .primary }
        guard let record = row.record else { return .primary }
        return record.severity == .danger ? .red : .primary
    }
}

private enum InspectSort {
    case cpu, memory, disk, status
}

private struct InspectRow: Identifiable, Hashable {
    var id: UUID
    var host: WatchedHost
    var record: InspectRecord?
    var running: Bool

    func compare(_ other: InspectRow, by key: InspectSort) -> ComparisonResult {
        switch key {
        case .cpu:
            return compareMetric(cpuSort, other.cpuSort)
        case .memory:
            return compareMetric(memorySort, other.memorySort)
        case .disk:
            return compareMetric(diskSort, other.diskSort)
        case .status:
            if statusSort == other.statusSort { return .orderedSame }
            return statusSort < other.statusSort ? .orderedAscending : .orderedDescending
        }
    }

    private var cpuSort: Double? { running ? nil : record?.cpuPercent }
    private var memorySort: Double? { running ? nil : record?.memoryPercent }
    private var diskSort: Double? { running ? nil : record?.diskPercent }
    private var statusSort: Int {
        if running { return 0 }
        guard let record else { return 0 }
        if record.error != nil { return 4 }
        switch record.severity {
        case .ok: return 1
        case .warning: return 2
        case .danger: return 3
        }
    }

    private func compareMetric(_ a: Double?, _ b: Double?) -> ComparisonResult {
        switch (a, b) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedAscending
        case (_, nil): return .orderedDescending
        case let (lhs?, rhs?):
            if lhs == rhs { return .orderedSame }
            return lhs < rhs ? .orderedAscending : .orderedDescending
        }
    }
}
