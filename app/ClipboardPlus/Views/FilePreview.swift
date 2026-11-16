import QuickLook
import SwiftUI

/// Shows a saved file with Quick Look, under its original name. The file is the history's own
/// copy, so it may be gone if the item was deleted while this sheet was on its way.
struct FilePreview: View {
    let file: HistoryFile
    let url: URL
    let onCopy: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if FileManager.default.fileExists(atPath: url.path) {
                    QuickLookView(url: url, title: file.displayName)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    ContentUnavailableView(
                        "ファイルが見つかりません",
                        systemImage: "questionmark.folder",
                        description: Text("履歴から削除されたか、保存が終わっていません。")
                    )
                }
            }
            .navigationTitle(file.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }.frame(minWidth: 44, minHeight: 44)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("コピー", systemImage: "doc.on.doc") { onCopy() }
                        .frame(minWidth: 44, minHeight: 44)
                }
            }
        }
        .tint(Theme.accent)
    }
}

private struct QuickLookView: UIViewControllerRepresentable {
    let url: URL
    let title: String

    func makeCoordinator() -> Coordinator {
        Coordinator(item: PreviewItem(url: url, title: title))
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let item: PreviewItem

        init(item: PreviewItem) {
            self.item = item
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewItem(at index: Int, for controller: QLPreviewController) -> QLPreviewItem { item }
    }

    /// Quick Look reads the type from the stored name's extension and shows the original name.
    final class PreviewItem: NSObject, QLPreviewItem {
        let previewItemURL: URL?
        let previewItemTitle: String?

        init(url: URL, title: String) {
            previewItemURL = url
            previewItemTitle = title
        }
    }
}
