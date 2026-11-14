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
    @Published private(set) var pendingSaveCount = 0
    private(set) var resumedAtLaunch = false

    let log: MeasurementLog

    private let pasteboard = UIPasteboard.general
    private let defaults: UserDefaults
    private let makeDatabase: (() throws -> HistoryPersistence)?
    private lazy var store = HistoryStore(makeDatabase: makeDatabase) { [weak self] event in
        self?.handleStorageEvent(event)
    }
    private var cleanupTimer: Timer?
    private var maintenancePending = false
    private var needsHistoryLoad = true
    private var admission = HistoryAdmission()
    private var lastObservedChangeCount = 0
    private var timer: Timer?
    private var isReading = false
    private var isWriting = false
    private var deferredDetections: [MeasurementEvent] = []
    private var pendingLogFlushes = 0
    private var logFlushTask: UIBackgroundTaskIdentifier = .invalid

    init(defaults: UserDefaults = .standard, log: MeasurementLog? = nil,
         makeDatabase: (() throws -> HistoryPersistence)? = nil, schedulesMaintenance: Bool = true) {
        self.defaults = defaults
        self.log = log ?? MeasurementLog()
        self.makeDatabase = makeDatabase
        super.init()
        let storedInterval = defaults.object(forKey: "pollingInterval") as? Double ?? 0.5
        pollingInterval = storedInterval.isFinite ? min(5, max(0.1, storedInterval)) : 0.5
        maintenancePending = true
        store.load { [weak self] result in
            self?.maintenancePending = false
            switch result {
            case .success: self?.needsHistoryLoad = false
            case .failure: self?.reportStorageFailure()
            }
        }
        if schedulesMaintenance {
            let cleanup = Timer(timeInterval: 1, target: self, selector: #selector(cleanupTimerFired(_:)), userInfo: nil, repeats: true)
            RunLoop.main.add(cleanup, forMode: .common)
            cleanupTimer = cleanup
        }
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
        cleanupExpired()
        if value == "inactive" || value == "background" {
            flushLogBeforeSuspension()
        }
    }

    func saveManually(_ strings: [String], receivedAt: Date) {
        let count = pasteboard.changeCount
        let details = "PasteButtonから受信; changeCountは処理時点の観測値で、本文との対応は未確定"
        for text in strings {
            admit(text, source: "手動保存", route: .manual, timestamp: receivedAt, count: count, additionalDetails: details)
            record(
                "手動保存", count: count, text: text,
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

    func receiveDropped(_ providers: [NSItemProvider], receivedAt: Date) -> Bool {
        let external = providers.filter { !DroppedTextLoader.isLocalRow($0) }
        for provider in external {
            DroppedTextLoader.load(provider) { result in
                switch result {
                case .success(let text):
                    _ = self.saveDropped([text], receivedAt: receivedAt)
                case .failure:
                    self.record("ドラッグの読み込み失敗", details: "文章を取得できませんでした", timestamp: receivedAt)
                }
            }
        }
        return !external.isEmpty
    }

    func saveDropped(_ strings: [String], receivedAt: Date) -> Bool {
        var saved = false
        for text in strings {
            if admit(text, source: "ドラッグ", route: .drag, timestamp: receivedAt) {
                saved = true
                record("ドラッグで受信", text: text, timestamp: receivedAt)
            }
        }
        return saved
    }

    func delete(_ entry: HistoryEntry, completion: @escaping (HistoryDeletion?) -> Void) {
        store.delete(id: entry.id) { result in
            switch result {
            case .success(let deletion):
                self.record("削除", historyNumber: entry.id, details: "履歴1件; 5秒間取り消し可能")
                completion(deletion)
            case .failure: self.reportStorageFailure(); completion(nil)
            }
        }
    }

    func deleteAllHistory(includePinned: Bool, completion: @escaping (HistoryDeletion?) -> Void) {
        store.deleteAll(includePinned: includePinned) { result in
            switch result {
            case .success(let deletion):
                self.record("削除", details: "履歴全消去=\(deletion?.count ?? 0)件; ピン留めを含む=\(includePinned)")
                completion(deletion)
            case .failure: self.reportStorageFailure(); completion(nil)
            }
        }
    }

    func undo(_ deletion: HistoryDeletion, completion: @escaping (Bool) -> Void) {
        store.undo(deletion) { result in
            switch result {
            case .success(let restored):
                self.record("削除の取り消し", details: "復元=\(restored)")
                completion(restored)
            case .failure: self.reportStorageFailure(); completion(false)
            }
        }
    }

    func pendingDeletion(completion: @escaping (HistoryDeletion?) -> Void) {
        store.latestDeletion { result in
            switch result {
            case .success(let deletion): completion(deletion)
            case .failure: self.reportStorageFailure(); completion(nil)
            }
        }
    }

    func togglePin(_ entry: HistoryEntry) {
        store.togglePin(id: entry.id) { result in
            if case .failure = result { self.reportStorageFailure() }
        }
    }

    func exportHistory(completion: @escaping (URL?) -> Void) {
        store.export { result in
            switch result {
            case .success(let url): self.rememberExport(at: url, completion: completion)
            case .failure: self.reportStorageFailure(); completion(nil)
            }
        }
    }

    func exportLog(completion: @escaping (URL?) -> Void) {
        log.prepareExport(context: logContext()) { url in
            guard let url else { completion(nil); return }
            self.rememberExport(at: url, completion: completion)
        }
    }

    private func rememberExport(at url: URL, completion: @escaping (URL?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try String(contentsOf: url, encoding: .utf8) }
            DispatchQueue.main.async {
                switch result {
                case .success(let text):
                    self.admission.recordExport(text)
                    completion(url)
                case .failure:
                    self.record("書き出しの失敗", details: "自動収集から除外する本文を取得できませんでした")
                    self.reportStorageFailure()
                    try? FileManager.default.removeItem(at: url)
                    completion(nil)
                }
            }
        }
    }

    @objc private func cleanupTimerFired(_ timer: Timer) {
        cleanupExpired()
    }

    private func cleanupExpired() {
        guard !maintenancePending else { return }
        maintenancePending = true
        if needsHistoryLoad {
            store.load { result in
                self.maintenancePending = false
                switch result {
                case .success:
                    self.needsHistoryLoad = false
                    if self.pendingSaveCount == 0 { self.storageError = nil }
                case .failure: self.reportStorageFailure()
                }
            }
            return
        }
        store.maintain { result in
            self.maintenancePending = false
            if case .failure = result { self.reportStorageFailure() }
        }
    }

    private func handleStorageEvent(_ event: HistoryStore.Event) {
        switch event {
        case .replace(let values): entries = values
        case .upsert(let entry): HistoryList.upsert(entry, into: &entries)
        case .remove(let id): entries.removeAll { $0.id == id }
        case .saved(let entry, let retried):
            pendingSaveCount -= 1
            HistoryList.upsert(entry, into: &entries)
            if pendingSaveCount == 0 { storageError = nil }
            record(retried ? "履歴保存の再試行成功" : "履歴保存成功", text: entry.text,
                   historyNumber: entry.id, details: "経路=\(entry.source.rawValue); 保存待ち=\(pendingSaveCount)件")
        case .saveFailed:
            reportStorageFailure()
            record("履歴保存の失敗", details: "未保存キューを保持して再試行; 保存待ち=\(pendingSaveCount)件")
        }
    }

    private func reportStorageFailure() {
        storageError = "履歴の保存・読み込み・書き出しに失敗しました。空き容量を確認してください。保存待ちは自動で再試行します。"
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
            admit(text, source: source, timestamp: finishedAt, count: after, before: before, after: after)
            log.append(MeasurementEvent(
                timestamp: finishedAt,
                kind: "読み取り成功",
                changeCount: after,
                scene: readScene,
                characterCount: text.count,
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
        timestamp: Date = Date(), count: Int? = nil, additionalDetails: String = "",
        before: Int? = nil, after: Int? = nil
    ) -> Bool {
        let decision = route == .automatic ? admission.receive(text, before: before, after: after) : .add
        switch decision {
        case .add:
            pendingSaveCount += 1
            store.collect(text, source: route, at: timestamp)
            return true
        case .skip(let reason):
            record(
                "追加の見送り",
                count: count,
                text: text,
                details: "取得元=\(source); 理由=\(reason)" + (additionalDetails.isEmpty ? "" : "; \(additionalDetails)"),
                timestamp: timestamp
            )
            return false
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
