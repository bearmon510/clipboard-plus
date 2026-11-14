import XCTest
@testable import ClipboardPlus

final class HistoryAdmissionTests: XCTestCase {
    func testMatchingExportIsSkippedEveryTime() {
        var admission = HistoryAdmission()
        let text = "{\"entries\":[]}\n"
        admission.recordExport(text)
        XCTAssertEqual(admission.receive(text), .skip(reason: "このアプリが書き出した内容"))
        XCTAssertEqual(admission.receive(text), .skip(reason: "このアプリが書き出した内容"))
    }

    func testDifferentTextAfterExportIsAdded() {
        var admission = HistoryAdmission()
        admission.recordExport("event\tdetails\n")
        XCTAssertEqual(admission.receive("event\tdetails"), .add)
        XCTAssertEqual(admission.receive("別の文章"), .add)
    }

    func testExportRemainsExcludedAfterOtherTextAndRecordingRestart() {
        var admission = HistoryAdmission()
        let text = "event\tdetails\n"
        admission.recordExport(text)
        XCTAssertEqual(admission.receive("別の文章"), .add)
        admission.discardPendingSelfCopy()
        XCTAssertEqual(admission.receive(text), .skip(reason: "このアプリが書き出した内容"))
    }

    func testOnlyLatestExportIsExcluded() {
        var admission = HistoryAdmission()
        admission.recordExport("古い書き出し")
        admission.recordExport("新しい書き出し")
        XCTAssertEqual(admission.receive("古い書き出し"), .add)
        XCTAssertEqual(admission.receive("新しい書き出し"), .skip(reason: "このアプリが書き出した内容"))
    }

    func testExportMatchingUsesExactUTF8InsteadOfUnicodeEquivalence() {
        var admission = HistoryAdmission()
        admission.recordExport("\u{00E9}")
        XCTAssertEqual(admission.receive("e\u{0301}"), .add)
        XCTAssertEqual(admission.receive("\u{00E9}"), .skip(reason: "このアプリが書き出した内容"))
    }

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

