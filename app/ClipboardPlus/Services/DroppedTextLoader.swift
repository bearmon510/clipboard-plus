import Foundation
import UIKit
import UniformTypeIdentifiers

enum DroppedTextLoader {
    static let contentTypes: [UTType] = [.plainText, .utf8PlainText, .text]
    private static let localRowType = "example.clipboardplus.local-history-row"

    enum LoadError: Error {
        case unavailableText
        case invalidTextData
    }

    static func rowProvider(text: String) -> NSItemProvider {
        let provider = NSItemProvider(object: text as NSString)
        markLocalRow(provider)
        return provider
    }

    static func markLocalRow(_ provider: NSItemProvider) {
        // Keep the origin marker private while allowing other apps to read the text.
        provider.registerDataRepresentation(forTypeIdentifier: localRowType, visibility: .ownProcess) { completion in
            completion(Data(), nil)
            return nil
        }
    }

    static func isLocalRow(_ provider: NSItemProvider) -> Bool {
        provider.hasItemConformingToTypeIdentifier(localRowType)
    }

    static func load(_ provider: NSItemProvider,
                     completion: @escaping @MainActor (Result<String, Error>) -> Void) {
        load(provider) { result, _ in completion(result) }
    }

    static func load(_ provider: NSItemProvider,
                     completion: @escaping @MainActor (Result<String, Error>, String) -> Void) {
        provider.loadObject(ofClass: NSString.self) { object, error in
            if error == nil, let text = object as? String {
                DispatchQueue.main.async { completion(.success(text), "loadObject(NSString): success") }
                return
            }
            let failure = error ?? LoadError.unavailableText
            loadData(provider, typeIdentifiers: [UTType.utf8PlainText.identifier, UTType.plainText.identifier],
                     attempts: ["loadObject(NSString): \(errorDetails(failure))"], completion: completion)
        }
    }

    static func decode(_ data: Data, typeIdentifier: String) -> String? {
        guard typeIdentifier == UTType.utf8PlainText.identifier || typeIdentifier == UTType.plainText.identifier else {
            return nil
        }
        return String(data: data, encoding: .utf8) ?? strictUTF16(data)
    }

    // Foundation's UTF-16 decoding turns invalid bytes into an empty string,
    // so UTF-16 is accepted only with a byte order mark and valid code units.
    private static func strictUTF16(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        guard bytes.count >= 2, bytes.count % 2 == 0 else { return nil }
        let bigEndian: Bool
        switch (bytes[0], bytes[1]) {
        case (0xFE, 0xFF): bigEndian = true
        case (0xFF, 0xFE): bigEndian = false
        default: return nil
        }
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2 - 1)
        var index = 2
        while index < bytes.count {
            let first = UInt16(bytes[index]), second = UInt16(bytes[index + 1])
            units.append(bigEndian ? first << 8 | second : second << 8 | first)
            index += 2
        }
        var scalars = String.UnicodeScalarView()
        var decoder = UTF16()
        var iterator = units.makeIterator()
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar): scalars.append(scalar)
            case .emptyInput: return String(scalars)
            case .error: return nil
            }
        }
    }

    private static func loadData(
        _ provider: NSItemProvider, typeIdentifiers: [String], attempts: [String],
        completion: @escaping @MainActor (Result<String, Error>, String) -> Void
    ) {
        guard let identifier = typeIdentifiers.first else { return }
        let method = "loadDataRepresentation(\(identifier))"
        provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, error in
            if error == nil, let data, let text = decode(data, typeIdentifier: identifier) {
                let details = (attempts + ["\(method): success (UTF-8/UTF-16)"]).joined(separator: "; ")
                DispatchQueue.main.async { completion(.success(text), details) }
                return
            }
            let failure = error ?? (data == nil ? LoadError.unavailableText : LoadError.invalidTextData)
            let updated = attempts + ["\(method): \(errorDetails(failure))"]
            let remaining = Array(typeIdentifiers.dropFirst())
            if remaining.isEmpty {
                let details = updated.joined(separator: "; ")
                DispatchQueue.main.async { completion(.failure(failure), details) }
            } else {
                loadData(provider, typeIdentifiers: remaining, attempts: updated, completion: completion)
            }
        }
    }

    private static func errorDetails(_ error: Error) -> String {
        if let error = error as? LoadError {
            switch error {
            case .unavailableText: return "LoadError.unavailableText"
            case .invalidTextData: return "LoadError.invalidTextData"
            }
        }
        return "errorType=\(String(reflecting: type(of: error))); code=\((error as NSError).code)"
    }
}
