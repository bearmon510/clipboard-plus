import XCTest
@testable import ClipboardPlus

final class ImageAdmissionTests: XCTestCase {
    func testOwnReadbackIsSkippedButNextExternalCopyCounts() {
        var admission = ImageAdmission()
        admission.recordSelfCopy(hash: "same", changeCount: 10)
        XCTAssertEqual(admission.receive(hash: "same", before: 10, after: 10), .skip(reason: "直前の内容と同じ"))
        XCTAssertEqual(admission.receive(hash: "same", before: 11, after: 11), .add)
    }

    func testExternalSameImageBeforeReadbackIsNotSuppressed() {
        var admission = ImageAdmission()
        admission.recordSelfCopy(hash: "same", changeCount: 10)
        XCTAssertEqual(admission.receive(hash: "same", before: 11, after: 11), .add)
    }

    func testDifferentImageConsumesSelfCopyMarker() {
        var admission = ImageAdmission()
        admission.recordSelfCopy(hash: "own", changeCount: 10)
        XCTAssertEqual(admission.receive(hash: "external", before: 11, after: 11), .add)
        XCTAssertEqual(admission.receive(hash: "own", before: 12, after: 12), .add)
    }

    func testChangedDuringReadIsRecheckedOnlyOnce() {
        var admission = ImageAdmission()
        XCTAssertEqual(admission.receive(hash: "B", before: 10, after: 11), .add)
        XCTAssertEqual(admission.receive(hash: "B", before: 11, after: 11), .skip(reason: "読み取り中の変更を再確認"))
        XCTAssertEqual(admission.receive(hash: "B", before: 12, after: 12), .add)
    }

    func testChangedDuringReadKeepsDifferentEndpointImage() {
        var admission = ImageAdmission()
        XCTAssertEqual(admission.receive(hash: "A", before: 10, after: 11), .add)
        XCTAssertEqual(admission.receive(hash: "B", before: 11, after: 11), .add)
    }

    func testResetAndSelfCopyClearRaceState() {
        var admission = ImageAdmission()
        admission.recordSelfCopy(hash: "A", changeCount: 10)
        admission.reset()
        XCTAssertEqual(admission.receive(hash: "A", before: 10, after: 10), .add)
        XCTAssertEqual(admission.receive(hash: "B", before: 11, after: 12), .add)
        admission.recordSelfCopy(hash: "C", changeCount: 13)
        XCTAssertEqual(admission.receive(hash: "B", before: 12, after: 12), .add)
    }
}
