# clipboard+ 同期の共通部品と試験データ

現在は第4版（第3版の古い相手とは BLE のみの後方互換で接続を継続する）。[通信の決まり](../docs/Windows同期の方針.md)、[Wi-Fiの直接転送の方針](../docs/Wi-Fiの直接転送の方針.md)、[テンプレート同期の方針](../docs/テンプレート同期の方針.md)、[保存・状態API・移行時の制約](../docs/Windows同期の段階3メモ.md)を参照。1つのQR／鍵を複数のiPhone・iPadで使う。QRの書式番号1と通信の版4は独立している。

`make-test-vectors.mjs` はSwift/C#から独立した実装。Node標準のcrypto/fsだけを使う。鍵・乱数・識別子・時刻は公開の固定試験値で、実運用には使わない。

```sh
node protocol/make-test-vectors.mjs
```

`test-vectors.json` はQR、版4のHELLO/WELCOME/AUTH（および `wifiBaseKey`）、版3互換ハンドシェイク（`legacyV3Handshake`：旧版3端末→新版4 PC の即時互換接続と、新版4端末→旧版3 PC の版違い応答 `0203` からの自動版3フォールバック判定）、PC ID入り版違い応答（同一PC・版2／別PC・版2／旧全ゼロID）、両IDを含むHMAC（交渉した版バイト `0x04` または `0x03`）、方向別の鍵（`clipboardplus v4` / `v3`）、12個の平文例、7個の暗号フレーム、20/182/512バイト分割、改ざん・巻き戻し・Cc制御文字名等の失敗例を持つ。さらにテンプレート同期の7個の平文例・6個の暗号フレーム・3段階パケット分割・各種失敗例・16個の2者間マージ例・6個の複数端末一括マージ例・3個のページ分割境界例・3個の同期対象選別例を持つ。加えて第4版（段階B）として Wi-Fi 直接転送のBLE交渉メッセージ7例（`wifiControlMessages`）・5個の暗号フレーム（`wifiControlFrames`）・20個の失敗例（`wifiControlFailures`）、および使い捨て鍵派生・TCP相互認証（`CPW2`）・TCP連続暗号フレーム6個（`wifiTransfer.streamFrames`）・ストリームメッセージ8例・13個の失敗例を持つ。大きい境界例（4MiB/256KiBフレーム境界・50MiB添付境界・64KiB本文・300件・1,000墓標・256KiBページ境界・240件実効上限など）は長さとパターンからテスト内で生成する。

Swift/C#は同じJSONからQR、認証、版3互換・版違い応答、HMAC、鍵、平文、暗号文、タグ、パケット、テンプレートメッセージとマージ結果、Wi-Fi交渉メッセージ・使い捨て鍵・TCP相互確認・連続暗号フレームの一致を検証する。期待値を製品実装自身から計算しない。失敗後の再利用禁止、厳格な構文（標準8-4-4-4-12 UUID表記とローカルIPv4限定を含む）、4MiB・256KiB・50MiBちょうどの境界も検証する。

## Wi-Fi 直接転送プロトコル（第4版・段階B）

### 古い相手（第3版）との扱い
- 既存の版3実装は認証前フレーム上限を HELLO 50バイト・WELCOME 82バイトに固定し、認証後も未知の `t` や `device` の追加キーを `Format` で切断するため、版3のまま拡張フィールドを足すと互換性を壊す。
- そこで通信の版を **第4版（`version = 4`、`minSupportedVersion = 3`、`wifiTransferMinVersion = 4`）** に上げ、50/82/33バイトの枠長は変えず、版3・版4の両方を受理する形とする。
  - **版4 ↔ 版4**：版4で認証し `SyncSessionKeys.supportsWifiTransfer == true` と専用の `wifiBaseKey`（HKDF info `clipboardplus v4 wifi-base`）を派生する。
  - **旧版3端末 ↔ 新版4 PC**：PC側 `SyncPcHandshake` が `0x03` を受理し版3の WELCOME・HMAC・HKDF鍵で応答する（切断なし、`supportsWifiTransfer == false`、BLEのみで同期継続）。
  - **新版4端末 ↔ 旧版3 PC**：旧版3 PCが版4 HELLOへ返す `0x02 | 0x03 | PC ID(16) | ゼロ(64)` を `SyncPadHandshake` が検知し、`suggestedFallbackVersion = 3` を記録して `.version` を投げる。呼び出し側は更新停止せず1回だけ `protocolVersion = 3` で再接続し、BLEのみで同期する（版2以下では `suggestedFallbackVersion = nil` のまま更新案内停止）。

