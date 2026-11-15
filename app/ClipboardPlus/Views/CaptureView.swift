import SwiftUI
import UIKit

/// Shows a still picture of the screen. Dragging chooses a part of it, and lifting the finger
/// finishes: the text in that part, or the part as a picture, goes to the clipboard.
struct CaptureView: View {
    let source: CaptureSource
    /// Called with text that was read. The caller saves it and puts it on the pasteboard.
    let onText: (String) -> Void
    /// Called with the chosen part as PNG data. The caller saves it and puts it on the pasteboard.
    let onImage: (Data) -> Void
    let onClose: () -> Void

    @State private var mode: CaptureMode
    /// The chosen part in the picture's unit space.
    @State private var selection: CGRect?
    /// Where the finger is during a drag, in view coordinates. Drives the magnifier.
    @State private var touch: CGPoint?
    @State private var phase: Phase

    enum Phase: Equatable {
        case choosing
        case reading
        case noText
        case failed
    }

    private static let magnifierDiameter: CGFloat = 124

    /// `preview*` values let screenshot tests show a state that normally appears only mid-drag.
    init(source: CaptureSource, mode: CaptureMode,
         previewSelection: CGRect? = nil, previewTouch: CGPoint? = nil, previewPhase: Phase = .choosing,
         onText: @escaping (String) -> Void, onImage: @escaping (Data) -> Void, onClose: @escaping () -> Void) {
        self.source = source
        self.onText = onText
        self.onImage = onImage
        self.onClose = onClose
        _mode = State(initialValue: mode)
        _selection = State(initialValue: previewSelection)
        _touch = State(initialValue: previewTouch)
        _phase = State(initialValue: previewPhase)
    }

    var body: some View {
        // The picture fills the window like a frozen screen. The controls stay inside the
        // safe area so that they clear the home indicator.
        ZStack {
            canvas.ignoresSafeArea()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) { topBar }
        .tint(Theme.accent)
        .statusBarHidden(true)
    }

    // MARK: Picture

