import Combine
import Foundation

@MainActor
final class BackupController: ObservableObject {
    @Published private(set) var isBusy = false
    @Published private(set) var phase = ""
    @Published private(set) var progress = BackupProgress(completed: 0, total: 0)
    @Published private(set) var resultMessage: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var estimate: RestoreCounts?
    @Published var export: BackupExport?

    private let store: HistoryStore
    private let record: (String, String) -> Void
    private let remember: (BackupExport) -> Void
    private var cancellation: BackupCancellation?
    private var validated: ValidatedBackup?
    private var sharedURL: URL?

    init(store: HistoryStore, record: @escaping (String, String) -> Void,
         remember: @escaping (BackupExport) -> Void) {
        self.store = store
        self.record = record
        self.remember = remember
    }

    func create() {
        guard !isBusy, validated == nil else { return }
        removeExport()
        let token = begin("バックアップ作成")
        store.createBackup(cancellation: token, progress: updateProgress) { result in
            self.isBusy = false
            self.cancellation = nil
            switch result {
            case .success(let backup):
                do { try token.check() }
                catch {
                    self.store.backupTemporaryFiles.remove(backup.url)
                    self.fail(error, operation: "バックアップ作成")
                    return
                }
                self.remember(backup)
                self.sharedURL = backup.url
                self.export = backup
                self.resultMessage = "\(backup.count)件のバックアップを作成しました。"
                self.record("バックアップ作成の完了", "件数=\(backup.count)")
            case .failure(let error): self.fail(error, operation: "バックアップ作成")
            }
        }
    }

    func validate(_ url: URL) {
        guard !isBusy, validated == nil else { return }
        let token = begin("バックアップ復元（検証）")
        store.validateBackup(at: url, cancellation: token, progress: updateProgress) { result in
            self.isBusy = false
            self.cancellation = nil
            switch result {
            case .success(let (backup, counts)):
                do { try token.check() }
                catch { backup.discard(); self.fail(error, operation: "バックアップ復元"); return }
                self.validated = backup
                self.estimate = counts
                self.record("バックアップ検証の完了", counts.description)
            case .failure(let error): self.fail(error, operation: "バックアップ復元")
            }
        }
    }

    func restore() {
        guard !isBusy, let backup = validated, let expected = estimate else { return }
        let token = begin("バックアップ復元（反映）")
        validated = nil
        estimate = nil
        store.restoreBackup(backup, cancellation: token, expectedCounts: expected, progress: updateProgress) { result in
            self.isBusy = false
            self.cancellation = nil
            switch result {
            case .success(let counts):
                self.resultMessage = "復元しました。\n\(counts.description)"
                self.record("バックアップ復元の完了", counts.description)
            case .failure(let error):
                if let changed = error as? RestoreEstimateChanged {
                    do { try token.check() }
                    catch { backup.discard(); self.fail(error, operation: "バックアップ復元"); return }
                    self.validated = backup
                    self.estimate = changed.counts
                    self.resultMessage = "履歴・設定・時刻の変化により件数が変わりました。新しい見積もりを確認して、もう一度「復元する」を押してください。"
                } else {
                    self.fail(error, operation: "バックアップ復元")
                }
            }
        }
    }

    func cancel() {
        cancellation?.cancel()
        if let backup = validated {
            validated = nil
            estimate = nil
            backup.discard()
            fail(BackupError.cancelled, operation: "バックアップ復元")
        }
    }

    func close() { cancel(); export = nil; removeExport() }

    func removeExport() {
        if let sharedURL { store.backupTemporaryFiles.remove(sharedURL) }
        sharedURL = nil
    }

    func importFailed(_ error: Error) { fail(error, operation: "バックアップ選択") }
    func shareFailed(_ error: Error) { fail(error, operation: "バックアップ共有") }

    private func begin(_ operation: String) -> BackupCancellation {
        let token = BackupCancellation()
        cancellation = token
        isBusy = true
        phase = operation
        progress = BackupProgress(completed: 0, total: 0)
        resultMessage = nil
        errorMessage = nil
        record("\(operation)の開始", "処理済み=0")
        return token
    }

    private func updateProgress(_ value: BackupProgress) { progress = value }

    private func fail(_ error: Error, operation: String) {
        let reason = BackupError.message(error)
        errorMessage = reason
        record("\(operation)の失敗", "理由=\(reason); 処理済み=\(progress.completed)/\(progress.total)")
    }
}

extension BackupExport: Identifiable {
    var id: URL { url }
}
