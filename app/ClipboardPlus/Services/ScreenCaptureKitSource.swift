#if canImport(ScreenCaptureKit)
import CoreImage
import CoreMedia
import CoreVideo
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
                            completion: @escaping @MainActor (Result<UIImage, ScreenCaptureError>) -> Void) {
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
        frames.onFrame = { [weak self] date, width, height in
            guard let self, self.active else { return }
            self.event(.frameReceived(at: date, width: width, height: height))
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
        configuration.allowsChangingSelectedContent = false
        if let identifier = Bundle.main.bundleIdentifier {
            // Documented as a picker exclusion, not a guarantee that our window
            // is removed from a full-display frame. Correctness does not rely on it.
            configuration.excludedBundleIDs = [identifier]
        }
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
        let scale = CGFloat(filter.pointPixelScale)
        event(.permissionGranted(contentRect: rect, pointPixelScale: scale))
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
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 4)
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.scalesToFit = false
        configuration.capturesAudio = false
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        self.stream = stream
        let output = ScreenCaptureOutput(frames: frames)
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
    init(frames: ScreenCaptureFrameBuffer) {
        self.frames = frames
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frames.replace(with: pixels, at: Date())
    }
}

// The sample queue, conversion queue and main actor share this single slot.
// Notifications carry no buffers and are coalesced if the main thread is busy.
private final class ScreenCaptureFrameBuffer {
    var onFrame: (@MainActor (Date, Int, Int) -> Void)?
    private let lock = NSLock()
    private var latest: (pixels: CVPixelBuffer, date: Date)?
    private var active = true
    private var notificationPending = false
    private let context: CIContext
    private let conversionQueue: DispatchQueue

    init(context: CIContext, conversionQueue: DispatchQueue) {
        self.context = context
        self.conversionQueue = conversionQueue
    }

    func replace(with pixels: CVPixelBuffer, at date: Date) {
        lock.lock()
        guard active else { lock.unlock(); return }
        latest = (pixels, date)
        let shouldNotify = !notificationPending
        notificationPending = true
        lock.unlock()
        guard shouldNotify else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let metadata = self.latest.map {
                ($0.date, CVPixelBufferGetWidth($0.pixels), CVPixelBufferGetHeight($0.pixels))
            }
            self.notificationPending = false
            self.lock.unlock()
            if let metadata { self.onFrame?(metadata.0, metadata.1, metadata.2) }
        }
    }

    func clear() {
        lock.lock()
        active = false
        latest = nil
        lock.unlock()
    }

    func convert(notBefore: Date,
                 completion: @escaping @MainActor (Result<UIImage, ScreenCaptureError>) -> Void) {
        conversionQueue.async { [self] in
            let result: Result<UIImage, ScreenCaptureError> = autoreleasepool {
                lock.lock()
                let frame = latest
                lock.unlock()
                guard let frame, frame.date >= notBefore else {
                    return .failure(.failed("no usable frame"))
                }
                let image = CIImage(cvPixelBuffer: frame.pixels)
                guard let cgImage = context.createCGImage(image, from: image.extent) else {
                    return .failure(.failed("CGImage conversion failed"))
                }
                return .success(UIImage(cgImage: cgImage, scale: 1, orientation: .up))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
#endif
