import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var monitor: ClipboardMonitor
    @ObservedObject var log: MeasurementLog
    @State private var presentedSheet: Panel?
    @State private var confirmHistoryClear = false
    @State private var copiedNotice = false
    @State private var noticeTask: Task<Void, Never>?

    private enum Panel: String, Identifiable {
        case settings, logs
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 8) {
            header
            controls
            Text("自動収集で、他アプリのコピー内容を読む許可を求められる場合があります。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
            HStack {
                Text(copiedNotice ? "コピーしました" : "履歴 \(monitor.entries.count)件")
                    .foregroundStyle(copiedNotice ? Color.accentColor : Color.secondary)
                Spacer()
                Text("新しい順")
                    .foregroundStyle(.secondary)
            }
            .font(.footnote)
            .padding(.horizontal)

            history
        }
        .padding(.top, 8)
        .onAppear { updateScene(scenePhase) }
        .onChange(of: scenePhase) { _, phase in updateScene(phase) }
        .sheet(item: $presentedSheet) { panel in
            switch panel {
            case .settings:
                SettingsView(monitor: monitor, log: log)
            case .logs:
                LogView(monitor: monitor, log: log)
            }
        }
        .confirmationDialog("履歴をすべて消しますか？", isPresented: $confirmHistoryClear, titleVisibility: .visible) {
            Button("履歴\(monitor.entries.count)件を全消去", role: .destructive) {
                monitor.deleteAllHistory()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("このアプリの履歴だけを消します。計測ログとクリップボードの内容は残ります。元に戻せません。")
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("clipboard+").font(.headline)
                Text(monitor.isRecording ? "記録: 開始中" : "記録: 停止中")
                Text("scene: \(monitor.sceneState)")
                    .monospaced()
            }
            .font(.subheadline)
            Spacer(minLength: 4)
            if log.errorMessage != nil {
                Button {
                    presentedSheet = .logs
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("ログエラー").font(.caption2)
                    }
                    .foregroundStyle(.red)
                    .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("ログのエラーを確認")
            }
            Menu {
                Button("設定", systemImage: "slider.horizontal.3") { presentedSheet = .settings }
                Button("計測ログ", systemImage: "doc.text") { presentedSheet = .logs }
                Divider()
                Button("履歴を全消去…", systemImage: "trash", role: .destructive) {
                    confirmHistoryClear = true
                }
                .disabled(monitor.entries.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title2)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("設定とログ、履歴の全消去")
        }
        .padding(.horizontal)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button(monitor.isRecording ? "記録を停止" : "記録を開始") {
                if monitor.isRecording { monitor.stop() } else { monitor.start() }
            }
            .buttonStyle(.borderedProminent)
            .frame(minHeight: 44)

            VStack(spacing: 0) {
                PasteButton(payloadType: String.self) { strings in
                    DispatchQueue.main.async { monitor.saveManually(strings) }
                }
                .labelStyle(.titleAndIcon)
                .frame(minWidth: 100, minHeight: 44)
                .accessibilityLabel("文章を手動保存")
            }
        }
        .controlSize(.large)
        .padding(.horizontal)
    }

    private var history: some View {
        List {
            if monitor.entries.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("文章の履歴はまだありません。")
                    Text("記録の開始後にコピーした文章を収集します。開始前の文章は「ペースト」で手動保存できます。")
                    Text("自動収集では、他アプリのコピー内容を読む許可を求められる場合があります。")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.vertical, 12)
            }
            ForEach(monitor.entries) { entry in
                Button {
                    monitor.copy(entry)
                    showCopiedNotice()
                } label: {
                    HistoryRow(entry: entry)
                }
                .buttonStyle(.plain)
                .draggable(entry.text)
                .swipeActions {
                    Button(role: .destructive) { monitor.delete(entry) } label: {
                        Label("この履歴1件を削除", systemImage: "trash")
                    }
                }
                .contextMenu {
                    Button("この履歴1件を削除（ログは残す）", role: .destructive) {
                        monitor.delete(entry)
                    }
                }
            }
            if !monitor.entries.isEmpty {
                Text("タップでコピー、長押ししてドラッグ。左へスワイプでこの履歴1件だけを削除します。計測ログとクリップボードの内容は残ります。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
        // Stable row IDs and no scroll-to or insertion animation limit unsolicited movement.
        .transaction { $0.animation = nil }
    }

    private func showCopiedNotice() {
        noticeTask?.cancel()
        copiedNotice = true
        noticeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            copiedNotice = false
        }
    }

    private func updateScene(_ phase: ScenePhase) {
        switch phase {
        case .active: monitor.updateScene("active")
        case .inactive: monitor.updateScene("inactive")
        case .background: monitor.updateScene("background")
        @unknown default: monitor.updateScene("inactive")
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("#\(entry.id)").fontWeight(.semibold)
                    Text(entry.savedAt, format: .dateTime.hour().minute().second())
                    Spacer()
                    Text("\(entry.characterCount)文字")
                }
                VStack(alignment: .leading) {
                    Text("#\(entry.id) · \(entry.characterCount)文字")
                    Text(entry.savedAt, format: .dateTime.hour().minute().second())
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(entry.text.isEmpty ? "（空文字）" : String(entry.text.prefix(160)))
                .font(.body)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityHint("タップでコピー。ドラッグで他のアプリへ持ち出せます。")
    }
}

