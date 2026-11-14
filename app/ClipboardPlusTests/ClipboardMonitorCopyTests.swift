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
    var extraTypes: [String] = []
    var hasImages: Bool { reportsImages && imageData != nil }
    var hasStrings: Bool { storedString != nil }
    var types: [String] { (imageType.map { [$0] } ?? []) + extraTypes }
    var image: UIImage? { nil }

    var string: String? {
        get { storedString }
        set {
            storedString = newValue
            imageData = nil
            imageType = nil
            changeCount += 1
        }
    }

    func data(forPasteboardType pasteboardType: String) -> Data? {
        imageType == pasteboardType ? imageData : nil
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
}
