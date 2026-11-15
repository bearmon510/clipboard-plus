import UIKit
import XCTest
@testable import ClipboardPlus
#if canImport(ScreenCaptureKit)
import CoreImage
import CoreVideo
import ImageIO
import ScreenCaptureKit
#endif

@MainActor
private final class CaptureTestClock {
    var date = Date(timeIntervalSince1970: 1_000)
    func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
}

@MainActor
private final class FakeScreenCaptureSource: ScreenCaptureSource {
    var isSupported = true
    var onEvent: (@MainActor (ScreenCaptureSourceEvent) -> Void)?
    var permissionRequests = 0
    var stops = 0
    var streamStops = 0
    var resumes = 0
    var hasFilter = false
    var deferStop = false
    var stopped: (@MainActor () -> Void)?
    var conversions = 0
    var latest: UIImage?
    var latestDate: Date?
    var deferConversion = false
    var conversion: (@MainActor (ScreenCaptureFrameResult) -> Void)?
    /// The controller under test. grant() tells it the app is active again, as happens when
    /// the system permission screen closes, unless a test needs that moment to come later.
    weak var controller: ScreenCaptureController?
    var reactivatesOnGrant = true

    func requestPermission() { permissionRequests += 1 }
    func resume() { resumes += 1 }
    func stopStream(completion: @escaping @MainActor () -> Void) {
        streamStops += 1
        latest = nil
        latestDate = nil
        if deferStop { stopped = completion }
        else { completion() }
    }
    func stop() {
        stops += 1
        hasFilter = false
        latest = nil
        latestDate = nil
    }
    func grant() {
        hasFilter = true
        onEvent?(.permissionGranted(contentRect: CGRect(x: 0, y: 0, width: 100, height: 200),
                                    pointPixelScale: 2))
        if reactivatesOnGrant { controller?.sceneDidActivate() }
    }
    func start(at date: Date) { onEvent?(.started(date)) }
    func frame(_ image: UIImage, at date: Date) {
        latest = image
        latestDate = date
        onEvent?(.frameReceived(at: date, width: 200, height: 400))
    }
    func idle(at date: Date) {
        guard latest != nil else { return }
        latestDate = date
        onEvent?(.frameReceived(at: date, width: 200, height: 400))
    }
    func invalidateFrame() {
        latest = nil
        latestDate = nil
        onEvent?(.frameInvalidated)
    }
    func convertLatestFrame(notBefore: Date,
                            completion: @escaping @MainActor (ScreenCaptureFrameResult) -> Void) {
        conversions += 1
        guard let latest, let latestDate, latestDate >= notBefore else {
            completion(.unavailable)
            return
        }
        if deferConversion { conversion = completion }
        else { completion(.success(latest)) }
    }
}

final class ScreenCaptureControllerTests: XCTestCase {
    @MainActor
    private func withController(supported: Bool = true, strategy: ScreenCaptureStrategy = .continuous,
                                _ body: (ScreenCaptureController, FakeScreenCaptureSource,
                                         CaptureTestClock, MeasurementLog) throws -> Void) throws {
        let root = try ImageTestSupport.directory(self)
        let log = MeasurementLog(writer: MeasurementLogWriter(fileURL: root.appendingPathComponent("capture-log.tsv")))
        let source = FakeScreenCaptureSource()
        source.isSupported = supported
        let clock = CaptureTestClock()
        let suite = "ScreenCaptureTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(strategy.rawValue, forKey: "screenCaptureStrategy")
        let controller = ScreenCaptureController(log: log, defaults: defaults, now: { clock.date }, source: source,
                                                 schedulesTimers: false)
        source.controller = controller
        defer {
            controller.stop(reason: "test cleanup")
            let done = expectation(description: "capture log drained")
            log.flush(context: MeasurementEvent(kind: "test", changeCount: 0, scene: "active")) { done.fulfill() }
            wait(for: [done], timeout: 5)
            XCTAssertNil(log.errorMessage)
        }
        try body(controller, source, clock, log)
    }

    @MainActor
    func testPermissionStartAndSettlingRejectEarlyFrames() throws {
        try withController { controller, source, clock, log in
            let image = UIImage()
            var received: UIImage?
            controller.requestFrame { result in
                if case .failure(let error) = result { XCTFail("\(error)") }
                if case .success(let image) = result { received = image }
            }
            XCTAssertEqual(controller.state, .requestingPermission)
            source.grant()
            XCTAssertEqual(controller.state, .starting)
            source.start(at: clock.date)
            XCTAssertEqual(controller.state, .running)
            clock.advance(0.59)
            source.frame(image, at: clock.date)
            XCTAssertNil(received)
            XCTAssertEqual(source.conversions, 0)
            clock.advance(0.02)
            source.frame(image, at: clock.date)
            XCTAssertTrue(received === image)
            XCTAssertEqual(source.conversions, 1)
            XCTAssertTrue(log.lines.contains { $0.primaryText.contains("許可画面を表示") })
            XCTAssertTrue(log.lines.contains { $0.primaryText.contains("開始成功") })
            XCTAssertTrue(log.lines.contains { $0.fileLine.contains("pointPixelScale=2") })
            XCTAssertTrue(log.lines.contains { $0.fileLine.contains("pixels=200x400") && $0.fileLine.contains("start_ms=") })
        }
    }

