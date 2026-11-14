import Combine
import Foundation
import UIKit

@MainActor
final class ClipboardMonitor: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var sceneState = "inactive"
    @Published private(set) var entries: [HistoryEntry] = []
    @Published private(set) var pollingInterval: TimeInterval = 0.5
    @Published private(set) var storageError: String?
    private(set) var resumedAtLaunch = false

    let log: MeasurementLog

    private let pasteboard = UIPasteboard.general
    private let defaults: UserDefaults
    private var database: HistoryDatabase?
    private var cleanupTimer: Timer?
    private var admission = HistoryAdmission()
    private var lastObservedChangeCount = 0
    private var timer: Timer?
    private var isReading = false
    private var isWriting = false
    private var deferredDetections: [MeasurementEvent] = []
    private var pendingLogFlushes = 0
    private var logFlushTask: UIBackgroundTaskIdentifier = .invalid

    override init() {
        defaults = .standard
        log = MeasurementLog()
        super.init()
        let storedInterval = defaults.object(forKey: "pollingInterval") as? Double ?? 0.5
        pollingInterval = storedInterval.isFinite ? min(5, max(0.1, storedInterval)) : 0.5
        do {
            let directory = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
            database = try HistoryDatabase(url: directory.appendingPathComponent("clipboardplus.sqlite"))
            entries = try requireDatabase().fetchAll()
        } catch { reportStorageFailure() }
        let cleanup = Timer(timeInterval: 1, target: self, selector: #selector(cleanupTimerFired(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(cleanup, forMode: .common)
        cleanupTimer = cleanup
        if defaults.bool(forKey: "isRecording") {
            resumedAtLaunch = true
            start(resuming: true)
        }
    }

    func start(resuming: Bool = false) {
        guard !isRecording else { return }
        // The baseline is not read, so it must not suppress the next external change.
        admission.discardPendingSelfCopy()
        lastObservedChangeCount = pasteboard.changeCount
        isRecording = true
        defaults.set(true, forKey: "isRecording")
        installTimer()
        record(resuming ? "記録の再開（起動時）" : "記録の開始", count: lastObservedChangeCount, details: collectionDescription)
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        defaults.set(false, forKey: "isRecording")
        timer?.invalidate()
        timer = nil
        record("記録の停止", details: collectionDescription)
    }

    func setPollingInterval(_ value: TimeInterval) {
        pollingInterval = value.isFinite ? min(5.0, max(0.1, value)) : 0.5
        defaults.set(pollingInterval, forKey: "pollingInterval")
        if isRecording {
            installTimer()
            record("定期確認の間隔変更", details: collectionDescription)
        }
    }

    func updateScene(_ value: String) {
        guard sceneState != value else { return }
        let observedAt = Date()
        let previous = sceneState
        sceneState = value
        let count = pasteboard.changeCount
        let sceneEvent = MeasurementEvent(
            timestamp: observedAt, kind: "scene状態の変化", changeCount: count,
            scene: value, details: "\(previous)→\(value)"
        )
        if value == "active", isRecording {
            readIfChanged(count: count, source: "復帰時", detections: [
                sceneEvent,
                MeasurementEvent(timestamp: observedAt, kind: "復帰時の確認", changeCount: count, scene: value)
            ])
        } else {
            log.append(sceneEvent)
        }
        // Resume collection before database maintenance can block the main thread.
        cleanupExpired()
        if value == "inactive" || value == "background" {
            flushLogBeforeSuspension()
        }
    }

    func saveManually(_ strings: [String], receivedAt: Date) {
        let count = pasteboard.changeCount
        let details = "PasteButtonから受信; changeCountは処理時点の観測値で、本文との対応は未確定"
        for text in strings {
            let number = admit(text, source: "手動保存", route: .manual, timestamp: receivedAt, count: count, additionalDetails: details)
            record(
                "手動保存", count: count, text: text, historyNumber: number,
                details: details,
                timestamp: receivedAt
            )
        }
    }

    func copy(_ entry: HistoryEntry) {
        let before = pasteboard.changeCount
        isWriting = true
        admission.recordSelfCopy(entry.text)
        pasteboard.string = entry.text
        let after = pasteboard.changeCount
        let writtenAt = Date()
        isWriting = false
        let copyEvent = MeasurementEvent(
            timestamp: writtenAt,
            kind: "自己コピー",
            changeCount: after,
            scene: sceneState,
            characterCount: entry.text.count,
            historyNumber: entry.id,
            details: "読み書き前changeCount=\(before); 書き込み後changeCount=\(after)",
            text: entry.text
        )
        if isRecording {
            let detections = deferredDetections
            deferredDetections.removeAll()
            let checkedAt = Date()
            let count = pasteboard.changeCount
            // Writing does not acknowledge unread pasteboard contents.
            readIfChanged(count: count, source: "自己コピー後の確認", detections: [copyEvent] + detections + [
                MeasurementEvent(timestamp: checkedAt, kind: "自己コピー後の確認", changeCount: count, scene: sceneState)
            ])
        } else {
            log.append(copyEvent)
        }
    }

    func saveDropped(_ strings: [String], receivedAt: Date) -> Bool {
        var saved = false
        for text in strings {
            if let number = admit(text, source: "ドラッグ", route: .drag, timestamp: receivedAt) {
                saved = true
                record("ドラッグで保存", text: text, historyNumber: number, timestamp: receivedAt)
            }
        }
        return saved
    }

    func delete(_ entry: HistoryEntry) -> HistoryDeletion? {
        do {
            let deletion = try requireDatabase().delete(id: entry.id)
            try reloadHistory()
            record("削除", historyNumber: entry.id, details: "履歴1件; 5秒間取り消し可能")
            return deletion
        } catch { reportStorageFailure(); return nil }
    }

    func deleteAllHistory(includePinned: Bool) -> HistoryDeletion? {
        do {
            let deletion = try requireDatabase().deleteAll(includePinned: includePinned)
            try reloadHistory()
            record("削除", details: "履歴全消去=\(deletion?.count ?? 0)件; ピン留めを含む=\(includePinned)")
            return deletion
        } catch { reportStorageFailure(); return nil }
    }

    func undo(_ deletion: HistoryDeletion) -> Bool {
        do {
            let restored = try requireDatabase().undo(deletion)
            try reloadHistory()
            record("削除の取り消し", details: "復元=\(restored)")
            return true
        } catch { reportStorageFailure(); return false }
    }

    func pendingDeletion() -> HistoryDeletion? {
        do { return try requireDatabase().latestDeletion() }
        catch { reportStorageFailure(); return nil }
    }

    func togglePin(_ entry: HistoryEntry) {
        do {
            try requireDatabase().togglePin(id: entry.id)
            try reloadHistory()
        } catch { reportStorageFailure() }
    }

    func exportHistory() -> URL? {
        do {
            let entries = try requireDatabase().fetchAll()
            let data = try HistoryExport.data(entries: entries, exportedAt: Date())
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("clipboardplus-\(UUID().uuidString).json")
            try data.write(to: url, options: .atomic)
            return url
        } catch { reportStorageFailure(); return nil }
    }

    @objc private func cleanupTimerFired(_ timer: Timer) {
        cleanupExpired()
    }

    private func cleanupExpired() {
        guard !isReading, !isWriting, database != nil else { return }
        do { try requireDatabase().purgeExpired() }
        catch { reportStorageFailure() }
    }

    private func requireDatabase() throws -> HistoryDatabase {
        guard let database else { throw HistoryDatabaseError.invalidRow }
        return database
    }

    private func reloadHistory() throws {
        entries = try requireDatabase().fetchAll()
        storageError = nil
    }

    private func reportStorageFailure() {
        storageError = "履歴の保存・読み込み・書き出しに失敗しました。空き容量を確認してアプリを開き直してください。"
    }

    func logContext() -> MeasurementEvent {
        MeasurementEvent(kind: "操作", changeCount: pasteboard.changeCount, scene: sceneState)
    }

    private var collectionDescription: String {
        "方式=定期確認; 間隔秒=\(String(format: "%.1f", pollingInterval))"
    }

    private func installTimer() {
        timer?.invalidate()
        let newTimer = Timer(
            timeInterval: pollingInterval,
            target: self,
            selector: #selector(pollPasteboard(_:)),
            userInfo: nil,
            repeats: true
        )
        // Common mode keeps polling scheduled while the user scrolls the history.
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    @objc private func pollPasteboard(_ timer: Timer) {
        guard isRecording else { return }
        let detectedAt = Date()
        let count = pasteboard.changeCount
        guard count != lastObservedChangeCount else { return }
        readIfChanged(count: count, source: "定期確認", detections: [
            MeasurementEvent(timestamp: detectedAt, kind: "定期確認での検知", changeCount: count, scene: sceneState)
        ])
    }

    private func readIfChanged(count: Int, source: String, detections: [MeasurementEvent]) {
        if isReading || isWriting {
            deferredDetections.append(contentsOf: detections)
            return
        }
        guard count != lastObservedChangeCount else {
            detections.forEach { log.append($0) }
            return
        }
        isReading = true
        defer {
            isReading = false
            if !deferredDetections.isEmpty {
                let deferred = deferredDetections
                deferredDetections.removeAll()
                if isRecording {
                    readIfChanged(count: pasteboard.changeCount, source: "保留した検知の再確認", detections: deferred)
                } else {
                    deferred.forEach { log.append($0) }
                }
            }
        }

        let startUptime = ProcessInfo.processInfo.systemUptime
        let readScene = sceneState
        let before = pasteboard.changeCount
        // A change during this read must remain eligible at the next check.
        lastObservedChangeCount = before
        let hasStrings = pasteboard.hasStrings
        let checkedAt = Date()
        let text = hasStrings ? pasteboard.string : nil
        let after = pasteboard.changeCount
        let finishedAt = Date()
        let elapsedMS = (ProcessInfo.processInfo.systemUptime - startUptime) * 1_000
        let details = "取得元=\(source); 読み取り前changeCount=\(before); 読み取り後changeCount=\(after); 所要ms=\(String(format: "%.3f", elapsedMS))"

        // Preserve detection times while reading before any log formatting or disk submission.
        detections.forEach { log.append($0) }
        log.append(MeasurementEvent(
            timestamp: checkedAt,
            kind: "hasStringsの結果",
            changeCount: before,
            scene: readScene,
            details: "hasStrings=\(hasStrings); \(details)"
        ))
        if let text {
            let number = admit(text, source: source, timestamp: finishedAt, count: after)
            log.append(MeasurementEvent(
                timestamp: finishedAt,
                kind: "読み取り成功",
                changeCount: after,
                scene: readScene,
                characterCount: text.count,
                historyNumber: number,
                details: details,
                text: text
            ))
        } else {
            admission.discardPendingSelfCopy()
            log.append(MeasurementEvent(
                timestamp: finishedAt,
                kind: hasStrings ? "取得できず・原因未確定" : "文章以外のため読み取らず",
                changeCount: after,
                scene: readScene,
                details: "string読取実施=\(hasStrings); \(details)"
            ))
        }
        if before != after {
            record("読み取り中の変更", count: after, details: "\(details); 件数の欠落とは判定しない")
        }
    }

    private func flushLogBeforeSuspension() {
        if pendingLogFlushes == 0 {
            logFlushTask = UIApplication.shared.beginBackgroundTask(withName: "Measurement log flush") { [weak self] in
                Task { @MainActor in self?.endLogFlushTask() }
            }
        }
        pendingLogFlushes += 1
        log.flush(context: logContext()) {
            self.pendingLogFlushes -= 1
            if self.pendingLogFlushes == 0 { self.endLogFlushTask() }
        }
    }

    private func endLogFlushTask() {
        guard logFlushTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(logFlushTask)
        logFlushTask = .invalid
    }

    @discardableResult
    private func admit(
        _ text: String, source: String, route: HistorySource = .automatic,
        timestamp: Date = Date(), count: Int? = nil, additionalDetails: String = ""
    ) -> Int? {
        let decision = route == .automatic ? admission.receive(text) : .add
        switch decision {
        case .add:
            do {
                let entry = try requireDatabase().collect(text, source: route, at: timestamp)
                try reloadHistory()
                return entry.id
            } catch { reportStorageFailure(); return nil }
        case .skip(let reason):
            record(
                "追加の見送り",
                count: count,
                text: text,
                details: "取得元=\(source); 理由=\(reason)" + (additionalDetails.isEmpty ? "" : "; \(additionalDetails)"),
                timestamp: timestamp
            )
            return nil
        }
    }

    private func record(
        _ kind: String,
        count: Int? = nil,
        text: String? = nil,
        historyNumber: Int? = nil,
        details: String = "",
        timestamp: Date = Date()
    ) {
        log.append(MeasurementEvent(
            timestamp: timestamp,
            kind: kind,
            changeCount: count ?? pasteboard.changeCount,
            scene: sceneState,
            characterCount: text?.count,
            historyNumber: historyNumber,
            details: details,
            text: text
        ))
    }
}
