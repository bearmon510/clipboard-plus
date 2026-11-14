import Foundation
import XCTest
@testable import ClipboardPlus

final class MeasurementLogTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @MainActor
    func testAppendImmediatelyUpdatesMemoryWithSuppliedTimestamp() throws {
        let file = try temporaryDirectory().appendingPathComponent("log.tsv")
        let writer = MeasurementLogWriter(fileURL: file)
        let log = MeasurementLog(writer: writer)
        let event = MeasurementEvent(
            timestamp: Date(timeIntervalSince1970: 0.123), kind: "手動保存", changeCount: 2, scene: "active"
        )
        log.append(event)
        XCTAssertEqual(log.lines.count, 1)
        let timestamp = log.lines[0].fileLine.components(separatedBy: "\t")[0]
        let parser = ISO8601DateFormatter()
        parser.timeZone = TimeZone(secondsFromGMT: 0)!
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(parser.date(from: timestamp)?.timeIntervalSince1970 ?? -1, 0.123, accuracy: 0.001)
        let done = expectation(description: "flushed")
        log.flush(context: event) { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    @MainActor
    func testExportIncludesAppendAndFlushFailureEvidence() throws {
        let file = try temporaryDirectory().appendingPathComponent("unavailable/log.tsv")
        let log = MeasurementLog(writer: MeasurementLogWriter(fileURL: file))
        let event = MeasurementEvent(kind: "通知受信", changeCount: 2, scene: "active")
        log.append(event)
        let done = expectation(description: "exported failure evidence")
        log.prepareExport(context: event) { url in
            if let url {
                defer { try? FileManager.default.removeItem(at: url) }
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                XCTAssertTrue(text.hasPrefix("# ファイルへ保存できなかった行"))
                XCTAssertEqual(log.lines.map { $0.id }, [1, 2, 3])
                XCTAssertTrue(log.lines[1].fileLine.contains("操作=追記"))
                XCTAssertTrue(log.lines[2].fileLine.contains("操作=同期"))
                XCTAssertTrue(text.hasSuffix(log.lines.map { $0.fileLine + "\n" }.joined()))
                XCTAssertNotNil(log.errorMessage)
            } else {
                XCTFail("Pending events and failure records should be exportable")
            }
            XCTAssertFalse(log.isPerformingFileOperation)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    @MainActor
    func testClearPreservesNewEventsAndContinuesEventNumbers() throws {
        let file = try temporaryDirectory().appendingPathComponent("log.tsv")
        let writer = MeasurementLogWriter(fileURL: file)
        let log = MeasurementLog(writer: writer)
        let event = MeasurementEvent(kind: "通知受信", changeCount: 2, scene: "active")
        log.append(event)
        log.clear(context: event)
        log.append(event)
        let done = expectation(description: "cleared older events")
        writer.flush { error in
            XCTAssertNil(error)
            XCTAssertEqual(log.lines.map { $0.id }, [2])
            XCTAssertEqual(try? String(contentsOf: file, encoding: .utf8), log.lines.first.map { $0.fileLine + "\n" })
            XCTAssertFalse(log.isPerformingFileOperation)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }
}
