import Combine
import UIKit
import XCTest
@testable import ClipboardPlus

final class ImageProviderTests: XCTestCase {
    private func provider(_ data: Data, text: String? = nil) -> NSItemProvider {
        let provider = text.map { NSItemProvider(object: $0 as NSString) } ?? NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: "public.png", visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    @MainActor
    private func monitor(imageByteLimit: Int = HistoryImageFiles.maximumTotalByteCount) throws -> ClipboardMonitor {
        let root = try ImageTestSupport.directory(self)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let log = MeasurementLog(writer: MeasurementLogWriter(fileURL: root.appendingPathComponent("log.tsv")))
        return ClipboardMonitor(defaults: defaults, log: log,
                                makeDatabase: { try HistoryDatabase(url: root.appendingPathComponent("history.sqlite"), imageByteLimit: imageByteLimit) },
                                schedulesMaintenance: false, imageDirectory: root.appendingPathComponent("images"))
    }

    @MainActor
    private func waitForSave(_ monitor: ClipboardMonitor, action: () -> Void) {
        let saved = expectation(description: "image or text saved")
        let previous = monitor.log.lines.filter { $0.fileLine.contains("履歴保存成功") }.count
        let observation = monitor.log.$lines.first { lines in
            lines.filter { $0.fileLine.contains("履歴保存成功") }.count > previous
        }.sink { _ in saved.fulfill() }
        action()
        wait(for: [saved], timeout: 5)
        observation.cancel()
        let done = expectation(description: "storage and logs drained")
        monitor.pendingDeletion { _ in monitor.log.flush(context: monitor.logContext()) { done.fulfill() } }
        wait(for: [done], timeout: 5)
    }

    @MainActor
    func testMixedImageAndTextDropSavesOnlyImageAndLogsMetadata() throws {
        let monitor = try self.monitor()
        monitor.log.includeTextPreview = true
        let privateText = "associated text must not enter history or image logs"
        let data = ImageTestSupport.png()
        waitForSave(monitor) {
            XCTAssertTrue(monitor.receiveDropped([provider(data, text: privateText)], receivedAt: Date()))
        }
        XCTAssertEqual(monitor.entries.count, 1)
        XCTAssertEqual(monitor.entries.first?.kind, .image)
        XCTAssertEqual(monitor.entries.first?.source, .drag)
        XCTAssertEqual(monitor.pendingSaveCount, 0)
        XCTAssertEqual(monitor.imageUsage.count, 1)
        let hash = try HistoryImageFiles.hash(data)
        let lines = monitor.log.lines.map(\.fileLine).joined()
        for expected in ["形式=public.png", "バイト数=\(data.count)", "ピクセル=8x6", "所要ms=", "registeredTypeIdentifiers=", "hash=\(hash.prefix(8))"] {
            XCTAssertTrue(lines.contains(expected), expected)
        }
        XCTAssertFalse(lines.contains(privateText))
        XCTAssertFalse(lines.contains(data.base64EncodedString()))
        XCTAssertFalse(lines.contains(hash))
    }

    @MainActor
    func testManualProviderKeepsTextWhitespace() throws {
        let monitor = try self.monitor()
        let text = " 文章\n手動保存\t"
        waitForSave(monitor) {
            monitor.saveManually([NSItemProvider(object: text as NSString)], receivedAt: Date())
        }
        XCTAssertEqual(monitor.entries.first?.text, text)
        XCTAssertEqual(monitor.entries.first?.source, .manual)
    }

    @MainActor
    func testManualProviderPrefersImageAndCopyPreservesOriginalBytesAndType() throws {
        let monitor = try self.monitor()
        let data = ImageTestSupport.png()
        waitForSave(monitor) {
            monitor.saveManually([provider(data, text: "https://example.com/image")], receivedAt: Date())
        }
        let entry = try XCTUnwrap(monitor.entries.first)
        XCTAssertEqual(entry.kind, .image)
        XCTAssertEqual(entry.source, .manual)
        let copied = expectation(description: "original copied")
        monitor.copy(entry) { success in
            XCTAssertTrue(success)
            XCTAssertEqual(UIPasteboard.general.data(forPasteboardType: "public.png"), data)
            XCTAssertEqual(monitor.entries, [entry])
            copied.fulfill()
        }
        wait(for: [copied], timeout: 5)
        UIPasteboard.general.items = []
    }

    @MainActor
    func testLocalImageDragIsIgnoredAndVendsOriginalData() throws {
        let monitor = try self.monitor()
        let data = ImageTestSupport.png()
        waitForSave(monitor) { monitor.saveManually([provider(data)], receivedAt: Date()) }
        let entry = try XCTUnwrap(monitor.entries.first)
        let row = monitor.rowProvider(entry)
        XCTAssertTrue(DroppedTextLoader.isLocalRow(row))
        XCTAssertFalse(monitor.receiveDropped([row], receivedAt: Date()))
        let loaded = expectation(description: "drag data loaded")
        row.loadDataRepresentation(forTypeIdentifier: "public.png") { original, error in
            XCTAssertNil(error)
            XCTAssertEqual(original, data)
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 5)
        XCTAssertEqual(monitor.entries, [entry])
        XCTAssertEqual(monitor.pendingSaveCount, 0)
    }

    func testProviderUsesPNGPreferenceOverJPEG() {
        let png = ImageTestSupport.png()
        let provider = self.provider(png)
        provider.registerDataRepresentation(forTypeIdentifier: "public.jpeg", visibility: .all) { completion in
            XCTFail("PNG should be requested first")
            completion(nil, HistoryImageError.invalidImage)
            return nil
        }
        let loaded = expectation(description: "preferred image loaded")
        HistoryImageLoader.load(provider) { result in
            switch result {
            case .success(.data(let data, let type)):
                XCTAssertEqual(data, png)
                XCTAssertEqual(type, "public.png")
            case .success(.bitmap(_)): XCTFail("Must preserve encoded data")
            case .failure(let error): XCTFail("\(error)")
            }
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 5)
    }

    @MainActor
    func testRejectedImageReportsNoticeAndReleasesPendingCount() throws {
        let monitor = try self.monitor()
        let rejected = expectation(description: "rejected image reported")
        let observation = monitor.$imageNotice.first { $0 != nil }.sink { notice in
            XCTAssertEqual(notice, HistoryImageError.invalidImage.message)
            rejected.fulfill()
        }
        monitor.saveManually([provider(Data("invalid".utf8))], receivedAt: Date())
        wait(for: [rejected], timeout: 5)
        observation.cancel()
        XCTAssertEqual(monitor.pendingSaveCount, 0)
        XCTAssertTrue(monitor.entries.isEmpty)
    }

    @MainActor
    func testMonitorDoesNotKeepRowsEvictedByImageByteLimit() throws {
        let first = ImageTestSupport.png(), second = ImageTestSupport.png(.blue)
        let monitor = try self.monitor(imageByteLimit: max(first.count, second.count))
        waitForSave(monitor) { monitor.saveManually([provider(first)], receivedAt: Date(timeIntervalSince1970: 1)) }
        let old = try XCTUnwrap(monitor.entries.first?.image)
        waitForSave(monitor) { monitor.saveManually([provider(second)], receivedAt: Date(timeIntervalSince1970: 2)) }
        XCTAssertEqual(monitor.entries.count, 1)
        XCTAssertEqual(monitor.entries.first?.image?.hash, try HistoryImageFiles.hash(second))
        XCTAssertEqual(monitor.imageUsage.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: monitor.imageURL(old, thumbnail: false).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: monitor.imageURL(old, thumbnail: true).path))
    }
}
