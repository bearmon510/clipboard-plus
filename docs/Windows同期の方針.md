# Windowsとの同期の方針

2026年11月17日。利用者がいちばんやりたいことは、iPadとWindowsのPCの間でクリップボードを同期すること。最終的には、PCでWin+Vを押すとclipboard+の履歴が開くようにしたい。

## 利用者の判断（2026年11月17日）

- 同期は両方向（iPad→PC、PC→iPad）。
- カフェや学校でも使いたい。場所ごとに設定し直すのは避けたい。
- PC側は、最終的にWin+Vでclipboard+の履歴を開く。
- App Storeへの公開は、全部がそろってから。
- TestFlightは段階ごとに出さず、まとめられるものはまとめる。

## つなぎ方：Bluetooth LE

同じWi-Fiの中で直接つなぐ方式は、カフェや学校のWi-Fiでは使えないことが多い。機器同士の通信を止めているネットワークが多いため。そこで、Wi-Fiに関係なく近くにあればつながるBluetooth LEを使う。インターネットもクラウドも通らない。

- **役割**：PCが待ち受け（GATTサーバー、peripheral）、iPadがつなぎに行く（central）。iOSのcentralは、一度つないだ相手への接続要求を出したままにでき、裏にいても相手が近づけばつながる（`bluetooth-central` のバックグラウンドモードと状態の復元）。利用者のPCのアダプターがperipheralの役割に対応していることは確かめた（LE、central、peripheral、拡張アドバタイズがすべて対応）。
- **組にする**：最初に1回だけ。PCが32バイトの乱数の鍵を作り、QRコードで表示する。iPadのclipboard+がカメラで読む。OSのBluetoothのペアリング画面は使わない。
- **暗号化**：アプリの中で行う（下の「通信の決まり」）。Bluetoothの通信を近くで傍受されても、中身は読めない。

## できること・できないこと

- PCでコピーしたものは、iPadのclipboard+が裏にいても受け取って履歴に入れられる見込み（試作で確かめる）。
- iPadでコピーしたものをPCへ送れるのは、clipboard+が集めたものだけ。iPadのクリップボードを読めるのは、clipboard+が画面に出ているときか戻ったときに限られる（iOSの制約で、これは変わらない）。
- 文章はすぐ届く。画像は数秒かかる見込み。大きなファイルは上限を決めるか対象外にする。

## 通信の決まり（第2版）

GATTのUUID、パケット先頭の開始／終了ビット、512バイト上限、AES-256-GCMのフレーム構造は第1版のまま。フレーム全体は4MiB、平文最大4,194,279バイト。接続ごとに1つの送信処理を使い、フレームの途中へ別フレームを挟まない。ack/pong/resumeは次の項目より優先する。

- HELLO: `0x01 | 0x02 | 端末ID(16) | Ni(32)`、計50バイト。
- WELCOME: `0x02 | 0x02 | PC ID(16) | Np(32) | HMAC(32)`、計82バイト。
- AUTH: `0x03 | HMAC(32)`、計33バイト。
- HMAC-SHA256の入力は `0x02 | ASCIIのpcまたはpad | PC ID | 端末ID | Ni | Np`。IDも認証する。UUIDはRFC 4122の順。AUTH成功前に端末一覧へ登録しない。
- HKDF-SHA256は入力鍵K、salt `Ni | Np`、info `clipboardplus v2 pad->pc` または `clipboardplus v2 pc->pad`、32バイト。再接続ごとに新しい乱数と暗号状態を使う。
- QRの書式は `clipboardplus-pair:1:...` のまま。QRの番号はペア情報の書式で、通信の版とは別。
- 認証前の組み立てはPCで50／33バイト、iOSで82バイトまで。認証後にだけ4MiBを認める。

暗号フレームは `0x10 | 番号8バイトbig-endian | 暗号文 | GCMタグ16バイト`。nonceはゼロ4バイトと番号、AADは先頭9バイト。送信は0から増加し、受信は直前より大きい番号だけを認める。認証成功後に番号を更新する。

