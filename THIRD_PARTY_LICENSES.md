# 第三者ソフトウェア・辞書データのライセンス表記

clipboard+ の日本語かな漢字変換機能では、Swift Package Manager 経由で以下のオープンソースソフトウェアおよび辞書データを利用します（リポジトリ内に第三者のバイナリやソースコード本体は複製せず、ビルド時にパッケージとして取得します）。

App Store / TestFlight へ配布する際は、本体アプリの設定画面（`SettingsView`）から参照できるライセンス／謝辞画面にも以下の著作権表示とライセンス本文（MIT / Apache-2.0）を掲載する必要があります。

## 1. AzooKeyKanaKanjiConverter（MIT License）

- リポジトリ: https://github.com/azooKey/AzooKeyKanaKanjiConverter
- 固定版: `v0.11.2`

```text
MIT License

Copyright (c) 2023 Miwa / Ensan

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## 2. azooKey_dictionary_storage（Apache License 2.0）

`KanaKanjiConverterModuleWithDefaultDictionary` のサブモジュールとしてバンドルに含まれる日本語かな漢字変換用辞書データです。

- リポジトリ: https://github.com/ensan-hcl/azooKey_dictionary_storage
- 著作権表示: `Copyright 2024 Miwa / ensan`
- ライセンス: Apache License, Version 2.0（全文: https://www.apache.org/licenses/LICENSE-2.0 / リポジトリ内 `LICENSE`）

## 3. azooKey_emoji_dictionary_storage（絵文字辞書サブモジュール）

`KanaKanjiConverterModuleWithDefaultDictionary` のもう 1 つのサブモジュールとして同梱される絵文字辞書データです。同リポジトリのルートには単独の `LICENSE` ファイルが置かれておらず、`README.md`（https://github.com/ensan-hcl/azooKey_emoji_dictionary_storage/blob/main/README.md）に Mozc の `emoji_data.tsv`、Unicode Emoji データおよび CLDR 日本語データから生成する構成が記載されています。

## 4. AzooKeyKanaKanjiConverter が依存する Swift パッケージ

- **swift-tokenizers**（`ensan-hcl/swift-tokenizers`）: Apache License 2.0
- **Jinja**（`johnmai-dev/Jinja`、`swift-tokenizers` 経由）: Apache License 2.0
- **swift-algorithms**（`apple/swift-algorithms`）: Apache License 2.0 with Runtime Library Exception
- **swift-collections**（`apple/swift-collections`）: Apache License 2.0 with Runtime Library Exception
- **swift-argument-parser**（`apple/swift-argument-parser`）: Apache License 2.0 with Runtime Library Exception

## 5. 上流辞書・形態素解析リソースに関する補足

`azooKey` 本体のオープンソースソフトウェア表示（https://github.com/azooKey/azooKey/blob/main/MainApp/Features/Settings/About/OpenSourceSoftwaresLicenseView.swift）では、辞書の構築基盤・語彙データとして以下も謝辞・ライセンス表示に含めています。一般公開前の本体アプリ内ライセンス画面の整備時に、実際の収録辞書構成に合わせて記載対象を最終確認してください。

- SudachiDict（Apache License 2.0）
- IPAdic（奈良先端科学技術大学院大学 / ICOT Free Software）
- MeCab（GPL / LGPL / BSD）
- mecab-ipadic-NEologd
- Mozc（BSD 3-Clause License, Copyright 2010-2022, Google Inc.）
- japanese-word2vec-model-builder
- Emoji-IME-Dictionary / Kaomojitoka to Google IME Dictionary / Kaomojic（絵文字・顔文字候補を使用する場合）
