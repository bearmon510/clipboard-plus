import UIKit
import XCTest
@testable import ClipboardPlus

final class CaptureTests: XCTestCase {
    // MARK: Geometry

    func testFittedFrameCentersThePictureAndKeepsItsShape() {
        XCTAssertEqual(CropGeometry.fittedFrame(imageSize: CGSize(width: 200, height: 100), in: CGSize(width: 400, height: 400)),
                       CGRect(x: 0, y: 100, width: 400, height: 200))
        XCTAssertEqual(CropGeometry.fittedFrame(imageSize: CGSize(width: 100, height: 200), in: CGSize(width: 400, height: 400)),
                       CGRect(x: 100, y: 0, width: 200, height: 400))
        XCTAssertEqual(CropGeometry.fittedFrame(imageSize: .zero, in: CGSize(width: 400, height: 400)), .zero)
    }

    func testRectFromTwoPointsWorksInAnyDirectionAndStaysInside() {
        let bounds = CGRect(x: 10, y: 20, width: 100, height: 50)
        XCTAssertEqual(CropGeometry.rect(from: CGPoint(x: 60, y: 60), to: CGPoint(x: 30, y: 40), within: bounds),
                       CGRect(x: 30, y: 40, width: 30, height: 20))
        XCTAssertEqual(CropGeometry.rect(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 500, y: 500), within: bounds), bounds)
    }

    func testTinySelectionsCountAsStrayTaps() {
        XCTAssertFalse(CropGeometry.isMeaningful(.zero))
        XCTAssertFalse(CropGeometry.isMeaningful(CGRect(x: 0, y: 0, width: 200, height: 11)))
        XCTAssertFalse(CropGeometry.isMeaningful(CGRect(x: 0, y: 0, width: 11, height: 200)))
        XCTAssertTrue(CropGeometry.isMeaningful(CGRect(x: 0, y: 0, width: 12, height: 12)))
    }

    func testUnitAndViewRectsAreInverse() {
        let frame = CGRect(x: 50, y: 100, width: 200, height: 400)
        let rect = CGRect(x: 100, y: 200, width: 50, height: 100)
        let unit = CropGeometry.unit(rect, in: frame)
        XCTAssertEqual(unit, CGRect(x: 0.25, y: 0.25, width: 0.25, height: 0.25))
        XCTAssertEqual(CropGeometry.viewRect(unit, in: frame), rect)
        XCTAssertEqual(CropGeometry.unit(rect, in: .zero), .zero)
    }

    func testPixelRectCoversWholePixelsAndNeverLeavesThePicture() {
        XCTAssertEqual(CropGeometry.pixelRect(CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25), imageWidth: 400, imageHeight: 200),
                       CGRect(x: 100, y: 100, width: 200, height: 50))
        XCTAssertEqual(CropGeometry.pixelRect(CGRect(x: 0, y: 0, width: 1, height: 1), imageWidth: 400, imageHeight: 200),
                       CGRect(x: 0, y: 0, width: 400, height: 200))
        // A sliver still yields one pixel, and values outside the picture are pulled in.
        XCTAssertEqual(CropGeometry.pixelRect(CGRect(x: 0.5, y: 0.5, width: 0, height: 0), imageWidth: 10, imageHeight: 10),
                       CGRect(x: 5, y: 5, width: 1, height: 1))
        XCTAssertEqual(CropGeometry.pixelRect(CGRect(x: 0.9, y: 0.9, width: 5, height: 5), imageWidth: 10, imageHeight: 10),
                       CGRect(x: 9, y: 9, width: 1, height: 1))
    }

    // MARK: Magnifier

    func testMagnifierSitsAboveTheFingerOrBelowItNearTheTop() {
        let container = CGSize(width: 360, height: 700)
        XCTAssertEqual(CropGeometry.magnifierCenter(for: CGPoint(x: 180, y: 400), in: container, diameter: 120, gap: 30),
                       CGPoint(x: 180, y: 310))
        // Too close to the top for the lens to fit above, so it goes below.
        XCTAssertEqual(CropGeometry.magnifierCenter(for: CGPoint(x: 180, y: 100), in: container, diameter: 120, gap: 30),
                       CGPoint(x: 180, y: 190))
        // Never past the side edges.
        XCTAssertEqual(CropGeometry.magnifierCenter(for: CGPoint(x: 5, y: 400), in: container, diameter: 120, gap: 30).x, 60)
        XCTAssertEqual(CropGeometry.magnifierCenter(for: CGPoint(x: 355, y: 400), in: container, diameter: 120, gap: 30).x, 300)
    }

    func testMagnificationShowsRealSizeInANarrowWindow() {
        // A 1366-point screen shrunk into a 340-point window needs about 4x to show it at real size.
        XCTAssertEqual(CropGeometry.magnification(displayedWidth: 341.5, imagePointWidth: 1_366), 4)
        XCTAssertEqual(CropGeometry.magnification(displayedWidth: 1_000, imagePointWidth: 2_500), 2.5)
        // A wide window still gets the minimum.
        XCTAssertEqual(CropGeometry.magnification(displayedWidth: 1_366, imagePointWidth: 1_366), 2)
        XCTAssertEqual(CropGeometry.magnification(displayedWidth: 100, imagePointWidth: 10_000), 4)
        XCTAssertEqual(CropGeometry.magnification(displayedWidth: 0, imagePointWidth: 100), 2)
    }

    func testMagnifiedOriginPutsTheTouchedPointInTheMiddle() {
        let frame = CGRect(x: 20, y: 50, width: 300, height: 200)
        let touch = CGPoint(x: 120, y: 150)
        let origin = CropGeometry.magnifiedOrigin(touch: touch, frame: frame, magnification: 3, diameter: 100)
        // The touched point lies 100 by 100 points into the picture; enlarged three times it is
        // 300 by 300 points in, and must land at the lens centre (50, 50).
        XCTAssertEqual(origin, CGPoint(x: -250, y: -250))
        XCTAssertEqual(origin.x + (touch.x - frame.minX) * 3, 50)
    }

    // MARK: Modes

    func testModesHaveDistinctTitlesAndSymbols() {
        XCTAssertEqual(CaptureMode.allCases, [.text, .image])
        XCTAssertNotEqual(CaptureMode.text.symbolName, CaptureMode.image.symbolName)
        XCTAssertEqual(CaptureMode.text.title, "文字")
        XCTAssertEqual(CaptureMode.image.title, "画像")
    }

    @MainActor
    func testToastPreviewKeepsOneShortLine() {
        XCTAssertEqual(ContentView.toastPreview("一行目\n二行目"), "一行目 二行目")
        XCTAssertEqual(ContentView.toastPreview(String(repeating: "あ", count: 30), limit: 24),
                       String(repeating: "あ", count: 24) + "…")
        XCTAssertEqual(ContentView.toastPreview("短い"), "短い")
    }

    // MARK: Text order

    func testAssembleReadsRowsTopToBottomAndLeftToRight() {
        let lines = [
            RecognizedLine(text: "右下", box: CGRect(x: 0.6, y: 0.52, width: 0.2, height: 0.08)),
            RecognizedLine(text: "見出し", box: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.1)),
            RecognizedLine(text: "左下", box: CGRect(x: 0.1, y: 0.5, width: 0.2, height: 0.1)),
            RecognizedLine(text: "  ", box: CGRect(x: 0.1, y: 0.3, width: 0.2, height: 0.1)),
        ]
        XCTAssertEqual(TextRecognizer.assemble(lines), "見出し\n左下 右下")
        XCTAssertEqual(TextRecognizer.assemble([]), "")
    }

    // MARK: Vision

    /// Vision may be unavailable on a CI simulator. The test then skips instead of failing.
    func testRecognizerReadsLargePrintedText() throws {
        let size = CGSize(width: 600, height: 200)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let picture = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            ("HELLO 2026" as NSString).draw(at: CGPoint(x: 40, y: 60), withAttributes: [
                .font: UIFont.systemFont(ofSize: 72, weight: .bold), .foregroundColor: UIColor.black,
            ])
        }
        let pixels = try XCTUnwrap(picture.cgImage)
        let text: String
        do {
            text = try TextRecognizer.text(in: pixels)
        } catch {
            throw XCTSkip("Vision text recognition is unavailable here: \(error)")
        }
        try XCTSkipIf(text.isEmpty, "Vision returned no text on this simulator")
        XCTAssertTrue(text.uppercased().contains("HELLO"), text)
        XCTAssertTrue(text.contains("2026"), text)
    }

    // MARK: Source

    func testCaptureSourceKeepsUprightPicturesAndRedrawsRotatedOnes() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let upright = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        }
        XCTAssertEqual(CaptureSource(image: upright).image.cgImage?.width, 40)
        let rotated = UIImage(cgImage: try XCTUnwrap(upright.cgImage), scale: 1, orientation: .right)
        let source = CaptureSource(image: rotated)
        XCTAssertEqual(source.image.imageOrientation, .up)
        // A picture turned on its side is 20 wide and 40 tall once its pixels are upright.
        XCTAssertEqual(source.image.cgImage?.width, 20)
        XCTAssertEqual(source.image.cgImage?.height, 40)
    }
}
