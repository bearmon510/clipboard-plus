# clipboard+ 同期の共通部品と試験データ

現在は第2版。[通信の決まり](../docs/Windows同期の方針.md)、[保存・状態API・移行時の制約](../docs/Windows同期の段階3メモ.md)を参照。1つのQR／鍵を複数のiPhone・iPadで使う。QRの書式番号1と通信の版2は独立している。

`make-test-vectors.mjs` はSwift/C#から独立した実装。Node標準のcrypto/fsだけを使う。鍵・乱数・識別子・時刻は公開の固定試験値で、実運用には使わない。

```sh
node protocol/make-test-vectors.mjs
```

`test-vectors.json` はQR、版2のHELLO/WELCOME/AUTH、PC ID入り版違い応答（同一PC／別PC／旧全ゼロID）、両IDを含むHMAC、方向別の鍵、12個の平文例、7個の暗号フレーム、20/182/512バイト分割、改ざん・巻き戻し・Cc制御文字名等の失敗例を持つ。item / ack / ping / pong / device / offer / chunk / resume、日本語ファイル名、ゼロ幅接合子（`U+200D`）入りファイル名、画像、途中offsetからのchunkを含む。大きい境界例は長さとパターンからテスト内で生成する。

Swift/C#は同じJSONからQR、認証、版違い応答、HMAC、鍵、平文、暗号文、タグ、パケットのバイト一致を検証する。期待値を製品実装自身から計算しない。失敗後の再利用禁止、厳格な構文（標準8-4-4-4-12 UUID表記を含む）、4MiBちょうどの境界も検証する。

## 共通API

Swiftのプロトコル型はFoundation/CryptoKitで動作する。状態を持つ型は接続・方向ごとに1個とし、同じactor／直列キューで呼ぶ。C#は同名の型とPascalCase API。

| 型 | APIと役割 |
| --- | --- |
| SyncPairing | init(pcId:key:name:)、create(name:)、parse、qrString、pcId/key/name。QRの読み書き |
| SyncPadHandshake | init(pairing:padId:testNonce:) → createHello → acceptWelcome。authを先に送り、keysを使う。acceptWelcomeはPC ID（非ゼロかつ組にしたPC ID一致）を版より先に検証 |
| SyncPcHandshake | init(pairing:expectedPadId:testNonce:) → acceptHello → acceptAuth / createVersionMismatch。authenticatedPadIdはAUTH成功後だけ公開 |
| SyncSessionKeys | padToPc / pcToPad。HKDFのinfoはclipboardplus v2の方向別文字列 |
| SyncFrameSender / SyncFrameReceiver | init(key:)、seal / open。AES-256-GCMと単調増加番号 |
| SyncPacketizer | split(_:packetLimit:)。GATT値上限に分割 |
| SyncPacketAssembler | init(packetLimit:frameLimit:)、append、hasPartialFrame、finish。認証前はPCで50／33バイト、iOSで82バイト |
| SyncMessage | item(id:at:from:text:)、ack(ids:)、ping、pong、device(kind:)、offer(SyncOffer)、chunk(id:offset:data:)、resume(id:offset:) |
| SyncOffer | id / at / from / kind / size / sha256 / name64 / type。添付全体の見出し。`name64` 復号後は `Cc`（`U+0000`〜`U+001F`、`U+007F`〜`U+009F`）不可、`Cf`（`U+200D` 等）は許可 |
| SyncMessageCodec | encode / decode。ASCII JSON見出しと本体 |
| SyncProtocol | version=2、maxItemBytes=10MiB、chunkBytes=32KiB、maxPending=100、pendingLifetime=24時間。既存フレーム・見出し・ack・時刻上限も維持 |
| SyncProtocolError | format / limit / packet / state / authentication / identity / sequence / version |

C#のメッセージはSyncItem / SyncAck / SyncPing / SyncPong / SyncDevice / SyncOffer / SyncChunk / SyncResume。SyncProtocolはPC用の履歴300件、重複窓10分、ファイル10件、画像40,000,000ピクセルの定数も公開する。

送信は `message → encode → seal → split → GATT`、受信は `GATT → append → open → decode → 保存層`。認証の3フレームはseal/openを使わない。受信エラーは接続を失効させ、次回は新しい乱数と暗号状態を作る。同じ鍵で送信番号を0に戻さない。

## 保存・接続層

| 実装 | 部品 |
| --- | --- |
| iOS Core/SyncStorage.swift | SyncPending、SyncDiskStore（未ack・受信途中・受信ID）、SyncEchoGuard（PC受信内容の指紋、異なる内容を読むまで保持） |
| iOS Services/PCSyncController.swift | 接続と永続キュー、ack優先、進捗、確認済み版違い／HMAC不一致での停止と再接続バックオフ。pendingCount / transferProgress / requiresPeerUpdate / requiresRepair / compatibilityMessageをPublishedで提供 |
| iOS Core/HistoryStore.swift | 保存済み履歴から送信データを作る。PNG/JPEG以外はPNGへ変換。PCからの項目はatで履歴へ保存 |
| Windows Core/SyncRepository.cs | 端末別キュー、既知端末、履歴、受信途中、重複記録。原子的JSONと別ファイルの本体 |
| Windows Core/SyncCoordinator.cs | 認証ID別の配送、まとめackキュー、進捗、履歴一覧／検索／通知／削除／コピー、状態API。Windows非依存Coreをテストにもリンク |

