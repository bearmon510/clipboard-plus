import AppIntents
import Combine
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import ClipboardPlus

@MainActor
private final class FilePasteboard: ClipboardPasteboard {
    var changeCount = 0
    var hasImages = false
    var hasStrings: Bool { storedText != nil }
    var types: [String] = []
    var itemProviders: [NSItemProvider] = []
    var image: UIImage? { nil }
    private var storedText: String?
    var string: String? {
        get { storedText }
        set { external([], text: newValue) }
    }
    func external(_ providers: [NSItemProvider], types extra: [String] = [], text: String? = nil) {
        itemProviders = providers
        types = providers.flatMap { $0.registeredTypeIdentifiers } + extra
        storedText = text
        changeCount += 1
    }
    func data(forPasteboardType pasteboardType: String) -> Data? { nil }
    func setData(_ data: Data, forPasteboardType pasteboardType: String) {
        external([], types: [pasteboardType])
    }
    func writeFileProviders(_ providers: [NSItemProvider]) -> Bool {
        external(providers)
        return true
    }
}

private final class FileReply {
    private let lock = NSLock()
    private var reply: ((URL?, Bool, Error?) -> Void)?
    func capture(_ reply: @escaping (URL?, Bool, Error?) -> Void) {
        lock.lock(); self.reply = reply; lock.unlock()
    }
    func finish(_ url: URL) {
        lock.lock(); let reply = self.reply; self.reply = nil; lock.unlock()
        reply?(url, false, nil)
    }
}

final class FileMonitorTests: XCTestCase {
    private func provider(in root: URL, type: String = "com.adobe.pdf", name: String? = "秘密の名前.pdf",
                          bytes: Data = FileTestSupport.bytes) throws -> NSItemProvider {
        let url = root.appendingPathComponent(UUID().uuidString + ".data")
        try bytes.write(to: url)
        let provider = NSItemProvider()
        provider.suggestedName = name
        provider.registerFileRepresentation(forTypeIdentifier: type, fileOptions: [], visibility: .all) { completion in
            completion(url, false, nil)
            return nil
        }
        return provider
    }

    @MainActor
    private func fixture(_ root: URL, board: FilePasteboard) throws -> ClipboardMonitor {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(0, forKey: HistoryRetention.defaultsKey)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let monitor = ClipboardMonitor(defaults: defaults,
                                       log: MeasurementLog(writer: MeasurementLogWriter(fileURL: root.appendingPathComponent("log.tsv"))),
                                       makeDatabase: { try HistoryDatabase(url: root.appendingPathComponent("history.sqlite")) },
                                       schedulesMaintenance: false, imageDirectory: root.appendingPathComponent("attachments"),
                                       pasteboard: board)
        drain(monitor)
        return monitor
    }

    @MainActor
    private func drain(_ monitor: ClipboardMonitor) {
        let idle = expectation(description: "file reads finished")
        let observation = monitor.$pendingSaveCount.first { $0 == 0 }.sink { _ in idle.fulfill() }
        wait(for: [idle], timeout: 10)
        observation.cancel()
        let drained = expectation(description: "database/log drained")
        monitor.pendingDeletion { _ in monitor.log.flush(context: monitor.logContext()) { drained.fulfill() } }
        wait(for: [drained], timeout: 5)
    }

    @MainActor
    func testFakeClipboardCollectsPDFZIPVideoAndLogsTypesWithoutFilenameOrBytes() throws {
        let root = try ImageTestSupport.directory(self)
        let board = FilePasteboard()
        let monitor = try fixture(root, board: board)
        monitor.start()
        defer { monitor.stop() }
        for (index, type) in ["com.adobe.pdf", "public.zip-archive", "public.mpeg-4"].enumerated() {
            let data = Data("file-body-secret-\(index)".utf8)
            board.external([try provider(in: root, type: type, bytes: data)])
            monitor.pollPasteboard()
            drain(monitor)
            XCTAssertEqual(monitor.entries.first?.file?.typeIdentifier, type)
        }
        XCTAssertEqual(monitor.entries.count, 3)
        XCTAssertEqual(monitor.fileUsage.count, 3)
        XCTAssertEqual(monitor.imageUsage.count, 0)
        let logs = monitor.log.lines.map(\.fileLine).joined()
        XCTAssertTrue(logs.contains("ファイルの読み取り成功"))
        XCTAssertTrue(logs.contains("provider.types="))
        XCTAssertTrue(logs.contains("選択型=public.mpeg-4"))
        XCTAssertFalse(logs.contains("秘密の名前"))
        XCTAssertFalse(logs.contains("file-body-secret"))
        monitor.log.includeTextPreview = true
        board.external([try provider(in: root, bytes: Data("preview-enabled-body".utf8))])
        monitor.pollPasteboard()
        drain(monitor)
        let previewLogs = monitor.log.lines.map(\.fileLine).joined()
        XCTAssertTrue(previewLogs.contains("冒頭20文字=秘密の名前.pdf"))
        XCTAssertFalse(previewLogs.contains("preview-enabled-body"))
    }

