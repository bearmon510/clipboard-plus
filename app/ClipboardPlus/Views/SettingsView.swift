import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @ObservedObject var monitor: ClipboardMonitor
    @ObservedObject var log: MeasurementLog
    let screenshots: ScreenshotWatcher
    @State private var showLogs = false
    @State private var showDeveloperSettings = false
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
                SyncSettingsSection(sync: PCSyncController.shared)
                // Picking up screenshots needs clipboard+ on screen beside the other app.
                if DeviceKind.current == .pad {
                    CaptureSettingsSection(screenshots: screenshots)
                }
                Section("キーボード") {
                    Picker("開いたときのタブ", selection: Binding(
                        get: { monitor.keyboardInitialTab },
                        set: { monitor.setKeyboardInitialTab($0) }
                    )) {
                        ForEach(KeyboardTab.allCases) { tab in
                            Text(tab.title).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(minHeight: 44)
                    Text("この\(DeviceKind.current.name)でほかのアプリに履歴やテンプレートを入れるには、設定アプリ →「一般」→「キーボード」→「キーボード」→「新しいキーボードを追加…」で「clipboard+」を選び、入力中に地球儀キーで切り替えます。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("必要に応じて「フルアクセスを許可」をオンにすると、キーボード上の「今のコピーを保存」からコピーした文章やリンクを保存できます。オフのままでも履歴とテンプレートの挿入は使えます。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    } label: {
                        Label("設定を開く", systemImage: "gear")
                    }
                    .frame(minHeight: 44)
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
                    Text("最後に収集した日時を基準に、指定した日数を過ぎた履歴を自動で削除します。テンプレートは消えません。自動削除した項目は元に戻せません。期間を短くすると、その場で対象の履歴が消えます。")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("初期値は30日です。この機能への更新後、最初の起動でも30日を過ぎた履歴が削除されます。起動時、前面に戻ったとき、起動中は1時間ごとに確認します。")
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("画像 \(monitor.imageUsage.count)件 · \(ByteCountFormatter.string(fromByteCount: Int64(monitor.imageUsage.byteCount), countStyle: .decimal))")
                    Text("ファイル \(monitor.fileUsage.count)件 · \(ByteCountFormatter.string(fromByteCount: Int64(monitor.fileUsage.byteCount), countStyle: .decimal))")
                    Text("画像は1件20MB、ファイルは1件50MBまで。履歴の画像とファイルの実体は合わせて500MBまでで、古いものから削除します。件数の上限はすべての種類の合計です。使用量はテンプレートと取り消し待ちの実体を含み、縮小画像は含みません。")
                    Text("履歴は端末内に保存します。履歴は1,000件までで、最後に収集した時刻の古いものから削除します。テンプレートは件数に数えず、自動では削除しません。")
                    Text("手動の削除後は5秒間取り消せます。取り消し待ちの項目は書き出しに含めません。")
                }
                Section("自動収集について") {
                    Text("他のアプリからのペースト許可が求められる場合があります。記録は初期状態で動いています。アプリの起動前や一時停止中からクリップボードにある内容は、自動では読みません。その内容を保存するには、「履歴｜テンプレート」の右にあるペーストのボタンを使ってください。")
                    Text(DeviceKind.current == .phone
                         ? "確認の間に複数回コピーされると、途中の内容は取り戻せません。ほかのアプリを使っている間は収集せず、clipboard+に戻ったときに最後の1件だけ取り込みます。"
                         : "確認の間に複数回コピーされると、途中の内容は取り戻せません。clipboard+の小窓を隠している間や別のアプリを全画面で使っている間は収集せず、戻ったときに最後の1件だけ取り込みます。")
                    Text("同じ原文は1項目にまとめ、最後に収集した時刻と回数を更新します。履歴をコピーした直後の読み取りは更新しません。")
                    Text("自動収集では、秘密・一時的・自動生成の印が付いた内容は読まずに保存を見送ります。")
                    Text("印のない秘密情報は判別できないため、必要に応じて記録を停止し、保存済みの履歴を削除してください。")
                }
                Section("JSONで書き出し") {
                    Text("書き出すJSONには文章の原文と画像の情報（時刻・回数・テンプレートかどうか・大きさ・ハッシュなど）が入ります。画像の実体は含まれません。共有先を確認してください。画像を含む保存と復元には「バックアップ」を使ってください。")
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
                BackupSection(backup: monitor.backup)
                Section {
                    DisclosureGroup("開発者向け", isExpanded: $showDeveloperSettings) {
                        Button("計測ログ", systemImage: "doc.text") { showLogs = true }
                            .frame(minHeight: 44)
                        Toggle(isOn: $log.includeTextPreview) {
                            Text("原文の冒頭20文字をログに含める")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(minHeight: 44)
                        Text("初期値はオフです。オフに戻しても記録済みの原文は消えません。ログは履歴とは別に保存され、アプリを終了しても残ります。")
                            .font(.footnote)
                        Text("scene: \(monitor.sceneState)")
                            .font(.caption).monospaced()
                        Text("実機試験には番号付きの架空の文章を使い、許可ダイアログの回数は目視で数えてください。")
                            .font(.footnote)
                    }
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
