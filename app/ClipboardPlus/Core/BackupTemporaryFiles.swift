import Foundation

// One process identity and one serial cleanup queue for exports and extracted images.
// Startup cleanup never traverses the current process's directory, even if work
// began before HistoryStore's first load or another store is opened later.
final class BackupTemporaryFiles {
    private static let processID = UUID().uuidString
    static let shared = BackupTemporaryFiles(
        root: FileManager.default.temporaryDirectory.appendingPathComponent("ClipboardPlusBackup", isDirectory: true))

    let root: URL
    let processDirectory: URL
    private let cleanupQueue: DispatchQueue

    init(root: URL,
         cleanupQueue: DispatchQueue = DispatchQueue(label: "clipboardplus.backup.cleanup", qos: .utility)) {
        self.root = root
        self.processDirectory = root.appendingPathComponent(Self.processID, isDirectory: true)
        self.cleanupQueue = cleanupQueue
    }

    func makeExportURL() throws -> URL {
        try FileManager.default.createDirectory(at: processDirectory, withIntermediateDirectories: true)
        return processDirectory.appendingPathComponent("clipboardplus-\(UUID().uuidString).clipboardplus")
    }

    func cleanPreviousProcesses() {
        let root = self.root
        let currentName = processDirectory.lastPathComponent
        cleanupQueue.async {
            guard let children = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
            for child in children where child.lastPathComponent != currentName {
                try? FileManager.default.removeItem(at: child)
            }
        }
    }

    func remove(_ url: URL) {
        cleanupQueue.async { try? FileManager.default.removeItem(at: url) }
    }

    // Completion is queued behind earlier removals; never wait on the main thread.
    func afterPendingCleanup(_ completion: @escaping () -> Void) {
        cleanupQueue.async { completion() }
    }
}
