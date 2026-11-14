import XCTest
@testable import ClipboardPlus

final class HistoryAdmissionTests: XCTestCase {
    func testConsecutiveExternalTextIsCollectedAgain() {
        var admission = HistoryAdmission()
        XCTAssertEqual(admission.receive("文章A"), .add)
        XCTAssertEqual(admission.receive("文章A"), .add)
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

    func testEmptyTextIsValidAndOnlySelfCopyReadbackIsSkipped() {
        var admission = HistoryAdmission()
        XCTAssertNil(admission.previousText)
        XCTAssertEqual(admission.receive(""), .add)
        XCTAssertEqual(admission.receive(""), .add)
        XCTAssertEqual(admission.receive("A"), .add)
        XCTAssertEqual(admission.receive(""), .add)
        admission.recordSelfCopy("")
        XCTAssertEqual(admission.receive(""), .skip(reason: "直前の内容と同じ"))
        XCTAssertEqual(admission.receive(""), .add)
    }

    func testDiscardingUnreadBaselineOrNonTextReadAllowsNextExternalCopy() {
        var admission = HistoryAdmission()
        admission.recordSelfCopy("A")
        admission.discardPendingSelfCopy()
        XCTAssertEqual(admission.receive("A"), .add)
    }

    func testSameTextAtEndpointOfChangedReadIsNotCountedTwice() {
        var admission = HistoryAdmission()
        XCTAssertEqual(admission.receive("B", before: 10, after: 11), .add)
        XCTAssertEqual(admission.receive("B", before: 11, after: 11), .skip(reason: "読み取り中の変更を再確認"))
        XCTAssertEqual(admission.receive("B", before: 12, after: 12), .add)
    }

    func testDifferentTextAfterChangedReadPreservesBoth() {
        var admission = HistoryAdmission()
        XCTAssertEqual(admission.receive("A", before: 10, after: 11), .add)
        XCTAssertEqual(admission.receive("B", before: 11, after: 11), .add)
    }

    func testNewChangeBeyondReadEndpointCountsSameExternalTextAgain() {
        var admission = HistoryAdmission()
        XCTAssertEqual(admission.receive("B", before: 10, after: 11), .add)
        XCTAssertEqual(admission.receive("B", before: 12, after: 12), .add)
    }

    func testMultipleChangesDuringReadOnlySuppressEndpointReadback() {
        var admission = HistoryAdmission()
        XCTAssertEqual(admission.receive("B", before: 10, after: 13), .add)
        XCTAssertEqual(admission.receive("B", before: 13, after: 13), .skip(reason: "読み取り中の変更を再確認"))
    }

    func testAnotherRaceIsPreservedAndItsStableReadbackIsSuppressed() {
        var admission = HistoryAdmission()
        XCTAssertEqual(admission.receive("B", before: 10, after: 11), .add)
        XCTAssertEqual(admission.receive("B", before: 11, after: 12), .add)
        XCTAssertEqual(admission.receive("B", before: 12, after: 12), .skip(reason: "読み取り中の変更を再確認"))
    }

    func testRaceComparisonPreservesExactUTF8Differences() {
        var admission = HistoryAdmission()
        XCTAssertEqual(admission.receive("é", before: 10, after: 11), .add)
        XCTAssertEqual(admission.receive("e\u{301}", before: 11, after: 11), .add)
    }

    func testBaselineAndNonTextReadDiscardRaceState() {
        var admission = HistoryAdmission()
        XCTAssertEqual(admission.receive("B", before: 10, after: 11), .add)
        admission.discardPendingSelfCopy()
        XCTAssertEqual(admission.receive("B", before: 11, after: 11), .add)
    }

    func testSelfCopyReplacesRaceState() {
        var admission = HistoryAdmission()
        XCTAssertEqual(admission.receive("B", before: 10, after: 11), .add)
        admission.recordSelfCopy("A")
        XCTAssertEqual(admission.receive("A", before: 12, after: 12), .skip(reason: "直前の内容と同じ"))
        XCTAssertEqual(admission.receive("B", before: 13, after: 13), .add)
    }
}

