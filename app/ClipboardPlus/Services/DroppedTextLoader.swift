import Foundation
import UIKit
import UniformTypeIdentifiers

enum DroppedTextLoader {
    static let contentTypes: [UTType] = [.plainText, .utf8PlainText, .text]
    private static let localRowType = "example.clipboardplus.local-history-row"

    enum LoadError: Error {
        case unavailableText
    }

    static func rowProvider(text: String) -> NSItemProvider {
        let provider = NSItemProvider(object: text as NSString)
        // Keep the origin marker private while allowing other apps to read the text.
        provider.registerDataRepresentation(forTypeIdentifier: localRowType, visibility: .ownProcess) { completion in
            completion(Data(), nil)
            return nil
        }
        return provider
    }

    static func isLocalRow(_ provider: NSItemProvider) -> Bool {
        provider.hasItemConformingToTypeIdentifier(localRowType)
    }

    static func load(_ provider: NSItemProvider,
                     completion: @escaping @MainActor (Result<String, Error>) -> Void) {
        provider.loadObject(ofClass: NSString.self) { object, error in
            let result: Result<String, Error>
            if let error {
                result = .failure(error)
            } else if let text = object as? String {
                result = .success(text)
            } else {
                result = .failure(LoadError.unavailableText)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
