import ImageIO
import SwiftUI
import UIKit

struct HistoryFileImage: View {
    let url: URL
    let maximumPixels: Int
    /// Rounds the picture itself, so no empty box shows around a tall or wide image.
    var cornerRadius: CGFloat = 0
    @State private var loaded: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let loaded {
                Image(uiImage: loaded).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else if failed {
                Label("画像を読み込めません", systemImage: "photo.badge.exclamationmark")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            loaded = nil
            failed = false
            let imageURL = url
            let pixelLimit = maximumPixels
            let result: UIImage? = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let image: UIImage? = autoreleasepool {
                        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                                kCGImageSourceCreateThumbnailFromImageAlways: true,
                                kCGImageSourceCreateThumbnailWithTransform: true,
                                kCGImageSourceThumbnailMaxPixelSize: pixelLimit,
                                kCGImageSourceShouldCacheImmediately: true
                              ] as CFDictionary) else { return nil }
                        return UIImage(cgImage: cgImage)
                    }
                    continuation.resume(returning: image)
                }
            }
            guard !Task.isCancelled else { return }
            loaded = result
            failed = result == nil
        }
    }
}

struct HistoryImagePreview: View {
    @Environment(\.dismiss) private var dismiss
    let image: HistoryImage
    let url: URL
    @State private var scale: CGFloat = 1
    @GestureState private var magnification: CGFloat = 1

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    HistoryFileImage(url: url, maximumPixels: 2_560)
                        .frame(width: geometry.size.width * max(1, scale * magnification),
                               height: geometry.size.height * max(1, scale * magnification))
                }
                .gesture(MagnificationGesture()
                    .updating($magnification) { value, state, _ in state = value }
                    .onEnded { scale = min(5, max(1, scale * $0)) })
            }
            .safeAreaInset(edge: .bottom) {
                Text("\(image.pixelWidth) × \(image.pixelHeight) px · \(ByteCountFormatter.string(fromByteCount: Int64(image.byteCount), countStyle: .decimal))")
                    .font(.caption).padding().frame(maxWidth: .infinity).background(.regularMaterial)
            }
            .navigationTitle("画像")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("倍率を戻す") { scale = 1 }.frame(minHeight: 44)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }.frame(minWidth: 44, minHeight: 44)
                }
            }
        }
    }
}
