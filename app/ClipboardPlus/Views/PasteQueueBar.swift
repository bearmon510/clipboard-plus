import SwiftUI

/// The bar for pasting several items in turn. Each paste in another app moves it on to the
/// next item; the buttons put it right when it moved too early or not at all.
struct PasteQueueBar: View {
    let state: PasteQueueState
    /// The queued items in order, as far as they still exist.
    let entries: [HistoryEntry]
    let onStart: () -> Void
    let onNext: () -> Void
    let onBack: () -> Void
    let onStop: () -> Void

    private enum Phase { case ready, running, paused, finished }

    private var phase: Phase {
        if state.isRunning { return state.isPaused ? .paused : .running }
        return state.currentIndex == nil ? .ready : .finished
    }

    private var index: Int { state.currentIndex ?? 0 }
    private var count: Int { state.entryIDs.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: phase == .paused ? "pause.circle.fill" : "list.number")
                    .foregroundStyle(phase == .paused ? Color.orange : Theme.accent)
                    .accessibilityHidden(true)
                Text(headline).font(.subheadline.weight(.semibold))
                Spacer(minLength: 4)
                Button(action: onStop) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Theme.field, in: Circle())
                        .frame(width: 44, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("連続貼り付けをやめる")
            }
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            controls
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 10)
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .shadow(color: Color.black.opacity(0.12), radius: 10, y: 3)
        .accessibilityElement(children: .contain)
    }

    private var headline: String {
        switch phase {
        case .ready: return "連続貼り付け　\(count)件"
        case .running: return "\(index + 1) / \(count) 件目をコピー中"
        case .paused: return "一時停止中　\(index + 1) / \(count) 件目"
        case .finished: return "\(count)件すべてを渡しました"
        }
    }

    private var lines: [String] {
        switch phase {
        case .ready:
            return ["開始すると1件目をコピーします。ほかのアプリで貼り付けるたびに、次に替わります。"]
        case .running:
            let next = index + 1 < entries.count ? "次：" + preview(entries[index + 1]) : "これが最後です"
            return [current.map { "今：" + preview($0) } ?? "", next].filter { !$0.isEmpty }
        case .paused:
            return ["ほかのコピーがあったか、アプリが裏に回りました。「再開」で今の項目をもう一度コピーします。"]
        case .finished:
            return []
        }
    }

    private var current: HistoryEntry? {
        entries.indices.contains(index) ? entries[index] : nil
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 8) {
            switch phase {
            case .ready:
                wide("開始", systemImage: "play.fill", prominent: true, action: onStart)
            case .running:
                wide("戻る", systemImage: "chevron.backward", prominent: false, action: onBack)
                    .disabled(index == 0)
                wide("次へ", systemImage: "chevron.forward", prominent: true, action: onNext)
            case .paused:
                wide("戻る", systemImage: "chevron.backward", prominent: false, action: onBack)
                    .disabled(index == 0)
                wide("再開", systemImage: "play.fill", prominent: true, action: onNext)
            case .finished:
                wide("最初から", systemImage: "arrow.counterclockwise", prominent: false, action: onStart)
                wide("閉じる", systemImage: "checkmark", prominent: true, action: onStop)
            }
        }
        .padding(.trailing, 8)
    }

    @ViewBuilder
    private func wide(_ title: String, systemImage: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        let label = Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 32)
        if prominent {
            Button(action: action) { label }.buttonStyle(.borderedProminent)
        } else {
            Button(action: action) { label }.buttonStyle(.bordered)
        }
    }

    private func preview(_ entry: HistoryEntry) -> String {
        entry.displayTitle ?? TemplateOrderView.summary(entry)
    }
}
