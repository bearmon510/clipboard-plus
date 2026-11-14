import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import ClipboardPlus

final class DroppedTextLoaderTests: XCTestCase {
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
        DroppedTextLoader.load(provider) { result in
            XCTAssertTrue(Thread.isMainThread)
            if case .success = result { XCTFail("Expected failure") }
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