offer→最終パケット引き渡し後に初回resumeを受理（引き渡し前のresumeは無視）→最大4チャンク（128KiB）までのスライディングウィンドウでchunkを先送りし、受信者はディスクへ順番どおり書き込んだ位置をresumeで返す（1チャンクずつの旧stop-and-wait相手とも互換動作）。応答期限（基本60秒、大きなフレーム受信中は各チャンク送信完了から最大4分）と最終パケット引き渡し段階はチャンク単位で管理し、印付けと通知開始の同期区間は端末ごとのロックで行い（PC側は全体ロックを巻き込まず `NotifyValueAsync` 完了を区間外で待つ）、最後のパケットを下へ渡していないchunk境界のresumeは無効（state）とする。最後に全体SHA-256を確認し、履歴保存後に項目単位のack（両側とも1通に最大1,024件までまとめる）。添付の応答期限切れや送信中フレームの24時間期限切れ時は接続を切って再接続でやり直し、同一接続内で未完了の重複offerを受けた場合やresume後に最終chunk送信完了前のackを受けた場合は状態誤り（state）として切断する（offerの最終パケット引き渡し後のackは受理し、引き渡し途中のackは無視する）。受信中の複数パケットフレームが進んでいる間は返信の60秒期限で切断せず、受信が止まった場合は組み立て期限で切断する。1台のackで他端末のキューは消さない。端末間の中継はしない。

端末は最後のパケット送受信から30秒でping、キュー投入から10秒以内にpongがなければ再接続。PCだけがpingへpongを返し、pongには返信しない。ack/pong/resumeは次の項目より優先する。GATT値上限はWindowsでmax(20,min(512,MaxPduSize-3))、iOSでmin(512,maximumWriteValueLength)。WindowsのGATTサーバー（`BleServer`）は `WriteAdmission` の受付上限をバイト数（既定値 全体4MiB・相手ごと1MiB）で数え、コピー前に実長で枠を再確保して上限超過で捨てた場合はログ出力前に枠と `Peer` の両方を即座に失効させ（件数のみ記録）、コーディネーターのロック取得後も枠と同じ失効状態を確認する。受け取った書き込みにはcharacteristic・実セッション・端末ごとの購読世代（単調増加）をイベント入口で記録して枠の結合・無効化の両方で世代を照合し、仮の枠は同じセッション・世代にだけ結び付け、購読解除・再登録や世代不一致の書き込みを破棄してリースとdeferralを返し（WinRTが再購読を区別できない場合に備え、同一端末の `HELLO` 再ハンドシェイクで前世代の枠も失効させる）、終了時は `BlePeerRegistry` でピア追加と終了判定を同一ロックで行って追加できなかったピアをその場で解放し、deferralの完了は1度だけ試みて例外をその項目内に閉じ込め、要求 `Status` 例外時も `finally` で解放し、ワーカー異常終了時は残余キューを破棄しながらリース・deferralを回収し、終了時は広告停止・購読解除をピア解放待ちより先に行ってWinRT呼び出しが戻らない場合も広告停止へ届くようにする。`WriteWithoutResponse` のdeferral即時完了、添付転送中の高スループット接続パラメータ要求（`net10.0-windows10.0.22621.0` のWinRT投影で `ApiInformation` を確認し、WPF Dispatcherから `FromIdAsync` を開始、受け取り途中添付の組み立て中パケット進捗も寿命判定に含め、終了時は要求オブジェクトの `Dispose` まで待機。対応OSのみ）、接続ごとの送信、認証前の制限を維持する。

## 実行

キャッシュだけから復元し、新しいパッケージは取得しない。

```powershell
$packageCache = Join-Path $env:USERPROFILE '.nuget/packages'
& 'C:/Program Files/dotnet/dotnet.exe' restore windows/ClipboardPlus.slnx --source $packageCache -p:NuGetAudit=false
& 'C:/Program Files/dotnet/dotnet.exe' build windows/ClipboardPlus.slnx --no-restore
& 'C:/Program Files/dotnet/dotnet.exe' test windows/ClipboardPlus.slnx --no-build --no-restore
```

Swiftは `app/ClipboardPlusTests/SyncProtocolTests.swift` が同じJSONを読む。保存層はSyncStorageTests、接続層はPCSyncControllerTests。XcodeGenのフォルダ指定で新規Swiftファイルも対象になる。MainActorではwait(for:)でなくawait fulfillment(of:)を使う。WindowsではSwiftを実行できないため、両言語の成功確認のうちSwift分は既存のXcode CIで行う。BLE、背景処理、Universal Clipboard、実OSのファイル／画像貼り付けは実機確認が必要。
