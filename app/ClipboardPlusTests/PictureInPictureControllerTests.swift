import AVKit
import UIKit
import XCTest
@testable import ClipboardPlus

@MainActor
private final class PiPTestPasteboard: ClipboardPasteboard {
    var changeCount = 0
    var hasImages = false
    var hasStrings = false
    var types: [String] = []
    var string: String?
    var image: UIImage? { nil }
    func data(forPasteboardType pasteboardType: String) -> Data? { nil }
    func setData(_ data: Data, forPasteboardType pasteboardType: String) {}
}

final class PictureInPictureControllerTests: XCTestCase {
    @MainActor
    private func withController(_ body: (PictureInPictureController, ClipboardMonitor, UserDefaults) throws -> Void) throws {
        let root = try ImageTestSupport.directory(self)
        let suite = "PiPTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        HistoryRetention.never.save(to: defaults)
        let log = MeasurementLog(writer: MeasurementLogWriter(fileURL: root.appendingPathComponent("log.tsv")))
        let databaseURL = root.appendingPathComponent("history.sqlite")
        let monitor = ClipboardMonitor(
            defaults: defaults, log: log, makeDatabase: { try HistoryDatabase(url: databaseURL) },
            schedulesMaintenance: false, imageDirectory: root.appendingPathComponent("images"),
            pasteboard: PiPTestPasteboard()
        )
        let pip = PictureInPictureController(monitor: monitor, defaults: defaults)
        defer {
            pip.setEnabled(false)
            monitor.stop()
            let done = expectation(description: "storage and log drained")
            monitor.pendingDeletion { _ in
                log.flush(context: monitor.logContext()) { done.fulfill() }
            }
            wait(for: [done], timeout: 5)
            XCTAssertNil(monitor.storageError)
        }
        try body(pip, monitor, defaults)
    }

    @MainActor
    func testButtonEnablesPiPAndStartsRecordingBeforeRequestingStart() throws {
        try withController { pip, monitor, defaults in
            XCTAssertFalse(pip.isEnabled)
            XCTAssertFalse(monitor.isRecording)
            var startCount = 0
            pip.togglePictureInPicture(start: {
                startCount += 1
                XCTAssertTrue(pip.isEnabled)
                XCTAssertTrue(monitor.isRecording)
                XCTAssertTrue(defaults.bool(forKey: "pictureInPictureEnabled"))
                XCTAssertTrue(defaults.bool(forKey: "isRecording"))
            })
            XCTAssertEqual(startCount, 1)
        }
    }

    @MainActor
    func testButtonKeepsAutomaticPreferenceOffWhenStartingManually() throws {
        try withController { pip, monitor, _ in
            pip.setAutomaticallyStarts(false)
            pip.togglePictureInPicture(start: {})
            XCTAssertTrue(pip.isEnabled)
            XCTAssertTrue(monitor.isRecording)
            XCTAssertFalse(pip.automaticallyStarts)
            XCTAssertFalse(pip.canStartAutomatically)
        }
    }

    @MainActor
    func testAutomaticPreferenceDefaultsToOnWithoutEnablingPiP() throws {
        try withController { pip, _, _ in
            XCTAssertTrue(pip.automaticallyStarts)
            XCTAssertFalse(pip.isEnabled)
            XCTAssertFalse(pip.canStartAutomatically)
        }
    }

    @MainActor
    func testAutomaticPreferencePersistsBothValuesAcrossControllerRecreation() throws {
        try withController { pip, monitor, defaults in
            for enabled in [false, true] {
                pip.setAutomaticallyStarts(enabled)
                XCTAssertEqual(defaults.object(forKey: PictureInPictureController.automaticallyStartsKey) as? Bool, enabled)
                let reloaded = PictureInPictureController(monitor: monitor, defaults: defaults)
                XCTAssertEqual(reloaded.automaticallyStarts, enabled)
                XCTAssertFalse(reloaded.isEnabled)
            }
        }
    }