    @MainActor
    func testMixedRichTextAndPDFDoesNotBecomeFileEvenWhenPlainStringUnavailable() throws {
        let root = try ImageTestSupport.directory(self)
        let board = FilePasteboard()
        let monitor = try fixture(root, board: board)
        monitor.start()
        defer { monitor.stop() }
        for type in ["public.rtf", "public.html", "com.apple.flat-rtfd", "public.url", "public.png"] {
            board.external([try provider(in: root)], types: [type])
            monitor.pollPasteboard()
            drain(monitor)
            XCTAssertTrue(monitor.entries.isEmpty, type)
        }
        board.external([try provider(in: root)], types: ["public.utf8-plain-text"], text: "メモの文章")
        monitor.pollPasteboard()
        drain(monitor)
        XCTAssertEqual(monitor.entries.first?.text, "メモの文章")
        XCTAssertEqual(monitor.fileUsage.count, 0)
    }

    @MainActor
    func testFakeClipboardRejectsDynamicAndInternalTypesWithoutLoadingThem() throws {
        let root = try ImageTestSupport.directory(self)
        let board = FilePasteboard()
        let monitor = try fixture(root, board: board)
        monitor.start()
        defer { monitor.stop() }
        for type in ["dyn.ah62d4rv4gk81g7d3ru", "com.apple.uikit.attributedstring"] {
            let provider = NSItemProvider()
            provider.registerFileRepresentation(forTypeIdentifier: type, fileOptions: [], visibility: .all) { completion in
                XCTFail("Excluded type must not be read")
                completion(nil, false, HistoryFileError.unavailable)
                return nil
            }
            board.external([provider])
            monitor.pollPasteboard()
            drain(monitor)
        }
        XCTAssertTrue(monitor.entries.isEmpty)
        XCTAssertTrue(monitor.log.lines.contains { $0.fileLine.contains("対象の型なし") })
    }