    private var canvas: some View {
        GeometryReader { proxy in
            let frame = CropGeometry.fittedFrame(imageSize: source.image.size, in: proxy.size)
            ZStack(alignment: .topLeading) {
                Color.black
                Image(uiImage: source.image)
                    .resizable()
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                    .accessibilityLabel("止めた画面")
                shade(frame: frame, container: proxy.size)
                if let selection {
                    selectionOutline(CropGeometry.viewRect(selection, in: frame))
                }
                if let touch, phase == .choosing {
                    magnifier(touch: touch, frame: frame, container: proxy.size)
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(frame: frame))
        }
    }

    /// Darkens everything except the chosen part.
    private func shade(frame: CGRect, container: CGSize) -> some View {
        Path { path in
            path.addRect(CGRect(origin: .zero, size: container))
            if let selection {
                path.addRect(CropGeometry.viewRect(selection, in: frame))
            }
        }
        .fill(Color.black.opacity(selection == nil ? 0.3 : 0.55), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
    }

    private func selectionOutline(_ rect: CGRect) -> some View {
        ZStack {
            Rectangle()
                .strokeBorder(Color.white, lineWidth: 2)
            if phase == .reading {
                ProgressView()
                    .controlSize(.large)
                    .tint(Color.white)
                    .padding(14)
                    .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .frame(width: rect.width, height: rect.height)
        .offset(x: rect.minX, y: rect.minY)
        .shadow(color: Color.black.opacity(0.45), radius: 3)
        .allowsHitTesting(false)
    }

    /// A round lens above the finger that shows the screen under it, enlarged,
    /// with a cross at the exact point. Without it, a narrow window makes small text hard to aim at.
    private func magnifier(touch: CGPoint, frame: CGRect, container: CGSize) -> some View {
        let diameter = Self.magnifierDiameter
        let scale = CropGeometry.magnification(displayedWidth: frame.width, imagePointWidth: source.image.size.width)
        let origin = CropGeometry.magnifiedOrigin(touch: touch, frame: frame, magnification: scale, diameter: diameter)
        let center = CropGeometry.magnifierCenter(for: touch, in: container, diameter: diameter, gap: 36)
        return ZStack(alignment: .topLeading) {
            Color.black
            Image(uiImage: source.image)
                .resizable()
                .frame(width: frame.width * scale, height: frame.height * scale)
                .offset(x: origin.x, y: origin.y)
            crosshair.frame(width: diameter, height: diameter)
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.white, lineWidth: 3))
        .shadow(color: Color.black.opacity(0.4), radius: 8, y: 2)
        .position(center)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var crosshair: some View {
        ZStack {
            Rectangle().fill(Theme.accent).frame(width: 18, height: 2)
            Rectangle().fill(Theme.accent).frame(width: 2, height: 18)
        }
    }

    private func dragGesture(frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard phase != .reading else { return }
                phase = .choosing
                touch = value.location
                let rect = CropGeometry.rect(from: value.startLocation, to: value.location, within: frame)
                selection = CropGeometry.unit(rect, in: frame)
            }
            .onEnded { value in
                guard phase == .choosing else { return }
                touch = nil
                let rect = CropGeometry.rect(from: value.startLocation, to: value.location, within: frame)
                // A stray tap does nothing, so that a slip of the finger never closes the screen.
                guard CropGeometry.isMeaningful(rect) else {
                    selection = nil
                    return
                }
                selection = CropGeometry.unit(rect, in: frame)
                finish()
            }
    }

    // MARK: Controls

    private var topBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                modePicker
                Spacer(minLength: 8)
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.white)
                        .frame(width: 44, height: 44)
                        .background(Color.black.opacity(0.55), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("切り取りをやめる")
            }
            notice
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .disabled(phase == .reading)
    }

    private var modePicker: some View {
        HStack(spacing: 2) {
            ForEach(CaptureMode.allCases) { value in
                Button {
                    mode = value
                } label: {
                    Label(value.title, systemImage: value.symbolName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(mode == value ? Color.black : Color.white)
                        .padding(.horizontal, 14)
                        .frame(height: 40)
                        .background(mode == value ? Color.white : Color.clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(mode == value ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(Color.black.opacity(0.55), in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("切り取ったものの扱い")
    }

    private var notice: some View {
        let text: String
        var symbol: String?
        switch phase {
        case .choosing: text = mode.hint
        case .reading: text = "文字を読み取っています"
        case .noText:
            text = "文字が見つかりませんでした。もう一度選んでください"
            symbol = "text.badge.xmark"
        case .failed:
            text = "切り取れませんでした。もう一度選んでください"
            symbol = "exclamationmark.triangle.fill"
        }
        return HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol) }
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(Color.white)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.6), in: Capsule())
        .allowsHitTesting(false)
    }

    // MARK: Finishing

    /// The chosen part of the picture, or nil when nothing usable is chosen.
    private func chosenImage() -> CGImage? {
        guard let whole = source.image.cgImage, let selection else { return nil }
        return whole.cropping(to: CropGeometry.pixelRect(selection, imageWidth: whole.width, imageHeight: whole.height))
    }

    private func finish() {
        guard let image = chosenImage() else {
            phase = .failed
            return
        }
        switch mode {
        case .image:
            guard let data = UIImage(cgImage: image).pngData() else {
                phase = .failed
                return
            }
            onImage(data)
            onClose()
        case .text:
            phase = .reading
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try TextRecognizer.text(in: image) }
                DispatchQueue.main.async {
                    switch result {
                    case .success(let text) where !text.isEmpty:
                        onText(text)
                        onClose()
                    case .success:
                        selection = nil
                        phase = .noText
                    case .failure:
                        selection = nil
                        phase = .failed
                    }
                }
            }
        }
    }
}
