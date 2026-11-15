import SwiftUI

/// The whole text of one item, with the actions that apply to it.
struct EntryDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let entry: HistoryEntry
    let onCopy: () -> Void

    /// Very long texts are cut for display only. Copying and sharing use the whole text.
    private static let displayLimit = 20_000

    private var linkURL: URL? {
        entry.kind == .url ? URL(string: entry.text.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    textBlock
                    actionRow
                    details
                }
                .padding(16)
            }
            .background(Theme.page)
            .navigationTitle("内容")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }.frame(minWidth: 44, minHeight: 44)
                }
            }
        }
        .tint(Theme.accent)
    }

    private var textBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.text.isEmpty ? "（空文字）" : String(entry.text.prefix(Self.displayLimit)))
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if entry.characterCount > Self.displayLimit {
                Text("長いため、冒頭の\(Self.displayLimit.formatted())文字だけを表示しています。コピーと共有では全文を使います。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
                onCopy()
                dismiss()
            } label: {
                actionLabel("コピー", "doc.on.doc")
            }
            .buttonStyle(.borderedProminent)
            ShareLink(item: entry.text) {
                actionLabel("共有", "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            if let linkURL {
                Button {
                    openURL(linkURL)
                } label: {
                    actionLabel("開く", "safari")
                }
                .buttonStyle(.bordered)
            }
        }
        .buttonBorderShape(.roundedRectangle(radius: 12))
    }

    /// Icon above the title, so three buttons fit side by side in a narrow window.
    private func actionLabel(_ title: String, _ symbol: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.body.weight(.semibold))
            Text(title).font(.footnote.weight(.semibold)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
    }

    private var details: some View {
        VStack(spacing: 0) {
            detailRow("文字数", "\(entry.characterCount.formatted())文字")
            Divider()
            detailRow("最後にコピー", entry.lastCollectedAt.formatted(date: .abbreviated, time: .shortened))
            Divider()
            detailRow("最初に保存", entry.savedAt.formatted(date: .abbreviated, time: .shortened))
            Divider()
            detailRow("コピーした回数", "\(entry.collectionCount.formatted())回")
            Divider()
            detailRow("取り込み方", sourceLabel)
        }
        .padding(.horizontal, 14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .padding(.vertical, 11)
    }

    private var sourceLabel: String {
        switch entry.source {
        case .automatic: return "自動"
        case .manual: return "ペースト"
        case .drag: return "ドラッグ"
        case .capture: return "切り取り"
        }
    }
}