平文は `見出し長2バイトbig-endian | ASCII JSON | 本体`。見出しは最大65,535バイト。出力は辞書順・空白なし。未知／重複キー、未知種類、深さ8超過、末尾カンマ、余分なJSONは拒否する。入力のキー順と標準JSON空白は許す。文字列も復号後にASCIIを検査する。`at` は整数Unixミリ秒（±9,007,199,254,740,991、小数／指数表記不可）。履歴には受信時刻でなくこの値を渡す。

| t | その他の見出し | 本体・意味 |
| --- | --- | --- |
| device | kind: phone / pad | 本体なし。AUTH直後の端末種別宣言 |
| item | id, at, from: pc / pad, kind: text | UTF-8文章。1フレームに収まること |
| offer | id, at, from, kind: image / file, size, sha256, name64, type | 本体なし。添付全体の見出し |
| chunk | id, offset | offsetからの連続バイト、1〜32,768バイト |
| resume | id, offset | 本体なし。受信側がディスクへ保存済みの連続バイト数 |
| ack | ids: UUID配列1〜1,024件 | 本体なし。項目全体の履歴保存成功 |
| ping / pong | なし | 本体なし。死活確認 |

`size` は0〜10MiB。`sha256` は全体の小文字16進64文字。`name64` はUTF-8名の通常base64（パディングあり、正規形）、復号後最大1,024バイト。Unicode一般カテゴリ `Cc`（`U+0000`〜`U+001F`、`U+007F`〜`U+009F`）の制御文字は不可とし、`Cf`（ゼロ幅接合子 `U+200D` 等）は通信で許可する。画像なら空文字可、ファイルなら空でない名前。実際の保存名には相手のパスを使用しない。`type` はASCII印字文字1〜255バイト。画像はpublic.png / public.jpegだけ、ファイルはUTI（不明ならpublic.data）。

送信側は1つの接続で添付の転送を1件ずつ進め、進行中の添付がある間は次の添付のofferを始めない（文章のitem・ack・ping/pongは挟んでよい）。手順はoffer→resumeを待つ→指定位置からchunkを1個→次のresumeを待つ。受信側はchunkをディスクへ同期書き込みした後だけresumeを返す。飛び位置・巻き戻し・サイズ以上（`offset >= size`、`0 <= offset < size` のみ有効）・文章へのresumeは拒否する。同じIDの再offerは見出し全体の一致を確認し、保存済みファイルの長さを返す。送信側は再接続ごとにofferから始め、古い送信offsetを信用しない。

全バイトを保存したらSHA-256をストリームで確認し、履歴保存後にackを返す。最後のchunkにはresumeでなくack。空ファイルや全体保存済みの再offerも検証・履歴保存へ進む。SHA不一致は受信途中を消して切断する。画像の上限超過・形式不一致・破損など受け取れない内容は、受信途中を消して履歴に入れず、固定理由だけを記録してackを返す（相手が再送し続けないようにする）。その他の受け取り失敗でも、受信途中を消してから切断する。受信済みIDは内容を書かずackだけ返す。削除／期限切れに対する遅いresumeは無視する。例と暗号フレームは `protocol/test-vectors.json`。


第2版は1つの共有鍵を複数の端末で使う。PCはAUTHで確定した端末IDごとにキューとackを管理し、PCでのコピーだけを登録済み全端末へ送る。端末間の中継はしない。キューは各端末100件／24時間、ディスクへ保存。PC履歴は300件。PCの内容重複窓は10分、iOSのPC受信ハッシュは別内容を読むまで時間制限なく保持する。

版違いの新しい端末は自動再接続を停止し、更新後にretryAfterPeerUpdateで再開する。旧アプリの処理をPC側から変更することはできないため、旧TestFlight版自身の再試行は旧実装のまま。保存層・画面用API・定数・実機試験と移行時の限界は [Windows同期の段階3メモ](Windows同期の段階3メモ.md) を参照。

## 段階とTestFlight