    @MainActor
    func testCancellationReturnsDeclinedAndClearsSource() throws {
        try withController { controller, source, _, _ in
            var failure: ScreenCaptureError?
            controller.requestFrame { if case .failure(let error) = $0 { failure = error } }
            source.onEvent?(.declined)
            XCTAssertEqual(failure, .declined)
            XCTAssertEqual(controller.state, .idle)
            XCTAssertEqual(source.stops, 1)
            XCTAssertNil(source.latest)
        }
    }

    @MainActor
    func testStartFailureContainsOnlyDomainAndCode() throws {
        try withController { controller, source, _, log in
            var failure: ScreenCaptureError?
            controller.requestFrame { if case .failure(let error) = $0 { failure = error } }
            source.grant()
            source.onEvent?(.failed(domain: "TestCapture", code: -42))
            XCTAssertEqual(failure, .failed("TestCapture (-42)"))
            XCTAssertEqual(controller.state, .idle)
            XCTAssertTrue(log.lines.contains { $0.primaryText.contains("開始失敗") && $0.fileLine.contains("code=-42") })
        }
    }

    @MainActor
    func testTimeoutWhenNoUsableFrameArrives() throws {
        try withController { controller, source, clock, _ in
            var failure: ScreenCaptureError?
            controller.requestFrame { if case .failure(let error) = $0 { failure = error } }
            source.grant()
            source.start(at: clock.date)
            clock.advance(7.99)
            controller.checkDeadlines()
            XCTAssertNil(failure)
            clock.advance(0.02)
            controller.checkDeadlines()
            XCTAssertEqual(failure, .timeout)
            XCTAssertEqual(controller.state, .idle)
            XCTAssertNil(source.latest)
        }
    }

    @MainActor
    func testPermissionWaitHasNoDeadlineAndStartWaitTimesOutFromGrant() throws {
        try withController { controller, source, clock, _ in
            var errors: [ScreenCaptureError] = []
            controller.requestFrame { if case .failure(let error) = $0 { errors.append(error) } }
            clock.advance(121)
            controller.checkDeadlines()
            controller.requestFrame { if case .failure(let error) = $0 { errors.append(error) } }
            clock.advance(300)
            controller.checkDeadlines()
            XCTAssertTrue(errors.isEmpty)
            XCTAssertEqual(controller.state, .requestingPermission)
            XCTAssertEqual(source.permissionRequests, 1)
            XCTAssertEqual(source.stops, 0)
            source.grant()
            clock.advance(7.99)
            controller.checkDeadlines()
            XCTAssertTrue(errors.isEmpty)
            clock.advance(0.01)
            controller.checkDeadlines()
            XCTAssertEqual(errors, [.timeout, .timeout])
            XCTAssertEqual(source.stops, 1)
        }
    }

    @MainActor
    func testLongPermissionWaitCanStillSucceed() throws {
        try withController { controller, source, clock, _ in
            var received: UIImage?
            controller.requestFrame {
                if case .failure(let error) = $0 { XCTFail("\(error)") }
                if case .success(let image) = $0 { received = image }
            }
            clock.advance(60)
            controller.checkDeadlines()
            source.grant()
            source.start(at: clock.date)
            clock.advance(1)
            let image = UIImage()
            source.frame(image, at: clock.date)
            XCTAssertTrue(received === image)
        }
    }

    @MainActor
    func testEarlyCompleteFollowedOnlyByIdleSucceeds() throws {
        try withController { controller, source, clock, _ in
            var received: UIImage?
            controller.requestFrame {
                if case .failure(let error) = $0 { XCTFail("\(error)") }
                if case .success(let image) = $0 { received = image }
            }
            source.grant()
            source.start(at: clock.date)
            clock.advance(0.1)
            let image = UIImage()
            source.frame(image, at: clock.date)
            clock.advance(0.4)
            source.idle(at: clock.date)
            XCTAssertNil(received)
            XCTAssertEqual(source.conversions, 0)
            clock.advance(0.2)
            source.idle(at: clock.date)
            XCTAssertTrue(received === image)
            XCTAssertEqual(source.conversions, 1)
        }
    }

    @MainActor
    func testInvalidationWaitsForNewCompleteInsteadOfReturningOldImage() throws {
        try withController { controller, source, clock, _ in
            controller.requestFrame { if case .failure(let error) = $0 { XCTFail("\(error)") } }
            source.grant()
            source.start(at: clock.date)
            clock.advance(1)
            source.frame(UIImage(), at: clock.date)
            source.invalidateFrame()
            var received: UIImage?
            controller.requestFrame {
                if case .failure(let error) = $0 { XCTFail("\(error)") }
                if case .success(let image) = $0 { received = image }
            }
            clock.advance(1)
            source.idle(at: clock.date)
            XCTAssertNil(received)
            XCTAssertEqual(source.conversions, 1)
            let next = UIImage()
            source.frame(next, at: clock.date)
            XCTAssertTrue(received === next)
            XCTAssertEqual(source.conversions, 2)
        }
    }

