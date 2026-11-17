import SwiftUI

/// Puts the templates of one tag in the order the user wants.
/// A list of its own, because the cards themselves drag out to other apps.
struct TemplateOrderView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var items: [HistoryEntry]
    let title: String
    let onSave: ([Int]) -> Void

    init(title: String, items: [HistoryEntry], onSave: @escaping ([Int]) -> Void) {
        _items = State(initialValue: items)
        self.title = title
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(items) { entry in
                        row(entry)
                    }
                    .onMove { items.move(fromOffsets: $0, toOffset: $1) }
                } footer: {
                    Text("右端のつまみをドラッグして並べ替えます。")
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") {
                        onSave(items.map(\.id))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .tint(Theme.accent)
    }

    private func row(_ entry: HistoryEntry) -> some View {
        let title = entry.displayTitle
        return HStack(spacing: 12) {
            Image(systemName: entry.file?.symbolName ?? EntryFlavor.detect(entry).symbolName)
                .foregroundStyle(Theme.accent)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    Text(title).font(.body.weight(.semibold)).lineLimit(1)
                }
                Text(Self.summary(entry))
                    .font(title == nil ? .body : .subheadline)
                    .foregroundStyle(title == nil ? HierarchicalShapeStyle.primary : HierarchicalShapeStyle.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    static func summary(_ entry: HistoryEntry) -> String {
        switch entry.kind {
        case .image: return "画像"
        case .file: return entry.file?.displayName ?? "ファイル"
        case .text, .url:
            let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            return text.isEmpty ? "（空文字）" : String(text.prefix(120))
        }
    }
}
