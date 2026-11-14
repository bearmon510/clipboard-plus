import SwiftUI
import UniformTypeIdentifiers

struct BackupSection: View {
    @ObservedObject var backup: BackupController
    @State private var showImporter = false

    var body: some View {
        Section("バックアップ") {
            Text("履歴の原文と画像がそのまま入ります。暗号化されません。取り消し待ちの項目と計測ログは含まれません。保存先・共有先を確認してください。")
            Button("バックアップを作成", systemImage: "square.and.arrow.up") { backup.create() }
                .frame(minHeight: 44)
                .disabled(backup.isBusy || backup.estimate != nil)
            Button("バックアップから復元", systemImage: "square.and.arrow.down") { showImporter = true }
                .frame(minHeight: 44)
                .disabled(backup.isBusy || backup.estimate != nil)
            if backup.isBusy {
                Text(backup.phase)
                ProgressView(value: Double(backup.progress.completed), total: Double(max(1, backup.progress.total)))
                Text("\(backup.progress.completed) / \(backup.progress.total)件")
                    .font(.footnote).monospacedDigit()
                Button("取り消す", role: .cancel) { backup.cancel() }.frame(minHeight: 44)
            }
            if let estimate = backup.estimate {
                Text("今の履歴にマージします。\n\(estimate.description)")
                    .fixedSize(horizontal: false, vertical: true)
                Text("確認中も収集が続くため、反映時に件数が変わることがあります。")
                    .font(.footnote)
                Button("復元する") { backup.restore() }.frame(minHeight: 44)
                Button("キャンセル", role: .cancel) { backup.cancel() }.frame(minHeight: 44)
            }
            if let result = backup.resultMessage {
                Text(result).fixedSize(horizontal: false, vertical: true)
            }
            if let error = backup.errorMessage {
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.clipboardPlusBackup]) { result in
            switch result {
            case .success(let url): backup.validate(url)
            case .failure(let error): backup.importFailed(error)
            }
        }
        .sheet(item: $backup.export, onDismiss: backup.removeExport) { item in
            ActivitySheet(url: item.url, onFailure: backup.shareFailed)
        }
    }
}
