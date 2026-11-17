import SwiftUI
import UIKit

/// Shown once on the first launch, and again from the menu: what to set up and how the app
/// collects. Collection depends on the paste permission and on the app being on screen, and
/// neither is obvious without being told.
struct WelcomeView: View {
    /// Set once the guide has been closed, so it opens by itself only once.
    static let shownKey = "welcomeShown"

    /// Set by the snapshot tests to draw the other device's guide; nil uses this device.
    var deviceOverride: DeviceKind?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var showCaptureGuide = false

    private var device: DeviceKind { deviceOverride ?? .current }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("ほかのアプリでコピーした文章・リンク・画像・ファイルを、自動で履歴に残します。押すだけで、もう一度コピーできます。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 4)
                    step(number: 1, symbol: "hand.raised", title: "貼り付けを許可する",
                         text: "「設定」でclipboard+の「他のAppからペースト」を「許可」にしてください。そのままだと、コピーを読むたびに確認が出ます。") {
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        } label: {
                            Label("設定を開く", systemImage: "gear")
                                .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .frame(minHeight: 44)
                    }
                    if device == .phone {
                        step(number: 2, symbol: "arrow.uturn.backward.circle", title: "clipboard+に戻って残す",
                             text: "iPhoneでは、clipboard+を開いている間と、clipboard+に戻ったときに、コピーした内容を取り込みます。ほかのアプリでコピーしたら、clipboard+を開くと残ります。") {
                            EmptyView()
                        }
                    } else {
                        step(number: 2, symbol: "rectangle.righthalf.inset.filled", title: "画面に出して使う",
                             text: "Slide OverやStage Managerの小窓でclipboard+を出しておくと、ほかのアプリでコピーしたものが次々に残ります。全画面で別のアプリを使っている間は集められません。clipboard+に戻ったときに、そのときの内容を1件取り込みます。") {
                            EmptyView()
                        }
                    }
                    step(number: 3, symbol: "camera.viewfinder", title: "画面の一部を切り取る",
                         text: device == .phone
                            ? "スクリーンショットから範囲を選んで、文字か画像としてコピーできます。ショートカットをアクションボタンに割り当てると、ボタン1回で始められます。"
                            : "スクリーンショットから範囲を選んで、文字か画像としてコピーできます。ショートカットとAssistiveTouchを使うと、ボタン1回で始められます。") {
                        Button("切り取りの使い方") { showCaptureGuide = true }
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: 44)
                    }
                    step(number: 4, symbol: "square.stack", title: "よく使う文はテンプレートに",
                         text: "上の「テンプレート」に入れておくと、押すだけでコピーできます。履歴のカードの「…」から移すこともできます。テンプレートは自動では消えません。") {
                        EmptyView()
                    }
                }
                .padding(20)
                .frame(maxWidth: 600, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.page)
            .safeAreaInset(edge: .bottom) {
                Button {
                    dismiss()
                } label: {
                    Text("はじめる")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: 420, minHeight: 36)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
            .navigationTitle("clipboard+へようこそ")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showCaptureGuide) { CaptureGuideView(deviceOverride: deviceOverride) }
        }
        .tint(Theme.accent)
    }

    private func step<Extra: View>(number: Int, symbol: String, title: String, text: String,
                                   @ViewBuilder extra: () -> Extra) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3.weight(.medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44)
                .background(Theme.accent.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                extra()
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(number). \(title)")
    }
}
