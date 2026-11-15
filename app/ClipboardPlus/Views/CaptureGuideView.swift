import SwiftUI

/// Explains the two ways to cut out a part of the screen, with the one-time setup each needs.
struct CaptureGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("画面の一部を選んで、文字を読み取ったり、画像として保存したりできます。やり方は2つあります。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    section(
                        title: "すぐ使える方法",
                        symbol: "camera.viewfinder",
                        lead: "iPadのスクリーンショットを使います。準備は要りません。",
                        steps: [
                            "スクリーンショットを撮ります。",
                            "左下に出る小さな画像をタップし、枠の角を引いて範囲を決めます。",
                            "「完了」→「コピーして削除」を選びます。clipboard+の履歴に入ります。",
                            "文字がほしいときは、履歴の画像の「⋯」から「文字を読み取る」を選びます。",
                        ]
                    )
                    section(
                        title: "1回のタップで始める方法",
                        symbol: "hand.tap",
                        lead: "ショートカットを1つ作ると、どの画面からでも切り取りを始められます。",
                        steps: [
                            "「ショートカット」アプリで新しいショートカットを作り、「スクリーンショットを撮る」を追加します。",
                            "続けて、clipboard+の「画面を切り取る」を追加します。名前は「切り取り」などにします。",
                            "「設定」→「アクセシビリティ」→「タッチ」→「AssistiveTouch」をオンにし、「カスタムアクション」のどれかにこのショートカットを割り当てます。",
                            "画面に浮かぶボタンをその操作で押すと、今の画面が止まった状態でclipboard+が開きます。範囲を選んで「文字を読み取る」か「画像で保存」を押します。",
                        ]
                    )
                    Text("ショートカットは、コントロールセンターやApple Pencil Proのスクイーズにも割り当てられます。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("読み取りはiPadの中で行い、画像や文字を外へ送りません。読み取った文字と切り取った画像は、履歴に保存してクリップボードにも入れます。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.page)
            .navigationTitle("画面の切り取り")
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
