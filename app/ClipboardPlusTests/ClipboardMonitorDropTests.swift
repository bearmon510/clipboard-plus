import Combine
import UIKit
import XCTest
@testable import ClipboardPlus

final class ClipboardMonitorDropTests: XCTestCase {
    @MainActor
    private func makeMonitor() throws -> ClipboardMonitor {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let log = MeasurementLog(writer: MeasurementLogWriter(fileURL: directory.appendingPathComponent("log.tsv")))
        let databaseURL = directory.appendingPathComponent("history.sqlite")
        return ClipboardMonitor(defaults: defaults, log: log,
                                makeDatabase: { try HistoryDatabase(url: databaseURL) }, schedulesMaintenance: false)
    }

    @MainActor
    func testLocalRowDropLogsReceiptAndSkipWithoutSaving() throws {
        let monitor = try makeMonitor()
        let text = "local row body"
        let provider = DroppedTextLoader.rowProvider(text: text)
        XCTAssertFalse(monitor.receiveDropped([provider], receivedAt: Date()))
        let lines = monitor.log.lines.map { $0.fileLine }
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("ドロップを受信"))
        XCTAssertTrue(lines[0].contains("providers=1"))
        for identifier in provider.registeredTypeIdentifiers {
            XCTAssertTrue(lines[0].contains(identifier))
        }
        XCTAssertTrue(lines[1].contains("追加の見送り"))
        XCTAssertTrue(lines[1].contains("理由=自分の履歴の行"))
        XCTAssertFalse(lines.joined().contains(text))
        XCTAssertEqual(monitor.pendingSaveCount, 0)
        let done = expectation(description: "local drop did not save")
        monitor.pendingDeletion { _ in
            XCTAssertTrue(monitor.entries.isEmpty)
            monitor.log.flush(context: monitor.logContext()) { done.fulfill() }
        }
        wait(for: [done], timeout: 5)
    }

    @MainActor
    func testMixedDropSavesExternalCopyOfSameTextExactlyOnce() throws {
        let monitor = try makeMonitor()
        let text = "same text from an external app"
        let local = DroppedTextLoader.rowProvider(text: text)
        let external = NSItemProvider(object: text as NSString)
        let loaded = expectation(description: "external text received")
        let observation = monitor.log.$lines.first(where: { records in
            records.contains { $0.fileLine.contains("ドラッグで受信") }
        }).sink { _ in loaded.fulfill() }
        let receivedAt = Date()
        XCTAssertTrue(monitor.receiveDropped([local, external], receivedAt: receivedAt))
        XCTAssertTrue(monitor.log.lines[0].fileLine.contains("providers=2"))
        XCTAssertTrue(monitor.log.lines[0].fileLine.contains("provider[1].registeredTypeIdentifiers="))
        wait(for: [loaded], timeout: 5)
        observation.cancel()
        let done = expectation(description: "external drop saved once")
        monitor.pendingDeletion { _ in
            XCTAssertEqual(monitor.entries.count, 1)
            XCTAssertEqual(monitor.entries.first?.text, text)
            XCTAssertEqual(monitor.entries.first?.source, .drag)
            XCTAssertEqual(monitor.entries.first?.collectionCount, 1)
            let received = monitor.log.lines.filter { $0.fileLine.contains("ドラッグで受信") }
            XCTAssertEqual(received.count, 1)
            XCTAssertTrue(received.first?.fileLine.contains("provider[1]; loadObject(NSString): success") == true)
            monitor.log.flush(context: monitor.logContext()) { done.fulfill() }
        }
        wait(for: [done], timeout: 5)
    }

    @MainActor
    func testFailedDropLogsMethodsAndCodesWithoutErrorDescription() throws {
        let monitor = try makeMonitor()
        let privateDescription = "source body must stay out of diagnostics"
        let provider = NSItemProvider()
        provider.registerObject(ofClass: NSString.self, visibility: .all) { completion in
            completion(nil, NSError(domain: "DropTest", code: 7, userInfo: [NSLocalizedDescriptionKey: privateDescription]))
            return nil
        }
        let failed = expectation(description: "loading failure logged")
        let observation = monitor.log.$lines.first(where: { records in
            records.contains { $0.fileLine.contains("ドラッグの読み込み失敗") }
        }).sink { records in
            let failure = records.last?.fileLine ?? ""
            XCTAssertTrue(failure.contains("loadObject(NSString):"))
            XCTAssertTrue(failure.contains("loadDataRepresentation(public.utf8-plain-text):"))
            XCTAssertTrue(failure.contains("loadDataRepresentation(public.plain-text):"))
            XCTAssertTrue(failure.contains("code="))
            XCTAssertFalse(records.map { $0.fileLine }.joined().contains(privateDescription))
            failed.fulfill()
        }
        XCTAssertTrue(monitor.receiveDropped([provider], receivedAt: Date()))
        wait(for: [failed], timeout: 5)
        observation.cancel()
        XCTAssertEqual(monitor.pendingSaveCount, 0)
        let done = expectation(description: "failed drop did not save")
        monitor.pendingDeletion { _ in
            XCTAssertTrue(monitor.entries.isEmpty)
            monitor.log.flush(context: monitor.logContext()) { done.fulfill() }
        }
        wait(for: [done], timeout: 5)
    }
}
