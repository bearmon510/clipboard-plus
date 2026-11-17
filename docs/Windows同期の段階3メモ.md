# Windows同期・段階3の実装メモ

2026年11月17日。ViewsとWin+Vの窓は変更しない。共通のQR／鍵を複数端末で使う。PCでのコピーは登録済み全端末に送るが、端末から他端末への中継はしない。初めて登録した端末へ過去のPC履歴を一括送信する機能はない。

## 通信の決まり（第2版）

GATTのUUID、パケット先頭の開始／終了ビット、512バイト上限、AES-256-GCMのフレーム構造は第1版のまま。フレーム全体は4MiB、平文最大4,194,279バイト。接続ごとに1つの送信処理を使い、フレームの途中へ別フレームを挟まない。ack/pong/resumeは次の項目より優先する。

- HELLO: `0x01 | 0x02 | 端末ID(16) | Ni(32)`、計50バイト。
- WELCOME: `0x02 | 0x02 | PC ID(16) | Np(32) | HMAC(32)`、計82バイト。版違い応答は `0x02 | 0x02 | PC ID(16) | ゼロ(64)` とし、iOSは版より先にPC IDを検証する（全ゼロや別PC IDなら停止せず10分除外、組にしたPC IDと一致して版が違う場合のみ停止）。
- AUTH: `0x03 | HMAC(32)`、計33バイト。
- HMAC-SHA256の入力は `0x02 | ASCIIのpcまたはpad | PC ID | 端末ID | Ni | Np`。IDも認証する。UUIDはRFC 4122の順（文字列表現は標準8-4-4-4-12の16進のみ受理、大文字・小文字不問）。AUTH成功前に端末一覧へ登録しない。
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

送信側は1つの接続で添付の転送を1件ずつ進め、進行中の添付がある間は次の添付のofferを始めない（文章のitem・ack・ping/pongは挟んでよい）。手順はoffer→resumeを待つ→指定位置からchunkを1個→次のresumeを待つ。受信側はchunkをディスクへ同期書き込みした後だけresumeを返す。飛び位置・巻き戻し・サイズ以上（`offset >= size`、`0 <= offset < size` のみ有効）・文章へのresume、および同一接続での未完了重複offerは拒否して切断する。再接続時はofferから始め、見出し全体の一致を確認して保存済みファイルの長さを返す。添付の60秒応答期限切れは同一接続内で再offerせず、接続を切って再接続でofferからやり直す（文章項目は同一接続で再送可）。またresumeを受理して転送を始めた添付については、最終chunkを送り終える前のackを状態誤り（state）として切断する（offer直後のackはこれまでどおり受理）。こちらが項目・offer・chunkを送った時点で相手がすでに送り始めていた複数パケットフレーム（65バイト以上かつデコード後にping/pong以外）が終わるまでは、そのフレームの進捗に応じて返信の60秒期限を最初の送信完了から最大追加3分（合計4分）まで延長し、送信後に始まったフレームやping/pongの短いフレームでは延長しない。受信が止まった場合は組み立て期限（PC 20秒、iOS 60秒）で切断する。

全バイトを保存したらSHA-256をストリームで確認し、履歴保存後にackを返す（PC側も専用ackキューへ溜め、1通に最大1,024件までまとめる）。最後のchunkにはresumeでなくack。空ファイルや全体保存済みの再offerも検証・履歴保存へ進む。SHA不一致は受信途中を消して切断する。画像の上限超過・形式不一致・破損など受け取れない内容は、受信途中を消して履歴に入れず、固定理由だけを記録してackを返す（相手が再送し続けないようにする）。その他の受け取り失敗でも、受信途中を消してから切断する。受信済みIDは内容を書かずackだけ返す。削除／期限切れに対する遅いresumeは無視する。例と暗号フレームは `protocol/test-vectors.json`。

## 保存と重複