| 段階 | 内容 | TestFlight |
| --- | --- | --- |
| 1 | 0.14.0：順に貼る・PiP・画面録画での取り込みを外す。初回の案内 | 2と一緒 |
| 2 | 試作：文章を両方向。組にする、状態の表示、ログ | 1と一緒（0.14.0） |
| 3 | 同期の本体：つながっていない間の分の受け渡しと保存、画像 | 4と一緒 |
| 4 | PC側の履歴の画面とWin+V | 3と一緒 |
| 5 | 共有拡張 | 6と一緒 |
| 6 | 公開の準備 | 5と一緒 |

## 第1版・段階2の記録（以下は当時の仕様）

現在の仕様は上の第2版と段階3メモを優先する。以下の文章のみ・50件・メモリ保存等は第1版の記録。

## 試作で確かめること（段階2）

1. 組にして、文章が両方向に届く。届くまでの時間。
2. iPadのclipboard+が裏にいるときに、PCのコピーが履歴に入るか。
3. 離れて戻ったとき、PCを再起動したとき、iPadのBluetoothを切って入れたときに、自動でつなぎ直るか。
4. Windowsのアドバタイズのアドレスが変わっても、iPadが見つけ直せるか。
5. PCで受け取った文章が、Win+Vの標準の履歴にも入るか。

## 置き場所

- iPad側：`app/ClipboardPlus/Core/Sync*.swift`（通信の決まり・暗号。テストしやすいように分ける）、`app/ClipboardPlus/Services/`（Bluetoothの接続と履歴への受け渡し）。
- PC側：`windows/`。.NET 10、`net10.0-windows10.0.19041.0`。通信の決まりと暗号のライブラリ、テスト、常駐アプリに分ける。このPCでビルドして試せる。
- 共通：`protocol/test-vectors.json`。

## iPad側の実装メモ

2026年11月17日。画面用の窓口は `Services/PCSyncController.swift` の `@MainActor PCSyncController.shared`。依頼どおりの `Status`、`pcName`、`lastSentAt`、`lastReceivedAt`、`copiesReceivedToPasteboard`、`pair(code:)`、`unpair()` を持つ。`pair` の失敗は `PCSyncPairError.message`（日本語）。画面向けAPIの変更はない。内部のテスト用初期化では履歴、Keychain、Bluetooth、時計を差し替えられる。

