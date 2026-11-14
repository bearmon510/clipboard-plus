import SwiftUI
import UIKit

struct ActivitySheet: UIViewControllerRepresentable {
    let url: URL
    let onFailure: (Error) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, error in
            if let error {
                DispatchQueue.main.async { self.onFailure(error) }
            }
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

