import AVFoundation
import SwiftUI

struct PictureInPicturePreview: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer
    let onReadinessChanged: (Bool) -> Void

    func makeUIView(context: Context) -> PreviewView {
        PreviewView(displayLayer: displayLayer, onReadinessChanged: onReadinessChanged)
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        private let displayLayer: AVSampleBufferDisplayLayer
        private let onReadinessChanged: (Bool) -> Void
        private var lastReadiness: Bool?

        init(displayLayer: AVSampleBufferDisplayLayer, onReadinessChanged: @escaping (Bool) -> Void) {
            self.displayLayer = displayLayer
            self.onReadinessChanged = onReadinessChanged
            super.init(frame: .zero)
            layer.addSublayer(displayLayer)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { return nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            reportReadiness()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            displayLayer.frame = bounds
            CATransaction.commit()
            reportReadiness()
        }

        private func reportReadiness() {
            // Report after SwiftUI's update, using the latest window and bounds.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let ready = self.window != nil && self.bounds.width > 0 && self.bounds.height > 0
                    && self.displayLayer.superlayer === self.layer && !self.displayLayer.bounds.isEmpty
                guard ready != self.lastReadiness else { return }
                self.lastReadiness = ready
                self.onReadinessChanged(ready)
            }
        }
    }
}
