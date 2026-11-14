import Foundation
import XCTest
@testable import ClipboardPlus

final class LogLineFormatterTests: XCTestCase {
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

    func testDefaultOmitsOriginalText() {
        let line = LogLineFormatter().format(event())
        XCTAssertFalse(line.contains("非公開の文章"))
        XCTAssertFalse(line.contains("冒頭20文字="))
        XCTAssertEqual(line.components(separatedBy: "\t").count, 7)
    }

    func testPreviewCanBeEnabledAndDisabled() {
        var formatter = LogLineFormatter()
        formatter.includeTextPreview = true
        XCTAssertTrue(formatter.format(event()).hasSuffix("冒頭20文字=非公開の文章"))
        formatter.includeTextPreview = false
        XCTAssertFalse(formatter.format(event()).contains("非公開の文章"))
    }

    func testPreviewContainsOnlyFirstTwentyCharacters() {
        let text = String(repeating: "あ", count: 20) + "末尾は含めない"
        let line = LogLineFormatter(includeTextPreview: true).format(event(text: text))
        XCTAssertTrue(line.hasSuffix("冒頭20文字=" + String(repeating: "あ", count: 20)))
        XCTAssertFalse(line.contains("末尾は含めない"))
    }

    func testNewlinesTabsAndBackslashesAreEscapedOnOneLine() {
        let line = LogLineFormatter(includeTextPreview: true).format(event(text: "A\r\nB\tC\\D"))
        XCTAssertTrue(line.hasSuffix("冒頭20文字=A\\r\\nB\\tC\\\\D"))
        XCTAssertFalse(line.contains("\n"))
        XCTAssertFalse(line.contains("\r"))
        XCTAssertEqual(line.components(separatedBy: "\t").count, 8)
    }

    func testUnicodeLineSeparatorsAreEscaped() {
        let line = LogLineFormatter(includeTextPreview: true)
            .format(event(text: "A\u{0085}B\u{2028}C\u{2029}"))
        XCTAssertTrue(line.hasSuffix("冒頭20文字=A\\u{0085}B\\u{2028}C\\u{2029}"))
    }

    func testTimestampUsesThreeMillisecondsDigitsAndUTC() {
        let line = LogLineFormatter().format(event())
        XCTAssertEqual(line.components(separatedBy: "\t").first, "1970-01-01T00:00:00.123Z")
        var wholeSecond = event()
        wholeSecond.timestamp = Date(timeIntervalSince1970: 1)
        XCTAssertTrue(LogLineFormatter().format(wholeSecond).hasPrefix("1970-01-01T00:00:01.000Z\t"))
    }

    func testRequiredColumnsAndMissingValues() {
        let line = LogLineFormatter().format(event(text: "123"))
        XCTAssertEqual(line.components(separatedBy: "\t"), [
            "1970-01-01T00:00:00.123Z", "読み取り成功", "42", "active", "3", "7", "取得元=通知"
        ])
        let withoutHistory = MeasurementEvent(kind: "記録の開始", changeCount: 0, scene: "inactive")
        let fields = LogLineFormatter().format(withoutHistory).components(separatedBy: "\t")
        XCTAssertEqual(fields[4], "-")
        XCTAssertEqual(fields[5], "-")
    }

    func testMetadataIsEscapedToo() {
        var value = event()
        value.details = "値=1\t次の値=2\n別行"
        let line = LogLineFormatter().format(value)
        XCTAssertEqual(line.components(separatedBy: "\t").count, 7)
        XCTAssertTrue(line.hasSuffix("値=1\\t次の値=2\\n別行"))
    }
}

