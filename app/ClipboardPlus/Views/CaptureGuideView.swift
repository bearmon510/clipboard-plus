import SwiftUI

/// Explains how to cut out a part of the screen, and the other routes when the main one is unavailable.
struct CaptureGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("画面の一部を選んで、その範囲の文字か画像をクリップボードにコピーします。コピーしたものは履歴にも残ります。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    section(
                        title: "基本の使い方",
                        symbol: "text.viewfinder",
                        lead: "clipboard+をSlide Overや小窓で横に置いて使います。iPadOS 27以降で使えます。",
                        steps: [
                            "上の「文字」か「画像」を押します。最初の1回は、画面の取り込みを許可する画面が出ます。「画面全体」を選んでください。",
                            "その時点の画面が止まって表示されます。ほしい範囲をドラッグします。指の上に拡大鏡が出ます。",
                            "指を離すとコピーされます。そのまま隣のアプリに貼り付けられます。",
                        ]
                    )
                    VStack(alignment: .leading, spacing: 6) {
                        Label("知っておくこと", systemImage: "info.circle").font(.subheadline.weight(.semibold))
                        Text("画面を取り込んでいる間は、ボタンに緑の点が付きます。clipboard+を隠すか、最後の切り取りから5分たつと止まります。メニューから止めることもできます。")
                        Text("取り込んだ画面は保存せず、外へ送りません。文字の読み取りもiPadの中で行います。")
                        Text("Slide Overで重ねているときは、clipboard+の下に隠れた部分は写りません。反対側へ動かしてから切り取ってください。")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                    section(
                        title: "スクリーンショットから",
                        symbol: "camera.viewfinder",
                        lead: "iPadOS 26以前や、画面の取り込みを許可しないときの方法です。",
                        steps: [
                            "スクリーンショットを撮り、左下の小さな画像から「コピーして削除」を選びます。履歴に画像が入ります。",
                            "履歴の画像の「⋯」から「文字で切り取る」か「画像で切り取る」を選ぶと、同じ方法で範囲を選べます。",
                        ]
                    )
                    section(
                        title: "ショートカットから",
                        symbol: "hand.tap",
                        lead: "ショートカットを1つ作ると、AssistiveTouchなどの操作1回で始められます。",
                        steps: [
                            "「ショートカット」アプリで、「スクリーンショットを撮る」と、clipboard+の「画面を切り取る」を順に並べます。",
                            "「設定」→「アクセシビリティ」→「タッチ」→「AssistiveTouch」の「カスタムアクション」に割り当てます。",
                        ]
                    )
                }
                .padding(16)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.page)
            .navigationTitle("切り取りの使い方")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }.frame(minWidth: 44, minHeight: 44)
                }
            }
        }
        .tint(Theme.accent)
    }

    private func section(title: String, symbol: String, lead: String, steps: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.headline)
            Text(lead)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 22, height: 22)
                        .background(Theme.accent, in: Circle())
                    Text(step)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }
}
