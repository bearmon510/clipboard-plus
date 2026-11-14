import XCTest
@testable import ClipboardPlus

final class PictureInPicturePolicyTests: XCTestCase {
    func testAutomaticStartRequiresAllThreeConditions() {
        let cases: [(enabled: Bool, recording: Bool, automatic: Bool, expected: Bool)] = [
            (false, false, false, false),
            (false, false, true, false),
            (false, true, false, false),
            (false, true, true, false),
            (true, false, false, false),
            (true, false, true, false),
            (true, true, false, false),
            (true, true, true, true)
        ]
        for value in cases {
            XCTAssertEqual(PictureInPicturePolicy.canStartAutomatically(
                isEnabled: value.enabled, isRecording: value.recording, automaticallyStarts: value.automatic
            ), value.expected, "enabled=\(value.enabled), recording=\(value.recording), automatic=\(value.automatic)")
        }
    }
}