    @MainActor
    func testExistingPiPEnabledKeyIsStillLoaded() throws {
        try withController { _, monitor, defaults in
            // withController's first launch has already performed the 0.8.0 migration.
            XCTAssertTrue(defaults.bool(forKey: PictureInPictureController.disabledForCaptureModeKey))
            defaults.set(true, forKey: "pictureInPictureEnabled")
            let reloaded = PictureInPictureController(monitor: monitor, defaults: defaults)
            defer { reloaded.setEnabled(false) }
            XCTAssertTrue(reloaded.isEnabled)
            XCTAssertTrue(reloaded.automaticallyStarts)
        }
    }

    @MainActor
    func testCaptureModeMigrationDisablesPiPOnlyOnce() throws {
        try withController { _, monitor, defaults in
            defaults.removeObject(forKey: PictureInPictureController.disabledForCaptureModeKey)
            defaults.set(true, forKey: PictureInPictureController.enabledKey)
            defaults.set(false, forKey: PictureInPictureController.automaticallyStartsKey)
            let migrated = PictureInPictureController(monitor: monitor, defaults: defaults)
            XCTAssertFalse(migrated.isEnabled)
            XCTAssertFalse(defaults.bool(forKey: PictureInPictureController.enabledKey))
            XCTAssertTrue(defaults.bool(forKey: PictureInPictureController.disabledForCaptureModeKey))
            XCTAssertFalse(migrated.automaticallyStarts)

            defaults.set(true, forKey: PictureInPictureController.enabledKey)
            let reloaded = PictureInPictureController(monitor: monitor, defaults: defaults)
            defer { reloaded.setEnabled(false) }
            XCTAssertTrue(reloaded.isEnabled)
            XCTAssertTrue(defaults.bool(forKey: PictureInPictureController.enabledKey))
            XCTAssertFalse(reloaded.automaticallyStarts)
        }
    }

    @MainActor
    func testAutomaticStartTracksRecordingAndBothSettingsImmediately() throws {
        try withController { pip, monitor, _ in
            guard pip.isSupported else { throw XCTSkip("PiP controller is unavailable on this simulator") }
            pip.setEnabled(true)
            XCTAssertFalse(pip.canStartAutomatically)
            monitor.start()
            XCTAssertTrue(pip.canStartAutomatically)
            monitor.stop()
            XCTAssertFalse(pip.canStartAutomatically)
            monitor.start()
            XCTAssertTrue(pip.canStartAutomatically)
            pip.setAutomaticallyStarts(false)
            XCTAssertFalse(pip.canStartAutomatically)
            pip.setAutomaticallyStarts(true)
            XCTAssertTrue(pip.canStartAutomatically)
            pip.setEnabled(false)
            XCTAssertFalse(pip.canStartAutomatically)
            XCTAssertTrue(monitor.isRecording)
            pip.setEnabled(true)
            XCTAssertTrue(pip.canStartAutomatically)
        }
    }

    @MainActor
    func testPendingStartIsCancelledWhenRecordingStopsOrPiPIsDisabled() throws {
        try withController { pip, monitor, _ in
            guard pip.isSupported else { throw XCTSkip("PiP controller is unavailable on this simulator") }
            // No source UIView is mounted, so this waits without starting system PiP.
            pip.togglePictureInPicture()
            XCTAssertTrue(pip.isStarting)
            monitor.stop()
            XCTAssertFalse(pip.isStarting)
            pip.togglePictureInPicture()
            XCTAssertTrue(pip.isStarting)
            pip.setEnabled(false)
            XCTAssertFalse(pip.isStarting)
            XCTAssertTrue(monitor.isRecording)
        }
    }

    @MainActor
    func testRestoreCompletesSuccessfullyAndLogsReturn() throws {
        try withController { pip, monitor, _ in
            let source = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: pip.displayLayer, playbackDelegate: pip
            )
            let controller = AVPictureInPictureController(contentSource: source)
            let restored = expectation(description: "restore completed")
            pip.pictureInPictureController(controller, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler: { success in
                XCTAssertTrue(success)
                restored.fulfill()
            })
            wait(for: [restored], timeout: 1)
            XCTAssertTrue(monitor.log.lines.contains { $0.primaryText.contains("PiPから本体へ戻る") })
        }
    }
}