### BLE上の Wi-Fi 交渉メッセージ（版4暗号セッション上、本体なし・ASCII JSON見出し）
| `t` | 向き | 見出しキーと検証 |
| --- | --- | --- |
| `wifi_request` | iOS → PC | `direction`（`send` / `receive` / `both`）、`ids`（重複なしUUID配列 `0〜100` 件） |
| `wifi_ready` | PC → iOS | `session`（UUID）、`ssid`（印字ASCII `1〜32B`、空白のみ不可）、`passphrase`（空白なし印字ASCII `24〜63B`）、`ip`（RFC 1918 プライベート／RFC 3927 リンクローカル IPv4 正規表記のみ）、`port`（`1〜65535`）、`token`（32B乱数の小文字16進64文字）、`ttl`（`1〜300` 秒、既定30秒） |
| `wifi_unavailable` | PC → iOS | `reason`（`unsupported` / `busy` / `conflict` / `start_failed` / `disabled`） |
| `wifi_join_result` | iOS → PC | `session`（UUID）、`status`（`joined` / `user_denied` / `not_foreground` / `join_failed` / `timeout`） |
| `wifi_cancel` | 双方向 | `session`（UUID）、`reason`（`user_cancelled` / `timeout` / `tcp_failed` / `protocol_error` / `completed` / `superseded`） |

### 使い捨て鍵の派生と TCP 相互認証（`CPW2` 第1版）
- **BLE鍵の分離**：BLE の送受信暗号鍵（`padToPc` / `pcToPad`）は TCP では使わない。BLE 版4ハンドシェイクで派生した `wifiBaseKey`（32B）と `wifi_ready.token`（32B）、`session`（RFC 4122 16B）から HKDF-SHA256 で転送ごとの使い捨て鍵を派生する。
  - `transferKey = HKDF-SHA256(ikm: wifiBaseKey || token, salt: sessionBytes, info: "clipboardplus wifi v1 key", 32)`
  - `authKey = HKDF-SHA256(ikm: transferKey, salt: sessionBytes, info: "clipboardplus wifi v1 auth", 32)`
- **TCP相互認証（リプレイ防止）**：
  - `TCP_HELLO`（iOS→PC、54B）：`"CPW2" | 0x01 | 0x01 | session(16) | padNonce(32)`
  - `TCP_WELCOME`（PC→iOS、86B）：`"CPW2" | 0x01 | 0x02 | session(16) | pcNonce(32) | pcHmac(32)`
  - `TCP_AUTH`（iOS→PC、38B）：`"CPW2" | 0x01 | 0x03 | padHmac(32)`
  - `HMAC-SHA256(authKey, "CPW2" | 0x01 | ASCII("pc" または "pad") | session(16) | padNonce(32) | pcNonce(32))`
  - 認証完了後、`salt = padNonce || pcNonce` で方向別トラフィック鍵 `pad->pc`（`clipboardplus wifi v1 pad->pc`）と `pc->pad`（`clipboardplus wifi v1 pc->pad`）を派生し、完了した `session` は `WifiSessionReplayGuard` で再利用を禁止する。

### TCP 連続暗号フレームと転送ストリーム
- **暗号フレーム（上限 256 KiB = 262,144B）**：`0x20 | dir(1B: pad->pc=0x01, pc->pad=0x02) | payloadLen(4B BE) | seq(8B BE) | ciphertext(N) | tag(16B)`。
  - `AAD` は先頭14バイト、`nonce` は `dir(1B) | 0x00, 0x00, 0x00 | seq(8B BE)`。`payloadLen` は `2〜262,114` バイト。
  - 受信側は `seq` が `0, 1, 2, ...` と厳密に1ずつ連続することを検証し、順番の入れ替え・欠け・重複（リプレイ）・方向違い・256KiB超過・途中切り詰め・改ざんをすべて検知して状態を永久失効させる。
- **ストリームメッセージ（平文 `見出し長2B BE | ASCII JSON | 本体`、Wi-Fi上限 1件 50 MiB = 52,428,800B、1チャンク最大 252 KiB = 258,048B）**：
  - `offer`（既存 `SyncOffer` と同形、`size` は `0〜50 MiB`）→ 受信側が既完了なら `ack`、未完了なら保存済み位置で `resume`（`id`, `offset`）を1回返す → `chunk`（`id`, `offset`, 本体 `1〜252 KiB`）を連続送信 → 受信側が全バイトの SHA-256 を検証して保存後 `ack`（`id`）（不一致なら途中データを破棄して `.authentication` で切断）→ 送り終えたら認証済み `done` を送る。
  - 1回の TCP 接続で iOS→PC の全件（`done` まで）に続けて PC→iOS の全件（`done` まで）を送受でき、`done` より前の EOF は切り詰め（`.packet`）として検出する。

## 共通API

Swiftのプロトコル型はFoundation/CryptoKitで動作する。状態を持つ型は接続・方向ごとに1個とし、同じactor／直列キューで呼ぶ。C#は同名の型とPascalCase API。

