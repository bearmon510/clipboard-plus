import SwiftUI

struct LogView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var monitor: ClipboardMonitor
    @ObservedObject var log: MeasurementLog
    @State private var confirmLogClear = false
    @State private var export: ExportSnapshot?
    @State private var exportedURL: URL?
    @State private var isExporting = false

    private struct ExportSnapshot: Identifiable {
        let id = UUID()
        let url: URL
    }

    var body: some View {
        NavigationStack {
            List {
                if let error = log.errorMessage {
                    Section("ログのエラー") {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                        Text("追記に失敗した行は未保存として保持し、次の書き込みで再送します。書き出し時にも未保存なら、ファイル末尾の見出しの下に含めます。消去前の同期に失敗した場合は消去しません。")
                        Button("エラー表示を閉じる") { log.dismissError() }
                            .frame(minHeight: 44)
                    }
                }

                Section("操作") {
                    Button("ログを書き出す", systemImage: "square.and.arrow.up") {
                        isExporting = true
                        monitor.exportLog { url in
                            isExporting = false
                            if let url {
                                exportedURL = url
                                export = ExportSnapshot(url: url)
                            }
                        }
                    }
                    .frame(minHeight: 44)
                    .disabled(isExporting || log.isPerformingFileOperation)
                    if let error = monitor.storageError {
                        Text(error).foregroundStyle(.red)
                    }
                    Button("ログを消去…", systemImage: "trash", role: .destructive) {
                        confirmLogClear = true
                    }
                    .frame(minHeight: 44)
                    .disabled(log.isPerformingFileOperation)
                    Text("ログの消去はメモリとDocumentsのログファイルが対象です。履歴は残ります。書き出し済みのログは消えません。")
                        .font(.footnote)
                }

                Section("この起動中のログ: \(log.lines.count)行") {
                    Text("主表示は現地時刻（時:分:秒.ミリ秒）・種別・履歴番号です。ファイルはタブ区切り: 現地時刻（ISO 8601、ミリ秒3桁、UTCとの差付き）／起動ID／イベント番号／種別／changeCount／scene／文字数／履歴番号／詳細／原文の冒頭（有効時のみ）。「-」は対応なし・未取得です。起動IDとイベント番号で再送の重複や欠番を確認できます。書き出すファイルには前回の起動までのログ（旧形式を含む）も含まれます。")
                        .font(.footnote)
                    ForEach(log.lines) { line in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(line.primaryText)
                                .font(.subheadline)
                            Text(line.secondaryText)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("計測ログ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }.frame(minWidth: 44, minHeight: 44)
                }
            }
            .confirmationDialog("計測ログを消去しますか？", isPresented: $confirmLogClear, titleVisibility: .visible) {
                Button("メモリとファイルのログを消去", role: .destructive) {
                    log.clear(context: monitor.logContext())
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("履歴は残ります。書き出し済みのログは消えません。記録中は、消去後のログが再び追記されます。")
            }
            .sheet(item: $export, onDismiss: removeSnapshot) { snapshot in
                ActivitySheet(url: snapshot.url) { error in
                    log.reportShareFailure(error, context: monitor.logContext())
                }
            }
        }
    }

    private func removeSnapshot() {
        if let url = exportedURL {
            try? FileManager.default.removeItem(at: url)
        }
        exportedURL = nil
    }
}

