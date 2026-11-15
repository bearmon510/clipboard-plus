import AppIntents
import Combine
import UIKit

/// A picture waiting to be cut out or read. `id` lets a sheet tell two pictures apart.
struct CaptureSource: Identifiable {
    let id = UUID()
    /// Upright pixels, so that a rectangle on screen maps straight onto the picture.
    let image: UIImage

    init(image: UIImage) {
        self.image = CaptureSource.upright(image)
    }

    /// Photos may carry a rotation flag instead of rotated pixels. Cropping works on the pixels,
    /// so the flag is applied here once.
    private static func upright(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up || image.cgImage == nil else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}

/// Hands a screenshot from a shortcut to the screen. The intent runs in the app's process.
@MainActor
final class CaptureInbox: ObservableObject {
    static let shared = CaptureInbox()
    @Published var pending: CaptureSource?
}

enum CaptureIntentError: Error, CustomLocalizedStringResourceConvertible {
    case unreadableImage

    var localizedStringResource: LocalizedStringResource {
        "画像を読み込めませんでした。スクリーンショットか画像を渡してください。"
    }
}

/// Used from the Shortcuts app after "スクリーンショットを撮る": opens clipboard+ on the picture so
/// that a part of it can be chosen, then read as text or saved as a picture.
struct CaptureRegionIntent: AppIntent {
    static let title: LocalizedStringResource = "画面を切り取る"
    static let description: IntentDescription? = IntentDescription("スクリーンショットや画像から範囲を選び、文字を読み取るか、画像として保存します。")
    static let openAppWhenRun: Bool = true

    @Parameter(title: "画像", supportedTypeIdentifiers: ["public.image"])
    var picture: IntentFile

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let image = UIImage(data: picture.data) else { throw CaptureIntentError.unreadableImage }
        CaptureInbox.shared.pending = CaptureSource(image: image)
        return .result()
    }
}