    @MainActor
    func testInvalidationDuringConversionDiscardsLateImageAndRetriesNewFrame() throws {
        try withController { controller, source, clock, _ in
            var received: UIImage?
            var completions = 0
            controller.requestFrame {
                completions += 1
                if case .failure(let error) = $0 { XCTFail("\(error)") }
                if case .success(let image) = $0 { received = image }
            }
            source.grant()
            source.start(at: clock.date)
            source.deferConversion = true
            clock.advance(1)
            let old = UIImage()
            source.frame(old, at: clock.date)
            let oldConversion = source.conversion
            source.invalidateFrame()
            clock.advance(1)
            let next = UIImage()
            source.frame(next, at: clock.date)
            oldConversion?(.success(old))
            XCTAssertEqual(completions, 0)
            XCTAssertEqual(source.conversions, 2)
            source.conversion?(.success(next))
            XCTAssertEqual(completions, 1)
            XCTAssertTrue(received === next)
        }
    }

    @MainActor
    func testUnavailableConversionWaitsForNextFrameWithinOriginalDeadline() throws {
        try withController { controller, source, clock, _ in
            var results: [Result<UIImage, ScreenCaptureError>] = []
            controller.requestFrame { results.append($0) }
            source.grant()
            source.start(at: clock.date)
            source.deferConversion = true
            clock.advance(1)
            source.frame(UIImage(), at: clock.date)
            source.conversion?(.unavailable)
            XCTAssertTrue(results.isEmpty)
            XCTAssertEqual(controller.state, .running)
            clock.advance(7)
            controller.checkDeadlines()
            XCTAssertEqual(results.count, 1)
            guard case .failure(.timeout)? = results.first else { return XCTFail("Expected timeout") }
        }
    }

    @MainActor
    func testRunningRequestUsesNewestFrameWithoutPermissionAgain() throws {
        try withController { controller, source, clock, _ in
            controller.requestFrame { if case .failure(let error) = $0 { XCTFail("\(error)") } }
            source.grant()
            source.start(at: clock.date)
            clock.advance(1)
            source.frame(UIImage(), at: clock.date)
            let newest = UIImage()
            clock.advance(1)
            source.frame(newest, at: clock.date)
            XCTAssertEqual(source.conversions, 1) // Idle streaming does not convert images.
            var received: UIImage?
            controller.requestFrame { result in
                if case .failure(let error) = result { XCTFail("\(error)") }
                if case .success(let image) = result { received = image }
            }
            XCTAssertTrue(received === newest)
            XCTAssertEqual(source.permissionRequests, 1)
            XCTAssertEqual(source.conversions, 2)
        }
    }

    @MainActor
    func testSceneInactiveDiscardsFrameAndRequiresNewPermissionOnReturn() throws {
        try withController { controller, source, clock, _ in
            controller.requestFrame { if case .failure(let error) = $0 { XCTFail("\(error)") } }
            source.grant()
            source.start(at: clock.date)
            clock.advance(1)
            source.frame(UIImage(), at: clock.date)
            controller.sceneDidChange(isActive: false)
            XCTAssertEqual(controller.state, .idle)
            XCTAssertNil(source.latest)
            controller.requestFrame {
                guard case .failure(.failed("scene inactive")) = $0 else { return XCTFail("Expected inactive failure") }
            }
            XCTAssertEqual(source.permissionRequests, 1)
            controller.sceneDidChange(isActive: true)
            var returnedOldFrame = false
            controller.requestFrame { if case .success = $0 { returnedOldFrame = true } }
            XCTAssertEqual(source.permissionRequests, 2)
            XCTAssertFalse(returnedOldFrame)
            XCTAssertEqual(controller.state, .requestingPermission)
        }
    }

    @MainActor
    func testFiveMinuteStopIsResetByCaptureUse() throws {
        try withController { controller, source, clock, _ in
            controller.requestFrame { if case .failure(let error) = $0 { XCTFail("\(error)") } }
            source.grant()
            source.start(at: clock.date)
            clock.advance(1)
            source.frame(UIImage(), at: clock.date)
            controller.noteCaptureUsed()
            clock.advance(299)
            controller.checkDeadlines()
            XCTAssertEqual(controller.state, .running)
            controller.noteCaptureUsed()
            clock.advance(299)
            controller.checkDeadlines()
            XCTAssertEqual(controller.state, .running)
            clock.advance(1)
            controller.checkDeadlines()
            XCTAssertEqual(controller.state, .idle)
            XCTAssertNil(source.latest)
        }
    }

