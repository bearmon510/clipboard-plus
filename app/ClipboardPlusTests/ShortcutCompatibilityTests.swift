import AppIntents
import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import ClipboardPlus

final class ShortcutCompatibilityTests: XCTestCase {
    func testAllExistingSourcesAndManualShortcutSourceRoundTripThroughBackupAndRestore() throws {
        let root = try ImageTestSupport.directory(self)
        let sourceURL = root.appendingPathComponent("source.sqlite")
        let source = try HistoryDatabase(url: sourceURL)
        let files = HistoryImageFiles(directory: root.appendingPathComponent("originals"))
        for (index, route) in [HistorySource.automatic, .manual, .drag, .capture, .pc].enumerated() {
            try source.collect("出どころ\(index)", source: route, at: Date(timeIntervalSince1970: Double(index + 1)))
        }
        let picture = try ImageTestSupport.prepare(files)
        try source.collectImage(picture, source: .manual, at: Date(timeIntervalSince1970: 10))
        let expected = try source.fetchAll()
        let reopened = try HistoryDatabase(url: sourceURL)
        XCTAssertEqual(try reopened.fetchAll(), expected)

        let export = try HistoryExport.data(entries: expected, exportedAt: Date())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: export) as? [String: Any])
        XCTAssertEqual(json["formatVersion"] as? Int, 5)
        let records = try XCTUnwrap(json["entries"] as? [[String: Any]])
        XCTAssertTrue(records.allSatisfy { ["automatic", "manual", "drag", "capture", "pc"].contains($0["source"] as? String ?? "") })

        let url = root.appendingPathComponent("shortcut.clipboardplus")
        _ = try HistoryBackup.write(entries: expected, files: files, to: url, cancellation: BackupCancellation())
        let backup = try HistoryBackup.validate(at: url, temporaryRoot: root, cancellation: BackupCancellation())
        let restoredFiles = HistoryImageFiles(directory: root.appendingPathComponent("restored"))
        let target = try HistoryDatabase(url: root.appendingPathComponent("restored.sqlite"))
        let result = try HistoryRestore.apply(backup, database: target, files: restoredFiles, cancellation: BackupCancellation())
        XCTAssertEqual(result, RestoreCounts(added: expected.count))
        let restored = try target.fetchAll()
        XCTAssertEqual(restored.map(\.text), expected.map(\.text))
        XCTAssertEqual(restored.map(\.source), expected.map(\.source))
        XCTAssertEqual(restored.map(\.savedAt), expected.map(\.savedAt))
        XCTAssertEqual(restored.map(\.lastCollectedAt), expected.map(\.lastCollectedAt))
        let restoredImage = try XCTUnwrap(restored.first?.image)
        XCTAssertEqual(try restoredFiles.read(restoredImage), try files.read(picture))
    }

    /// Documents why a new raw value is not written: both the existing Codable reader and
    /// SQLite reader reject unknown sources. A new enum case would break older versions.
    func testUnknownSourceIsNotBackwardCompatible() throws {
        XCTAssertThrowsError(try JSONDecoder().decode(HistorySource.self, from: Data("\"shortcut\"".utf8)))
        let root = try ImageTestSupport.directory(self)
        let url = root.appendingPathComponent("history.sqlite")
        let database = try HistoryDatabase(url: url)
        try database.collect("旧版で読めなくなる値", source: .manual)
        try ImageTestSupport.sql("UPDATE history SET source = 'shortcut'", at: url)
        XCTAssertThrowsError(try database.fetchAll())
    }

    func testShortcutPNGConversionAppliesEXIFOrientationLikeCaptureSource() async throws {
        let original = try XCTUnwrap(UIImage(data: ImageTestSupport.png(size: CGSize(width: 40, height: 20)))?.cgImage)
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, original, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let input = IntentFile(data: bytes as Data, filename: "rotated.jpg", type: .jpeg)
        let png = try await ShortcutImageReader.png(in: input)
        let output = try XCTUnwrap(UIImage(data: png))
        XCTAssertEqual(output.imageOrientation, .up)
        XCTAssertEqual(output.cgImage?.width, 20)
        XCTAssertEqual(output.cgImage?.height, 40)
    }

    func testUnreadableImageHasJapaneseErrorWithoutShortcutsRuntime() async {
        let file = IntentFile(data: Data([0, 1, 2]), filename: "broken.png", type: .png)
        do {
            _ = try await ShortcutImageReader.lines(in: file)
            XCTFail("Expected unreadable image")
        } catch {
            guard case ShortcutError.unreadableImage = error else { XCTFail("Unexpected error: \(error)"); return }
            XCTAssertTrue(error.localizedDescription.contains("画像を読み込めません"))
        }
    }
}
