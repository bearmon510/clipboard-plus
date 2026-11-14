import Foundation
import XCTest
@testable import ClipboardPlus

final class LogLineFormatterTests: XCTestCase {
    private let fixedZone = TimeZone(secondsFromGMT: 9 * 3_600)!

    private func event(text: String = "非公開の文章") -> MeasurementEvent {
        MeasurementEvent(
            timestamp: Date(timeIntervalSince1970: 0.123),
            kind: "読み取り成功",
            changeCount: 42,
            scene: "active",
            characterCount: text.count,
            historyNumber: 7,
            details: "取得元=通知",
            text: text
        )
    }

    private func format(_ value: MeasurementEvent, preview: Bool = false) -> String {
        LogLineFormatter(includeTextPreview: preview, timeZone: fixedZone)
            .format(value, sessionID: "test-session", eventNumber: 1)
    }

    func testDefaultOmitsOriginalText() {
        let line = format(event())
        XCTAssertFalse(line.contains("非公開の文章"))
        XCTAssertFalse(line.contains("冒頭20文字="))
        XCTAssertEqual(line.components(separatedBy: "\t").count, 9)
    }

    func testPreviewCanBeEnabledAndDisabled() {
        var formatter = LogLineFormatter(timeZone: fixedZone)
        formatter.includeTextPreview = true
        XCTAssertTrue(formatter.format(event(), sessionID: "test", eventNumber: 1).hasSuffix("冒頭20文字=非公開の文章"))
        formatter.includeTextPreview = false
        XCTAssertFalse(formatter.format(event(), sessionID: "test", eventNumber: 2).contains("非公開の文章"))
    }

    func testPreviewContainsOnlyFirstTwentyCharacters() {
        let text = String(repeating: "あ", count: 20) + "末尾は含めない"
        let line = format(event(text: text), preview: true)
        XCTAssertTrue(line.hasSuffix("冒頭20文字=" + String(repeating: "あ", count: 20)))
        XCTAssertFalse(line.contains("末尾は含めない"))
    }

    func testNewlinesTabsAndBackslashesAreEscapedOnOneLine() {
        let line = format(event(text: "A\r\nB\tC\\D"), preview: true)
        XCTAssertTrue(line.hasSuffix("冒頭20文字=A\\r\\nB\\tC\\\\D"))
        XCTAssertFalse(line.contains("\n"))
        XCTAssertFalse(line.contains("\r"))
        XCTAssertEqual(line.components(separatedBy: "\t").count, 10)
    }

    func testUnicodeLineSeparatorsAreEscaped() {
        let line = format(event(text: "A\u{0085}B\u{2028}C\u{2029}"), preview: true)
        XCTAssertTrue(line.hasSuffix("冒頭20文字=A\\u{0085}B\\u{2028}C\\u{2029}"))
    }

    func testTimestampUsesThreeMillisecondsDigitsAndLocalOffset() {
        XCTAssertEqual(format(event()).components(separatedBy: "\t").first, "1970-01-01T09:00:00.123+09:00")
        var wholeSecond = event()
        wholeSecond.timestamp = Date(timeIntervalSince1970: 1)
        XCTAssertTrue(format(wholeSecond).hasPrefix("1970-01-01T09:00:01.000+09:00\t"))
    }

    func testZeroAndNegativeOffsetsAndDateBoundary() {
        let date = Date(timeIntervalSince1970: 0.007)
        XCTAssertEqual(LogLineFormatter(timeZone: TimeZone(secondsFromGMT: 0)!).timestamp(date),
                       "1970-01-01T00:00:00.007+00:00")
        XCTAssertEqual(LogLineFormatter(timeZone: TimeZone(secondsFromGMT: -12_600)!).timestamp(date),
                       "1969-12-31T20:30:00.007-03:30")
    }

    func testDisplayTimeUsesLocalTimeAndThreeMillisecondsDigits() {
        var sequence = LogEventSequence(sessionID: "test")
        let formatter = LogLineFormatter(timeZone: fixedZone)
        XCTAssertTrue(sequence.makeRecord(event(), formatter: formatter).primaryText.hasPrefix("09:00:00.123・"))
        var wholeSecond = event()
        wholeSecond.timestamp = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(sequence.makeRecord(wholeSecond, formatter: formatter).primaryText.hasPrefix("09:00:00.000・"))
    }

    func testRequiredColumnsAndMissingValues() {
        XCTAssertEqual(format(event(text: "123")).components(separatedBy: "\t"), [
            "1970-01-01T09:00:00.123+09:00", "test-session", "1", "読み取り成功", "42", "active", "3", "7", "取得元=通知"
        ])
        let withoutHistory = MeasurementEvent(kind: "記録の開始", changeCount: 0, scene: "inactive")
        let fields = format(withoutHistory).components(separatedBy: "\t")
        XCTAssertEqual(fields[6], "-")
        XCTAssertEqual(fields[7], "-")
    }

    func testMetadataIsEscapedToo() {
        var value = event()
        value.details = "値=1\t次の値=2\n別行"
        let line = format(value)
        XCTAssertEqual(line.components(separatedBy: "\t").count, 9)
        XCTAssertTrue(line.hasSuffix("値=1\\t次の値=2\\n別行"))
        XCTAssertFalse(LogLineFormatter(timeZone: fixedZone).format(value, sessionID: "session\tID", eventNumber: 1)
            .contains("session\tID"))
    }
}