    @MainActor
    func testOverlappingRequestsShareOneConversionAndSameImage() throws {
        try withController { controller, source, clock, _ in
            var images: [UIImage] = []
            let receive: @MainActor (Result<UIImage, ScreenCaptureError>) -> Void = { result in
                if case .failure(let error) = result { XCTFail("\(error)") }
                if case .success(let image) = result { images.append(image) }
            }
            controller.requestFrame(completion: receive)
            controller.requestFrame(completion: receive)
            source.grant()
            controller.requestFrame(completion: receive)
            source.start(at: clock.date)
            source.deferConversion = true
            clock.advance(1)
            let image = UIImage()
            source.frame(image, at: clock.date)
            controller.requestFrame(completion: receive)
            source.conversion?(.success(image))
            XCTAssertEqual(images.count, 4)
            XCTAssertTrue(images.allSatisfy { $0 === image })
            XCTAssertEqual(source.permissionRequests, 1)
            XCTAssertEqual(source.conversions, 1)
        }
    }

    @MainActor
    func testOverlappingRequestsShareFailure() throws {
        try withController { controller, source, _, _ in
            var errors: [ScreenCaptureError] = []
            for _ in 0..<2 {
                controller.requestFrame { if case .failure(let error) = $0 { errors.append(error) } }
            }
            source.onEvent?(.declined)
            XCTAssertEqual(errors, [.declined, .declined])
        }
    }

    @MainActor
    func testStopDuringConversionIgnoresLateResultAndOldEvents() throws {
        try withController { controller, source, clock, _ in
            var completions = 0
            controller.requestFrame { _ in completions += 1 }
            let oldEvents = source.onEvent
            source.grant()
            source.start(at: clock.date)
            source.deferConversion = true
            clock.advance(1)
            source.frame(UIImage(), at: clock.date)
            let oldConversion = source.conversion
            controller.stop(reason: "manual")
            XCTAssertEqual(completions, 1)
            XCTAssertNil(source.latest)
            controller.requestFrame { _ in completions += 1 }
            oldConversion?(.success(UIImage()))
            oldEvents?(.declined)
            oldEvents?(.started(clock.date))
            XCTAssertEqual(completions, 1)
            XCTAssertEqual(controller.state, .requestingPermission)
        }
    }

    @MainActor
    func testStreamErrorStopsAndDiscardsFrame() throws {
        try withController { controller, source, clock, log in
            controller.requestFrame { if case .failure(let error) = $0 { XCTFail("\(error)") } }
            source.grant()
            source.start(at: clock.date)
            clock.advance(1)
            source.frame(UIImage(), at: clock.date)
            source.onEvent?(.failed(domain: "TestCapture", code: -3824))
            XCTAssertEqual(controller.state, .idle)
            XCTAssertNil(source.latest)
            XCTAssertTrue(log.lines.contains { $0.primaryText.contains("映像停止") && $0.fileLine.contains("-3824") })
        }
    }

    @MainActor
    func testSceneInactiveWhileWaitingCompletesEveryRequest() throws {
        try withController { controller, source, _, _ in
            var errors: [ScreenCaptureError] = []
            for _ in 0..<2 {
                controller.requestFrame { if case .failure(let error) = $0 { errors.append(error) } }
            }
            source.grant()
            controller.sceneDidChange(isActive: false)
            XCTAssertEqual(errors, [.failed("scene inactive"), .failed("scene inactive")])
            XCTAssertEqual(controller.state, .idle)
            XCTAssertEqual(source.stops, 1)
        }
    }

    @MainActor
    func testConversionCannotReturnSuccessAfterDeadline() throws {
        try withController { controller, source, clock, _ in
            var results = 0
            var failure: ScreenCaptureError?
            controller.requestFrame {
                results += 1
                if case .failure(let error) = $0 { failure = error }
            }
            source.grant()
            source.start(at: clock.date)
            source.deferConversion = true
            clock.advance(1)
            source.frame(UIImage(), at: clock.date)
            clock.advance(7)
            source.conversion?(.success(UIImage()))
            XCTAssertEqual(failure, .timeout)
            XCTAssertEqual(results, 1)
            XCTAssertEqual(controller.state, .idle)
        }
    }

    @MainActor
    func testPickerCancellationWhileRunningDiscardsLatestFrame() throws {
        try withController { controller, source, clock, _ in
            controller.requestFrame { if case .failure(let error) = $0 { XCTFail("\(error)") } }
            source.grant()
            source.start(at: clock.date)
            clock.advance(1)
            source.frame(UIImage(), at: clock.date)
            source.onEvent?(.declined)
            XCTAssertEqual(controller.state, .idle)
            XCTAssertNil(source.latest)
            XCTAssertEqual(source.stops, 1)
        }
    }

    @MainActor
    func testUnsupportedSourceNeverPresentsPicker() throws {
        try withController(supported: false) { controller, source, _, _ in
            XCTAssertFalse(controller.isSupported)
            XCTAssertEqual(controller.state, .unsupported)
            var failure: ScreenCaptureError?
            controller.requestFrame { if case .failure(let error) = $0 { failure = error } }
            XCTAssertEqual(failure, .unsupported)
            controller.stop(reason: "manual")
            controller.sceneDidChange(isActive: false)
            XCTAssertEqual(controller.state, .unsupported)
            XCTAssertEqual(source.permissionRequests, 0)
            XCTAssertEqual(source.stops, 0)
        }
    }