- PC: `%LOCALAPPDATA%\clipboardplus\sync-state.json` に登録端末、端末別キュー、受信済みID、10分間の重複記録、途中受信見出し、履歴メタデータを原子的に保存。本体は `bodies/`、途中受信は `partial/`。SHA-256をファイル名に使い、外部の名前やパスを保存先として使わない。
- 登録端末は識別子・種類・最後の認証接続時刻を保存。同じ識別子の新しい認証接続は古い接続を失効させる。ackはその接続の認証済み端末のキューだけを消す。
- キューは各端末100件、コピー時刻から24時間以内の新しいものを残す。iOSも同じ上限。本体は別ファイル、キューには履歴IDを記録し、削除時・再起動時に照合する。送信開始済みのデータは相手から取り消せない。
- 途中受信も各端末100件、作成から24時間まで（100件到達時の新規offerは作成が最古のものを追い出し、切断はしない）。32KiB単位で読み書きし、添付全体をGATTパケット配列として保持しない。iOSでは送信変換とハッシュ計算は履歴キュー、受信本体はディスクに置く。
- iOS同期用ディレクトリはApplication Supportの画像ディレクトリ内 `PCSync-v2/`。バックアップ対象から除外し、最初のロック解除後にアクセス可能なファイル保護を設定。Keychainと既存ペア設定は引き続き使用。
- iOSはPC受信内容の「種類＋本体SHA-256」をUserDefaultsへ記憶。同じ内容のクリップボード読み取りは履歴・回数・送信から除外し、理由だけログに残す。時間では消さず、異なる内容を読んだときに消す。PC受信カードのコピーも送信対象外。
- PCは「種類＋本体SHA-256」で、10分以内の他端末からの受信またはPC自身の送信と一致したら、ackだけを返す。自分自身の別のコピーは通常どおり扱う。ファイル名は同一内容の判定に含めない。
- 履歴は新しい順で300件。同じ種類・内容は1件にまとめ、識別子を保ち、新しい時刻と出どころへ更新。古いオフライン項目で最新の時刻を巻き戻さない。本文・ファイル名・パスはデータ層に保持するがログへ出さない。
- PCの組み直しで既知端末・キュー・受信途中・受信ID・重複窓を消す。PC履歴は残す。iOSの組解除は同期ディレクトリと受信ハッシュもクリアする。

## クリップボード

PCは監視除外の3形式（ExcludeClipboardContentFromMonitorProcessing、CanIncludeInClipboardHistory=0、CanUploadToCloudClipboard=0）を同じOpenClipboard内で調べる。除外印が読めない場合も見送る。画像はPNG形式またはCF_DIBを読み、PNGへ正規化。画像デコードの上限は40,000,000ピクセル。CF_HDROPは通常ファイルのみ最大10件、フォルダーとreparse pointは除外。超過・読めない項目は件数と固定理由だけログへ出す。