- **起動と許可。** アプリの初期化で窓口を起動する。未登録では `CBCentralManager` を作らず、有効なQRの検証とKeychain保存に成功した後に初めて作る。登録済みなら起動時に作る。カメラの許可要求は別担当のQR画面に任せる。テストホストのアプリ初期化では自動接続を起動しない。
- **保存。** 鍵は `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` の非同期化Keychain項目。PCの識別子・名前、iPadのUUID、確認済みperipheralのUUID、設定は `pcSync.v1.*` のUserDefaultsに置く。iPadのUUIDは組の解除でも維持する。解除時に鍵を消せない場合は解除済みの印を残して再利用を禁止し、タイマー・ロック解除・次回起動で削除を再試行する。OS再起動後の最初のロック解除前には鍵が読めないため、解除後に再開する。
- **接続。** `PCSyncTransport` が差し替え可能な薄い境界、`PCSyncBluetooth` が実機のcentral。CoreBluetoothのdelegateと通信処理をmain queue/MainActorに直列化する。確認済みの識別子には `retrievePeripherals` と期限なしの `connect` を出す。未接続の前面ではサービスUUID指定のscanも継続し、広告の重複通知を許可して失敗後・10分の除外期間後にも再発見する。既知の接続待ちと新しい候補は最大2台。新しい未確認の候補への接続待ちは20秒で次に進む（確認済み相手の待ちは切らない）。確認失敗は10分除外、通常の再試行は3秒間隔。初回発見とアドレス変更後の再発見はアプリを前面に置く。
- **状態復元。** `clipboardplus.pc-sync.central.v1` を復元識別子とし `willRestoreState` でperipheralを保持する。既に接続済みの復元リンクは一度切断し、PC側にも古い暗号セッションを捨てさせてから新しいHELLOを送る。暗号鍵・送信番号を復元せず、新しい乱数で接続し直す。
- **送受信。** 通知の有効化後にHELLOを送り、WELCOMEを検証し、AUTHの全パケットをwrite without responseへ渡してから項目を送る。送信の値上限には `min(512, maximumWriteValueLength(for: .withoutResponse))` を使い、`canSendWriteWithoutResponse` とready callbackで停止・再開する。通知側の交渉済み上限はiOS APIから得られないため、受信組み立て器にはGATT属性値の最大512バイトを渡す（送信上限とは分ける）。一度に展開する送信フレームは1個、ackを次の項目より先に送る。
- **期限。** サービス・通知準備と接続確認はそれぞれ30秒。組み立ての無進行、送信の無進行、項目全体を書き込んでからのack待ちは60秒。期限切れは接続を切り、未ackの項目を同じIDで再送する。背景でOSに停止されている間の実時間どおりのタイマー実行は保証されない。
- **死活確認。** 接続済みで30秒パケットの送受信がなければpingを送信待ちに入れる。送信準備の停止も検出するため、その時点から10秒以内にpongが来なければ切断・再接続する。pong待ちはほかの受信や送信では延長せず、切断・組み直しで捨てる。ack、ping、次の項目の順に優先し、送信中のフレームには割り込ませない。PCからの最初の通知が失敗して部分フレームやack待ちがない場合も、この期限で復帰できる。
- **履歴との受け渡し。** `ClipboardMonitor.admit` が取り込みイベントごと（同一本文の再取り込みを含む）に送信通知し、文章・リンクのカードコピーも通知する。履歴とテンプレートの両方に適用する。`source == .pc` のカードコピーとPC受信専用経路では送信しない。未ackは最大50件をメモリに保持し、古い順に破棄する。組の解除・変更とプロセス終了では消える。画像・ファイルは対象外。
- **受信とack。** `HistoryStore.collectFromPC` は通常と同じ本文の重複統合を `source: .pc` で行い、SQLiteへの保存成功後だけackする。PCの時計ずれで履歴の順番や自動削除が乱れないよう、履歴の時刻はiPadで受け取った時刻にする。保存失敗はackせず、履歴層には別の再試行を残さずPCからの再送に任せる。保存中のIDも二重に保存しない。保存済みIDは直近500件をメモリに保持し、再受信はackのみ返す。プロセス終了をまたぐ重複排除は次段階。
- **iPadのクリップボード。** 設定は初期値true。保存済みの本文を書き込み、既存の自己コピー印と書き込み後のchangeCountで二重取り込みを抑える。書いた本文を再読しないので、同期ログへ本文を出さない。後から外部アプリが同じ本文をコピーした場合は通常どおり取り込む。背景でも書き込みを試すが、UIKitは失敗をthrowしないためchangeCountの増加で判定する。変化しなければ書けなかったことを固定文でログに残し、履歴保存とackは続ける。他のコピー・読み取り操作中は書き込みを見送る。組の解除中に終わった古い受信の保存は、新しい組へのackやクリップボード書き込みを行わない。
- **ログ。** 既存の計測ログに `PC同期` として状態、scan、接続、確認、失敗理由、GATT値上限、件数、GATTパケットのバイト数、所要時間、再送とack待ち時間を出す。OSエラーは数値コードだけにし、本文・QR・鍵・機器名・UUID・NSErrorの説明を渡さない。本文プレビュー設定が有効でもPC受信経路の本文は出ない。
- **バックアップ・JSON・ショートカット。** 履歴のCodable/SQLite/バックアップは `pc` を保持し、リンクは既存のURL判定とショートカット表示を使う。鍵・接続先UUID・送受信ID・送信待ち・設定は履歴モデルに持たせず、アプリのバックアップとJSON書き出しには入れない。`pc` を知らない旧版では新しい履歴・バックアップを読めないため、ダウングレードは対象外。iOS自体の端末バックアップとは別の話で、UserDefaultsは通常のOS保存に従う。
- **画面担当との結合。** `HistorySource.pc` の追加に伴い、`Views/EntryDetailView.swift` の `sourceLabel` のswitchに `case .pc: return "PC"` が必要。Viewsを編集しないという担当境界のため、画面側でこの分岐を追加する（未追加のままでは網羅性エラーになる）。
- **検証。** `PCSyncControllerTests` は偽のGATT接続・Keychain・pasteboardと実際の `SyncPcHandshake`/暗号部品を使用する。QR、遅延Bluetooth生成、認証、flow control、ack、再送、待ち件数、受信の重複500件、source pc、リンク、自己コピー、送り返しの防止、解除、期限、ログの秘匿に加え、30秒／10秒の死活確認、pong後の再確認、pingを返答しないこと、書き込みの512バイト上限を検証する。`PCSyncControllerTests` と `ScreenSnapshotTests` のMainActor上のexpectation待ちは `await fulfillment` とし、メインキューへ戻る履歴・ログ完了を阻害しない。WindowsではSwift/XCTestを実行できないため、Xcode 27.1の既存CIと実機BLEでの確認が必要。
- **実機で試す際の注意。** 最初の接続とアドレス変更後の再発見はアプリを前面に置く。背景の再接続では、切断コールバックの中で既知の相手への接続要求を出し直し、アプリのタイマーの再実行を待たない。アプリを利用者が強制終了した場合は通常の状態復元で再起動されないので、一度手動で開く。端末再起動後も最初にロック解除する。未ackの送信待ちと受信ID一覧は試作のためアプリ終了で失われる。
- **APIの根拠。** 接続要求と状態復元は[Appleの背景処理の説明](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html)、強制終了時の制約は[Apple TN3115](https://developer.apple.com/documentation/technotes/tn3115-bluetooth-state-restoration-app-relaunch-rules)、受信属性値512バイトの上限は[Bluetooth ATT仕様](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/Core-62/out/en/host/attribute-protocol--att-.html)を参照。

## PC側の実装メモ

2026年11月17日。`windows/ClipboardPlus.Windows/` にWPFの常駐アプリを実装。出力名は `ClipboardPlusForWindows`。レビュー対応で共通プロトコルにpongを追加し、Nodeの試験データと両言語のテストを更新した。追加のNuGetパッケージはない。

- **構成。** `Core/SyncCoordinator.cs` はWindows APIに依存しない接続・確認・送受信の窓口。`ISyncPeer` と `IClipboardAccess` が差し替え可能な境界。既存の組み立て型の名前は `SyncPacketAssembler`。同じソースを既存の `ClipboardPlus.Sync.Tests` にリンクし、WPFや実機に依存せずテストする。
- **Bluetooth。** `Infrastructure/BleServer.cs` がGATTサーバー。指定のUUID、write / write without response / notify、Plain、discoverable / connectableを使用。イベントキューは128件。writeは入口で処理中を含め全体64件、相手ごと16件まで受け付け、上限超過・キュー満杯・停止中は受け付けない。取得済みのwrite with responseにはATT Insufficient Resourcesを返す。要求取得自体が未完ならキャンセルしてGATTスタックへ返し、拒否用の非同期待ち行列は作らない。受理・拒否・例外・キュー終了の各経路でdeferralを解放する。要求取得の待ちは最大10秒。通知値上限は `max(20, min(512, MaxPduSize - 3))`。購読後のMTU増加にも対応する。
- **送信待ち。** 接続ごとに1個の送信処理を持ち、共通gateの中では次のフレームの選択・暗号化と状態更新だけを行う。通知完了を待つ間はgateとBLEイベントworkerを占有しない。フレームは順序どおり送り、ack/pongの返信（最大64件）を次の項目より優先する。項目は共有の未ack一覧から1件ずつ選び、全項目を暗号フレームとして複製しない。通知完了直前のackを受けても未確認扱いへ戻さない。切断時は送信の待機をキャンセルし、再接続には新しい暗号状態を使う。
- **再開と破棄。** アダプター・radio・広告状態を3秒間隔で確認し、オフ・無効・非対応・アクセス不可・開始失敗を区別して表示する。オンに戻ればサービスと広告を作り直す。購読解除・sessionのClosedで接続状態を破棄する。受信不正、認証失敗、復号失敗、通知失敗、クリップボード書き込み失敗でもその相手の状態を破棄する。認証前は接続開始から20秒、組み立て途中は最後のパケットから20秒で期限切れ。通知1回の待ちは最大10秒。
- **GATT APIの制約。** ローカルGATTサーバーの公開APIには相手を強制切断する操作がないため、失敗した購読は失効させ、以後のwriteを拒否する。write with responseにはATTエラーを返し、write without responseは処理しない。通知失敗時は接続の暗号・組み立て・送信待ち状態を破棄し、購読側には拒否の印だけを残す。iPadはpong待ちなどの期限で切断し、購読し直してから新しいHELLOを送る。失敗した購読のままHELLOを送り直しても復帰させない。購読・接続は最大8件まで保持する。認証前の組み立て上限はHELLO 50バイト、AUTH 33バイトで、認証後だけ4MiBを認める。
- **組にする情報。** 初回に `SyncPairing.Create(Environment.MachineName)` を呼ぶ。`%LOCALAPPDATA%\clipboardplus\pairing.dat` はQR文字列全体をDPAPI CurrentUserで暗号化し、一時ファイルから置き換える。平文のQRや鍵をファイル・ログに出さない。読み込み・復号に失敗したら黙って新しい鍵に置き換えず、起動エラーを表示する。「組み直す」は確認後に新しいPC識別子と鍵を保存し、古い接続・未確認項目を捨てて再開する。
- **クリップボード。** メッセージ専用の見えないHwndSourceと `AddClipboardFormatListener` を使う。1回のOpenClipboard中に文章と3種類の除外形式を読み、開けない場合は40/80/120/160/200ms待ちながら最大5回試す。除外形式が存在して読めない場合も送信を見送る。iPadからの書き込みはDispatcherで行い、その直後の通し番号の変化だけを除外する。同じ本文を利用者が新たにコピーした場合は送る。本文・除外理由の元データはログに出さない。
- **待ち項目と重複。** 未ackは最大50件をメモリに保持し、超過時は最古を捨てて件数だけ記録する。新しい認証接続に同じ項目IDで再送し、同じ接続でも60秒ackがなければ番号を進めた新しい暗号フレームで再送する。受信はクリップボード書き込みの成功後にackし、成功済みの直近500個のIDは本文を書かずackだけ返す。未ackと重複IDはプロセス終了・組み直しで消える。ディスクへの履歴保存は次段階。
- **画面・常駐。** 名前付きMutexとイベントで二重起動を防ぎ、2回目は元の画面を開く。閉じる操作は非表示にし、トレイの「終了」で広告と監視を停止する。起動時のチェックはHKCUのRunに実行ファイルと `--background` を登録する。QR・送受信時刻・確認待ち件数を表示する。`--preview` は画面確認専用で、Bluetooth、クリップボード、レジストリ、ペア情報ファイル、ログ、トレイ、単一起動IPCを使用しない。QRもプレビュー用にメモリで生成する。
- **ログ。** `%LOCALAPPDATA%\clipboardplus\logs\sync.log` と `.1`〜`.4`。約1MiBごとに回し、最大5ファイルを保持する。接続・広告・認証・MTU・件数・バイト数・所要時間・再送を残す。例外は型名または固定コードのみを記録し、例外メッセージ、本文、鍵、QR、機器名、相手のIDやアドレスを記録しない。

### PC側のビルドとテスト

リポジトリ直下のPowerShellで実行する。通常は既定のNuGetキャッシュで復元できる。実行環境の既定キャッシュが異なる場合は、取得済みのパッケージフォルダを明示してオフライン復元する（新しいパッケージを取得する操作ではない）。

```powershell
$packageCache = Join-Path $env:USERPROFILE '.nuget/packages'
& 'C:/Program Files/dotnet/dotnet.exe' restore windows/ClipboardPlus.slnx --source $packageCache -p:NuGetAudit=false
& 'C:/Program Files/dotnet/dotnet.exe' build windows/ClipboardPlus.slnx --no-restore
& 'C:/Program Files/dotnet/dotnet.exe' test windows/ClipboardPlus.slnx --no-build --no-restore
```

レビュー修正後の確認結果：buildは警告0・エラー0。既存の通信試験を含め41件成功、失敗0。新しいNode生成例のpong、20/182/512バイト分割に加え、全体／相手別の入口制限、並行した受付、拒否・例外・キュー終了時の解放、認証前50/33バイトの上限、遅延通知中の受信・ack・タイマー・切断、ack/pong優先、通知失敗後の状態破棄、MTU 517→512と513バイト拒否を確認した。テストランナーは `VSTEST_ARTIFACTS_DIRECTORY` 未設定時に一時フォルダへ出力する案内を表示するが、全テストは成功している。

CI停止の点検：前回の「テスト出力0件」の原因は未確定。`PCSyncControllerTests` の履歴・ログ・テンプレート完了待ちと `ScreenSnapshotTests.makeMonitor` はMainActor上で `wait(for:)` を使っていたため、`await fulfillment` に変更した。`PCSyncController` は未ペアリング時にも初期化中に同期Keychain読み取りを行っていたため、保存済みPC情報がない場合は読み取りを省略する。`SettingsView` 経由で `PCSyncController.shared` を作るスナップショットにも適用される。初期化経路に循環したsingleton参照、セマフォ待ち、メインキューへの同期dispatchは見つからず、復元とタイマーにも完了を同期的に待つ箇所はない。`SyncProtocolTests` は非同期処理やexpectationを持たず、分割ループは各回でoffsetを進める。変更したSwiftのenum分岐とasync化したヘルパーの全呼び出しを点検したが、このPCではSwiftのbuild・テストは未実行。新しい例でのSwiftテスト成功とCI停止の解消はMacのCIで確認が必要。

画面だけのプレビューはプロセス起動まで確認したが、画面操作ツールからウインドウを取得できなかったため、見た目の確認は未完了。通常起動はBLEとクリップボードへの影響について自動承認レビューで停止されたため、実機の広告開始・接続・常駐・レジストリ変更は未確認。

### PCとiPadで試す手順

1. ビルド後、`windows/ClipboardPlus.Windows/bin/Debug/net10.0-windows10.0.19041.0/ClipboardPlusForWindows.exe` を起動する。WindowsのBluetoothをオンにし、状態が「iPadを待っています」になることと、ログに広告のStartedが出ることを確認する。画面だけなら実行ファイルに `--preview` を付ける。
2. iPadのclipboard+で「設定」→「Windowsと同期」→「QRコードを読む」。必要なBluetooth・カメラの許可を利用者が行う。PCが「iPadとつながっています」になること、ログの認証とMTUを確認する。
3. 検証用の文章（日本語、絵文字、改行、長い文章）をPCでコピーし、iPadの履歴・PCの確認待ち件数の解消を確認する。逆方向はiPadのclipboard+に取り込んだ文章を使い、PCのメモ帳などへ貼り付ける。Windowsの履歴が有効ならWin+Vにも入ることを確認する。受信した文章が往復して件数を増やさないことも見る。
4. iPadを背景にしてPCでコピーし、iPadの履歴への到着を確認する。次にiPadのBluetoothを切り、PCで数件コピーしてから戻し、同じIDの再送で履歴が二重にならないことを確認する。PC側のBluetoothも切って戻し、3秒程度で待ち受けを再開することを確認する。
5. パスワード管理アプリ等の監視除外付きコピーと画像のみのコピーが送られないことを、内容をログに出さず件数で確認する。クリップボードが一時的に使用中でも、リトライ後に文章が届くことを確認する。
6. ウインドウを閉じても同期が続くこと、もう一度exeを起動すると元の画面が開くこと、トレイの「開く」「終了」を確認する。「Windowsの起動時に開く」は利用者がチェックし、次のWindowsサインインで画面を出さず常駐することを確認する。
7. 「組み直す」のキャンセルでは既存接続が続くこと、確定後は古いiPadの鍵では認証できず、新しいQRで組み直せることを確認する。PC再起動後もQRのPC識別子と鍵が維持されることを確認する（未ack項目のプロセス終了をまたぐ保持は対象外）。
