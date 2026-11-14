import CoreMedia
import CoreVideo
import XCTest
@testable import ClipboardPlus

final class PictureInPictureFrameTests: XCTestCase {
    private func status(recording: Bool = true, textCount: Int = 0, imageCount: Int = 0) -> PictureInPictureStatus {
        PictureInPictureStatus(isRecording: recording, textCount: textCount, imageCount: imageCount,
                               lastCollectedAt: nil, updatedAt: Date(timeIntervalSince1970: 100),
                               timeZone: TimeZone(secondsFromGMT: 0)!)
    }

    func testRendererMakesRequestedSizeBGRAWithIOSurface() throws {
        let buffer = try PictureInPictureFrame.render(status(), width: 320, height: 180)
        XCTAssertEqual(CVPixelBufferGetWidth(buffer), 320)
        XCTAssertEqual(CVPixelBufferGetHeight(buffer), 180)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(buffer), kCVPixelFormatType_32BGRA)
        XCTAssertNotNil(CVPixelBufferGetIOSurface(buffer))
    }

    func testRendererAcceptsZeroCountsAndNoCollectionTime() throws {
        let buffer = try PictureInPictureFrame.render(status(recording: false))
        XCTAssertEqual(CVPixelBufferGetWidth(buffer), 640)
        XCTAssertEqual(CVPixelBufferGetHeight(buffer), 360)
    }

    func testRendererAcceptsLargeCountsAndCollectionTime() throws {
        let value = PictureInPictureStatus(isRecording: true, textCount: Int.max, imageCount: Int.max,
                                          lastCollectedAt: Date(timeIntervalSince1970: 99),
                                          updatedAt: Date(timeIntervalSince1970: 100),
                                          timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertNoThrow(try PictureInPictureFrame.render(value))
    }

    func testRendererRejectsNonpositiveDimensions() {
        XCTAssertThrowsError(try PictureInPictureFrame.render(status(), width: 0))
        XCTAssertThrowsError(try PictureInPictureFrame.render(status(), height: -1))
    }

    func testSampleBufferIsReadyAndHasDisplayImmediatelyAttachment() throws {
        let pixelBuffer = try PictureInPictureFrame.render(status())
        let time = CMTime(value: 123, timescale: 10)
        let sample = try PictureInPictureFrame.makeSampleBuffer(from: pixelBuffer, presentationTime: time)
        XCTAssertTrue(CMSampleBufferDataIsReady(sample))
        XCTAssertEqual(CMSampleBufferGetNumSamples(sample), 1)
        XCTAssertEqual(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), time), 0)
        let image = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
        XCTAssertEqual(CVPixelBufferGetWidth(image), 640)
        let attachments = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false))
        XCTAssertEqual(CFArrayGetCount(attachments), 1)
        let pointer = try XCTUnwrap(CFArrayGetValueAtIndex(attachments, 0))
        let dictionary = unsafeBitCast(pointer, to: CFDictionary.self)
        let value = try XCTUnwrap(CFDictionaryGetValue(
            dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque()
        ))
        let boolean = unsafeBitCast(value, to: CFBoolean.self)
        XCTAssertTrue(CFBooleanGetValue(boolean))
    }

    func testRecordingMapsToPlaybackStateWithoutPiPController() {
        XCTAssertFalse(status(recording: true).isPlaybackPaused)
        XCTAssertTrue(status(recording: false).isPlaybackPaused)
    }
}
