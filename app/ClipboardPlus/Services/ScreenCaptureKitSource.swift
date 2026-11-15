#if canImport(ScreenCaptureKit)
import CoreImage
import CoreMedia
import CoreVideo
import ImageIO
import ScreenCaptureKit
import UIKit

@available(iOS 27.0, *)
@MainActor
final class ScreenCaptureKitSource: ScreenCaptureSource {
    let isSupported = true
    var onEvent: (@MainActor (ScreenCaptureSourceEvent) -> Void)?
    private let conversionQueue = DispatchQueue(label: "clipboardplus.screen-conversion", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var session: ScreenCaptureKitSession?

    func requestPermission() {
        stop()
        let session = ScreenCaptureKitSession(context: context, conversionQueue: conversionQueue) { [weak self] event in
            self?.onEvent?(event)
        }
        self.session = session
        session.present()
    }

    func stop() {
        session?.close()
        session = nil
    }

    func convertLatestFrame(notBefore: Date,
                            completion: @escaping @MainActor (ScreenCaptureFrameResult) -> Void) {
        guard let session else { completion(.failure(.failed("capture stopped"))); return }
        session.frames.convert(notBefore: notBefore, completion: completion)
    }
}

// One observer per permission session. Late picker callbacks (including those
// with a nil stream) can never start a later session by accident.
@available(iOS 27.0, *)
@MainActor
private final class ScreenCaptureKitSession: NSObject, SCContentSharingPickerObserver, SCStreamDelegate {
    let frames: ScreenCaptureFrameBuffer
    private let event: @MainActor (ScreenCaptureSourceEvent) -> Void
    private var stream: SCStream?
    private var output: ScreenCaptureOutput?
    private var active = true
    private let sampleQueue = DispatchQueue(label: "clipboardplus.screen-samples", qos: .userInitiated)

    init(context: CIContext, conversionQueue: DispatchQueue,
         event: @escaping @MainActor (ScreenCaptureSourceEvent) -> Void) {
        self.event = event
        frames = ScreenCaptureFrameBuffer(context: context, conversionQueue: conversionQueue)
        super.init()
        frames.onEvent = { [weak self] event in
            guard let self, self.active else { return }
            self.event(event)
        }
    }

    func present() {
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        // Apple's iOS sample uses present() for full-display selection. Keep the
        // default allowed modes: singleDisplay's documentation still lists iOS
        // as unavailable, unlike allowedPickerModes itself.
        configuration.showsMicrophoneControl = false
        configuration.showsCameraControl = false
        // allowsChangingSelectedContent and excludedBundleIDs exist in the documentation,
        // but the iOS 27.1 device SDK marks them unavailable (the simulator SDK does not).
        picker.defaultConfiguration = configuration
        picker.add(self)
        picker.isActive = true
        picker.present()
    }

    func close() {
        guard active else { return }
        active = false
        frames.clear()
        let picker = SCContentSharingPicker.shared
        picker.remove(self)
        picker.isActive = false
        let previous = stream
        stream = nil
        output = nil
        previous?.stopCapture(completionHandler: nil)
    }

    private func begin(filter: SCContentFilter) {
        guard active, stream == nil else { return }
        let rect = filter.contentRect
        let pointPixelScale = CGFloat(filter.pointPixelScale)
        let scale = ScreenCaptureFrameBuffer.imageScale(pointPixelScale)
        event(.permissionGranted(contentRect: rect, pointPixelScale: pointPixelScale))
        // The callback may synchronously stop this session.
        guard active else { return }
        let width = (rect.width * scale).rounded()
        let height = (rect.height * scale).rounded()
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              width < CGFloat(Int.max), height < CGFloat(Int.max) else {
            event(.failed(domain: "ScreenCapture.InvalidContentSize", code: 1))
            return
        }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(width)
        configuration.height = Int(height)
        // minimumFrameInterval, queueDepth, pixelFormat, showsCursor and scalesToFit are
        // unavailable in the iOS 27.1 device SDK, so the system decides the frame rate and
        // pixel format. Only the newest frame is kept, and it is converted only on request.
        configuration.capturesAudio = false
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        self.stream = stream
        let output = ScreenCaptureOutput(frames: frames, pointPixelScale: scale)
        self.output = output
        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleQueue)
        } catch {
            report(error)
            return
        }
        stream.startCapture { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.active, self.stream === stream else {
                    // stop() can race an outstanding startCapture completion.
                    stream.stopCapture(completionHandler: nil)
                    return
                }
                if let error { self.report(error) }
                else { self.event(.started(Date())) }
            }
        }
    }

    private func report(_ error: Error) {
        guard active else { return }
        let error = error as NSError
        // Avoid localizedDescription/userInfo: these can include private paths.
        event(.failed(domain: error.domain, code: error.code))
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker,
                                         didCancelFor stream: SCStream?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active,
                  stream == nil || self.stream === stream else { return }
            self.event(.declined)
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker,
                                         didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active, stream == nil || self.stream === stream else { return }
            self.begin(filter: filter)
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        DispatchQueue.main.async { [weak self] in self?.report(error) }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.report(error)
        }
    }
}