    @MainActor
    func testBurstStopsOnlyStreamAndNextRequestResumesAfterSettling() throws {
        try withController(strategy: .burst) { controller, source, clock, log in
            var images: [UIImage] = []
            let receive: @MainActor (Result<UIImage, ScreenCaptureError>) -> Void = {
                if case .failure(let error) = $0 { XCTFail("\(error)") }
                if case .success(let image) = $0 { images.append(image) }
            }
            controller.requestFrame(completion: receive)
            source.reactivatesOnGrant = false
            source.grant()
            source.start(at: clock.date)
            clock.advance(0.7)
            source.frame(UIImage(), at: clock.date)
            XCTAssertTrue(images.isEmpty) // First burst still waits for the permission screen.
            controller.sceneDidActivate()
            clock.advance(0.5)
            source.frame(UIImage(), at: clock.date)
            XCTAssertEqual(images.count, 1)
            XCTAssertEqual(controller.state, .ready)
            XCTAssertTrue(source.hasFilter)
            XCTAssertEqual(source.streamStops, 1)
            XCTAssertEqual(source.stops, 0)
            XCTAssertNil(source.latest)

            controller.requestFrame(completion: receive)
            XCTAssertEqual(controller.state, .starting)
            XCTAssertEqual(source.resumes, 1)
            XCTAssertEqual(source.permissionRequests, 1)
            source.start(at: clock.date)
            clock.advance(0.59)
            source.frame(UIImage(), at: clock.date)
            XCTAssertEqual(images.count, 1)
            clock.advance(0.02)
            let next = UIImage()
            source.frame(next, at: clock.date)
            XCTAssertTrue(images.last === next)
            XCTAssertEqual(images.count, 2)
            XCTAssertEqual(controller.state, .ready)
            XCTAssertEqual(source.streamStops, 2)
            XCTAssertTrue(log.lines.contains { $0.fileLine.contains("resume_ms=") })
            XCTAssertTrue(log.lines.contains { $0.primaryText.contains("再開成功") })
        }
    }

    @MainActor
    func testBurstResumeFailuresRetryPermissionWithinSameRequest() throws {
        // Start error, stream error after start, and no-frame timeout each fall back once.
        for failure in 0..<3 {
            try withController(strategy: .burst) { controller, source, clock, log in
                controller.requestFrame { if case .failure(let error) = $0 { XCTFail("\(error)") } }
                source.grant()
                source.start(at: clock.date)
                clock.advance(1)
                source.frame(UIImage(), at: clock.date)
                var results: [Result<UIImage, ScreenCaptureError>] = []
                controller.requestFrame { results.append($0) }
                let oldEvents = source.onEvent
                if failure == 0 {
                    source.onEvent?(.failed(domain: "TestResume", code: -42))
                } else {
                    source.start(at: clock.date)
                    if failure == 1 { source.onEvent?(.failed(domain: "TestResume", code: -43)) }
                    else { clock.advance(8); controller.checkDeadlines() }
                }
                XCTAssertTrue(results.isEmpty)
                XCTAssertEqual(source.permissionRequests, 2)
                XCTAssertEqual(source.resumes, 1)
                XCTAssertFalse(source.hasFilter)
                XCTAssertEqual(controller.state, .requestingPermission)
                oldEvents?(.failed(domain: "LateOldStream", code: -99))
                XCTAssertEqual(controller.state, .requestingPermission)
                source.grant()
                source.start(at: clock.date)
                clock.advance(1)
                source.frame(UIImage(), at: clock.date)
                XCTAssertEqual(results.count, 1)
                if case .failure(let error)? = results.first { XCTFail("\(error)") }
                XCTAssertEqual(controller.state, .ready)
                XCTAssertTrue(log.lines.contains { $0.primaryText.contains("再開失敗") && $0.fileLine.contains("code=") })
            }
        }
    }

    @MainActor
    func testBurstFallbackFailureCompletesInsteadOfRetryingForever() throws {
        try withController(strategy: .burst) { controller, source, clock, _ in
            controller.requestFrame { if case .failure(let error) = $0 { XCTFail("\(error)") } }
            source.grant()
            source.start(at: clock.date)
            clock.advance(1)
            source.frame(UIImage(), at: clock.date)
            var results: [Result<UIImage, ScreenCaptureError>] = []
            controller.requestFrame { results.append($0) }
            source.onEvent?(.failed(domain: "Resume", code: 1))
            source.grant()
            source.onEvent?(.failed(domain: "FreshStart", code: 2))
            XCTAssertEqual(results.count, 1)
            guard case .failure(.failed("FreshStart (2)"))? = results.first else { return XCTFail("Expected failure") }
            XCTAssertEqual(source.permissionRequests, 2)
            XCTAssertEqual(controller.state, .idle)
        }
    }

