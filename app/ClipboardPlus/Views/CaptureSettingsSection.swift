import SwiftUI
import UIKit

/// Settings for the capture mode: opening it from an iPad screenshot, and how direct capture behaves.
/// The 0.9.0 "instant" capture was dropped after device testing, because iPadOS asked for
/// permission every time.
struct CaptureSettingsSection: View {
    @ObservedObject var screenCapture: ScreenCaptureController
    @ObservedObject var screenshots: ScreenshotWatcher
    @AppStorage(CaptureSettings.screenshotModeKey) private var screenshotMode = CaptureMode.text.rawValue
    @State private var deleteMessage: String?
    @State private var isDeleting = false

    var body: some View {
        Section {
            Toggle(isOn: Binding(
                get: { screenshots.isEnabled },
                set: { screenshots.setEnabled($0) }
            )) {
                Text("スクリーンショットで切り取りを開く")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: 44)
            accessNote
            if screenshots.isEnabled {
                Picker("開いたときの方式", selection: $screenshotMode) {
                    ForEach(CaptureMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .frame(minHeight: 44)
            }
            Text("iPadでスクリーンショットを撮ると、clipboard+がそれを拾って切り取りの画面を開きます。録画の表示は出ません。clipboard+を小窓やSlide Overで画面に出しておく必要があります。写真ライブラリの「すべての写真」へのアクセスが要ります。AssistiveTouchの1回タップにスクリーンショットを割り当てると、指1本で始められます。")
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)

            if screenshots.usedCount > 0 {
                Button(role: .destructive) {
                    deleteUsed()
                } label: {
                    Label("切り取りに使ったスクリーンショットを削除（\(screenshots.usedCount)枚）", systemImage: "trash")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(minHeight: 44)
                .disabled(isDeleting)
            }
            if let deleteMessage {
                Text(deleteMessage).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("切り取り")
        }
    }

    @ViewBuilder private var accessNote: some View {
        switch screenshots.access {
        case .limited:
            VStack(alignment: .leading, spacing: 6) {
                Text("写真へのアクセスが「選択した写真」になっているため、新しいスクリーンショットを見つけられません。「設定」で「すべての写真」に変えてください。")
                    .font(.footnote)
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                openSettingsButton
            }
        case .denied:
            VStack(alignment: .leading, spacing: 6) {
                Text("写真へのアクセスが許可されていません。使うには「設定」で「すべての写真」を許可してください。")
                    .font(.footnote)
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                openSettingsButton
            }
        case .notDetermined, .authorized:
            EmptyView()
        }
    }

    private var openSettingsButton: some View {
        Button("「設定」を開く") {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        }
        .font(.footnote.weight(.semibold))
        .frame(minHeight: 44)
    }

    private func deleteUsed() {
        isDeleting = true
        deleteMessage = nil
        screenshots.deleteUsed { result in
            isDeleting = false
            switch result {
            case .success(let count): deleteMessage = "\(count)枚を削除しました。"
            case .failure: deleteMessage = "削除しませんでした。"
            }
        }
    }
}

enum CaptureSettings {
    /// Which mode the capture screen starts in when opened from a screenshot.
    static let screenshotModeKey = "screenshotCaptureMode"
    /// Taking the screen directly (ScreenCaptureKit) is hidden since 0.11.0, like PiP: the
    /// shortcut with a screenshot became the main route. Off unless turned on for development.
    static let directCaptureKey = "directCaptureEnabled"

    static func screenshotMode(_ defaults: UserDefaults = .standard) -> CaptureMode {
        defaults.string(forKey: screenshotModeKey).flatMap(CaptureMode.init(rawValue:)) ?? .text
    }
}
