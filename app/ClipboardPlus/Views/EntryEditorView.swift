import SwiftUI

/// Writes a new template, or changes a template's name, tag and text. Pictures and files keep
/// their contents, so for them only the name and the tag can change.
struct EntryEditorView: View {
    enum Mode: Identifiable {
        /// A new template, with the tag of the group it was started from.
        case create(tag: String?)
        case edit(HistoryEntry)

        var id: String {
            switch self {
            case .create(let tag): return "create-\(tag ?? "")"
            case .edit(let entry): return "edit-\(entry.id)"
            }
        }
    }

    private enum Field { case title, tag, text }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject var monitor: ClipboardMonitor
    let mode: Mode
    /// Tags already in use, offered so that the same tag is spelled the same way.
    let tags: [String]
    /// Receives a short message for the toast after a successful save.
    let onSaved: (String) -> Void

    @State private var title: String
    @State private var tag: String
    @State private var text: String
    @State private var error: String?
    @State private var isSaving = false
    @FocusState private var focus: Field?

    init(monitor: ClipboardMonitor, mode: Mode, tags: [String], onSaved: @escaping (String) -> Void) {
        self.monitor = monitor
        self.mode = mode
        self.tags = tags
        self.onSaved = onSaved
        switch mode {
        case .create(let tag):
            _title = State(initialValue: "")
            _tag = State(initialValue: tag ?? "")
            _text = State(initialValue: "")
        case .edit(let entry):
            _title = State(initialValue: entry.title ?? "")
            _tag = State(initialValue: entry.tag ?? "")
            _text = State(initialValue: entry.text)
        }
    }

    private var entry: HistoryEntry? {
        if case .edit(let entry) = mode { return entry }
        return nil
    }

    private var editsText: Bool { entry.map { $0.kind == .text || $0.kind == .url } ?? true }

    private var canSave: Bool {
        !isSaving && (!editsText || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private static func optional(_ value: String) -> String? {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("例：署名、自宅の住所", text: $title)
                        .focused($focus, equals: .title)
                        .submitLabel(.next)
                        .onSubmit { focus = .tag }
                } header: {
                    Text("名前")
                } footer: {
                    Text("付けておくと、検索やショートカット、Siriで名前から探せます。なくてもかまいません。")
                }
                Section {
                    HStack(spacing: 8) {
                        TextField("例：住所セット", text: $tag)
                            .focused($focus, equals: .tag)
                            .submitLabel(editsText ? .next : .done)
                            .onSubmit {
                                if editsText { focus = .text } else { save() }
                            }
                        if !tags.isEmpty || !tag.isEmpty {
                            Menu {
                                ForEach(Array(tags.enumerated()), id: \.offset) { _, value in
                                    Button(value) { tag = value }
                                }
                                if !tag.isEmpty {
                                    Divider()
                                    Button("タグを外す", systemImage: "xmark") { tag = "" }
                                }
                            } label: {
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(width: 36, height: 32)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel("使っているタグから選ぶ")
                        }
                    }
                } header: {
                    Text("タグ")
                } footer: {
                    Text("同じタグのものがひとつにまとまります。なければ「その他」に入ります。")
                }
                if editsText {
                    Section("本文") {
                        TextEditor(text: $text)
                            .focused($focus, equals: .text)
                            .frame(minHeight: 180)
                    }
                } else if let entry {
                    Section {
                        Label(entry.file?.displayName ?? "画像",
                              systemImage: entry.file?.symbolName ?? "photo")
                            .lineLimit(2)
                    } footer: {
                        Text("画像とファイルは、名前とタグだけを変えられます。")
                    }
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.red)
                    }
                }
            }
            // Short, so a narrow window shows it whole between the two buttons.
            .navigationTitle(entry == nil ? "新規作成" : "編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
            }
            .onAppear {
                // A sheet takes the keyboard only after it has finished sliding in.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    focus = editsText ? .text : .title
                }
            }
        }
        .tint(Theme.accent)
    }

    private func save() {
        guard canSave else { return }
        error = nil
        isSaving = true
        let name = Self.optional(title)
        let group = Self.optional(tag)
        switch mode {
        case .create:
            monitor.createTemplate(text: text, title: name, tag: group) { result in
                finish(result, message: "テンプレートに追加しました")
            }
        case .edit(let entry):
            monitor.updateTemplate(entry, text: editsText ? text : nil, title: name, tag: group) { result in
                finish(result, message: "保存しました")
            }
        }
    }

    private func finish(_ result: Result<HistoryEntry, HistoryEditError>, message: String) {
        isSaving = false
        switch result {
        case .success:
            onSaved(message)
            dismiss()
        case .failure(let failure):
            error = failure.message
        }
    }
}
