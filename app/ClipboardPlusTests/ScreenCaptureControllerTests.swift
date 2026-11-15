import UIKit
import XCTest
@testable import ClipboardPlus

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
    var conversions = 0
    var latest: UIImage?
    var latestDate: Date?
    var deferConversion = false
    var conversion: (@MainActor (Result<UIImage, ScreenCaptureError>) -> Void)?

    func requestPermission() { permissionRequests += 1 }
    func stop() {
        stops += 1
        latest = nil
        latestDate = nil
    }
    func grant() {
        onEvent?(.permissionGranted(contentRect: CGRect(x: 0, y: 0, width: 100, height: 200),
                                    pointPixelScale: 2))
    }
    func start(at date: Date) { onEvent?(.started(date)) }
    func frame(_ image: UIImage, at date: Date) {
        latest = image
        latestDate = date
        onEvent?(.frameReceived(at: date, width: 200, height: 400))
    }
    func convertLatestFrame(notBefore: Date,
                            completion: @escaping @MainActor (Result<UIImage, ScreenCaptureError>) -> Void) {
        conversions += 1
        guard let latest, let latestDate, latestDate >= notBefore else {
            completion(.failure(.failed("no usable frame")))
            return
        }
        if deferConversion { conversion = completion }
        else { completion(.success(latest)) }
    }
}

final class ScreenCaptureControllerTests: XCTestCase {
    @MainActor
    private func withController(supported: Bool = true,
                                _ body: (ScreenCaptureController, FakeScreenCaptureSource,
                                         CaptureTestClock, MeasurementLog) throws -> Void) throws {
        let root = try ImageTestSupport.directory(self)
        let log = MeasurementLog(writer: MeasurementLogWriter(fileURL: root.appendingPathComponent("capture-log.tsv")))
        let source = FakeScreenCaptureSource()
        source.isSupported = supported
        let clock = CaptureTestClock()
        let controller = ScreenCaptureController(log: log, now: { clock.date }, source: source,
                                                 schedulesTimers: false)
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
    func testPermissionAndStartWaitsAlsoTimeOut() throws {
        for grant in [false, true] {
            try withController { controller, source, clock, _ in
                var failure: ScreenCaptureError?
                controller.requestFrame { if case .failure(let error) = $0 { failure = error } }
                if grant { source.grant() }
                clock.advance(8)
                controller.checkDeadlines()
                XCTAssertEqual(failure, .timeout)
                XCTAssertEqual(source.stops, 1)
            }
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
}
