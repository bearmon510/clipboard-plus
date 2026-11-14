import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import ClipboardPlus

final class DroppedTextLoaderTests: XCTestCase {
    func testDecodesUTF8WithoutChangingWhitespace() {
        let text = " 文章\nSafariからのドロップ\t\n"
        for identifier in [UTType.utf8PlainText.identifier, UTType.plainText.identifier] {
            let decoded = DroppedTextLoader.decode(Data(text.utf8), typeIdentifier: identifier)
            XCTAssertEqual(decoded.map { Array($0.utf8) }, Array(text.utf8))
        }
    }

    func testDecodesUTF16LittleEndianAfterUTF8Fails() {
        let data = Data([0xFF, 0xFE, 0x87, 0x65, 0x20, 0x00, 0x0A, 0x00])
        for identifier in [UTType.utf8PlainText.identifier, UTType.plainText.identifier] {
            XCTAssertEqual(DroppedTextLoader.decode(data, typeIdentifier: identifier), "文 \n")
        }
    }

    func testDecodesUTF16BigEndianAfterUTF8Fails() {
        let data = Data([0xFE, 0xFF, 0x65, 0x87, 0x00, 0x20, 0x00, 0x0A])
        for identifier in [UTType.utf8PlainText.identifier, UTType.plainText.identifier] {
            XCTAssertEqual(DroppedTextLoader.decode(data, typeIdentifier: identifier), "文 \n")
        }
    }

    func testDecodesEmptyDataAsEmptyString() {
        for identifier in [UTType.utf8PlainText.identifier, UTType.plainText.identifier] {
            XCTAssertEqual(DroppedTextLoader.decode(Data(), typeIdentifier: identifier), "")
        }
    }

    func testRejectsInvalidTextData() {
        for data in [Data([0xFF]), Data([0xFF, 0xFE, 0x00, 0xD8])] {
            for identifier in [UTType.utf8PlainText.identifier, UTType.plainText.identifier] {
                XCTAssertNil(DroppedTextLoader.decode(data, typeIdentifier: identifier))
            }
        }
    }

    func testRejectsUnsupportedDataType() {
        XCTAssertNil(DroppedTextLoader.decode(Data("文章".utf8), typeIdentifier: UTType.data.identifier))
    }

    func testLoadsUTF8DataRepresentation() {
        let text = "Safariの文章\n次の行"
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .all) { completion in
            completion(Data(text.utf8), nil)
            return nil
        }
        let done = expectation(description: "UTF-8 text loaded")
        DroppedTextLoader.load(provider) { result in
            switch result {
            case .success(let loaded): XCTAssertEqual(loaded, text)
            case .failure: XCTFail("Expected UTF-8 text")
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testLoadsTextWithoutChangingWhitespaceOnMainThread() {
        let text = " 文章\nSafariからのドロップ\t\n"
        let provider = NSItemProvider(object: text as NSString)
        let done = expectation(description: "text loaded")
        DroppedTextLoader.load(provider) { result in
            XCTAssertTrue(Thread.isMainThread)
            switch result {
            case .success(let loaded): XCTAssertTrue(loaded.utf8.elementsEqual(text.utf8))
            case .failure: XCTFail("Expected text")
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testLoadsPlainTextDataRepresentation() {
        let text = "文章\nplain text"
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { completion in
            completion(Data(text.utf8), nil)
            return nil
        }
        let done = expectation(description: "plain text loaded")
        DroppedTextLoader.load(provider) { result in
            XCTAssertTrue(Thread.isMainThread)
            switch result {
            case .success(let loaded): XCTAssertEqual(loaded, text)
            case .failure: XCTFail("Expected plain text")
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testSuccessfulObjectLoadReportsOnlyObjectAttempt() {
        let text = "本文を診断情報へ入れない"
        let done = expectation(description: "object diagnostics returned")
        DroppedTextLoader.load(NSItemProvider(object: text as NSString)) { result, details in
            XCTAssertTrue(Thread.isMainThread)
            if case .failure = result { XCTFail("Expected text") }
            XCTAssertEqual(details, "loadObject(NSString): success")
            XCTAssertFalse(details.contains(text))
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testEmptyStringIsLoaded() {
        let done = expectation(description: "empty text loaded")
        DroppedTextLoader.load(NSItemProvider(object: "" as NSString)) { result in
            switch result {
            case .success(let text): XCTAssertEqual(text, "")
            case .failure: XCTFail("Expected empty text")
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testUnsupportedProviderFailsOnMainThread() {
        let done = expectation(description: "unsupported provider rejected")
        DroppedTextLoader.load(NSItemProvider()) { result in
            XCTAssertTrue(Thread.isMainThread)
            if case .success = result { XCTFail("Expected failure") }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testProviderLoadingErrorIsReturned() {
        let provider = NSItemProvider()
        provider.registerObject(ofClass: NSString.self, visibility: .all) { completion in
            completion(nil, CocoaError(.fileReadUnknown))
            return nil
        }
        let done = expectation(description: "loading failure returned")
        DroppedTextLoader.load(provider) { result, details in
            XCTAssertTrue(Thread.isMainThread)
            if case .success = result { XCTFail("Expected failure") }
            XCTAssertTrue(details.contains("code="))
            let methods = details.components(separatedBy: "; ").filter {
                $0.hasPrefix("loadObject(") || $0.hasPrefix("loadDataRepresentation(")
            }
            XCTAssertEqual(methods.count, 3)
            XCTAssertTrue(methods.first?.hasPrefix("loadObject(NSString):") == true)
            XCTAssertTrue(methods.dropFirst().first?.hasPrefix("loadDataRepresentation(public.utf8-plain-text):") == true)
            XCTAssertTrue(methods.last?.hasPrefix("loadDataRepresentation(public.plain-text):") == true)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testLocalRowIsDistinguishedFromExternalCopyOfSameText() {
        let local = DroppedTextLoader.rowProvider(text: "同じ文章")
        let external = NSItemProvider(object: "同じ文章" as NSString)
        XCTAssertTrue(DroppedTextLoader.isLocalRow(local))
        XCTAssertFalse(DroppedTextLoader.isLocalRow(external))
        XCTAssertTrue(local.canLoadObject(ofClass: NSString.self))
    }
}
