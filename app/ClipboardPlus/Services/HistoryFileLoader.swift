import Foundation
import UIKit

enum HistoryFileLoader {
    static func load(_ provider: NSItemProvider, typeIdentifier: String,
                     completion: @escaping @MainActor (Result<HistoryFileInput, Error>) -> Void) {
        let name = provider.suggestedName
        DispatchQueue.global(qos: .userInitiated).async {
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                // Copy before returning: the system removes this URL after the callback.
                let result = Result { () throws -> HistoryFileInput in
                    guard let url, error == nil else { throw HistoryFileError.unavailable }
                    return try HistoryFileFiles.stage(url, typeIdentifier: typeIdentifier, suggestedName: name)
                }
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    @MainActor
    static func rowProvider(file: HistoryFile, store: HistoryStore) -> NSItemProvider {
        let snapshot = FileProviderSnapshot()
        store.snapshotFile(file) { snapshot.resolve($0) }
        let provider = provider(file: file, snapshot: snapshot)
        DroppedTextLoader.markLocalRow(provider)
        return provider
    }

    static func copyProvider(_ input: HistoryFileInput) -> NSItemProvider {
        let snapshot = FileProviderSnapshot()
        snapshot.resolve(.success(input))
        return provider(file: input.file, snapshot: snapshot)
    }

    private static func provider(file: HistoryFile, snapshot: FileProviderSnapshot) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = file.originalFilename
        provider.registerFileRepresentation(forTypeIdentifier: file.typeIdentifier, fileOptions: [], visibility: .all) { completion in
            snapshot.read { result in
                switch result {
                case .success(let input): completion(input.url, false, nil)
                case .failure: completion(nil, false, HistoryFileError.unavailable)
                }
            }
            return nil
        }
        return provider
    }
}

/// NSItemProvider may request a representation before the storage queue finishes its snapshot.
/// Keep the lease alive until the provider releases this box; never block the main thread.
private final class FileProviderSnapshot {
    private let lock = NSLock()
    private var result: Result<HistoryFileInput, Error>?
    private var readers: [(Result<HistoryFileInput, Error>) -> Void] = []
    func resolve(_ value: Result<HistoryFileInput, Error>) {
        lock.lock()
        result = value
        let callbacks = readers
        readers.removeAll()
        lock.unlock()
        callbacks.forEach { $0(value) }
    }
    func read(_ completion: @escaping (Result<HistoryFileInput, Error>) -> Void) {
        lock.lock()
        if let result {
            lock.unlock()
            completion(result)
        } else {
            readers.append(completion)
            lock.unlock()
        }
    }
}
