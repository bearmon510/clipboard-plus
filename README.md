# clipboard+

clipboard+（クリップボードプラス）は、iPadでコピーした文章・URL・画像を保存し、タッチ操作で使い直せるクリップボード管理アプリ。

ウインドウ表示やStage Managerの小窓で使うことを想定し、現在のウインドウサイズに合わせた画面を設計する。

## 開発状況

競合調査と外部レビュー2件を整理した。最初の試作は、Safariの横で連続コピーした文章を、小窓から選んでメモへ戻す操作を対象にする。[レビュー結果と試作方針](docs/レビュー結果と試作方針.md)

文章を対象にした試作1のソースは `app/ClipboardPlus/`、純粋なロジックの単体テストは `app/ClipboardPlusTests/` にある。GitHub ActionsのmacOS 26上で `app/project.yml` からXcodeGenでプロジェクトを生成し、署名なしビルドとiPadシミュレータでのテストを行う。Windowsでのコンパイルと、iPad実機での動作確認は未実施。

## 開発方針

- 文章・URL・画像の履歴保存
- 小窓で使える一覧、検索、ピン留め
- 共有メニューとドラッグによる保存・再利用
- 記録の一時停止、削除の取り消し、容量管理
- 端末内保存とバックアップ

対応OSはiPadOS 17以降を候補とし、実装・検証を通して確定する。

最初の試作の範囲、Macなしの開発経路、試験の手順は[試作1の実装方針](docs/試作1の実装方針.md)に記載している。

## 開発ツール

Claude Codeを司令塔とし、Codex CLIへ実装・レビューを依頼する。[CLAUDE.md](CLAUDE.md)に役割と呼び出し方法を記載している。VS CodeのClaude Code拡張でこのフォルダを開いて利用する。

呼び出しにはNode.jsとログイン済みのCodex CLIが必要。プロジェクトルートで次を実行すると、読み取り専用でCodexにレビューを依頼できる。

```sh
node scripts/invoke-codex.mjs --mode review --task "README.mdを読んで開発状況を確認してください"
```

実装時は `--mode implement` を指定する。`--model` と `--effort` でモデルと推論の強さを指定できる。Codexが利用制限に達した場合は、解除時刻まで待って自動で再実行する。Windowsではnpmでインストールした `codex.cmd` を利用する。
