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
        let session = UUID()
        let observer = ScreenshotPhotoObserver(worker: worker, session: session, onChange: onChange)
        self.observer = observer
        PHPhotoLibrary.shared().register(observer)
        worker.startTracking(session: session)
    }

    func stopObserving() {
        if let observer { PHPhotoLibrary.shared().unregisterChangeObserver(observer) }
        observer = nil
        worker.stopTracking()
    }

    func screenshots(since: Date, completion: @escaping @MainActor ([ScreenshotAsset]) -> Void) {
        worker.screenshots(since: since, completion: completion)
    }

    // Shared with the request path so tests can inspect the actual options.
    nonisolated static func imageRequestOptions() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.isSynchronous = true
        options.version = .current
        return options
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
    private let session: UUID
    private let onChange: @MainActor (Date) -> Void

    init(worker: ScreenshotPhotoWorker, session: UUID, onChange: @escaping @MainActor (Date) -> Void) {
        self.worker = worker
        self.session = session
        self.onChange = onChange
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        let date = Date()
        worker.updateTracking(changeInstance, at: date, session: session, onChange: onChange)
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
    private var session: UUID?
    private var inserted: [String: Date] = [:]

    func startTracking(session: UUID) {
        queue.async { [self] in
            self.session = session
            inserted.removeAll()
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "(mediaSubtype & %d) != 0", PHAssetMediaSubtype.photoScreenshot.rawValue)
            // Track the entire screenshot result. A limit of one can hide real
            // insertions behind an old asset with a future creationDate.
            options.wantsIncrementalChangeDetails = true
            tracked = PHAsset.fetchAssets(with: .image, options: options)
        }
    }

    func stopTracking() {
        queue.async { [self] in
            session = nil
            tracked = nil
            inserted.removeAll()
        }
    }

    func updateTracking(_ change: PHChange, at date: Date, session: UUID,
                        onChange: @escaping @MainActor (Date) -> Void) {
        queue.async { [self] in
            guard self.session == session, let tracked,
                  let details = change.changeDetails(for: tracked) else { return }
            self.tracked = details.fetchResultAfterChanges
            // A full reload supplies no insertion evidence. Never infer it by
            // comparing dates or by treating the replacement result as new.
            guard details.hasIncrementalChanges else {
                inserted.removeAll()
                return
            }
            for asset in details.removedObjects { inserted.removeValue(forKey: asset.localIdentifier) }
            for asset in details.insertedObjects {
                if inserted[asset.localIdentifier] == nil { inserted[asset.localIdentifier] = date }
            }
            // Notify only after the insertion ledger and retained result agree.
            DispatchQueue.main.async { onChange(date) }
        }
    }

    func screenshots(since: Date, completion: @escaping @MainActor ([ScreenshotAsset]) -> Void) {
        queue.async { [self] in
            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: Array(inserted.keys), options: nil)
            var result: [ScreenshotAsset] = []
            fetched.enumerateObjects { [self] asset, _, _ in
                guard asset.mediaSubtypes.contains(.photoScreenshot),
                      let date = asset.creationDate, date >= since,
                      let insertedAt = inserted[asset.localIdentifier] else { return }
                result.append(ScreenshotAsset(id: asset.localIdentifier, takenAt: date, insertedAt: insertedAt))
            }
            let candidates = result
            DispatchQueue.main.async { completion(candidates) }
        }
    }

    func loadImage(for asset: ScreenshotAsset, completion: @escaping @MainActor (Result<UIImage, Error>) -> Void) {
        queue.async { [self] in
            guard let photo = PHAsset.fetchAssets(withLocalIdentifiers: [asset.id], options: nil).firstObject,
                  photo.mediaSubtypes.contains(.photoScreenshot) else {
                DispatchQueue.main.async { completion(.failure(ScreenshotLibraryError.imageUnavailable)) }
                return
            }
            let options = PhotoScreenshotLibrary.imageRequestOptions()
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
