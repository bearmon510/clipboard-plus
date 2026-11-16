import SwiftUI

/// Writes a new pinned text, or changes the name and text of an item. Pictures and files
/// keep their contents, so for them only the name can change.
struct EntryEditorView: View {
    enum Mode: Identifiable {
        case create
        case edit(HistoryEntry)

        var id: String {
            switch self {
            case .create: return "create"
            case .edit(let entry): return "edit-\(entry.id)"
            }
        }
    }

    private enum Field { case title, text }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject var monitor: ClipboardMonitor
    let mode: Mode
    /// Receives a short message for the toast after a successful save.
    let onSaved: (String) -> Void

    @State private var title: String
    @State private var text: String
    @State private var error: String?
    @State private var isSaving = false
    @FocusState private var focus: Field?

    init(monitor: ClipboardMonitor, mode: Mode, onSaved: @escaping (String) -> Void) {
        self.monitor = monitor
        self.mode = mode
        self.onSaved = onSaved
        switch mode {
        case .create:
            _title = State(initialValue: "")
            _text = State(initialValue: "")
        case .edit(let entry):
            _title = State(initialValue: entry.title ?? "")
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

    private var navigationTitle: String {
        guard let entry else { return "ピン留めに追加" }
        return editsText ? "編集" : (entry.displayTitle == nil ? "名前を付ける" : "名前を変更")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("例：署名、住所", text: $title)
                        .focused($focus, equals: .title)
                        .submitLabel(editsText ? .next : .done)
                        .onSubmit {
                            if editsText { focus = .text } else { save() }
                        }
                } header: {
                    Text("名前")
                } footer: {
                    Text("付けておくと、検索やショートカット、Siriで名前から探せます。なくてもかまいません。")
                }
                if editsText {
                    Section {
                        TextEditor(text: $text)
                            .focused($focus, equals: .text)
                            .frame(minHeight: 180)
                    } header: {
                        Text("本文")
                    } footer: {
                        if entry == nil {
                            Text("ピン留めに入ります。ピンを外すか削除するまで、自動では消えません。")
                        }
                    }
                } else if let entry {
                    Section {
                        Label(entry.file?.displayName ?? "画像",
                              systemImage: entry.file?.symbolName ?? "photo")
                            .lineLimit(2)
                    } footer: {
                        Text("画像とファイルは、名前だけを変えられます。")
                    }
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.red)
                    }
                }
            }
            .navigationTitle(navigationTitle)
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
        let name: String? = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : title
        error = nil
        switch mode {
        case .create:
            isSaving = true
            monitor.createWritten(text: text, title: name) { result in
                finish(result, message: "ピン留めに追加しました")
            }
        case .edit(let entry):
            if editsText {
                isSaving = true
                monitor.editText(entry, text: text, title: name) { result in
                    finish(result, message: "保存しました")
                }
            } else {
                monitor.setTitle(name, for: entry)
                onSaved(name == nil ? "名前を外しました" : "名前を付けました")
                dismiss()
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
