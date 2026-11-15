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
                        title: "スクリーンショットから（おすすめ）",
                        symbol: "camera.viewfinder",
                        lead: "撮った瞬間の画面から切り取ります。録画の表示は出ません。設定の「切り取り」で「スクリーンショットで切り取りを開く」をオンにします。",
                        steps: [
                            "clipboard+をSlide Overや小窓で画面に出しておきます。",
                            "iPadでスクリーンショットを撮ります。clipboard+に切り取りの画面が開きます。",
                            "ほしい範囲をドラッグします。指の上に拡大鏡が出ます。指を離すとコピーされます。",
                            "使ったスクリーンショットは写真に残ります。設定の「切り取り」からまとめて削除できます。",
                        ]
                    )
                    VStack(alignment: .leading, spacing: 6) {
                        Label("スクリーンショットを撮りやすくする", systemImage: "hand.tap").font(.subheadline.weight(.semibold))
                        Text("「設定」→「アクセシビリティ」→「タッチ」→「AssistiveTouch」をオンにし、「カスタムアクション」の「シングルタップ」に「スクリーンショット」を選びます。画面に浮かぶボタンを1回押すだけで撮れます。")
                        Text("iPadの「設定」で、スクリーンショットをフルスクリーンでプレビューする設定をオフにすると、撮ってすぐ切り取りに移れます。")
                        Text("画面の隅からのスワイプにスクリーンショットを割り当てる方法もあります（「設定」の「マルチタスクとジェスチャ」）。")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                    section(
                        title: "画面を直接取り込む",
                        symbol: "text.viewfinder",
                        lead: "写真へのアクセスを使わない方法です。iPadOS 27以降で使えます。",
                        steps: [
                            "上の「文字」か「画像」を押します。最初の1回は、画面の取り込みを許可する画面が出ます。「画面全体」を選んでください。",
                            "その時点の画面が止まって表示されます。範囲を選んで指を離すとコピーされます。",
                        ]
                    )
                    VStack(alignment: .leading, spacing: 6) {
                        Label("知っておくこと", systemImage: "info.circle").font(.subheadline.weight(.semibold))
                        Text("画面を直接取り込んでいる間は、ボタンに緑の点が付き、録画中の表示が出ます。clipboard+を隠すか、最後の切り取りから5分たつと止まります。メニューから止めることもできます。")
                        Text("取り込んだ画面は保存せず、外へ送りません。文字の読み取りもiPadの中で行います。")
                        Text("Slide Overで重ねているときは、clipboard+の下に隠れた部分は写りません。反対側へ動かしてから切り取ってください。")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                    section(
                        title: "保存した画像から",
                        symbol: "photo.on.rectangle",
                        lead: "iPadOS 26以前や、ほかの方法を使わないときの方法です。",
                        steps: [
                            "スクリーンショットを撮り、プレビューから「コピー」を選びます。履歴に画像が入ります。",
                            "履歴の画像の「⋯」から「文字で切り取る」か「画像で切り取る」を選ぶと、同じ方法で範囲を選べます。",
                        ]
                    )
                    section(
                        title: "ショートカットで範囲を選ぶ",
                        symbol: "square.on.square.dashed",
                        lead: "文字用と画像用を別々に作ると、呼び出すだけでその方式の切り取りが開きます。スクリーンショットは写真に残りません。",
                        steps: [
                            "「ショートカット」アプリで新しいショートカットを作り、「スクリーンショットを撮る」を置きます。",
                            "続けてclipboard+の「画面を切り取る」を置き、方式を「文字」か「画像」にします。",
                            "名前を「文字を切り取る」などにします。画像用も同じように作ります。",
                        ]
                    )
                    section(
                        title: "ショートカットで、アプリを開かずに",
                        symbol: "list.bullet.rectangle",
                        lead: "画面の文字を行ごとに一覧で出し、選んだ行をコピーします。clipboard+へ移りません。",
                        steps: [
                            "「スクリーンショットを撮る」を置きます。",
                            "clipboard+の「画像の文字を行ごとに取り出す」を置きます。",
                            "「リストから選択」を置き、「複数を選択」をオンにします。",
                            "clipboard+の「clipboard+に追加」を置きます。選んだ行が1件にまとまってコピーされます。",
                            "画面の文字を全部コピーするだけなら、2の代わりに「画像の文字を読み取る」を置き、「コピーして履歴に保存」をオンにします。",
                        ]
                    )
                    VStack(alignment: .leading, spacing: 6) {
                        Label("ショートカットの呼び出し方", systemImage: "hand.tap").font(.subheadline.weight(.semibold))
                        Text("AssistiveTouch：「カスタムアクション」のシングルタップ、ダブルタップ、長押しに、別々のショートカットを割り当てられます。例えば、シングルタップで文字、ダブルタップで画像、長押しで一覧から選ぶ、とします。")
                        Text("Apple Pencil Pro：「設定」→「Apple Pencil」→「握る」で「ショートカット」を選びます。")
                        Text("コントロールセンター：作ったショートカットを置けます。clipboard+の「文字を切り取る」「画像を切り取る」も置けます。こちらはスクリーンショットを撮らずに、画面を直接取り込みます。")
                        Text("Siri：「clipboard+で文字を切り取る」と話しかけても始められます。")
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
