import SwiftUI
import UIKit

/// Shows a picture, usually a screenshot, dimmed like a frozen screen. Dragging chooses a part;
/// the two main buttons then read the text in that part or save it as a picture.
/// With nothing chosen, both buttons work on the whole picture.
struct CaptureView: View {
    let source: CaptureSource
    /// Called with text that was read. The caller saves it and puts it on the pasteboard.
    let onText: (String) -> Void
    /// Called with the chosen part as PNG data. The caller saves it and puts it on the pasteboard.
    let onImage: (Data) -> Void
    let onClose: () -> Void

    /// The chosen part in the picture's unit space. Nil means the whole picture.
    @State private var selection: CGRect?
    @State private var dragMode: CropGeometry.DragMode?
    @State private var selectionAtDragStart: CGRect?
    @State private var isReading = false
    @State private var outcome: Outcome?

    private enum Outcome: Equatable {
        case text(String)
        case noText
        case failed
    }

    init(source: CaptureSource, initialSelection: CGRect? = nil,
         onText: @escaping (String) -> Void, onImage: @escaping (Data) -> Void, onClose: @escaping () -> Void) {
        self.source = source
        self.onText = onText
        self.onImage = onImage
        self.onClose = onClose
        _selection = State(initialValue: initialSelection)
    }

    var body: some View {
        // The picture fills the whole window like a frozen screen. The panels stay
        // inside the safe area so that they clear the home indicator.
        ZStack {
            canvas.ignoresSafeArea()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) { hint }
        .overlay(alignment: .bottom) { bottomPanel }
        .tint(Theme.accent)
        .statusBarHidden(true)
    }

    private var canvas: some View {
        GeometryReader { proxy in
            let frame = CropGeometry.fittedFrame(imageSize: source.image.size, in: proxy.size)
            ZStack(alignment: .topLeading) {
                Color.black
                Image(uiImage: source.image)
                    .resizable()
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                    .accessibilityLabel("切り取る画像")
                shade(frame: frame, container: proxy.size)
                if let selection {
                    selectionOutline(CropGeometry.viewRect(selection, in: frame))
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(frame: frame))
        }
    }

    // MARK: Picture and selection

    /// Darkens everything except the chosen part.
    private func shade(frame: CGRect, container: CGSize) -> some View {
        Path { path in
            path.addRect(CGRect(origin: .zero, size: container))
            if let selection {
                path.addRect(CropGeometry.viewRect(selection, in: frame))
            }
        }
        .fill(Color.black.opacity(selection == nil ? 0.28 : 0.55), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
    }

    private func selectionOutline(_ rect: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .strokeBorder(Color.white, lineWidth: 2)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
            ForEach(0..<4, id: \.self) { index in
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().strokeBorder(Theme.accent, lineWidth: 3))
                    .frame(width: 18, height: 18)
                    .offset(x: (index % 2 == 0 ? rect.minX : rect.maxX) - 9,
                            y: (index < 2 ? rect.minY : rect.maxY) - 9)
            }
        }
        .shadow(color: Color.black.opacity(0.4), radius: 3)
        .allowsHitTesting(false)
    }

    private func dragGesture(frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard outcome == nil, !isReading else { return }
                let current = selection.map { CropGeometry.viewRect($0, in: frame) }
                if dragMode == nil {
                    dragMode = CropGeometry.dragMode(at: value.startLocation, selection: current)
                    selectionAtDragStart = current
                }
                let rect: CGRect
                switch dragMode {
                case .move:
                    rect = CropGeometry.moved(selectionAtDragStart ?? .zero, by: value.translation, within: frame)
                case .resize(let anchor):
                    rect = CropGeometry.rect(from: anchor, to: value.location, within: frame)
                case .new, .none:
                    rect = CropGeometry.rect(from: value.startLocation, to: value.location, within: frame)
                }
                selection = CropGeometry.unit(rect, in: frame)
            }
            .onEnded { _ in
                dragMode = nil
                selectionAtDragStart = nil
                // A tap, or a sliver too small to mean anything, clears the choice.
                if let selection {
                    let rect = CropGeometry.viewRect(selection, in: frame)
                    if rect.width < 12 || rect.height < 12 { self.selection = nil }
                }
            }
    }

    // MARK: Panels

    @ViewBuilder private var hint: some View {
        if outcome == nil {
            Text(selection == nil ? "ドラッグして範囲を選べます。選ばなければ全体が対象です。" : "角を引くと大きさを変えられます。外側をドラッグすると選び直せます。")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Color.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.6), in: Capsule())
                .padding(.top, 14)
                .padding(.horizontal, 16)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder private var bottomPanel: some View {
        if let outcome {
            resultPanel(outcome)
        } else {
            actionBar
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 48, height: 48)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .accessibilityLabel("閉じる")
            Button {
                readText()
            } label: {
                actionLabel(isReading ? "読み取り中" : "文字を読み取る", "text.viewfinder")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isReading)
            Button {
                saveImage()
            } label: {
                actionLabel("画像で保存", "crop")
            }
            .buttonStyle(.bordered)
            .disabled(isReading)
        }
        .buttonBorderShape(.roundedRectangle(radius: 14))
        .padding(10)
        .frame(maxWidth: 480)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 14)
    }

    private func actionLabel(_ title: String, _ symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.body.weight(.semibold))
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 34)
    }

    private func resultPanel(_ outcome: Outcome) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            switch outcome {
            case .text(let text):
                Label("読み取ってコピーしました", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                ScrollView {
                    Text(text)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            case .noText:
                Label("文字が見つかりませんでした", systemImage: "text.badge.xmark")
                    .font(.subheadline.weight(.semibold))
                Text("範囲を選び直すと読み取れることがあります。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .failed:
                Label("文字を読み取れませんでした", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.red)
            }
            HStack(spacing: 10) {
                Button {
                    self.outcome = nil
                } label: {
                    Text("続けて選ぶ").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.bordered)
                Button {
                    onClose()
                } label: {
                    Text("閉じる").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.borderedProminent)
            }
            .buttonBorderShape(.roundedRectangle(radius: 14))
        }
        .padding(14)
        .frame(maxWidth: 480)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 14)
    }

    // MARK: Actions

    /// The chosen part of the picture, or the whole picture when nothing is chosen.
    private func chosenImage() -> CGImage? {
        guard let whole = source.image.cgImage else { return nil }
        guard let selection else { return whole }
        return whole.cropping(to: CropGeometry.pixelRect(selection, imageWidth: whole.width, imageHeight: whole.height))
    }

    private func readText() {
        guard let image = chosenImage() else { outcome = .failed; return }
        isReading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try TextRecognizer.text(in: image) }
            DispatchQueue.main.async {
                isReading = false
                switch result {
                case .success(let text) where !text.isEmpty:
                    onText(text)
                    outcome = .text(text)
                case .success:
                    outcome = .noText
                case .failure:
                    outcome = .failed
                }
            }
        }
    }

    private func saveImage() {
        guard let image = chosenImage(), let data = UIImage(cgImage: image).pngData() else {
            outcome = .failed
            return
        }
        onImage(data)
        onClose()
    }
}
