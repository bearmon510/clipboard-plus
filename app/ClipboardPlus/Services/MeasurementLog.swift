import Combine
import Foundation

@MainActor
final class MeasurementLog: ObservableObject {
    @Published private(set) var lines: [LogRecord] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var isPerformingFileOperation = false
    @Published var includeTextPreview = false

    static let maximumLinesInMemory = 2_000

    private let writer: MeasurementLogWriter
    private var sequence = LogEventSequence()

    init(writer: MeasurementLogWriter = MeasurementLogWriter()) {
        self.writer = writer
    }

    func append(_ event: MeasurementEvent) {
        enqueue(event, attemptWrite: true)
    }

    func flush(context: MeasurementEvent, completion: @escaping () -> Void = {}) {
        writer.flush { error in
            if let error {
                self.recordFailure("ログ書き込みの失敗", operation: "同期", error: error, context: context)
            }
            completion()
        }
    }

    func clear(context: MeasurementEvent) {
        guard !isPerformingFileOperation else { return }
        isPerformingFileOperation = true
        let lastNumber = sequence.nextEventNumber - 1
        writer.clear { error in
            self.isPerformingFileOperation = false
            if let error {
                self.recordFailure("ログ書き込みの失敗", operation: "消去前の同期または消去", error: error, context: context)
            } else {
                // Events accepted after the clear request belong to the new file.
                self.lines.removeAll { $0.id <= lastNumber }
                self.errorMessage = nil
            }
        }
    }

    func prepareExport(context: MeasurementEvent, completion: @escaping (URL?) -> Void) {
        guard !isPerformingFileOperation else { return }
        isPerformingFileOperation = true
        flush(context: context) {
            // Flush failures have now been enqueued too, so the snapshot includes their evidence.
            self.writer.exportSnapshot { result in
                self.isPerformingFileOperation = false
                switch result {
                case .success(let url): completion(url)
                case .failure(let error):
                    self.recordFailure("ログ書き出しの失敗", operation: "書き出し", error: error, context: context)
                    completion(nil)
                }
            }
        }
    }

    func reportShareFailure(_ error: Error, context: MeasurementEvent) {
        append(MeasurementEvent(
            kind: "ログ書き出しの失敗",
            changeCount: context.changeCount,
            scene: context.scene,
            details: "共有: \(error.localizedDescription)"
        ))
        errorMessage = "ログを書き出せませんでした。\(error.localizedDescription)"
    }

    func dismissError() {
        errorMessage = nil
    }

    private func enqueue(_ event: MeasurementEvent, attemptWrite: Bool) {
        let record = sequence.makeRecord(event, formatter: LogLineFormatter(includeTextPreview: includeTextPreview))
        lines.append(record)
        // The on-screen list keeps recent lines only. The file holds the rest.
        if lines.count > Self.maximumLinesInMemory + 200 {
            lines.removeFirst(lines.count - Self.maximumLinesInMemory)
        }
        writer.append(record, attemptWrite: attemptWrite) { error in
            if let error {
                self.recordFailure("ログ書き込みの失敗", operation: "追記", error: error, context: event)
            }
        }
    }

    private func recordFailure(_ kind: String, operation: String, error: Error, context: MeasurementEvent) {
        errorMessage = "ログの\(operation)に失敗しました。\(error.localizedDescription)"
        // Retain the failure as pending without recursively retrying a failing write.
        enqueue(MeasurementEvent(
            kind: kind,
            changeCount: context.changeCount,
            scene: context.scene,
            details: "操作=\(operation); \(error.localizedDescription)"
        ), attemptWrite: false)
    }
}
