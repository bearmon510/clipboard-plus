import Combine
import Foundation
import UIKit

enum CollectionMethod: String, CaseIterable, Identifiable {
    case notification = "通知"
    case polling = "定期確認"

    var id: String { rawValue }
}

@MainActor
final class ClipboardMonitor: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var sceneState = "inactive"
    @Published private(set) var entries: [HistoryEntry] = []
    // On the device test of 2026-11-14 (iPadOS 27.2.1), change notifications
    // never arrived for copies made in Safari, while polling caught all three.
    @Published private(set) var method: CollectionMethod = .polling
    @Published private(set) var pollingInterval: TimeInterval = 0.5

    let log: MeasurementLog

    private let pasteboard = UIPasteboard.general
    private var admission = HistoryAdmission()
    private var lastObservedChangeCount = 0
    private var nextHistoryNumber = 1
    private var timer: Timer?
    private var isReading = false
    private var isWriting = false
    private var deferredDetections: [MeasurementEvent] = []
    private var pendingLogFlushes = 0
    private var logFlushTask: UIBackgroundTaskIdentifier = .invalid

    override init() {
        log = MeasurementLog()
        super.init()
    }

    func start() {
        guard !isRecording else { return }
        lastObservedChangeCount = pasteboard.changeCount
        isRecording = true
        if method == .notification {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(pasteboardChanged(_:)),
                name: UIPasteboard.changedNotification,
                object: pasteboard
            )
        } else {
            installTimer()
        }
        record("記録の開始", count: lastObservedChangeCount, details: collectionDescription)
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        timer?.invalidate()
        timer = nil
        NotificationCenter.default.removeObserver(self, name: UIPasteboard.changedNotification, object: pasteboard)
        record("記録の停止", details: collectionDescription)
    }

    func setMethod(_ value: CollectionMethod) {
        guard !isRecording else { return }
        method = value
    }

    func setPollingInterval(_ value: TimeInterval) {
        pollingInterval = min(5.0, max(0.1, value))
        if isRecording, method == .polling {
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
        if value == "inactive" || value == "background" {
            flushLogBeforeSuspension()
        }
    }

    func saveManually(_ strings: [String], receivedAt: Date) {
        let count = pasteboard.changeCount
        let details = "PasteButtonから受信; changeCountは処理時点の観測値で、本文との対応は未確定"
        for text in strings {
            let number = admit(text, source: "手動保存", timestamp: receivedAt, count: count, additionalDetails: details)
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
            // Neither the write nor notifications during it acknowledge unread pasteboard contents.
            readIfChanged(count: count, source: "自己コピー後の確認", detections: [copyEvent] + detections + [
                MeasurementEvent(timestamp: checkedAt, kind: "自己コピー後の確認", changeCount: count, scene: sceneState)
            ])
        } else {
            log.append(copyEvent)
        }
    }

    func delete(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        record("削除", historyNumber: entry.id, details: "履歴1件; ログとクリップボードは保持")
    }

    func deleteAllHistory() {
        let count = entries.count
        entries.removeAll()
        // Deletion does not represent a new read or copy, so the admission state is retained.
        record("削除", details: "履歴全消去=\(count)件; ログとクリップボードは保持")
    }

    func logContext() -> MeasurementEvent {
        MeasurementEvent(kind: "操作", changeCount: pasteboard.changeCount, scene: sceneState)
    }

    private var collectionDescription: String {
        "方式=\(method.rawValue); 間隔秒=\(String(format: "%.1f", pollingInterval))"
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
        guard isRecording, method == .polling else { return }
        let detectedAt = Date()
        let count = pasteboard.changeCount
        guard count != lastObservedChangeCount else { return }
        readIfChanged(count: count, source: "定期確認", detections: [
            MeasurementEvent(timestamp: detectedAt, kind: "定期確認での検知", changeCount: count, scene: sceneState)
        ])
    }

    @objc private func pasteboardChanged(_ notification: Notification) {
        guard isRecording, method == .notification else { return }
        let detectedAt = Date()
        let count = pasteboard.changeCount
        readIfChanged(count: count, source: "通知", detections: [
            MeasurementEvent(timestamp: detectedAt, kind: "通知受信", changeCount: count, scene: sceneState)
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
            log.append(MeasurementEvent(
                timestamp: finishedAt,
                kind: "取得できず・原因未確定",
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
        _ text: String, source: String, timestamp: Date = Date(), count: Int? = nil, additionalDetails: String = ""
    ) -> Int? {
        switch admission.receive(text) {
        case .add:
            let entry = HistoryEntry(id: nextHistoryNumber, savedAt: timestamp, text: text)
            nextHistoryNumber += 1
            entries.insert(entry, at: 0)
            return entry.id
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
