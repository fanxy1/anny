import AppKit
import SwiftUI

struct KeysPane: View {
    let hostID: UUID
    var snapshot: AuthKeysSnapshot?
    var loading: Bool
    var mutating: Bool
    var onAdd: (String) async throws -> Void
    var onDelete: (Set<Int>) async throws -> Void

    @State private var selected = Set<Int>()
    @State private var showAdd = false
    @State private var pendingDelete = false
    @State private var deleteError: String?

    private var rows: [AuthKeyRow] {
        snapshot?.rows ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            toolbar
            if loading && snapshot == nil {
                loadingCard
            } else if let error = snapshot?.error, rows.isEmpty {
                errorCard(error)
            } else if snapshot == nil {
                emptyCard
            } else {
                table
            }
        }
        .onChange(of: hostID) { _, _ in
            resetLocalState()
        }
        .onChange(of: snapshot?.fetchedAt) { _, _ in
            selected = []
            pendingDelete = false
        }
        .sheet(isPresented: $showAdd) {
            AddAuthKeySheet(fingerprints: existingFingerprints, onAdd: onAdd)
        }
        .confirmationDialog(
            "删除 \(selected.count) 把密钥？",
            isPresented: $pendingDelete,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                pendingDelete = false
                deleteSelected()
            }
            Button("取消", role: .cancel) { pendingDelete = false }
        } message: {
            Text("从当前账户的 authorized_keys 里去掉勾选的行。确认后立刻写回。")
        }
        .alert("出错", isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )) {
            Button("好", role: .cancel) { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text(statusLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Button("添加") { showAdd = true }
                .disabled(snapshot == nil || mutating || loading)
                .help("粘贴一行公钥，写入当前账户的 authorized_keys")
                .annyGlass(prominent: true)

            Button("删除", role: .destructive) { pendingDelete = true }
                .disabled(!canDelete)
                .help(deleteHelp)
                .annyGlass()
        }
        .cardBackground()
    }

    private var loadingCard: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("正在读取密钥…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .cardBackground()
    }

    private func errorCard(_ error: String) -> some View {
        ContentUnavailableView {
            Label("读不到密钥", systemImage: AnnyIcon.keys)
        } description: {
            Text(error)
        }
        .symbolRenderingMode(.hierarchical)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cardBackground()
    }

    private var emptyCard: some View {
        ContentUnavailableView {
            Label("尚未读取密钥", systemImage: AnnyIcon.keys)
        } description: {
            Text("点「刷新」或打开这一页会自动读一次。")
        }
        .symbolRenderingMode(.hierarchical)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cardBackground()
    }

    private var table: some View {
        VStack(spacing: 0) {
            keyRow(isHeader: true) {
                headerCheckbox
                Text("类型")
                    .frame(width: 88, alignment: .leading)
                Text("备注")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("指纹")
                    .frame(width: 360, alignment: .leading)
            }
            .foregroundStyle(.secondary)
            .font(.caption.weight(.medium))
            Divider().opacity(0.55)

            if rows.isEmpty {
                Text("还没有密钥")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            keyRow(selected: selected.contains(row.id)) {
                                rowCheckbox(row)
                                Text(row.typeLabel)
                                    .font(.body.monospaced())
                                    .foregroundStyle(row.valid ? Color.primary : Color.secondary)
                                    .lineLimit(1)
                                    .frame(width: 88, alignment: .leading)
                                Text(row.comment.isEmpty ? "无备注" : row.comment)
                                    .foregroundStyle(row.comment.isEmpty ? Color.secondary : Color.primary)
                                    .lineLimit(1)
                                    .help(row.comment.isEmpty ? "无备注" : row.comment)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(row.fingerprint)
                                    .font(.body.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                    .help(row.fingerprint)
                                    .frame(width: 360, alignment: .leading)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { toggle(row.id) }
                            .contextMenu {
                                Button("复制指纹") {
                                    copy(row.fingerprint)
                                }
                                .disabled(!row.valid)
                                Button("复制整行公钥") {
                                    copy(row.raw)
                                }
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

    private var headerCheckbox: some View {
        let allOn = !rows.isEmpty && rows.allSatisfy { selected.contains($0.id) }
        return Toggle("全选", isOn: Binding(
            get: { allOn },
            set: { on in
                if on {
                    selected = Set(rows.map(\.id))
                } else {
                    selected = []
                }
            }
        ))
        .toggleStyle(.checkbox)
        .labelsHidden()
        .disabled(rows.isEmpty || mutating)
        .frame(width: 22)
        .help(allOn ? "取消全选" : "全选")
    }

    private func rowCheckbox(_ row: AuthKeyRow) -> some View {
        Toggle("选中", isOn: Binding(
            get: { selected.contains(row.id) },
            set: { on in
                if on {
                    selected.insert(row.id)
                } else {
                    selected.remove(row.id)
                }
            }
        ))
        .toggleStyle(.checkbox)
        .labelsHidden()
        .disabled(mutating)
        .frame(width: 22)
    }

    private func keyRow<Content: View>(
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

    private var statusLine: String {
        if loading && snapshot == nil {
            return "正在读取…"
        }
        if mutating {
            return "正在写入…"
        }
        let total = rows.count
        if selected.isEmpty {
            return total == 0 ? "还没有密钥" : "\(total) 把密钥"
        }
        return "已选 \(selected.count)/\(total)"
    }

    private var canDelete: Bool {
        !selected.isEmpty && !mutating && !loading && snapshot != nil
    }

    private var deleteHelp: String {
        if selected.isEmpty { return "先勾选要删除的密钥" }
        if mutating { return "正在写入" }
        return "从 authorized_keys 去掉勾选的行"
    }

    private var existingFingerprints: Set<String> {
        Set(rows.filter(\.valid).map(\.fingerprint))
    }

    private func toggle(_ id: Int) {
        guard !mutating else { return }
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
    }

    private func deleteSelected() {
        let indices = selected
        Task {
            do {
                try await onDelete(indices)
            } catch {
                deleteError = error.localizedDescription
            }
        }
    }

    private func resetLocalState() {
        selected = []
        showAdd = false
        pendingDelete = false
        deleteError = nil
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct AddAuthKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    var fingerprints: Set<String>
    var onAdd: (String) async throws -> Void

    @State private var text = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .font(.body.monospaced())
                        .frame(minHeight: 140)
                } header: {
                    Label("公钥", systemImage: AnnyIcon.keys)
                } footer: {
                    if let error {
                        Text(error)
                    } else {
                        Text("粘贴一行 ssh-ed25519 AAAA… comment")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("添加密钥")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", role: .cancel) { dismiss() }
                        .disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") { submit() }
                        .disabled(saving)
                }
            }
            .onChange(of: text) { _, _ in
                error = nil
            }
        }
        .frame(width: 520, height: 360)
    }

    private func submit() {
        let parsed = AuthKeys.parsePasted(text)
        if let message = parsed.error {
            error = message
            return
        }
        guard let line = parsed.line else {
            error = "不是合法的公钥"
            return
        }
        let row = AuthKeys.parseLine(line, index: 0)
        if fingerprints.contains(row.fingerprint) {
            error = "这把密钥已经在名单里"
            return
        }
        saving = true
        Task {
            do {
                try await onAdd(line)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }
}