受信画像はビットマップとPNGの両形式。受信ファイルは `%LOCALAPPDATA%\clipboardplus\received\` にUUID接頭辞と無害化した名前で保存し、CF_HDROPとしてコピーする。安全化では区切り文字・`Cc` 制御文字・双方向制御文字（`U+061C`、`U+200E`、`U+200F`、`U+202A`〜`U+202E`、`U+2066`〜`U+2069`）・禁止文字を置換し、末尾の空白とドットを除き、名前を120文字までにする。UUID接頭辞で予約名と衝突も避ける。貼り付け先が後から読む可能性があるため、received内のファイルは履歴削除では消さない。

iOSは履歴へコミットした画像・ファイル、およびローカルカードのコピーを送る。PNG/JPEG以外の画像はImageIOでPNGへ変換して上限を再検査する。受信はPC由来で履歴へ渡す。設定オンなら画像は画像型、ファイルは実際のUTIのファイル／データ表現としてコピーする。public.dataのファイルは拡張子から型を推定し、不適切ならpublic.dataへ戻す。

## 画面から使うAPI

PCは `Core/SyncCoordinator.cs` の公開APIを窓から使う。`App` が所有するcoordinatorを次の窓へ渡す形で利用できる。

| API | 用途 |
| --- | --- |
| GetHistoryAsync(search: string? = null) | 新しい順の不変スナップショット。文章とファイル名の大文字小文字を無視した部分一致検索 |
| HistoryChanged | 変更通知。呼び出し側でDispatcher.BeginInvokeへ渡す。イベント内で同期的にGetHistoryAsyncの完了を待たない |
| DeleteHistoryAsync(id) / ClearHistoryAsync() | 削除・全消去。関連する送信待ちも除外 |
| CopyHistoryAsync(id) | クリップボードへ入れる。自分のsequenceを記憶し、端末へ再送しない |
| GetStatusAsync() / Changed(SyncStatus) | 状態の取得・変更通知。UIスレッドへpostして利用 |
| SyncStatus | 既存のConnected / Pending / LastSent / LastReceivedに、Paired / Devices / Transfers / RequiresPeerUpdateを追加 |
| DeviceStatus | Id / Kind（phoneまたはpad）/ Connected / LastConnected / Pending |
| TransferProgress | DeviceId / Direction（sendまたはreceive）/ ItemId / ItemNumber / ItemCount / Bytes / TotalBytes |
| HistoryItem | Id / Kind / Text / Filename / Path / Size / At / Source（PC / iPhone / iPad）/ Hash / Type |

Pairedはcoordinatorが有効な共有鍵を持つこと。個別の組はDevicesの登録数で確認する。PCには現在「未ペア」でもQR用の共有鍵がある。受信側の件数は、送信者の総キュー数を通信に含めないため1/1。送信側の件数はその時点の待ち列内の位置と件数。バイト進捗は送信時は送信へ渡すchunk末尾、受信時はディスクへ保存した長さ。転送方向の最新1件を接続ごとに表示し、送信待ちや途中受信の整理で表示中の項目が消えた場合はその方向の進捗表示を消す。

iOS `PCSyncController` の追加API（既存Statusのcaseは増やさず、Viewsの網羅switchを維持）:

- `@Published private(set) pendingCount: Int`
- `@Published private(set) transferProgress: TransferProgress?`。direction（send / receive）、itemID、bytes、totalBytes。未転送／完了／対象項目消去でnil。
- `@Published private(set) requiresPeerUpdate: Bool`
- `@Published private(set) requiresRepair: Bool`
- `@Published private(set) compatibilityMessage: String?`
- `retryAfterPeerUpdate()` / `retryAfterRepair()`。停止を解除して再接続。Claude側の画面では更新案内・組み直し案内とこの操作を追加する。

## 版違いと移行

第2版の端末は、組にしたPC IDと一致する相手から異なる版のWELCOMEを受けた場合のみ停止（`requiresPeerUpdate = true`、`"相手のアプリを更新してください"`）し、停止状態を保存する。利用者が更新後の `retryAfterPeerUpdate()` を行うまで再接続しない。別PC IDまたは全ゼロIDの版違い応答は相手を特定できないため停止せず、そのperipheralだけを10分間避ける。組にしたPC IDと一致するのに認証（HMAC）不一致が3回続いた場合は、版違いではなく組み直しが必要な状態（`requiresRepair = true`、`"PCとの組が一致しません。PCのQRコードを読み直して組み直してください"`）で停止する。WELCOME未着や書き込み不可などの接続確認タイムアウト、およびHELLO前／認証前の切断（記憶したPCでのサービス／characteristic探索失敗など一時的な失敗を含む）では停止せず、連続失敗に応じて再接続間隔を段階的に延ばし（0秒→30秒→2分→5分、上限10分）、認証成功でリセットする。再接続の回数・間隔・待機はBluetooth輸送層の `PCSyncReconnectPolicy` でperipheral IDごとに1か所で管理し、別候補との失敗で記憶したPCの待ち時間を延ばさず、別PCと判明した10分除外やBluetooth電源オフは間隔回数に数えない。アプリが裏にいるとき（待機中に裏へ移ったときを含む）も、記憶したPCへのOS管理の接続予約を失わないよう、`CBConnectPeripheralOptionStartDelayKey` に残り待機秒数を渡して `connect` を預ける（待ち時間0なら即時 `connect`）。

第2版のPCは異なる版のHELLOに自局PC ID入りの版2のWELCOME形応答を返し、認証せず接続を失効させる。第2版で認証・登録済みの端末IDからの版違いHELLOに限り（最大100件記録）RequiresPeerUpdateを出し、同じIDで正しい認証ができればその更新要求を解除する（未登録IDからの未認証HELLOでは誤表示防止のため出さない）。

**未更新の旧TestFlightアプリ自身の表示・再接続処理はPCから変更できない。** 第1版には登録端末の保存がないため、第1版からPCだけ更新した場合はPC側に更新案内は出ず、旧端末の10分後の再試行も旧実装のまま。両側の更新案内と自動停止を使うには第2版を両側へ導入する必要がある。旧版とのデータ互換はない。

## 既知の制限

- **iOSの受信コミット直後の終了による収集回数+1**: iOS側でPCからの受信項目（文章・画像・ファイル）を履歴DB（SQLite）へコミットした後、`SyncDiskStore.markSeen`（`state.json`）へ受信済みIDを保存する前にアプリが強制終了または異常終了した場合、PCには `ack` が返らず、iOS側にも受信済みIDが残りません。次回接続時にPCが同じIDで再送すると、iOS側の履歴DBは内容で重複統合するため重複行は作られませんが、収集回数（`collectionCount`）が1回多くカウントされます。解消には受信済みIDの記録を履歴DBの同一トランザクションに統合する必要があり、影響が限定的であるため既知の制限としています。

## 定数

| 項目 | 値 |
| --- | --- |
| キュー | 端末ごと100件、24時間 |
| 途中受信 | 端末ごと100件、24時間 |
| 添付 | 10MiB（10,485,760バイト） |
| chunk | 32KiB（32,768バイト） |
| フレーム / GATT値 | 4MiB / 512バイト |
| PC履歴 | 300件 |
| PCの内容重複窓 | 10分 |
| 受信ID記録 | 各端末500件 |
| 1回のCF_HDROP | 通常ファイル10件 |
| 画像変換 | 40,000,000ピクセル |
| ping / pong / ack・resume待ち | 30秒 / 10秒 / 60秒（送信中フレーム完了まで最大+3分、合計4分） |
| 認証HMAC不一致の停止 / 認証前バックオフ | 端末側3回 / peripheral別 0→30秒→2分→5分→上限10分 |

## 検証と実機確認

指定のdotnetでキャッシュだけからrestoreし、buildとtestを実行。NuGetパッケージ追加なし。Nodeは標準ライブラリだけで第2版のHMAC、鍵、device / offer / chunk / resume、画像とファイルの例、暗号フレームを生成する。

PCテストは既存の入口制限・認証前サイズ・接続ごとの送信・ack/pong優先・512バイトに加え、2台のack分離、オフラインキューと再起動、期限・件数、4MiB超の添付再開、SHA不一致、別端末の同内容、履歴API、削除と本体掃除、ID認証・版違いを検証する。Swiftにも同じ例を読むテストと保存・受信再開・重複抑止・画像カード・版違いのテストを追加。非同期テストはawait fulfillmentを使う。

WindowsではSwiftをビルド・実行できないため、Swiftの成功結果は未確認。Xcodeの既存CIでコンパイルと実行が必要。変えたメッセージenum・初期化・コールバック・受信APIの参照を点検し、Viewsには変更しない。

実機では次を確認する:

1. 同じQRでiPhoneとiPadを登録し、片方だけのackで他方の待ち件数が残ること。
2. PC→両端末→Apple共有の順序が入れ替わる場合、端末を後で開く場合、端末の再起動後の回数・送り返し。共有がBLE受信より先に届いた場合も観察する。
3. iPhoneでコピーしてiPadからも届いた場合、PCには1回だけ書き込むこと。
4. 10MiBちょうど／超過、空ファイル、複数ファイル・フォルダー・日本語名・同名、PNG/JPEG/HEIC/WebP、CF_DIBを両方向で確認する。
5. 転送途中の切断・PC再起動・端末終了後に、保存済みoffsetから再開して全体SHAが一致すること。背景・初回ロック解除前・省電力時の制約も確認する。
6. PCで受信画像をペイント等へ、受信ファイルをExplorerへ貼り付けること。iOSで画像／型付きファイルを貼り付けること。
7. 除外印付きの内容、キュー内履歴の削除、組み直し、24時間失効、PC履歴からのコピーが端末へ送られないこと。
8. 新旧版の組み合わせと、更新後の再試行を確認する。現在のiOSの画面追加は別担当のため、新しい更新メッセージは状態APIで提供する。

コミット・push・実機アプリの起動・本番操作は行わない。
