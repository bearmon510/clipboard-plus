import CoreImage
import Photos
import UIKit

@MainActor
final class PhotoScreenshotLibrary: ScreenshotLibrary {
    private let worker = ScreenshotPhotoWorker()
    private var observer: ScreenshotPhotoObserver?

    var access: ScreenshotWatcher.Access {
        Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    private static func map(_ status: PHAuthorizationStatus) -> ScreenshotWatcher.Access {
        switch status {
        case .authorized: return .authorized
        case .limited: return .limited
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    func requestAccess(completion: @escaping @MainActor (ScreenshotWatcher.Access) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            DispatchQueue.main.async { completion(Self.map(status)) }
        }
    }

    func startObserving(onChange: @escaping @MainActor (Date) -> Void) {
        stopObserving()
        let observer = ScreenshotPhotoObserver(worker: worker, onChange: onChange)
        self.observer = observer
        PHPhotoLibrary.shared().register(observer)
        worker.startTracking()
    }

    func stopObserving() {
        if let observer { PHPhotoLibrary.shared().unregisterChangeObserver(observer) }
        observer = nil
        worker.stopTracking()
    }

    func latestScreenshot(since: Date, completion: @escaping @MainActor (ScreenshotAsset?) -> Void) {
        worker.latestScreenshot(since: since, completion: completion)
    }

    func loadImage(for asset: ScreenshotAsset, completion: @escaping @MainActor (Result<UIImage, Error>) -> Void) {
        worker.loadImage(for: asset, completion: completion)
    }

    func delete(_ ids: [String], completion: @escaping @MainActor (Result<Int, Error>) -> Void) {
        worker.delete(ids, completion: completion)
    }
}

private final class ScreenshotPhotoObserver: NSObject, PHPhotoLibraryChangeObserver {
    private let worker: ScreenshotPhotoWorker
    private let onChange: @MainActor (Date) -> Void

    init(worker: ScreenshotPhotoWorker, onChange: @escaping @MainActor (Date) -> Void) {
        self.worker = worker
        self.onChange = onChange
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        let date = Date()
        worker.updateTracking(changeInstance)
        DispatchQueue.main.async { [onChange] in onChange(date) }
    }
}

// This object is deliberately not main-actor isolated. Even PHAsset fetches and
// PHImageManager's synchronous local-data request run on this serial worker.
private final class ScreenshotPhotoWorker {
    private let queue = DispatchQueue(label: "clipboardplus.screenshots", qos: .userInitiated)
    private let imageManager = PHImageManager.default()
    private let context = CIContext(options: [.cacheIntermediates: false])
    // Retain a fetch result so PhotoKit can report newly inserted screenshots
    // even before the first UIApplication notification or search has occurred.
    private var tracked: PHFetchResult<PHAsset>?

    func startTracking() {
        queue.async { [self] in
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "(mediaSubtype & %d) != 0", PHAssetMediaSubtype.photoScreenshot.rawValue)
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.fetchLimit = 1
            tracked = PHAsset.fetchAssets(with: .image, options: options)
        }
    }

    func stopTracking() { queue.async { [self] in tracked = nil } }

    func updateTracking(_ change: PHChange) {
        queue.async { [self] in
            guard let tracked, let details = change.changeDetails(for: tracked) else { return }
            self.tracked = details.fetchResultAfterChanges
        }
    }

    func latestScreenshot(since: Date, completion: @escaping @MainActor (ScreenshotAsset?) -> Void) {
        queue.async {
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "(mediaSubtype & %d) != 0 AND creationDate >= %@",
                                            PHAssetMediaSubtype.photoScreenshot.rawValue, since as NSDate)
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.fetchLimit = 1
            let asset = PHAsset.fetchAssets(with: .image, options: options).firstObject
            let result = asset.flatMap { asset in
                asset.creationDate.map { ScreenshotAsset(id: asset.localIdentifier, takenAt: $0) }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func loadImage(for asset: ScreenshotAsset, completion: @escaping @MainActor (Result<UIImage, Error>) -> Void) {
        queue.async { [self] in
            guard let photo = PHAsset.fetchAssets(withLocalIdentifiers: [asset.id], options: nil).firstObject,
                  photo.mediaSubtypes.contains(.photoScreenshot) else {
                DispatchQueue.main.async { completion(.failure(ScreenshotLibraryError.imageUnavailable)) }
                return
            }
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = false
            options.isSynchronous = true
            options.version = .original
            imageManager.requestImageDataAndOrientation(for: photo, options: options) { [self] data, _, orientation, info in
                // Explicitly enqueue decoding too: PhotoKit chooses its callback queue.
                queue.async { [self] in
                    let result: Result<UIImage, Error> = autoreleasepool {
                        if let error = info?[PHImageErrorKey] as? Error { return .failure(error) }
                        guard let data else { return .failure(ScreenshotLibraryError.imageUnavailable) }
                        guard let source = CIImage(data: data, options: [.applyOrientationProperty: false]) else {
                            return .failure(ScreenshotLibraryError.decodingFailed)
                        }
                        let upright = source.oriented(orientation)
                        guard let pixels = context.createCGImage(upright, from: upright.extent) else {
                            return .failure(ScreenshotLibraryError.decodingFailed)
                        }
                        return .success(UIImage(cgImage: pixels, scale: 1, orientation: .up))
                    }
                    DispatchQueue.main.async { completion(result) }
                }
            }
        }
    }

    func delete(_ ids: [String], completion: @escaping @MainActor (Result<Int, Error>) -> Void) {
        queue.async {
            guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
                DispatchQueue.main.async { completion(.failure(ScreenshotLibraryError.accessDenied)) }
                return
            }
            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            var assets: [PHAsset] = []
            fetched.enumerateObjects { asset, _, _ in
                if asset.mediaSubtypes.contains(.photoScreenshot) { assets.append(asset) }
            }
            // Already removed assets are a successful no-op and can leave the ledger.
            guard !assets.isEmpty else {
                DispatchQueue.main.async { completion(.success(0)) }
                return
            }
            let deletingAssets = assets
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.deleteAssets(deletingAssets as NSArray)
            }) { success, error in
                DispatchQueue.main.async {
                    if success { completion(.success(deletingAssets.count)) }
                    else { completion(.failure(error ?? ScreenshotLibraryError.deletionFailed)) }
                }
            }
        }
    }
}
