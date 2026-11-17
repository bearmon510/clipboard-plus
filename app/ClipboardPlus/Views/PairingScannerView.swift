import AVFoundation
import SwiftUI
import UIKit
import VisionKit

/// Reads the QR code that clipboard+ for Windows shows, to pair with that PC.
struct PairingScannerView: View {
    /// Tries a scanned code. Returns a message to show when it is not a usable code, or nil
    /// when pairing worked and the sheet can close.
    let onCode: (String) -> String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var access = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var message: String?
    /// The scanner reports the same code again while it stays in view; try each one once.
    @State private var lastCode: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("QRコードを読む")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("キャンセル") { dismiss() }
                    }
                }
        }
        .tint(Theme.accent)
        .task {
            guard access == .notDetermined else { return }
            access = await AVCaptureDevice.requestAccess(for: .video) ? .authorized : .denied
        }
    }

    @ViewBuilder private var content: some View {
        if !DataScannerViewController.isSupported {
            unavailable(title: "このiPadではQRコードを読めません",
                        text: "カメラで文字やコードを読む機能に対応していないため、組にできません。",
                        showsSettings: false)
        } else if access == .notDetermined {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if access == .authorized {
            ZStack(alignment: .bottom) {
                QRScanner { code in handle(code) }
                    .ignoresSafeArea(edges: .bottom)
                VStack(spacing: 6) {
                    if let message {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.subheadline.weight(.semibold))
                    }
                    Text("PCの「clipboard+ for Windows」に出ているQRコードを、枠の中に入れてください。")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                }
                .padding(14)
                .frame(maxWidth: 480)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                .padding(16)
            }
        } else {
            unavailable(title: "カメラが許可されていません",
                        text: "「設定」でclipboard+のカメラをオンにすると、QRコードを読めます。",
                        showsSettings: true)
        }
    }

    private func unavailable(title: String, text: String, showsSettings: Bool) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text(title).font(.headline)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if showsSettings {
                Button("設定を開く") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
            }
        }
        .padding(28)
        .frame(maxWidth: 440)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func handle(_ code: String) {
        guard code != lastCode else { return }
        lastCode = code
        if let error = onCode(code) {
            message = error
        } else {
            dismiss()
        }
    }
}

private struct QRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onCode = onCode
        // Starting needs the camera granted and the scanner on screen, so it is retried here.
        if !scanner.isScanning, DataScannerViewController.isAvailable {
            try? scanner.startScanning()
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCode: (String) -> Void

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let barcode) = item, let value = barcode.payloadStringValue {
                    onCode(value)
                    return
                }
            }
        }
    }
}
