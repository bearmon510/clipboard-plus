import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var monitor: ClipboardMonitor
    @ObservedObject var log: MeasurementLog
    @State private var showLogs = false
    @State private var export: ExportSnapshot?
    @State private var exportedURL: URL?
    @State private var shareError: String?
    @State private var isExporting = false

    private struct ExportSnapshot: Identifiable {
        let id = UUID()
        let url: URL
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("収集") {
                    Text("定期確認の間隔: \(monitor.pollingInterval, specifier: "%.1f")秒")
                    Slider(value: Binding(
                        get: { monitor.pollingInterval },
                        set: { monitor.setPollingInterval($0) }
                    ), in: 0.1...5.0, step: 0.1)
                    .frame(minHeight: 44)
                    .accessibilityLabel("定期確認の間隔、秒")
                    Text("0.1〜5.0秒。間隔と記録の状態は、アプリを開き直しても保持します。")
                        .font(.footnote)
                }
                Section("自動収集について") {
                    Text("他のアプリからのペースト許可が求められる場合があります。記録開始前・起動時の再開前からある文章は自動では読みません。手動保存には「ペースト」を使ってください。")
                    Text("確認の間に複数回コピーされると、途中の内容は取り戻せません。アプリが画面にない間は収集できず、戻った時点の内容だけを確認します。")
                    Text("同じ原文は1項目にまとめ、最後に収集した時刻と回数を更新します。履歴をコピーした直後の読み取りは更新しません。")
                }
                Section("履歴の保存") {
                    Text("履歴は端末内に保存します。ピン留めしていない項目は1,000件までで、最後に収集した時刻の古いものから削除します。ピン留めした項目は自動では削除しません。")
                    Text("削除後は5秒間取り消せます。取り消し待ちの項目は書き出しに含めません。")
                }
                Section("JSONで書き出し") {
                    Text("書き出したファイルには、すべての履歴の原文が入ります。共有先を確認してください。このアプリでの復元には対応していません。")
                    Button("すべての履歴を書き出す", systemImage: "square.and.arrow.up") {
                        shareError = nil
                        isExporting = true
                        monitor.exportHistory { url in
                            isExporting = false
                            if let url {
                                exportedURL = url
                                export = ExportSnapshot(url: url)
                            }
                        }
                    }
                    .frame(minHeight: 44)
                    .disabled(isExporting)
                    if let error = shareError ?? monitor.storageError {
                        Text(error).foregroundStyle(.red)
                    }
                }
                Section("計測ログ") {
                    Button("計測ログ", systemImage: "doc.text") { showLogs = true }
                        .frame(minHeight: 44)
                    Toggle("原文の冒頭20文字をログに含める", isOn: $log.includeTextPreview)
                        .frame(minHeight: 44)
                    Text("初期値はオフです。オフに戻しても記録済みの原文は消えません。ログは履歴とは別に保存され、アプリを終了しても残ります。")
                        .font(.footnote)
                    Text("scene: \(monitor.sceneState)")
                        .font(.caption).monospaced()
                    Text("実機試験には番号付きの架空の文章を使い、許可ダイアログの回数は目視で数えてください。")
                        .font(.footnote)
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }.frame(minWidth: 44, minHeight: 44)
                }
            }
            .sheet(isPresented: $showLogs) { LogView(monitor: monitor, log: log) }
            .sheet(item: $export, onDismiss: removeSnapshot) { snapshot in
                ActivitySheet(url: snapshot.url) { _ in shareError = "履歴を共有できませんでした。" }
            }
        }
    }

    private func removeSnapshot() {
        if let url = exportedURL { try? FileManager.default.removeItem(at: url) }
        exportedURL = nil
    }
}
