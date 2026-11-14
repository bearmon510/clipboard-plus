import Combine
import Foundation

@MainActor
final class MeasurementLog: ObservableObject {
    @Published private(set) var lines: [String] = []
    @Published private(set) var errorMessage: String?
    @Published var includeTextPreview = false

    private var fileURL: URL?

    init() {
        do {
            let documents = try FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let url = documents.appendingPathComponent("clipboardplus-measurements.tsv")
            if !FileManager.default.fileExists(atPath: url.path) {
                try Data().write(to: url, options: .atomic)
            }
            fileURL = url
        } catch {
            errorMessage = "ログファイルを準備できませんでした。\(error.localizedDescription)"
        }
    }

    func append(_ event: MeasurementEvent) {
        let line = LogLineFormatter(includeTextPreview: includeTextPreview).format(event)
        lines.append(line)
        do {
            let url = try requireFileURL()
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((line + "\n").utf8))
            try handle.synchronize()
        } catch {
            recordFailure("ログ書き込みの失敗", operation: "追記", error: error, context: event)
        }
    }

    func clear(context: MeasurementEvent) {
        do {
            try Data().write(to: requireFileURL(), options: .atomic)
            lines.removeAll()
            errorMessage = nil
        } catch {
            recordFailure("ログ書き込みの失敗", operation: "消去", error: error, context: context)
        }
    }

    func prepareExport(context: MeasurementEvent) -> URL? {
        do {
            let data = try Data(contentsOf: requireFileURL())
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("clipboardplus-log-\(UUID().uuidString).tsv")
            // Share a snapshot so recording and clearing cannot change an open share sheet.
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            recordFailure("ログ書き出しの失敗", operation: "書き出し", error: error, context: context)
            return nil
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

    private func requireFileURL() throws -> URL {
        guard let fileURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        return fileURL
    }

    private func recordFailure(
        _ kind: String,
        operation: String,
        error: Error,
        context: MeasurementEvent
    ) {
        errorMessage = "ログの\(operation)に失敗しました。\(error.localizedDescription)"
        let event = MeasurementEvent(
            kind: kind,
            changeCount: context.changeCount,
            scene: context.scene,
            details: "操作=\(operation); \(error.localizedDescription)"
        )
        // A failed file write must remain visible without recursively attempting another write.
        lines.append(LogLineFormatter().format(event))
    }
}

