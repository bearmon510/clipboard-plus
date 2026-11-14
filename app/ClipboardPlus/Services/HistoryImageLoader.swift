import Foundation
import UIKit
import UniformTypeIdentifiers

enum HistoryImageInput {
    case data(Data, typeIdentifier: String)
    case bitmap(UIImage)

    // Fallback PNG encoding is also performed on the store queue, never by the view/monitor.
    func encoded() throws -> (Data, String) {
        switch self {
        case .data(let data, let type): return (data, type)
        case .bitmap(let image):
            guard let data = image.pngData() else { throw HistoryImageError.invalidImage }
            return (data, UTType.png.identifier)
        }
    }
}

enum HistoryImageLoader {
    static let contentTypes: [UTType] = [.image] + DroppedTextLoader.contentTypes

    static func hasImage(_ provider: NSItemProvider) -> Bool {
        provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) ||
            provider.canLoadObject(ofClass: UIImage.self)
    }

    static func load(_ provider: NSItemProvider,
                     completion: @escaping @MainActor (Result<HistoryImageInput, Error>) -> Void) {
        let offered = provider.registeredTypeIdentifiers
        let types = HistoryImageFiles.preferredTypes.filter { offered.contains($0) }
        let otherImages = offered.filter {
            !types.contains($0) && $0 != UTType.image.identifier && UTType($0)?.conforms(to: .image) == true
        }
        loadData(provider, types: types + otherImages, completion: completion)
    }

    private static func loadData(_ provider: NSItemProvider, types: [String],
                                 completion: @escaping @MainActor (Result<HistoryImageInput, Error>) -> Void) {
        guard let type = types.first else {
            provider.loadObject(ofClass: UIImage.self) { object, error in
                let result: Result<HistoryImageInput, Error>
                if let image = object as? UIImage, error == nil { result = .success(.bitmap(image)) }
                else { result = .failure(HistoryImageError.invalidImage) }
                DispatchQueue.main.async { completion(result) }
            }
            return
        }
        provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
            if let data, error == nil {
                DispatchQueue.main.async { completion(.success(.data(data, typeIdentifier: type))) }
            } else {
                loadData(provider, types: Array(types.dropFirst()), completion: completion)
            }
        }
    }

    static func rowProvider(image: HistoryImage, files: HistoryImageFiles) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: image.typeIdentifier, visibility: .all) { completion in
            DispatchQueue.global(qos: .userInitiated).async {
                do { completion(try files.read(image), nil) }
                catch { completion(nil, HistoryImageError.unavailable) }
            }
            return nil
        }
        DroppedTextLoader.markLocalRow(provider)
        return provider
    }
}
