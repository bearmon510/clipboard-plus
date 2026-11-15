import Foundation
import XCTest
@testable import ClipboardPlus

final class MeasurementLogWriterTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func records(_ kinds: [String]) -> [LogRecord] {
        var sequence = LogEventSequence(sessionID: "test-launch")
        return kinds.map {
            sequence.makeRecord(
                MeasurementEvent(kind: $0, changeCount: 1, scene: "active"),
                formatter: LogLineFormatter(timeZone: TimeZone(secondsFromGMT: 0)!)
            )
        }
    }

    func testQueuedWritesAndFlushPreserveSubmissionOrder() throws {
        let file = try temporaryDirectory().appendingPathComponent("log.tsv")
        let writer = MeasurementLogWriter(fileURL: file)
        let values = records(["通知受信", "hasStringsの結果", "読み取り成功"])
        let done = expectation(description: "flushed")
        for value in values { writer.append(value) { XCTAssertNil($0) } }
        writer.flush { error in
            XCTAssertNil(error)
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(try? String(contentsOf: file, encoding: .utf8), values.map { $0.fileLine + "\n" }.joined())
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testLargeLogKeepsOnlyItsNewestWholeLinesAtFirstWrite() throws {
        let file = try temporaryDirectory().appendingPathComponent("log.tsv")
        let old = (1...40).map { "old line \($0)\n" }.joined()
        try old.write(to: file, atomically: true, encoding: .utf8)
        let writer = MeasurementLogWriter(fileURL: file, maximumFileBytes: 100, trimmedFileBytes: 60)
        let value = records(["読み取り成功"])[0]
        let done = expectation(description: "flushed")
        writer.append(value) { XCTAssertNil($0) }
        writer.flush { error in
            XCTAssertNil(error)
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            let lines = text.split(separator: "\n").map(String.init)
            XCTAssertEqual(lines.last, value.fileLine)
            XCTAssertEqual(lines.dropLast().last, "old line 40")
            // The cut falls on a line boundary and removes the oldest lines.
            XCTAssertTrue(lines.dropLast().allSatisfy { $0.hasPrefix("old line ") })
            XCTAssertFalse(text.contains("old line 1\n"))
            XCTAssertLessThan(lines.count, 10)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testSmallLogIsNotTrimmed() throws {
        let file = try temporaryDirectory().appendingPathComponent("log.tsv")
        try "kept line\n".write(to: file, atomically: true, encoding: .utf8)
        let writer = MeasurementLogWriter(fileURL: file, maximumFileBytes: 100, trimmedFileBytes: 60)
        let value = records(["読み取り成功"])[0]
        let done = expectation(description: "flushed")
        writer.append(value) { XCTAssertNil($0) }
        writer.flush { error in
            XCTAssertNil(error)
            XCTAssertEqual(try? String(contentsOf: file, encoding: .utf8), "kept line\n" + value.fileLine + "\n")
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testFailedAppendAndFailureRowAreRetriedWithNextAppend() throws {
        let parent = try temporaryDirectory().appendingPathComponent("unavailable")
        let file = parent.appendingPathComponent("log.tsv")
        let writer = MeasurementLogWriter(fileURL: file)
        let values = records(["通知受信", "ログ書き込みの失敗", "読み取り成功"])
        let done = expectation(description: "retried")
        writer.append(values[0]) { error in
            XCTAssertNotNil(error)
            do {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            } catch { XCTFail("Could not prepare retry directory") }
            writer.append(values[1], attemptWrite: false) { XCTAssertNil($0) }
            writer.append(values[2]) { XCTAssertNil($0) }
            writer.flush { error in
                XCTAssertNil(error)
                XCTAssertEqual(try? String(contentsOf: file, encoding: .utf8), values.map { $0.fileLine + "\n" }.joined())
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 5)
    }

    func testExportIncludesUnsavedRowsWhenSourceFileCannotBeCreated() throws {
        let file = try temporaryDirectory().appendingPathComponent("unavailable/log.tsv")
        let writer = MeasurementLogWriter(fileURL: file)
        let values = records(["通知受信", "ログ書き込みの失敗"])
        let done = expectation(description: "exported pending")
        writer.append(values[0]) { XCTAssertNotNil($0) }
        writer.append(values[1], attemptWrite: false) { XCTAssertNil($0) }
        writer.flush { error in
            XCTAssertNotNil(error)
            writer.exportSnapshot { result in
                switch result {
                case .success(let url):
                    defer { try? FileManager.default.removeItem(at: url) }
                    let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                    XCTAssertTrue(text.hasPrefix("# ファイルへ保存できなかった行"))
                    XCTAssertTrue(text.hasSuffix(values.map { $0.fileLine + "\n" }.joined()))
                case .failure:
                    XCTFail("Pending rows should be exportable without a source file")
                }
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 5)
    }

    func testClearDoesNotDiscardPendingRowsIfFlushFails() throws {
        let parent = try temporaryDirectory().appendingPathComponent("unavailable")
        let file = parent.appendingPathComponent("log.tsv")
        let writer = MeasurementLogWriter(fileURL: file)
        let value = records(["通知受信"])[0]
        let done = expectation(description: "preserved after failed clear")
        writer.append(value, attemptWrite: false) { XCTAssertNil($0) }
        writer.clear { error in
            XCTAssertNotNil(error)
            do {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            } catch { XCTFail("Could not prepare retry directory") }
            writer.flush { error in
                XCTAssertNil(error)
                XCTAssertEqual(try? String(contentsOf: file, encoding: .utf8), value.fileLine + "\n")
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 5)
    }

    func testClearSeparatesOlderAndNewlySubmittedRows() throws {
        let file = try temporaryDirectory().appendingPathComponent("log.tsv")
        let writer = MeasurementLogWriter(fileURL: file)
        let values = records(["消去前", "消去後"])
        let done = expectation(description: "clear boundary")
        writer.append(values[0], attemptWrite: false) { XCTAssertNil($0) }
        writer.clear { XCTAssertNil($0) }
        writer.append(values[1]) { XCTAssertNil($0) }
        writer.flush { error in
            XCTAssertNil(error)
            XCTAssertEqual(try? String(contentsOf: file, encoding: .utf8), values[1].fileLine + "\n")
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testAppendSeparatesAnExistingPartialLine() throws {
        let file = try temporaryDirectory().appendingPathComponent("log.tsv")
        try Data("partial".utf8).write(to: file)
        let writer = MeasurementLogWriter(fileURL: file)
        let value = records(["通知受信"])[0]
        let done = expectation(description: "partial tail")
        writer.append(value) { XCTAssertNil($0) }
        writer.flush { error in
            XCTAssertNil(error)
            XCTAssertEqual(try? String(contentsOf: file, encoding: .utf8), "partial\n" + value.fileLine + "\n")
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }
}
