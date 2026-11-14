import UIKit
import XCTest
@testable import ClipboardPlus

@MainActor
private final class TestClipboardPasteboard: ClipboardPasteboard {
    private(set) var changeCount = 0
    private var storedString: String?
    private var imageData: Data?
    private var imageType: String?
    /// False imitates UIPasteboard.hasImages ignoring some image types, such as WebP.
    var reportsImages = true
    var reportsStrings: Bool?
    private(set) var stringReadCount = 0
    private(set) var imageReadCount = 0
    private(set) var dataReadCount = 0
    var extraTypes: [String] = []
    var hasImages: Bool { reportsImages && imageData != nil }
    var hasStrings: Bool { reportsStrings ?? (storedString != nil) }
    var types: [String] { (imageType.map { [$0] } ?? []) + extraTypes }
    var image: UIImage? { imageReadCount += 1; return nil }

    /// Runs once inside the next string read, before the value is returned, to imitate
    /// another app writing between the type check and the content read.
    var beforeNextStringRead: (() -> Void)?

    func writeExternally(_ text: String, types: [String]) {
        storedString = text
        imageData = nil
        imageType = nil
        extraTypes = types
        changeCount += 1
    }

    var string: String? {
        get {
            stringReadCount += 1
            let hook = beforeNextStringRead
            beforeNextStringRead = nil
            hook?()
            return storedString
        }
        set {
            storedString = newValue
            imageData = nil
            imageType = nil
            changeCount += 1
        }
    }

    func data(forPasteboardType pasteboardType: String) -> Data? {
        dataReadCount += 1
        return imageType == pasteboardType ? imageData : nil
    }

    func setData(_ data: Data, forPasteboardType pasteboardType: String) {
        storedString = nil
        imageData = data
        imageType = pasteboardType
        changeCount += 1
    }
}

final class ClipboardMonitorCopyTests: XCTestCase {
    @MainActor
    private func monitor(root: URL, pasteboard: ClipboardPasteboard,
                         makeDatabase: @escaping () throws -> HistoryPersistence) throws -> ClipboardMonitor {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let log = MeasurementLog(writer: MeasurementLogWriter(fileURL: root.appendingPathComponent("log.tsv")))
        let monitor = ClipboardMonitor(defaults: defaults, log: log, makeDatabase: makeDatabase,
                                       schedulesMaintenance: false, imageDirectory: root.appendingPathComponent("images"),
                                       pasteboard: pasteboard)
        monitor.setPollingInterval(5)
        return monitor
    }

    @MainActor
    private func drain(_ monitor: ClipboardMonitor) {
        let done = expectation(description: "storage drained")
        monitor.pendingDeletion { _ in
            monitor.log.flush(context: monitor.logContext()) { done.fulfill() }
        }
        wait(for: [done], timeout: 5)
        XCTAssertNil(monitor.storageError)
        XCTAssertEqual(monitor.pendingSaveCount, 0)
    }

    @MainActor
    func testImageCopyCollectsExternalChangesWhileReadIsWaitingAndBeforeWrite() throws {
        let root = try ImageTestSupport.directory(self)
        let url = root.appendingPathComponent("history.sqlite")
        let files = HistoryImageFiles(directory: root.appendingPathComponent("images"))
        let image = try ImageTestSupport.prepare(files)
        let data = try files.read(image)
        let entry: HistoryEntry
        do {
            let database = try HistoryDatabase(url: url)
            entry = try database.collectImage(image, source: .manual, at: Date(timeIntervalSince1970: 1))
        }
        let blocked = expectation(description: "storage queue blocked before image read")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let pasteboard = TestClipboardPasteboard()
        let monitor = try self.monitor(root: root, pasteboard: pasteboard) {
            blocked.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            return try HistoryDatabase(url: url)
        }
        wait(for: [blocked], timeout: 5)
        monitor.start()
        defer { monitor.stop() }
        let copied = expectation(description: "image copy completed")
        monitor.copy(entry) { success in
            XCTAssertTrue(success)
            copied.fulfill()
        }
        var secondCopy: Bool?
        monitor.copy(entry) { secondCopy = $0 }
        XCTAssertEqual(secondCopy, false)

        pasteboard.string = "external text during image read"
        monitor.pollPasteboard()
        // The storage queue is still blocked: polling must capture the content now.
        XCTAssertEqual(monitor.pendingSaveCount, 1)

        // A further external copy arrives after polling. It must be captured before
        // setData, even when its hash matches the image we are about to copy.
        pasteboard.setData(data, forPasteboardType: image.typeIdentifier)
        release.signal()
        wait(for: [copied], timeout: 5)
        drain(monitor)
        XCTAssertEqual(pasteboard.data(forPasteboardType: image.typeIdentifier), data)
        XCTAssertEqual(monitor.entries.count, 2)
        let external = try XCTUnwrap(monitor.entries.first { $0.text == "external text during image read" })
        XCTAssertEqual(external.source, .automatic)
        XCTAssertEqual(external.collectionCount, 1)
        let updated = try XCTUnwrap(monitor.entries.first { $0.id == entry.id })
        XCTAssertEqual(updated.source, .automatic)
        XCTAssertEqual(updated.collectionCount, 2) // External image only; self readback is skipped.
        XCTAssertGreaterThan(updated.lastCollectedAt, entry.lastCollectedAt)
    }

