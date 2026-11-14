import XCTest
@testable import ClipboardPlus

final class HistoryAdmissionTests: XCTestCase {
    func testConsecutiveIdenticalTextIsSkippedWithReason() {
        var admission = HistoryAdmission()
        XCTAssertEqual(admission.receive("文章A"), .add)
        XCTAssertEqual(admission.receive("文章A"), .skip(reason: "直前の内容と同じ"))
        XCTAssertEqual(admission.previousText, "文章A")
    }

    func testSelfCopyUpdatesPreviousTextWithoutAdding() {
        var admission = HistoryAdmission()
        XCTAssertEqual(admission.receive("文章A"), .add)
        admission.recordSelfCopy("文章B")
        XCTAssertEqual(admission.previousText, "文章B")
        XCTAssertEqual(admission.receive("文章B"), .skip(reason: "直前の内容と同じ"))
        XCTAssertEqual(admission.receive("文章A"), .add)
    }

    func testAlternatingTextIsAlwaysAdded() {
        var admission = HistoryAdmission()
        for text in ["A", "B", "A", "B", "A"] {
            XCTAssertEqual(admission.receive(text), .add)
        }
    }

    func testExternalChangeAfterSelfCopyAllowsEarlierTextAgain() {
        var admission = HistoryAdmission()
        XCTAssertEqual(admission.receive("A"), .add)
        admission.recordSelfCopy("A")
        XCTAssertEqual(admission.receive("B"), .add)
        XCTAssertEqual(admission.receive("A"), .add)
    }

    func testEmptyTextIsAValidValueAndOnlyConsecutiveDuplicateIsSkipped() {
        var admission = HistoryAdmission()
        XCTAssertNil(admission.previousText)
        XCTAssertEqual(admission.receive(""), .add)
        XCTAssertEqual(admission.receive(""), .skip(reason: "直前の内容と同じ"))
        XCTAssertEqual(admission.receive("A"), .add)
        XCTAssertEqual(admission.receive(""), .add)
        admission.recordSelfCopy("")
        XCTAssertEqual(admission.receive(""), .skip(reason: "直前の内容と同じ"))
    }
}

