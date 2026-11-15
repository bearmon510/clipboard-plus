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

    func testMoveStopsAtTheEdgesWithoutChangingSize() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let rect = CGRect(x: 10, y: 10, width: 30, height: 20)
        XCTAssertEqual(CropGeometry.moved(rect, by: CGSize(width: 5, height: 7), within: bounds),
                       CGRect(x: 15, y: 17, width: 30, height: 20))
        XCTAssertEqual(CropGeometry.moved(rect, by: CGSize(width: 500, height: -500), within: bounds),
                       CGRect(x: 70, y: 0, width: 30, height: 20))
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

    func testDragModeDependsOnWhereTheDragStarts() {
        let selection = CGRect(x: 100, y: 100, width: 200, height: 100)
        XCTAssertEqual(CropGeometry.dragMode(at: CGPoint(x: 10, y: 10), selection: nil), .new)
        XCTAssertEqual(CropGeometry.dragMode(at: CGPoint(x: 200, y: 150), selection: selection), .move)
        XCTAssertEqual(CropGeometry.dragMode(at: CGPoint(x: 500, y: 500), selection: selection), .new)
        // A drag from a corner resizes around the opposite corner.
        XCTAssertEqual(CropGeometry.dragMode(at: CGPoint(x: 105, y: 96), selection: selection),
                       .resize(anchor: CGPoint(x: 300, y: 200)))
        XCTAssertEqual(CropGeometry.dragMode(at: CGPoint(x: 310, y: 210), selection: selection),
                       .resize(anchor: CGPoint(x: 100, y: 100)))
        // In a small selection the nearest corner wins.
        let small = CGRect(x: 100, y: 100, width: 20, height: 20)
        XCTAssertEqual(CropGeometry.dragMode(at: CGPoint(x: 118, y: 118), selection: small),
                       .resize(anchor: CGPoint(x: 100, y: 100)))
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