    @MainActor
    func testBurstReadyDiscardsFilterOnBackgroundManualStopAndStrategyChange() throws {
        for action in 0..<3 {
            try withController(strategy: .burst) { controller, source, clock, _ in
                controller.requestFrame { if case .failure(let error) = $0 { XCTFail("\(error)") } }
                source.grant()
                source.start(at: clock.date)
                clock.advance(1)
                source.frame(UIImage(), at: clock.date)
                if action == 0 { controller.sceneDidChange(isActive: false) }
                if action == 1 { controller.stop(reason: "manual") }
                if action == 2 { controller.setStrategy(.continuous) }
                XCTAssertEqual(controller.state, .idle)
                XCTAssertFalse(source.hasFilter)
                XCTAssertEqual(source.stops, 1)
                controller.sceneDidChange(isActive: true)
                controller.requestFrame { _ in }
                XCTAssertEqual(source.permissionRequests, 2)
            }
        }
    }

    @MainActor
    func testBurstReadyExpiresFiveMinutesAfterLastUse() throws {
        try withController(strategy: .burst) { controller, source, clock, _ in
            controller.requestFrame { if case .failure(let error) = $0 { XCTFail("\(error)") } }
            source.grant()
            source.start(at: clock.date)
            clock.advance(1)
            source.frame(UIImage(), at: clock.date)
            clock.advance(299)
            controller.checkDeadlines()
            XCTAssertEqual(controller.state, .ready)
            controller.noteCaptureUsed()
            clock.advance(299)
            controller.checkDeadlines()
            XCTAssertTrue(source.hasFilter)
            clock.advance(1)
            controller.checkDeadlines()
            XCTAssertEqual(controller.state, .idle)
            XCTAssertFalse(source.hasFilter)
        }
    }

    @MainActor
    func testBurstOverlappingRequestsWaitForStopAndCanRequestAgainInCompletion() throws {
        try withController(strategy: .burst) { controller, source, clock, _ in
            var delivered = 0
            controller.requestFrame { result in
                if case .failure(let error) = result { XCTFail("\(error)") }
                delivered += 1
                controller.requestFrame { _ in } // Must start a fresh burst, not use the old frame.
            }
            source.grant()
            source.start(at: clock.date)
            source.deferStop = true
            clock.advance(1)
            source.frame(UIImage(), at: clock.date)
            controller.requestFrame { result in
                if case .failure(let error) = result { XCTFail("\(error)") }
                delivered += 1
            }
            XCTAssertEqual(delivered, 0)
            XCTAssertEqual(source.streamStops, 1)
            source.stopped?()
            XCTAssertEqual(delivered, 2)
            XCTAssertEqual(source.resumes, 1)
            XCTAssertEqual(source.permissionRequests, 1)
            XCTAssertEqual(controller.state, .starting)
        }
    }

    @MainActor
    func testBurstStopCompletionCannotDeliverAfterBackgrounding() throws {
        try withController(strategy: .burst) { controller, source, clock, _ in
            var results: [Result<UIImage, ScreenCaptureError>] = []
            controller.requestFrame { results.append($0) }
            source.grant()
            source.start(at: clock.date)
            source.deferStop = true
            clock.advance(1)
            source.frame(UIImage(), at: clock.date)
            XCTAssertTrue(results.isEmpty)
            controller.sceneDidChange(isActive: false)
            source.stopped?()
            XCTAssertEqual(results.count, 1)
            guard case .failure? = results.first else { return XCTFail("Expected stopped request") }
            XCTAssertEqual(controller.state, .idle)
        }
    }

    @MainActor
    func testStrategyPersistenceDefaultAndSwitchStopsContinuous() throws {
        try withController { controller, source, clock, log in
            XCTAssertEqual(controller.strategy, .continuous)
            controller.requestFrame { if case .failure(let error) = $0 { XCTFail("\(error)") } }
            source.grant()
            source.start(at: clock.date)
            clock.advance(1)
            source.frame(UIImage(), at: clock.date)
            controller.setStrategy(.burst)
            XCTAssertEqual(controller.state, .idle)
            XCTAssertEqual(source.stops, 1)
            let suite = "StrategyPersistence.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let first = ScreenCaptureController(log: log, defaults: defaults, source: FakeScreenCaptureSource(), schedulesTimers: false)
            XCTAssertEqual(first.strategy, .continuous)
            first.setStrategy(.burst)
            XCTAssertEqual(defaults.string(forKey: "screenCaptureStrategy"), "burst")
            let second = ScreenCaptureController(log: log, defaults: defaults, source: FakeScreenCaptureSource(), schedulesTimers: false)
            XCTAssertEqual(second.strategy, .burst)
            defaults.set("unknown", forKey: "screenCaptureStrategy")
            let fallback = ScreenCaptureController(log: log, defaults: defaults, source: FakeScreenCaptureSource(), schedulesTimers: false)
            XCTAssertEqual(fallback.strategy, .continuous)
        }
    }

    // MARK: The first capture after approval

