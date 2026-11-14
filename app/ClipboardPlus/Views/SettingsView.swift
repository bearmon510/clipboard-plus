import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var monitor: ClipboardMonitor
    @ObservedObject var log: MeasurementLog

    var body: some View {
        NavigationStack {
            Form {
                Section("収集") {
                    Picker("収集方式", selection: Binding(
                        get: { monitor.method },
                        set: { monitor.setMethod($0) }
                    )) {
                        ForEach(CollectionMethod.allCases) { method in
                            Text(method.rawValue).tag(method)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(minHeight: 44)
                    .disabled(monitor.isRecording)

                    Text("方式の切り替えは記録停止中だけできます。")
                        .font(.footnote)
                    Text("定期確認の間隔: \(monitor.pollingInterval, specifier: "%.1f")秒")
                    Slider(value: Binding(
                        get: { monitor.pollingInterval },
                        set: { monitor.setPollingInterval($0) }
                    ), in: 0.1...5.0, step: 0.1)
                    .frame(minHeight: 44)
                    .accessibilityLabel("定期確認の間隔、秒")
                    Text("0.1〜5.0秒。通知方式ではこの間隔を使いません。")
                        .font(.footnote)
                }

                Section("自動収集について") {
                    Text("他アプリのコピー内容を読む許可が求められる場合があります。記録開始前からある文章は自動では読みません。手動保存には「ペースト」を使ってください。")
                    Text("どちらの方式も全コピーの取得を保証しません。確認の間に複数回コピーされると、途中の内容は取り戻せません。changeCountの差は欠落件数として数えません。")
                    Text("記録中はscene状態が変わっても監視を解除しません。OSによる実行の停止中は処理できず、activeへ戻るとchangeCountを1回確認します。")
                    Text("同じ文章の連続コピーと、自己コピー直後の同じ文章は追加を見送ります。別の文章を挟めば再び追加します。")
                }

                Section("計測ログ") {
                    Toggle("原文の冒頭20文字をログに含める", isOn: $log.includeTextPreview)
                        .frame(minHeight: 44)
                    Text("初期値はオフです。有効な間だけ冒頭を記録します。オフに戻しても、記録済みの原文は消えません。")
                        .font(.footnote)
                    Text("ログはDocumentsに追記し、アプリを終了しても残ります。履歴と設定はメモリ上だけで、再起動すると失われます。")
                    Text("許可ダイアログの回数は利用者が目視で数えてください。試験には番号を付けた架空の文章を使います。")
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }.frame(minWidth: 44, minHeight: 44)
                }
            }
        }
    }
}