    @MainActor
    func testTextCopyCollectsUnreadExternalTextBeforeWritingAndSkipsSelfReadback() throws {
        let root = try ImageTestSupport.directory(self)
        let url = root.appendingPathComponent("history.sqlite")
        let entry: HistoryEntry
        do {
            let database = try HistoryDatabase(url: url)
            entry = try database.collect("history text", source: .manual, at: Date(timeIntervalSince1970: 1))
        }
        let pasteboard = TestClipboardPasteboard()
        let monitor = try self.monitor(root: root, pasteboard: pasteboard) { try HistoryDatabase(url: url) }
        drain(monitor)
        monitor.start()
        defer { monitor.stop() }
        pasteboard.string = "external text before tap"
        var copied: Bool?
        monitor.copy(entry) { copied = $0 }
        XCTAssertEqual(copied, true)
        XCTAssertEqual(pasteboard.string, entry.text)
        drain(monitor)
        XCTAssertEqual(monitor.entries.count, 2)
        XCTAssertEqual(monitor.entries.first { $0.id == entry.id }, entry)
        let external = try XCTUnwrap(monitor.entries.first { $0.text == "external text before tap" })
        XCTAssertEqual(external.source, .automatic)
        XCTAssertEqual(external.collectionCount, 1)
    }

    @MainActor
    func testImageTypeIsCollectedEvenWhenHasImagesIsFalse() throws {
        let root = try ImageTestSupport.directory(self)
        let url = root.appendingPathComponent("history.sqlite")
        let pasteboard = TestClipboardPasteboard()
        pasteboard.reportsImages = false
        pasteboard.extraTypes = ["public.url"]
        let monitor = try self.monitor(root: root, pasteboard: pasteboard) { try HistoryDatabase(url: url) }
        drain(monitor)
        monitor.start()
        defer { monitor.stop() }
        pasteboard.setData(ImageTestSupport.png(), forPasteboardType: "public.png")
        XCTAssertFalse(pasteboard.hasImages)
        monitor.pollPasteboard()
        drain(monitor)
        XCTAssertEqual(monitor.entries.count, 1)
        XCTAssertEqual(monitor.entries.first?.kind, .image)
        XCTAssertEqual(monitor.entries.first?.image?.typeIdentifier, "public.png")
    }

    func testImageTypesFindsWebPAndKeepsPreferredOrder() {
        XCTAssertEqual(HistoryImageFiles.imageTypes(in: ["org.webmproject.webp", "public.url"]), ["org.webmproject.webp"])
        XCTAssertEqual(HistoryImageFiles.imageTypes(in: ["public.jpeg", "public.png", "public.utf8-plain-text"]),
                       ["public.png", "public.jpeg"])
        XCTAssertEqual(HistoryImageFiles.imageTypes(in: ["public.utf8-plain-text", "public.url"]), [])
    }

    @MainActor
    func testPrivateTextIsNeverReadAndNextUnmarkedTextIsCollected() throws {
        let root = try ImageTestSupport.directory(self)
        let url = root.appendingPathComponent("history.sqlite")
        let pasteboard = TestClipboardPasteboard()
        let monitor = try self.monitor(root: root, pasteboard: pasteboard) { try HistoryDatabase(url: url) }
        drain(monitor)
        monitor.log.includeTextPreview = true
        monitor.start()
        defer { monitor.stop() }
        let markers = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"]
        for marker in markers {
            pasteboard.extraTypes = ["public.utf8-plain-text", marker]
            pasteboard.string = "private test value"
            monitor.pollPasteboard()
            monitor.pollPasteboard() // The ignored change must already be acknowledged.
        }
        drain(monitor)
        XCTAssertTrue(monitor.entries.isEmpty)
        XCTAssertEqual(pasteboard.stringReadCount, 0)
        XCTAssertEqual(pasteboard.imageReadCount, 0)
        XCTAssertEqual(pasteboard.dataReadCount, 0)
        let skipped = monitor.log.lines.filter { $0.primaryText.contains("秘密の印のため保存せず") }
        XCTAssertEqual(skipped.count, 3)
        for marker in markers { XCTAssertTrue(skipped.contains { $0.secondaryText.contains(marker) }) }
        XCTAssertFalse(monitor.log.lines.contains { $0.fileLine.contains("private test value") })

        pasteboard.extraTypes = ["public.utf8-plain-text"]
        pasteboard.string = "ordinary test value"
        monitor.pollPasteboard()
        drain(monitor)
        XCTAssertEqual(monitor.entries.map(\.text), ["ordinary test value"])
        XCTAssertEqual(pasteboard.stringReadCount, 1)
    }