    @MainActor
    func testOversizeAndReadFailureNotifyAndClearPendingCount() throws {
        let root = try ImageTestSupport.directory(self)
        let board = FilePasteboard()
        let monitor = try fixture(root, board: board)
        let large = root.appendingPathComponent("large.pdf")
        XCTAssertTrue(FileManager.default.createFile(atPath: large.path, contents: nil))
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: 50_000_001)
        try handle.close()
        let provider = NSItemProvider()
        provider.registerFileRepresentation(forTypeIdentifier: "com.adobe.pdf", fileOptions: [], visibility: .all) { completion in
            completion(large, false, nil)
            return nil
        }
        monitor.start()
        defer { monitor.stop() }
        board.external([provider])
        monitor.pollPasteboard()
        drain(monitor)
        XCTAssertEqual(monitor.fileNotice, HistoryFileError.tooLarge.message)
        XCTAssertTrue(monitor.entries.isEmpty)
        let failed = NSItemProvider()
        failed.registerFileRepresentation(forTypeIdentifier: "com.adobe.pdf", fileOptions: [], visibility: .all) { completion in
            completion(nil, false, HistoryFileError.unavailable)
            return nil
        }
        board.external([failed])
        monitor.pollPasteboard()
        drain(monitor)
        XCTAssertEqual(monitor.fileNotice, HistoryFileError.unavailable.message)
        XCTAssertEqual(monitor.pendingSaveCount, 0)
        XCTAssertTrue(monitor.log.lines.contains { $0.fileLine.contains("tooLarge") })
    }

    @MainActor
    // Synchronous on purpose: drain() uses wait(for:), which in an async test blocks the main
    // queue completions it is waiting for.
    func testDuplicateAndSelfCopyAreCountedCorrectlyAndShortcutEntityContainsFile() throws {
        let root = try ImageTestSupport.directory(self)
        let board = FilePasteboard()
        let monitor = try fixture(root, board: board)
        let original = try provider(in: root)
        monitor.start()
        defer { monitor.stop() }
        for _ in 0..<2 {
            board.external([original])
            monitor.pollPasteboard()
            drain(monitor)
        }
        let entry = try XCTUnwrap(monitor.entries.first)
        XCTAssertEqual(entry.collectionCount, 2)
        let copied = expectation(description: "file copied")
        monitor.copy(entry) { succeeded in XCTAssertTrue(succeeded); copied.fulfill() }
        wait(for: [copied], timeout: 5)
        drain(monitor)
        XCTAssertEqual(monitor.entries, [entry])
        XCTAssertEqual(board.itemProviders.first?.suggestedName, "秘密の名前.pdf")
        let file = try XCTUnwrap(entry.file)
        let entities = HistoryEntryEntity.make([entry], monitor: monitor)
        let entity = try XCTUnwrap(entities.first)
        XCTAssertEqual(entity.displayTitle, file.originalFilename)
        XCTAssertEqual(entity.kind, "ファイル")
        XCTAssertTrue(entity.displaySubtitle.contains(file.sizeDescription))
        XCTAssertEqual(entity.file?.filename, file.originalFilename)
        XCTAssertEqual(entity.file?.data, FileTestSupport.bytes)
        XCTAssertEqual(HistoryFilterOption.files.filter, .files)
        let shortcutCopied = expectation(description: "shortcut copy finished")
        Task { @MainActor in
            do { try await monitor.copyForShortcut(entry) } catch { XCTFail("shortcut copy failed: \(error)") }
            shortcutCopied.fulfill()
        }
        wait(for: [shortcutCopied], timeout: 10)
        drain(monitor)
        XCTAssertEqual(monitor.entries, [entry])
        board.external([original])
        monitor.pollPasteboard()
        drain(monitor)
        XCTAssertEqual(monitor.entries.first?.collectionCount, 3)
    }

    @MainActor
    func testPrivacyMarkersAreHonoredForAutomaticAndDroppedFiles() throws {
        let root = try ImageTestSupport.directory(self)
        let board = FilePasteboard()
        let monitor = try fixture(root, board: board)
        let provider = NSItemProvider()
        provider.registerFileRepresentation(forTypeIdentifier: "com.adobe.pdf", fileOptions: [], visibility: .all) { completion in
            XCTFail("Private file must not be loaded")
            completion(nil, false, HistoryFileError.unavailable)
            return nil
        }
        provider.registerDataRepresentation(forTypeIdentifier: "org.nspasteboard.ConcealedType", visibility: .all) { completion in
            completion(Data(), nil); return nil
        }
        monitor.start()
        defer { monitor.stop() }
        board.external([provider])
        monitor.pollPasteboard()
        _ = monitor.receiveDropped([provider], receivedAt: Date())
        drain(monitor)
        XCTAssertTrue(monitor.entries.isEmpty)
        XCTAssertEqual(monitor.pendingSaveCount, 0)
    }

    @MainActor
    func testChangeWhileLoadingDiscardsResultIncludingConcealedReplacement() throws {
        let root = try ImageTestSupport.directory(self)
        let board = FilePasteboard()
        let monitor = try fixture(root, board: board)
        let gate = FileReply()
        let requested = expectation(description: "provider requested")
        let provider = NSItemProvider()
        provider.registerFileRepresentation(forTypeIdentifier: "com.adobe.pdf", fileOptions: [], visibility: .all) { completion in
            gate.capture(completion)
            requested.fulfill()
            return nil
        }
        let source = root.appendingPathComponent("source.pdf")
        try FileTestSupport.bytes.write(to: source)
        monitor.start()
        defer { monitor.stop() }
        board.external([provider])
        monitor.pollPasteboard()
        wait(for: [requested], timeout: 5)
        board.external([], types: ["org.nspasteboard.ConcealedType"], text: "secret")
        gate.finish(source)
        drain(monitor)
        monitor.pollPasteboard()
        drain(monitor)
        XCTAssertTrue(monitor.entries.isEmpty)
        XCTAssertEqual(monitor.pendingSaveCount, 0)
        XCTAssertTrue(monitor.log.lines.contains { $0.fileLine.contains("非同期読み取り中の変更") })
    }

    @MainActor
    func testDropAndRowProviderPreserveFilenameTypeBytesAndIgnoreLocalDrop() throws {
        let root = try ImageTestSupport.directory(self)
        let board = FilePasteboard()
        let monitor = try fixture(root, board: board)
        XCTAssertTrue(monitor.receiveDropped([try provider(in: root)], receivedAt: Date()))
        drain(monitor)
        let entry = try XCTUnwrap(monitor.entries.first)
        XCTAssertEqual(entry.source, .drag)
        XCTAssertTrue(HistoryImageLoader.contentTypes.contains(.data))
        let row = monitor.rowProvider(entry)
        XCTAssertEqual(row.suggestedName, entry.file?.originalFilename)
        XCTAssertTrue(row.registeredTypeIdentifiers.contains("com.adobe.pdf"))
        XCTAssertFalse(monitor.receiveDropped([row], receivedAt: Date()))
        let removed = expectation(description: "history removed")
        monitor.deleteAllHistory(includePinned: true) { _ in removed.fulfill() }
        wait(for: [removed], timeout: 5)
        // Force expiry through SQL, then run maintenance through the foreground transition.
        try ImageTestSupport.sql("UPDATE history SET delete_after = 0", at: root.appendingPathComponent("history.sqlite"))
        monitor.updateScene("active")
        drain(monitor)
        let file = try XCTUnwrap(entry.file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: monitor.fileURL(file).path))
        let loaded = expectation(description: "delayed external drag load")
        row.loadFileRepresentation(forTypeIdentifier: "com.adobe.pdf") { url, error in
            XCTAssertNil(error)
            if let url { XCTAssertEqual(try? Data(contentsOf: url), FileTestSupport.bytes) }
            else { XCTFail("No file URL") }
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 5)
    }
}
