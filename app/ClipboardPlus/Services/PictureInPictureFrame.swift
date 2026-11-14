import CoreMedia
import CoreVideo
import UIKit

// Only status metadata crosses the renderer boundary. No history content is accepted.
struct PictureInPictureStatus {
    let isRecording: Bool
    let textCount: Int
    let imageCount: Int
    let lastCollectedAt: Date?
    let updatedAt: Date
    let timeZone: TimeZone
    /// Saves since launch. Unlike the item counts, it grows when a copy merges into an existing item.
    var savedCount: Int = 0

    var isPlaybackPaused: Bool { !isRecording }
}

enum PictureInPictureFrameError: Error {
    case invalidSize
    case pixelBuffer(CVReturn)
    case drawingContext
    case formatDescription(OSStatus)
    case sampleBuffer(OSStatus)
    case attachments
}

enum PictureInPictureFrame {
    // Dates, time zone and dimensions are inputs; no clock, store or pasteboard access.
    static func render(_ status: PictureInPictureStatus, width: Int = 640, height: Int = 360) throws -> CVPixelBuffer {
        guard width > 0, height > 0 else { throw PictureInPictureFrameError.invalidSize }
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        var output: CVPixelBuffer?
        let result = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_32BGRA, attributes as CFDictionary, &output)
        guard result == kCVReturnSuccess, let buffer = output else {
            throw PictureInPictureFrameError.pixelBuffer(result)
        }
        let lockResult = CVPixelBufferLockBaseAddress(buffer, [])
        guard lockResult == kCVReturnSuccess else { throw PictureInPictureFrameError.pixelBuffer(lockResult) }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let address = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(
                data: address, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
              ) else { throw PictureInPictureFrameError.drawingContext }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(width) / 640, y: -CGFloat(height) / 360)
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        UIColor(red: 0.06, green: 0.09, blue: 0.14, alpha: 1).setFill()
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = status.timeZone
        formatter.dateFormat = "HH:mm:ss"
        let collected = status.lastCollectedAt.map { formatter.string(from: $0) } ?? "—"
        draw(status.isRecording ? "記録中" : "停止中", y: 20, size: 52,
             color: UIColor(red: 0.4, green: 0.9, blue: 0.7, alpha: 1))
        draw("取り込み  \(status.savedCount)回", y: 94, size: 40)
        draw("最終取り込み  \(collected)", y: 156, size: 34)
        draw("履歴  文章\(status.textCount)件・画像\(status.imageCount)件", y: 222, size: 28)
        draw("画面更新  \(formatter.string(from: status.updatedAt))", y: 278, size: 28)
        return buffer
    }

    private static func draw(_ text: String, y: CGFloat, size: CGFloat, color: UIColor = .white) {
        let value = text as NSString
        let font = UIFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
        let measured = value.size(withAttributes: [.font: font]).width
        let fitted = font.withSize(size * min(1, 584 / max(1, measured)))
        value.draw(in: CGRect(x: 28, y: y, width: 584, height: 66),
                   withAttributes: [.font: fitted, .foregroundColor: color])
    }

    static func makeSampleBuffer(from pixelBuffer: CVPixelBuffer, presentationTime: CMTime) throws -> CMSampleBuffer {
        var formatOutput: CMVideoFormatDescription?
        let formatResult = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &formatOutput
        )
        guard formatResult == noErr, let format = formatOutput else {
            throw PictureInPictureFrameError.formatDescription(formatResult)
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 1),
                                        presentationTimeStamp: presentationTime, decodeTimeStamp: .invalid)
        var sampleOutput: CMSampleBuffer?
        let sampleResult = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &sampleOutput
        )
        guard sampleResult == noErr, let sample = sampleOutput else {
            throw PictureInPictureFrameError.sampleBuffer(sampleResult)
        }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
              CFArrayGetCount(attachments) > 0,
              let pointer = CFArrayGetValueAtIndex(attachments, 0) else {
            throw PictureInPictureFrameError.attachments
        }
        // Mutate the actual per-sample CF dictionary, not a bridged Swift copy.
        let dictionary = unsafeBitCast(pointer, to: CFMutableDictionary.self)
        CFDictionarySetValue(dictionary,
                             Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        return sample
    }
}