    @MainActor
    func testFirstFrameWaitsUntilThePermissionScreenHasGone() throws {
        try withController { controller, source, clock, log in
            source.reactivatesOnGrant = false
            var result: Result<UIImage, ScreenCaptureError>?
            controller.requestFrame { result = $0 }
            source.grant()
            source.start(at: clock.date)
            // The permission screen is still closing: frames now must not be used.
            clock.advance(1.0)
            source.frame(UIImage(), at: clock.date)
            XCTAssertNil(result)
            // The app becomes active again as the screen goes away.
            clock.advance(0.8)
            controller.sceneDidActivate()
            source.frame(UIImage(), at: clock.date)
            XCTAssertNil(result, "a frame from the moment of reactivation can still show the closing screen")
            clock.advance(0.5)
            let clean = UIImage()
            source.frame(clean, at: clock.date)
            guard case .success(let image)? = result else { return XCTFail("expected a frame, got \(String(describing: result))") }
            XCTAssertTrue(image === clean)
            XCTAssertTrue(log.lines.contains { $0.primaryText.contains("許可後に前面へ復帰") })
        }
    }

    @MainActor
    func testFirstFrameFallsBackToAFixedWaitWhenReactivationIsNeverSeen() throws {
        try withController { controller, source, clock, _ in
            source.reactivatesOnGrant = false
            var result: Result<UIImage, ScreenCaptureError>?
            controller.requestFrame { result = $0 }
            source.grant()
            source.start(at: clock.date)
            clock.advance(2.4)
            source.frame(UIImage(), at: clock.date)
            XCTAssertNil(result)
            clock.advance(0.1)
            let clean = UIImage()
            source.frame(clean, at: clock.date)
            guard case .success(let image)? = result else { return XCTFail("expected a frame, got \(String(describing: result))") }
            XCTAssertTrue(image === clean)
        }
    }

    @MainActor
    func testLaterCapturesInTheSameSessionDoNotWaitAgain() throws {
        try withController { controller, source, clock, _ in
            var first: Result<UIImage, ScreenCaptureError>?
            controller.requestFrame { first = $0 }
            source.grant()
            source.start(at: clock.date)
            clock.advance(1)
            source.frame(UIImage(), at: clock.date)
            guard case .success? = first else { return XCTFail("expected the first frame") }
            // Switching to another app and back must not delay the next capture.
            controller.sceneDidActivate()
            clock.advance(0.05)
            let next = UIImage()
            source.frame(next, at: clock.date)
            var second: Result<UIImage, ScreenCaptureError>?
            controller.requestFrame { second = $0 }
            guard case .success(let image)? = second else { return XCTFail("expected an immediate frame, got \(String(describing: second))") }
            XCTAssertTrue(image === next)
        }
    }
}

#if canImport(ScreenCaptureKit)
@available(iOS 27.0, *)
final class ScreenCaptureFrameBufferTests: XCTestCase {
    private func makePixels() throws -> CVPixelBuffer {
        var pixels: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 12, 8,
                                        kCVPixelFormatType_32BGRA, nil, &pixels)
        XCTAssertEqual(status, kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixels)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        memset(base, 0, CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
        return buffer
    }

    private func makeBuffer(queue: DispatchQueue = DispatchQueue(label: "test.screen-conversion")) -> ScreenCaptureFrameBuffer {
        ScreenCaptureFrameBuffer(context: CIContext(options: [.useSoftwareRenderer: true]),
                                 conversionQueue: queue)
    }

