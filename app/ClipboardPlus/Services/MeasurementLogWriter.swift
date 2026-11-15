import Foundation

final class MeasurementLogWriter {
    private let queue = DispatchQueue(label: "clipboardplus.measurement-log")
    private var fileURL: URL?
    private var pending = PendingLogLines()
    private let maximumFileBytes: Int
    private let trimmedFileBytes: Int
    private var didTrim = false

    /// The log is a diagnostic aid, so it must not grow without bound in daily use.
    /// Once per launch, a file above `maximumFileBytes` keeps only its newest `trimmedFileBytes`.
    init(fileURL: URL? = nil, maximumFileBytes: Int = 4_000_000, trimmedFileBytes: Int = 1_000_000) {
        self.fileURL = fileURL
        self.maximumFileBytes = maximumFileBytes
        self.trimmedFileBytes = trimmedFileBytes
    }

    func append(_ record: LogRecord, attemptWrite: Bool = true, completion: @escaping @MainActor (Error?) -> Void) {
        queue.async {
            self.pending.append(record)
            let error = attemptWrite ? self.writePending(synchronize: false) : nil
            DispatchQueue.main.async { completion(error) }
        }
    }

    func flush(completion: @escaping @MainActor (Error?) -> Void) {
        queue.async {
            let error = self.writePending(synchronize: true)
            DispatchQueue.main.async { completion(error) }
        }
    }

    func clear(completion: @escaping @MainActor (Error?) -> Void) {
        queue.async {
            var error = self.writePending(synchronize: true)
            if error == nil {
                do {
                    try Data().write(to: self.requireFileURL(), options: .atomic)
                } catch let failure {
                    error = failure
                }
            }
            DispatchQueue.main.async { completion(error) }
        }
    }

    func exportSnapshot(completion: @escaping @MainActor (Result<URL, Error>) -> Void) {
        queue.async {
            let result: Result<URL, Error>
            do {
                let source = try self.resolveFileURL()
                let saved: Data
                if FileManager.default.fileExists(atPath: source.path) {
                    saved = try Data(contentsOf: source)
                } else {
                    saved = Data()
                }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("clipboardplus-log-\(UUID().uuidString).tsv")
                try self.pending.exportData(savedData: saved).write(to: url, options: .atomic)
                result = .success(url)
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func resolveFileURL() throws -> URL {
        if fileURL == nil {
            let documents = try FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
            fileURL = documents.appendingPathComponent("clipboardplus-measurements.tsv")
        }
        guard let fileURL else { throw CocoaError(.fileNoSuchFile) }
        return fileURL
    }

    private func requireFileURL() throws -> URL {
        let fileURL = try resolveFileURL()
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try Data().write(to: fileURL, options: .atomic)
        }
        return fileURL
    }

    private func trimIfNeeded(_ url: URL) {
        guard !didTrim else { return }
        didTrim = true
        // Trimming is best effort. A failure leaves the file as it was.
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maximumFileBytes,
              let data = try? Data(contentsOf: url) else { return }
        var tail = data.suffix(max(0, trimmedFileBytes))
        // Start at a line boundary so the first kept line is whole.
        if let newline = tail.firstIndex(of: 0x0A) {
            tail = tail[tail.index(after: newline)...]
        }
        try? Data(tail).write(to: url, options: .atomic)
    }

    private func writePending(synchronize: Bool) -> Error? {
        do {
            let url = try requireFileURL()
            trimIfNeeded(url)
            try pending.persist { data in
                let handle = try FileHandle(forUpdating: url)
                do {
                    let end = try handle.seekToEnd()
                    if !data.isEmpty {
                        // A partial failed write must not merge with the next retried event.
                        if end > 0 {
                            try handle.seek(toOffset: end - 1)
                            let tail = try handle.read(upToCount: 1)
                            try handle.seekToEnd()
                            if tail?.last != 0x0A { try handle.write(contentsOf: Data([0x0A])) }
                        }
                        try handle.write(contentsOf: data)
                    }
                    if synchronize { try handle.synchronize() }
                } catch {
                    try? handle.close()
                    throw error
                }
                // Closed exactly once; a close error still counts as a failed write.
                try handle.close()
            }
            return nil
        } catch {
            return error
        }
    }
}
