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
                        title: "ショートカットで切り取る（おすすめ）",
                        symbol: "camera.viewfinder",
                        lead: "スクリーンショットを撮って、そのままclipboard+の切り取りを開くショートカットを作ります。AssistiveTouchに割り当てると、浮かぶボタンを1回押すだけで始められます。スクリーンショットは写真に残りません。",
                        steps: [
                            "「ショートカット」アプリで新しいショートカットを作り、「スクリーンショットを撮る」を置きます。",
                            "続けてclipboard+の「画面を切り取る」を置き、方式を「文字」にします。名前は「文字を切り取る」などにします。",
                            "「設定」→「アクセシビリティ」→「タッチ」→「AssistiveTouch」をオンにし、「カスタムアクション」の「シングルタップ」で、作ったショートカットを選びます。",
                            "ボタンを押すと、clipboard+に切り取りの画面が開きます。ほしい範囲をドラッグし、指を離すとコピーされます。",
                        ]
                    )
                    VStack(alignment: .leading, spacing: 6) {
                        Label("もっと便利にする", systemImage: "hand.tap").font(.subheadline.weight(.semibold))
                        Text("画像用も作る：方式を「画像」にしたショートカットを作り、AssistiveTouchの「ダブルタップ」に割り当てます。")
                        Text("Apple Pencil Pro：「設定」→「Apple Pencil」→「握る」で「ショートカット」を選ぶと、握るだけで始められます。")
                        Text("コントロールセンター：「ショートカット」のボタンを置き、作ったショートカットを選びます。")
                        Text("Siri：ショートカットの名前で呼べます。「文字を切り取る」と話しかけます。")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                    section(
                        title: "アプリを開かずに、行を選んでコピー",
                        symbol: "list.bullet.rectangle",
                        lead: "画面の文字を行ごとに一覧で出し、選んだ行をコピーします。clipboard+へ移りません。AssistiveTouchの「長押し」に割り当てると便利です。",
                        steps: [
                            "「スクリーンショットを撮る」を置きます。",
                            "clipboard+の「画像の文字を行ごとに取り出す」を置きます。",
                            "「リストから選択」を置き、「複数を選択」をオンにします。",
                            "clipboard+の「clipboard+に追加」を置きます。選んだ行が1件にまとまってコピーされます。",
                            "画面の文字を全部コピーするだけなら、2の代わりに「画像の文字を読み取る」を置き、「コピーして履歴に保存」をオンにします。",
                        ]
                    )
                    section(
                        title: "普段のスクリーンショットから",
                        symbol: "photo.badge.checkmark",
                        lead: "ショートカットを作らずに、iPadで撮ったスクリーンショットから切り取りを開きます。設定の「切り取り」で「スクリーンショットで切り取りを開く」をオンにします。写真へのアクセスが要ります。",
                        steps: [
                            "clipboard+をSlide Overや小窓で画面に出しておきます。",
                            "iPadでスクリーンショットを撮ると、clipboard+に切り取りの画面が開きます。フルスクリーンのプレビューをオフにしておくと、すぐ移れます。",
                            "使ったスクリーンショットは写真に残ります。設定の「切り取り」からまとめて削除できます。",
                        ]
                    )
                    section(
                        title: "保存した画像から",
                        symbol: "photo.on.rectangle",
                        lead: "履歴に入っている画像からも切り取れます。",
                        steps: [
                            "履歴の画像の「⋯」から「文字で切り取る」か「画像で切り取る」を選ぶと、同じ方法で範囲を選べます。",
                        ]
                    )
                    VStack(alignment: .leading, spacing: 6) {
                        Label("知っておくこと", systemImage: "info.circle").font(.subheadline.weight(.semibold))
                        Text("文字の読み取りはiPadの中で行い、画面を外へ送りません。")
                        Text("Slide Overで重ねているときは、clipboard+の下に隠れた部分は写りません。反対側へ動かしてから撮ってください。")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
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