    @MainActor
    private func convert(_ frames: ScreenCaptureFrameBuffer, notBefore: Date) throws -> UIImage? {
        let done = expectation(description: "frame converted")
        var result: ScreenCaptureFrameResult?
        frames.convert(notBefore: notBefore) {
            result = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        switch try XCTUnwrap(result) {
        case .success(let image): return image
        case .unavailable: return nil
        case .failure(let error):
            XCTFail("Unexpected conversion failure: \(error)")
            return nil
        }
    }

    func testVideoOrientationUsesImageIOValuesIncludingMirrorsAndDefaultsToUp() {
        let orientations: [CGImagePropertyOrientation] = [
            .up, .upMirrored, .down, .downMirrored,
            .leftMirrored, .right, .rightMirrored, .left
        ]
        for (index, orientation) in orientations.enumerated() {
            // CMSampleBuffer attachments bridge CFNumber to NSNumber.
            XCTAssertEqual(ScreenCaptureFrameBuffer.orientation(NSNumber(value: index + 1)), orientation)
            XCTAssertEqual(ScreenCaptureFrameBuffer.orientation(UInt32(index + 1)), orientation)
            XCTAssertEqual(ScreenCaptureFrameBuffer.orientation(orientation), orientation)
        }
        let invalidValues: [Any?] = [nil, 0, 9, -1, "right"]
        for value in invalidValues {
            XCTAssertEqual(ScreenCaptureFrameBuffer.orientation(value), .up)
        }
    }

    @MainActor
    func testConversionAppliesOrientationToPixelsAndPreservesPointScale() throws {
        let pixels = try makePixels()
        let frames = makeBuffer()
        defer { frames.clear() }
        let date = Date(timeIntervalSince1970: 100)
        frames.receive(status: .complete, pixels: pixels, orientation: .right,
                       pointPixelScale: 2, at: date)
        let image = try XCTUnwrap(convert(frames, notBefore: date))
        XCTAssertEqual(image.imageOrientation, .up)
        XCTAssertEqual(image.cgImage?.width, 8)
        XCTAssertEqual(image.cgImage?.height, 12)
        XCTAssertEqual(image.scale, 2)
        XCTAssertEqual(image.size, CGSize(width: 4, height: 6))
    }

    @MainActor
    func testImageScaleUsesPointPixelScaleOrOneForInvalidValues() throws {
        let pixels = try makePixels()
        let frames = makeBuffer()
        defer { frames.clear() }
        let date = Date(timeIntervalSince1970: 100)
        let cases: [(CGFloat, CGFloat)] = [(2, 2), (3, 3), (0, 1), (-1, 1),
                                          (.nan, 1), (.infinity, 1), (-.infinity, 1)]
        for (scale, expected) in cases {
            frames.receive(status: .complete, pixels: pixels, pointPixelScale: scale, at: date)
            let image = try XCTUnwrap(convert(frames, notBefore: date))
            XCTAssertEqual(image.scale, expected)
            XCTAssertEqual(image.size, CGSize(width: 12 / expected, height: 8 / expected))
        }
    }

    @MainActor
    func testIdleRefreshesEarlyCompleteWithoutLosingOrientationOrScale() throws {
        let frames = makeBuffer()
        defer { frames.clear() }
        let start = Date(timeIntervalSince1970: 100)
        let threshold = start.addingTimeInterval(0.6)
        frames.receive(status: .complete, pixels: try makePixels(), orientation: .left,
                       pointPixelScale: 2, at: start.addingTimeInterval(0.1))
        XCTAssertNil(try convert(frames, notBefore: threshold))
        frames.receive(status: .idle, at: start.addingTimeInterval(0.7))
        let image = try XCTUnwrap(convert(frames, notBefore: threshold))
        XCTAssertEqual(image.cgImage?.width, 8)
        XCTAssertEqual(image.cgImage?.height, 12)
        XCTAssertEqual(image.scale, 2)
    }

    @MainActor
    func testInvalidStatusesDiscardPixelsAndIdleCannotReviveThem() throws {
        let date = Date(timeIntervalSince1970: 100)
        let invalidStatuses: [SCFrameStatus] = [.blank, .suspended, .stopped]
        for status in invalidStatuses {
            let frames = makeBuffer()
            defer { frames.clear() }
            let pixels = try makePixels()
            frames.receive(status: .complete, pixels: pixels, at: date)
            XCTAssertNotNil(try convert(frames, notBefore: date))
            frames.receive(status: status, at: date.addingTimeInterval(1))
            frames.receive(status: .idle, at: date.addingTimeInterval(2))
            XCTAssertNil(try convert(frames, notBefore: date))
            frames.receive(status: .complete, pixels: pixels, at: date.addingTimeInterval(3))
            XCTAssertNotNil(try convert(frames, notBefore: date))
        }
    }

    @MainActor
    func testIdleWithoutCompleteDoesNotInventFrame() throws {
        let frames = makeBuffer()
        defer { frames.clear() }
        let date = Date(timeIntervalSince1970: 100)
        frames.receive(status: .idle, at: date)
        XCTAssertNil(try convert(frames, notBefore: date))
    }

    @MainActor
    func testInvalidationAfterConversionBeforeDeliveryDiscardsImage() throws {
        let queue = DispatchQueue(label: "test.screen-conversion-race")
        let frames = makeBuffer(queue: queue)
        defer { frames.clear() }
        let date = Date(timeIntervalSince1970: 100)
        frames.receive(status: .complete, pixels: try makePixels(), at: date)
        let done = expectation(description: "invalidated conversion")
        frames.convert(notBefore: date) {
            if case .unavailable = $0 {} else { XCTFail("Expected unavailable frame") }
            done.fulfill()
        }
        // Finish conversion while the main queue's delivery is still blocked
        // by this test, then invalidate the pixels before delivery can run.
        queue.sync {}
        frames.receive(status: .blank, at: date.addingTimeInterval(1))
        wait(for: [done], timeout: 5)
    }

    @MainActor
    func testCoalescingPreservesInvalidationBeforeReplacementFrame() throws {
        let frames = makeBuffer()
        defer { frames.clear() }
        let date = Date(timeIntervalSince1970: 100)
        let pixels = try makePixels()
        frames.receive(status: .complete, pixels: pixels, at: date)
        _ = try convert(frames, notBefore: date) // Drain the first notification.
        let done = expectation(description: "invalidation then replacement")
        done.expectedFulfillmentCount = 2
        var events: [String] = []
        frames.onEvent = {
            switch $0 {
            case .frameInvalidated: events.append("invalidated")
            case .frameReceived: events.append("frame")
            default: XCTFail("Unexpected event")
            }
            done.fulfill()
        }
        frames.receive(status: .suspended, at: date.addingTimeInterval(1))
        frames.receive(status: .complete, pixels: pixels, at: date.addingTimeInterval(2))
        wait(for: [done], timeout: 5)
        XCTAssertEqual(events, ["invalidated", "frame"])
    }
}
#endif