@available(iOS 27.0, *)
private final class ScreenCaptureOutput: NSObject, SCStreamOutput {
    private let frames: ScreenCaptureFrameBuffer
    private let pointPixelScale: CGFloat
    init(frames: ScreenCaptureFrameBuffer, pointPixelScale: CGFloat) {
        self.frames = frames
        self.pointPixelScale = pointPixelScale
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let rawStatus = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else { return }
        // Status-only samples need not have ready image data (or a buffer).
        let pixels = CMSampleBufferDataIsReady(sampleBuffer) ? CMSampleBufferGetImageBuffer(sampleBuffer) : nil
        frames.receive(status: status, pixels: pixels,
                       orientation: ScreenCaptureFrameBuffer.orientation(info[.videoOrientation]),
                       pointPixelScale: pointPixelScale, at: Date())
    }
}

// The sample queue, conversion queue and main actor share this single slot.
// Notifications carry no buffers and are coalesced if the main thread is busy.
@available(iOS 27.0, *)
final class ScreenCaptureFrameBuffer {
    @MainActor var onEvent: (@MainActor (ScreenCaptureSourceEvent) -> Void)?
    private let lock = NSLock()
    private struct Frame {
        let pixels: CVPixelBuffer
        var date: Date
        let orientation: CGImagePropertyOrientation
        let scale: CGFloat
    }
    private var latest: Frame?
    private var validity = UUID()
    // Kept separately from the coalesced frame notification, so a temporary
    // invalidation is still delivered even if a new complete frame follows it.
    private var invalidationPending = false
    private var active = true
    private var notificationPending = false
    private let context: CIContext
    private let conversionQueue: DispatchQueue

    init(context: CIContext, conversionQueue: DispatchQueue) {
        self.context = context
        self.conversionQueue = conversionQueue
    }

    static func orientation(_ value: Any?) -> CGImagePropertyOrientation {
        if let orientation = value as? CGImagePropertyOrientation { return orientation }
        guard let rawValue = value as? UInt32 else { return .up }
        return CGImagePropertyOrientation(rawValue: rawValue) ?? .up
    }

    static func imageScale(_ value: CGFloat) -> CGFloat {
        value.isFinite && value > 0 ? value : 1
    }

    func receive(status: SCFrameStatus, pixels: CVPixelBuffer? = nil,
                 orientation: CGImagePropertyOrientation = .up,
                 pointPixelScale: CGFloat = 1, at date: Date) {
        lock.lock()
        guard active else { lock.unlock(); return }
        switch status {
        case .complete:
            guard let pixels else { lock.unlock(); return }
            latest = Frame(pixels: pixels, date: date, orientation: orientation,
                           scale: Self.imageScale(pointPixelScale))
        case .idle:
            guard latest != nil else { lock.unlock(); return }
            // The retained complete frame still represents the display now.
            latest?.date = date
        case .blank, .suspended, .stopped:
            latest = nil
            validity = UUID()
            invalidationPending = true
        default:
            lock.unlock()
            return
        }
        let shouldNotify = !notificationPending
        notificationPending = true
        lock.unlock()
        guard shouldNotify else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let active = self.active
            let invalidated = self.invalidationPending
            let metadata = self.latest.map {
                ($0.date, CVPixelBufferGetWidth($0.pixels), CVPixelBufferGetHeight($0.pixels))
            }
            self.notificationPending = false
            self.invalidationPending = false
            self.lock.unlock()
            guard active else { return }
            if invalidated { self.onEvent?(.frameInvalidated) }
            if let metadata {
                self.onEvent?(.frameReceived(at: metadata.0, width: metadata.1, height: metadata.2))
            }
        }
    }

    func clear() {
        lock.lock()
        active = false
        latest = nil
        lock.unlock()
    }

    func convert(notBefore: Date,
                 completion: @escaping @MainActor (ScreenCaptureFrameResult) -> Void) {
        conversionQueue.async { [self] in
            lock.lock()
            let frame = latest
            let token = validity
            lock.unlock()
            let result: ScreenCaptureFrameResult = autoreleasepool {
                guard let frame, frame.date >= notBefore else {
                    return .unavailable
                }
                let image = CIImage(cvPixelBuffer: frame.pixels).oriented(frame.orientation)
                guard let cgImage = context.createCGImage(image, from: image.extent) else {
                    return .failure(.failed("CGImage conversion failed"))
                }
                return .success(UIImage(cgImage: cgImage, scale: frame.scale, orientation: .up))
            }
            DispatchQueue.main.async { [self] in
                lock.lock()
                let stillValid = active && validity == token
                lock.unlock()
                completion(stillValid ? result : .unavailable)
            }
        }
    }
}
#endif
