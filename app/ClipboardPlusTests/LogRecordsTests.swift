import Foundation
import XCTest
@testable import ClipboardPlus

final class LogRecordsTests: XCTestCase {
    private let formatter = LogLineFormatter(timeZone: TimeZone(secondsFromGMT: 9 * 3_600)!)

    private func event(_ kind: String = "通知受信", at time: TimeInterval = 0.123) -> MeasurementEvent {
        MeasurementEvent(timestamp: Date(timeIntervalSince1970: time), kind: kind, changeCount: 3, scene: "active")
    }

    func testSequenceNumbersIncreaseAcrossKindsAndClockChanges() {
        var sequence = LogEventSequence(sessionID: "launch-A")
        let first = sequence.makeRecord(event(), formatter: formatter)
        let failure = sequence.makeRecord(event("ログ書き込みの失敗", at: 0), formatter: formatter)
        XCTAssertEqual([first.id, failure.id], [1, 2])
        XCTAssertEqual(Array(first.fileLine.components(separatedBy: "\t")[1...2]), ["launch-A", "1"])
        XCTAssertEqual(Array(failure.fileLine.components(separatedBy: "\t")[1...2]), ["launch-A", "2"])
        XCTAssertEqual(sequence.nextEventNumber, 3)
    }

    func testNewLaunchHasDistinctIdentityAndStartsAtOne() {
        var first = LogEventSequence(sessionID: "launch-A")
        var second = LogEventSequence(sessionID: "launch-B")
        XCTAssertEqual(first.makeRecord(event(), formatter: formatter).id, 1)
        XCTAssertEqual(second.makeRecord(event(), formatter: formatter).id, 1)
        XCTAssertNotEqual(first.sessionID, second.sessionID)
        XCTAssertNotEqual(LogEventSequence().sessionID, LogEventSequence().sessionID)
    }

    func testPrimaryDisplayAndPreviewPolicy() {
        var sequence = LogEventSequence(sessionID: "launch")
        var value = event("読み取り成功")
        value.historyNumber = 7
        value.text = "原文は表示しない"
        let record = sequence.makeRecord(value, formatter: formatter)
        XCTAssertEqual(record.primaryText, "09:00:00.123・読み取り成功・履歴#7")
        XCTAssertTrue(record.secondaryText.contains("changeCount=3"))
        XCTAssertFalse(record.fileLine.contains("原文は表示しない"))
        XCTAssertFalse(record.secondaryText.contains("原文は表示しない"))
        XCTAssertTrue(sequence.makeRecord(event(), formatter: formatter).primaryText.hasSuffix("履歴-"))
    }

    func testFailureRetainsOriginalAndFailureRowsUntilSuccessfulRetry() throws {
        var sequence = LogEventSequence(sessionID: "launch")
        var pending = PendingLogLines()
        let original = sequence.makeRecord(event(), formatter: formatter)
        pending.append(original)
        XCTAssertThrowsError(try pending.persist { _ in throw CocoaError(.fileWriteOutOfSpace) })
        let failure = sequence.makeRecord(event("ログ書き込みの失敗"), formatter: formatter)
        pending.append(failure)
        XCTAssertThrowsError(try pending.persist { _ in throw CocoaError(.fileWriteOutOfSpace) })
        XCTAssertEqual(pending.records.map { $0.id }, [1, 2])

        var retried = Data()
        pending.persist { retried = $0 }
        XCTAssertEqual(String(decoding: retried, as: UTF8.self), original.fileLine + "\n" + failure.fileLine + "\n")
        XCTAssertTrue(pending.records.isEmpty)
        XCTAssertEqual(sequence.makeRecord(event(), formatter: formatter).id, 3)
    }

    func testPartialFailureRetriesSameIdentifiersAndExportKeepsEvidence() {
        var sequence = LogEventSequence(sessionID: "launch")
        var pending = PendingLogLines()
        let record = sequence.makeRecord(event(), formatter: formatter)
        pending.append(record)
        var saved = Data()
        XCTAssertThrowsError(try pending.persist { data in
            saved.append(data)
            throw CocoaError(.fileWriteUnknown)
        })
        let export = String(decoding: pending.exportData(savedData: saved), as: UTF8.self)
        XCTAssertEqual(export.components(separatedBy: record.fileLine).count - 1, 2)
        XCTAssertTrue(export.contains("# ファイルへ保存できなかった行"))
        XCTAssertEqual(pending.records.map { $0.id }, [1])
    }

    func testExportSeparatesPartialTailAndDoesNotChangePendingRows() {
        var sequence = LogEventSequence(sessionID: "launch")
        var pending = PendingLogLines()
        let record = sequence.makeRecord(event("ログ書き込みの失敗"), formatter: formatter)
        pending.append(record)
        let export = String(decoding: pending.exportData(savedData: Data("partial".utf8)), as: UTF8.self)
        XCTAssertTrue(export.hasPrefix("partial\n# ファイルへ保存できなかった行"))
        XCTAssertTrue(export.hasSuffix(record.fileLine + "\n"))
        XCTAssertEqual(pending.records.count, 1)
    }

    func testExportWithoutPendingRowsPreservesSavedDataExactly() {
        let saved = Data("previous launch\n".utf8)
        XCTAssertEqual(PendingLogLines().exportData(savedData: saved), saved)
        XCTAssertEqual(PendingLogLines().exportData(savedData: Data()), Data())
    }
}