    @MainActor
    func testConcealedContentWrittenDuringReadIsNeitherSavedNorLogged() throws {
        let root = try ImageTestSupport.directory(self)
        let url = root.appendingPathComponent("history.sqlite")
        let pasteboard = TestClipboardPasteboard()
        let monitor = try self.monitor(root: root, pasteboard: pasteboard) { try HistoryDatabase(url: url) }
        drain(monitor)
        monitor.log.includeTextPreview = true
        monitor.start()
        defer { monitor.stop() }
        pasteboard.extraTypes = ["public.utf8-plain-text"]
        pasteboard.string = "ordinary before race"
        pasteboard.beforeNextStringRead = {
            pasteboard.writeExternally("secret written during read",
                                       types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"])
        }
        monitor.pollPasteboard()
        monitor.pollPasteboard() // The next check sees the marker before reading.
        drain(monitor)
        XCTAssertTrue(monitor.entries.isEmpty)
        XCTAssertEqual(pasteboard.stringReadCount, 1)
        XCTAssertFalse(monitor.log.lines.contains { $0.fileLine.contains("secret written during read") })
        XCTAssertEqual(monitor.log.lines.filter { $0.primaryText.contains("秘密の印のため保存せず") }.count, 2)
    }

    @MainActor
    func testPrivateImageDoesNotReadDataOrBitmap() throws {
        let root = try ImageTestSupport.directory(self)
        let url = root.appendingPathComponent("history.sqlite")
        let pasteboard = TestClipboardPasteboard()
        let monitor = try self.monitor(root: root, pasteboard: pasteboard) { try HistoryDatabase(url: url) }
        drain(monitor)
        monitor.start()
        defer { monitor.stop() }
        pasteboard.extraTypes = ["org.nspasteboard.ConcealedType"]
        pasteboard.setData(ImageTestSupport.png(), forPasteboardType: "public.png")
        monitor.pollPasteboard()
        drain(monitor)
        XCTAssertTrue(monitor.entries.isEmpty)
        XCTAssertEqual(pasteboard.stringReadCount, 0)
        XCTAssertEqual(pasteboard.imageReadCount, 0)
        XCTAssertEqual(pasteboard.dataReadCount, 0)
    }

    @MainActor
    func testBackgroundPollHeartbeatIsThrottledAndAbsentWhileActive() throws {
        let root = try ImageTestSupport.directory(self)
        let url = root.appendingPathComponent("history.sqlite")
        let pasteboard = TestClipboardPasteboard()
        let monitor = try self.monitor(root: root, pasteboard: pasteboard) { try HistoryDatabase(url: url) }
        drain(monitor)
        monitor.start()
        defer { monitor.stop() }
        monitor.updateScene("active")
        monitor.pollPasteboard()
        XCTAssertFalse(monitor.log.lines.contains { $0.primaryText.contains("裏での定期確認") })
        monitor.updateScene("background")
        monitor.pollPasteboard()
        monitor.pollPasteboard()
        let heartbeat = monitor.log.lines.filter { $0.primaryText.contains("裏での定期確認") }
        XCTAssertEqual(heartbeat.count, 1)
        XCTAssertTrue(heartbeat.first?.secondaryText.contains("scene=background") == true)
        XCTAssertTrue(heartbeat.first?.secondaryText.contains("changeCount=0") == true)
        monitor.updateScene("active")
        monitor.pollPasteboard()
        XCTAssertEqual(monitor.log.lines.filter { $0.primaryText.contains("裏での定期確認") }.count, 1)
        drain(monitor)
    }

    @MainActor
    func testReadLogDistinguishesNilStringAndEmptyTypeList() throws {
        let root = try ImageTestSupport.directory(self)
        let url = root.appendingPathComponent("history.sqlite")
        let pasteboard = TestClipboardPasteboard()
        let monitor = try self.monitor(root: root, pasteboard: pasteboard) { try HistoryDatabase(url: url) }
        drain(monitor)
        monitor.start()
        defer { monitor.stop() }
        monitor.updateScene("background")
        pasteboard.extraTypes = ["public.utf8-plain-text"]
        pasteboard.reportsStrings = true
        pasteboard.string = nil
        monitor.pollPasteboard()
        let nilRead = try XCTUnwrap(monitor.log.lines.last { $0.primaryText.contains("取得できず・原因未確定") })
        XCTAssertTrue(nilRead.secondaryText.contains("scene=background"))
        XCTAssertTrue(nilRead.secondaryText.contains("hasStrings=true; string=nil=true; 形式一覧が空=false"))
        pasteboard.extraTypes = []
        pasteboard.reportsStrings = false
        pasteboard.string = nil
        monitor.pollPasteboard()
        let emptyTypes = try XCTUnwrap(monitor.log.lines.last { $0.primaryText.contains("文章以外のため読み取らず") })
        XCTAssertTrue(emptyTypes.secondaryText.contains("scene=background"))
        XCTAssertTrue(emptyTypes.secondaryText.contains("hasStrings=false; string=nil=true; 形式一覧が空=true"))
        drain(monitor)
    }
}
