# clipboard+ 同期プロトコルの試験データ

仕様は [Windows同期の方針.md の「通信の決まり（第1版）」](../docs/Windows同期の方針.md)。`make-test-vectors.mjs` はSwift/C#から独立した第3の実装で、暗号処理にはNode.js標準の `node:crypto` だけを使う（ファイル出力は `node:fs`）。鍵・乱数・識別子・時刻はすべて公開の固定試験値。実運用には使わない。

リポジトリ直下で生成する。外部パッケージ不要、結果は常に同じ。

```sh
node protocol/make-test-vectors.mjs
```

`test-vectors.json` にはQRとその読み取り結果、HELLO/WELCOME/AUTH、両HMAC、両方向の鍵、4種類の平文（item / ack / ping / pong）、両方向それぞれ番号0・1のフレーム、上限20/182/512バイトでの分割、失敗例を収録する。PC→iPadの番号1はpongの暗号フレーム。大きすぎるフレームはJSONを肥大化させないよう、長さと埋めるバイト値で指定してテスト内で生成する。終わりのない始まりは `finish: true` に従い組み立て終了を通知して検出する。

Swift/C#のテストは同じファイルから、QRの往復、接続確認の両側の状態遷移、HMACと鍵、平文・暗号文・タグ・パケットのバイト単位の一致、復号と組み立てを確かめる。さらに改ざん・巻き戻し・HMAC不一致・サイズ超過・不正な並びの拒否、失敗後の再使用禁止、厳密な入力検査、4MiBちょうどの境界を確認する。テストで暗号の期待値を実装自身から計算しない。

```powershell
& 'C:/Program Files/dotnet/dotnet.exe' build windows/ClipboardPlus.slnx
& 'C:/Program Files/dotnet/dotnet.exe' test windows/ClipboardPlus.slnx --no-build
```

NuGetへの接続が必要なのはxUnitとテストランナーの初回取得だけ。通信ライブラリ自体に外部パッケージはない。Swiftテストは `app/ClipboardPlusTests/SyncProtocolTests.swift`。`#filePath` から3階層上のリポジトリへ移動して試験データを読む。既存のXcodeGenのフォルダ指定で新しいSwiftファイルが対象になるため `app/project.yml` の編集は不要。WindowsではSwiftをビルドせず、push後のXcode 27.1のCIでコンパイルと実行を確認する。

## iPad接続層から使うAPI

すべてFoundation/CryptoKitだけで動作する。状態を持つ型は `final class` で、呼び出しは同じactor/直列キューにまとめる。接続確認・受信処理・平文の読み取りに失敗したら切断し、次の接続では新しいインスタンスを使う。

| 型 | 公開APIと役割 |
| --- | --- |
| `SyncPairing` | `init(pcId:key:name:)`、`create(name:)`、`parse(_:)`、`qrString()`、`pcId/key/name`。QRの読み書き。保存先やKeychainは今回の範囲外。 |
| `SyncPadHandshake` | `init(pairing:padId:testNonce:)` → `createHello()` → `acceptWelcome(_:)`。最後の戻り値 `SyncPadAuthentication` の `auth` を先に送り、`keys` を使う。実運用は `testNonce` を省略する。 |
| `SyncPcHandshake` | `init(pairing:expectedPadId:testNonce:)` → `acceptHello(_:)` がWELCOMEを返す → `acceptAuth(_:)` が鍵を返す。`authenticatedPadId` はAUTH成功後だけ得られる。PC側の動作試験用にも使用可能。 |
| `SyncSessionKeys` | `padToPc`、`pcToPad`。iPadの送信に前者、受信に後者を使う。 |
| `SyncFrameSender` | `init(key:)`、`seal(_:)`。平文からフレームを作り送信番号を進める。方向・接続ごとに1個。同じ鍵で作り直さない。 |
| `SyncFrameReceiver` | `init(key:)`、`open(_:)`。認証・番号検査後に平文を返す。 |
| `SyncPacketizer` | `split(_:packetLimit:)`。HELLO等を含むフレームをGATTの値の上限に分割。 |
| `SyncPacketAssembler` | `init(packetLimit:)`、`append(_:)`、`hasPartialFrame`、`finish()`。`append` は未完ならnil、完成時だけフレーム。切断・タイムアウト時は `finish` を呼ぶ。 |
| `SyncMessage` | `.item(id:at:from:text:)`、`.ack(ids:)`、`.ping`、`.pong`。履歴の型から独立した受け渡し用の値。 |
| `SyncMessageCodec` | `encode(_:)`、`decode(_:)`。見出しJSONと本体の読み書き。 |
| `SyncProtocol` / `SyncProtocolError` | サイズ・件数・時刻の上限定数と、`.format/.limit/.packet/.state/.authentication/.identity/.sequence`。 |

送信は `SyncMessage → encode → seal → split → GATT`、受信は `GATT → append → open → decode → 履歴層`。接続確認の3種類のフレームには暗号化を適用せず `split/append` だけを使う。Bluetooth接続、認証前データの拒否、タイムアウト、相手を無視する期間、鍵の保存、ACK待ちの保存・再送、項目IDの重複排除は次の接続層・履歴層が担当する。

C#側は同名の型とPascalCaseメソッドを使い、メッセージは `SyncItem` / `SyncAck` / `SyncPing` / `SyncPong`。C#の組み立て器には省略可能な `frameLimit` があり、Windows接続層は認証前にHELLOの50バイト／AUTHの33バイトを指定し、認証後に4MiBへ切り替える。暗号APIの参照：[Apple CryptoKit AES.GCM](https://developer.apple.com/documentation/cryptokit/aes/gcm)、[.NET HKDF.DeriveKey](https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.hkdf.derivekey?view=net-10.0)。

`{"t":"pong"}` は本文を持たず、pingと同じ暗号化・番号検査を通す。接続済みのiPadは最後のパケット送受信から30秒でpingを送り、10秒以内にpongがなければ切断して再接続する。送信準備が止まっていても確認要求を永久に残さないよう、10秒はpingを送信待ちに入れた時点から数える。ping以外の通信や受信途中のフレームはpongの代わりにならない。Windowsだけがpingにpongで返答し、iPadはpingを無視する。pongへの返答は両側とも行わない。

Windowsの通知値上限は `max(20, min(512, MaxPduSize - 3))`。iPadの書き込み値上限も `min(512, maximumWriteValueLength)`。フレームの途中へ別のフレームを挟まず、ack/pongを次の項目より先に送る。接続層のテストには遅延通知、30秒／10秒の偽時計、512／513バイトの境界を含む。
