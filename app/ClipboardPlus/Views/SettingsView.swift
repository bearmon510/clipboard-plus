import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var monitor: ClipboardMonitor
    @ObservedObject var log: MeasurementLog
    @ObservedObject var pictureInPicture: PictureInPictureController
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
                Section("PiPの技術検証") {
                    Toggle("PiPで裏でも収集（試験中）", isOn: Binding(
                        get: { pictureInPicture.isEnabled },
                        set: { pictureInPicture.setEnabled($0) }
                    ))
                    .frame(minHeight: 44)
                    Text("試験中の機能です。初期値はオフで、裏で収集できるかは実機で確認が必要です。オンにした後、本体画面の「PiPを開始」で小窓を出します。")
                    Text("小窓には状態だけが表示され、内容を触って操作することはできません。小窓の再生で記録を開始し、一時停止で記録を停止します。画面を更新し続けるため、電池を使います。")
                        .font(.footnote)
                }
                Section("自動収集について") {
                    Text("他のアプリからのペースト許可が求められる場合があります。記録開始前・起動時の再開前からある文章は自動では読みません。手動保存には「ペースト」を使ってください。")
                    Text("確認の間に複数回コピーされると、途中の内容は取り戻せません。PiPの試験を使わない場合、アプリが画面にない間は収集できず、戻った時点の内容だけを確認します。")
                    Text("同じ原文は1項目にまとめ、最後に収集した時刻と回数を更新します。履歴をコピーした直後の読み取りは更新しません。")
                    Text("自動収集では、秘密・一時的・自動生成の印が付いた内容は読まずに保存を見送ります。")
                    Text("印のない秘密情報は判別できないため、必要に応じて記録を停止し、保存済みの履歴を削除してください。")
                }
                Section("履歴の保存") {
                    Picker("自動削除", selection: Binding(
                        get: { monitor.historyRetention },
                        set: { monitor.setHistoryRetention($0) }
                    )) {
                        ForEach(HistoryRetention.allCases, id: \.self) { retention in
                            Text(retention.displayName).tag(retention)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(minHeight: 44)
                    Text("最後に収集した日時を基準に、指定した日数を過ぎた履歴を自動で削除します。ピン留めした項目は消えません。自動削除した項目は元に戻せません。期間を短くすると、その場で対象の履歴が消えます。")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("初期値は30日です。この機能への更新後、最初の起動でも30日を過ぎた履歴が削除されます。起動時、前面に戻ったとき、起動中は1時間ごとに確認します。")
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("画像 \(monitor.imageUsage.count)件 · \(ByteCountFormatter.string(fromByteCount: Int64(monitor.imageUsage.byteCount), countStyle: .decimal))")
                    Text("画像は1件20MBまで。ピン留め以外の画像の実体は合計500MBまでで、古いものから削除します。件数の上限は文章と画像の合計です。使用量はピン留めと取り消し待ちの実体を含み、縮小画像は含みません。")
                    Text("履歴は端末内に保存します。ピン留めしていない項目は1,000件までで、最後に収集した時刻の古いものから削除します。ピン留めした項目は自動では削除しません。")
                    Text("手動の削除後は5秒間取り消せます。取り消し待ちの項目は書き出しに含めません。")
                }
                BackupSection(backup: monitor.backup)
                Section("JSONで書き出し") {
                    Text("書き出すJSON（形式の版2）には文章の原文と画像の情報（時刻・回数・ピン留め・大きさ・ハッシュなど）が入ります。画像の実体は含まれません。共有先を確認してください。画像を含む保存と復元には「バックアップ」を使ってください。")
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
                    Button("閉じる") { monitor.backup.close(); dismiss() }.frame(minWidth: 44, minHeight: 44)
                }
            }
            .sheet(isPresented: $showLogs) { LogView(monitor: monitor, log: log) }
            .sheet(item: $export, onDismiss: removeSnapshot) { snapshot in
                ActivitySheet(url: snapshot.url) { _ in shareError = "履歴を共有できませんでした。" }
            }
            .onDisappear { monitor.backup.close() }
        }
    }

    private func removeSnapshot() {
        if let url = exportedURL { try? FileManager.default.removeItem(at: url) }
        exportedURL = nil
    }
}