| 型 | APIと役割 |
| --- | --- |
| SyncPairing | init(pcId:key:name:)、create(name:)、parse、qrString、pcId/key/name。QRの読み書き |
| SyncPadHandshake | init(pairing:padId:testNonce:protocolVersion:) → createHello → acceptWelcome。requestedVersion / suggestedFallbackVersion を公開し、版3 PC 応答時のみ自動フォールバック候補を返す |
| SyncPcHandshake | init(pairing:expectedPadId:testNonce:) → acceptHello → acceptAuth / createVersionMismatch。版3・版4を受理し、authenticatedPadId / negotiatedVersion は AUTH 成功後だけ公開 |
| SyncSessionKeys | protocolVersion / padToPc / pcToPad / wifiBaseKey / supportsWifiTransfer。版4のみ `wifiBaseKey` を派生 |
| SyncFrameSender / SyncFrameReceiver | init(key:)、seal / open。BLE 用 AES-256-GCM と単調増加番号 |
| SyncPacketizer | split(_:packetLimit:)。GATT値上限に分割 |
| SyncPacketAssembler | init(packetLimit:frameLimit:)、append、hasPartialFrame、finish。認証前はPCで50／33バイト、iOSで82バイト |
| SyncMessage | item(id:at:from:text:)、ack(ids:)、ping、pong、device(kind:)、offer(SyncOffer)、chunk(id:offset:data:)、resume(id:offset:) |
| SyncOffer | id / at / from / kind / size / sha256 / name64 / type。添付全体の見出し。BLE は既定 10MiB、Wi-Fi は 50MiB 上限で検証 |
| SyncMessageCodec | encode / decode。ASCII JSON見出しと本体 |
| WifiControlMessage / WifiControlMessageCodec | request / ready / unavailable / joinResult / cancel の厳格なエンコード・デコードとローカル IPv4 検証。`ready` 文字列表現は秘匿情報を伏せる |
| WifiTransferKeys / WifiTrafficKeys | BLE の `wifiBaseKey` + `token` + `session` から HKDF-SHA256 で `transferKey` / `authKey` と TCP 方向別鍵を派生 |
| WifiTcpPadHandshake / WifiTcpPcHandshake / WifiSessionReplayGuard | `CPW2` 第1版の双方向 HMAC-SHA256 認証と完了済み `session` の再利用禁止 |
| WifiStreamFrameSender / WifiStreamFrameReceiver | 256KiB上限・14Bヘッダ・厳密連続通し番号の AES-256-GCM ストリーム枠 |
| WifiStreamMessage / WifiStreamMessageCodec / WifiEncryptedStream / WifiTransferEngine | `offer`→`resume`→`chunk`→SHA-256検証→`ack`→`done` の OS 非依存ストリーム転送部品（途中再開・双方向一括・50MiB対応） |
| TemplateSyncMessage | pull(op:)、push(op:part:total:page:)、state(op:part:total:page:)、ack(op:)（C#は `TemplateSyncPull` / `TemplateSyncPush` / `TemplateSyncStateMessage` / `TemplateSyncAck`）。見出しはASCII JSON、本体はUTF-8 JSON |
| TemplateSyncMessageCodec | encode / decode、splitPages、`maxOrder = 2,147,483,647`。300件、墓標1,000件、本文64KiB、名前100文字/400B、タグ30文字/120B（`Cc`・改行不可）、`order` 上限2,147,483,647、ページ256KiB（継続空JSON 32B、バイト上限付き書き出し）・最大80ページ・合計20MiBを検証 |
| TemplateSyncPageAssembler | append / finish。`tpl_push` / `tpl_state` の複数ページを連結し重複IDと合計上限を検証 |
| TemplateSyncMerge | merge / mergeAll / prepareSyncState / contentHash / normalizeLineEndings / normalizedTitle / normalizedTag / nextUpdatedAt / clockSkewSeconds / makeConflictTitle。UTF-8バイト一致・改行LF正規化・`syncId`・`updatedAt`・`baseHash`・180日墓標（`sentAt` 換算と再送延長抑止）・削除済み衝突写しの再生成抑止・同一本文統合・複数端末一括マージ・実効上限超過項目の除外カウントを両言語共通で実装 |
| SyncProtocol | version=4、minSupportedVersion=3、wifiTransferMinVersion=4、maxItemBytes=10MiB、maxWifiItemBytes=50MiB、defaultWifiThresholdBytes=500KiB、maxWifiFrameBytes=256KiB、maxWifiChunkBytes=252KiB、chunkBytes=32KiB、maxPending=100、pendingLifetime=24時間、テンプレート同期上限一式。既存フレーム・見出し・ack・時刻上限も維持 |
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
