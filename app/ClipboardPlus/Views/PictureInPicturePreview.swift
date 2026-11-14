import AVFoundation
import SwiftUI

struct PictureInPicturePreview: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> PreviewView {
        PreviewView(displayLayer: displayLayer)
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        private let displayLayer: AVSampleBufferDisplayLayer

        init(displayLayer: AVSampleBufferDisplayLayer) {
            self.displayLayer = displayLayer
            super.init(frame: .zero)
            layer.addSublayer(displayLayer)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { return nil }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            displayLayer.frame = bounds
            CATransaction.commit()
        }
    }
}
