# Wi-Fiの直接転送の方針

2026年11月18日。Bluetooth LE（BLE）による同期の土台はそのまま残し、大きな画像やファイルだけを「PCがその場で作る小さなWi-Fi」へ逃がして高速に送る仕組みを整理する。既存のBLE同期の仕様と保存の仕組みは [Windows同期の方針](Windows同期の方針.md)、[共通部品と試験データ](../protocol/README.md)、[Windows同期の段階3メモ](Windows同期の段階3メモ.md) を前提とする。

## 背景と前提

- **実機で分かった上限（2026年11月18日）**：BLEの添付転送は、4チャンク（128KiB）の先送り窓や接続間隔の短縮を入れても実測で秒速 9〜40KB（2.1MBで 84〜172秒）にとどまった。WindowsのWinRT GATTサーバーが書き込みを1つずつしか渡さないことが上限と見ている。また、BLEで連続送信している間はBluetoothイヤホンの音も途切れる。
- **利用者の判断（2026年11月18日）**：AirDropが使う仕組み（AWDL）をWindowsで再現するのは現実的でないため、**PCがその場で小さなWi-Fi（一時的なアクセスポイント）を作り、iPhone・iPadがそこへ直接つなぐ形**をとる。目安として **500KB以上のときはこの方式** を使い、それより小さい項目と、Wi-Fiにつなげなかったときは今のBLEで送る。カフェや学校のWi-Fiごとに設定し直す手間は増やさない。

---

## 1. Windows 側で使える手

Windowsがソフトウェアのアクセスポイントを立てる公開WinRT APIには、**① `WiFiDirectAdvertisementPublisher` のレガシーモード** と **② モバイルホットスポット（`NetworkOperatorTetheringManager`）** の2つがある。

### 2つの方式の比較

| 項目 | ① `WiFiDirectAdvertisementPublisher`（レガシーモード） | ② `NetworkOperatorTetheringManager`（モバイルホットスポット） |
| --- | --- | --- |
| **見せ方** | Wi-Fi Directの自律グループオーナーを普通のWPA2アクセスポイントとして見せる | Windows標準の「モバイルホットスポット」機能をアプリから起動する |
| **非パッケージWPF（.NET 10）** | 呼び出し可（`DualApiPartition` 対象） | 呼び出し可（`DualApiPartition` 対象） |
| **管理者権限（API呼び出し）** | 不要（ファイアウォール規則の初回許可にはUACが必要） | 文書上は不要だが、ICS制御を伴うため通常権限での成否は要実機確認（ファイアウォールは左と同じ） |
| **別Wi-Fiでネット接続中** | 対応アダプタなら同時作成可（モバイルホットスポットがオンの間は競合して不可） | 対応アダプタなら同時作成可 |
| **PCがオフラインのとき** | **単独で作成可** | `GetInternetConnectionProfile()` が空になり、そのままでは開始不可 |
| **OS設定への影響** | **残らない**（停止すれば消える一時SSID・パスフレーズ） | 従来のAPIではOSのモバイルホットスポット設定（SSID・パスワード）を上書きする（Windows 11 24H2以降はセッション限定APIあり） |
| **起動にかかる秒数（推測）** | 約 0.5〜3秒 | 約 2〜6秒（ICSとDHCPの準備を含む） |
| **IP割り当て（DHCP）** | 仮想アダプタ上でPCが親機（通常 `192.168.137.1`）になるが、DHCP応答の速さは要実機確認 | ICSによりPCが `192.168.137.1` となり、安定したDHCPとネット共有（NAT）を提供する |
| **iOS側のネット接続** | インターネット共有なし（Wi-FiモデルのiPadは接続中の数秒間ネットが止まる） | PCがネット接続中なら、参加中もPC経由でインターネットに出られる |

### 確かなこと

- **パッケージ化していない .NET 10 WPF から使えるか**：
  - PC側の実行ファイル（`windows/ClipboardPlus.Windows/ClipboardPlus.Windows.csproj`、`net10.0-windows10.0.22621.0`）はパッケージIDを持たない通常のデスクトップアプリである。`WiFiDirectAdvertisementPublisher`、`WiFiDirectLegacySettings`、`NetworkOperatorTetheringManager` はいずれもWinRTのメタデータで `DualApiPartitionAttribute` が付与されており、デスクトップアプリから呼び出せるAPIに含まれ、パッケージIDが必須のAPI一覧には入っていない。既存の `BleServer` と同じく標準のWinRT投影から呼べるため、新しいNuGetパッケージも不要である。
    - 根拠：[Desktop apps calling WinRT APIs](https://learn.microsoft.com/windows/apps/desktop/modernize/desktop-to-uwp-supported-api)、[DualApiPartitionAttribute](https://learn.microsoft.com/uwp/api/windows.foundation.metadata.dualapipartitionattribute)、[WiFiDirectAdvertisementPublisher](https://learn.microsoft.com/uwp/api/windows.devices.wifidirect.wifidirectadvertisementpublisher)、[NetworkOperatorTetheringManager](https://learn.microsoft.com/uwp/api/windows.networking.networkoperators.networkoperatortetheringmanager)
  - UWPパッケージの場合はマニフェストに `wiFiControl` デバイス機能が必要と定められているが、AppContainer外で動く非パッケージのデスクトップアプリにはマニフェスト機能の制限はない。一方、Windows 11（とくに24H2以降）では周辺のWi-Fi情報を読むAPIに対してOSの「位置情報」アクセス許可が求められる変更が入っているため、周囲のSSIDやBSSIDを読むAPIは呼ばず、アクセスポイントの作成と自局IPの取得だけに絞る。
    - 根拠：[Wi-Fi access and location API behavior changes](https://learn.microsoft.com/windows/win32/nativewifi/wi-fi-access-and-location-api-behavior-changes)
- **それぞれの作り方と排他関係**：
  - ①は `WiFiDirectAdvertisementPublisher` の `Advertisement.IsAutonomousGroupOwnerEnabled` と `Advertisement.LegacySettings.IsEnabled` をともに有効にし、`Ssid` と `Passphrase`（WPA2パスフレーズ）を指定して開始する。これによりWi-Fi Direct非対応のiPhone・iPadから通常のWi-Fiアクセスポイントとして見える。
    - 根拠：[IsAutonomousGroupOwnerEnabled](https://learn.microsoft.com/uwp/api/windows.devices.wifidirect.wifidirectadvertisement.isautonomousgroupownerenabled)、[WiFiDirectLegacySettings](https://learn.microsoft.com/uwp/api/windows.devices.wifidirect.wifidirectlegacysettings)
  - ②は `NetworkOperatorTetheringManager.CreateFromConnectionProfile` に共有元の接続プロファイルを渡し、`ConfigureAccessPointAsync` と `StartTetheringAsync` で起動する。ただし `ConfigureAccessPointAsync` はOSのモバイルホットスポット設定をセッションをまたいで書き換える仕様である。Windows 11 24H2（ビルド `10.0.26100.0`）以降では、永続設定を書き換えない `NetworkOperatorTetheringSessionAccessPointConfiguration` が追加されている。
    - 根拠：[CreateFromConnectionProfile](https://learn.microsoft.com/uwp/api/windows.networking.networkoperators.networkoperatortetheringmanager.createfromconnectionprofile)、[ConfigureAccessPointAsync](https://learn.microsoft.com/uwp/api/windows.networking.networkoperators.networkoperatortetheringmanager.configureaccesspointasync)、[StartTetheringAsync](https://learn.microsoft.com/uwp/api/windows.networking.networkoperators.networkoperatortetheringmanager.starttetheringasync)、[NetworkOperatorTetheringSessionAccessPointConfiguration](https://learn.microsoft.com/uwp/api/windows.networking.networkoperators.networkoperatortetheringsessionaccesspointconfiguration)
  - **同時実行の制限**：Windows 10（1607）以降、モバイルホットスポットと `WiFiDirectLegacySettings` によるグループオーナーは同時に動かせず、常にモバイルホットスポット側が優先される（モバイルホットスポットがオンの状態で①を使うと停止または失敗する）。
    - 根拠：[WiFiDirectLegacySettings Remarks](https://learn.microsoft.com/uwp/api/windows.devices.wifidirect.wifidirectlegacysettings)
- **PCがほかのWi-Fiでインターネットにつないだまま作れるか**：
  - Windowsは「Microsoft Wi-Fi Direct Virtual Adapter」を使って、物理Wi-Fiアダプタが親Wi-Fiにつながったまま仮想アクセスポイントを同時に立てられる。ただし①はPCが完全オフラインでも単独で立てられるのに対し、②は共有元の接続プロファイルが前提であり、オフライン時には `NetworkInformation.GetInternetConnectionProfile()` が `null` になる。
    - 根拠：[Windows PC をモバイル ホットスポットとして使用する](https://support.microsoft.com/ja-jp/windows/windows-pc-%E3%82%92%E3%83%A2%E3%83%90%E3%82%A4%E3%83%AB-%E3%83%9B%E3%83%83%E3%83%88%E3%82%B9%E3%83%9D%E3%83%83%E3%83%88%E3%81%A8%E3%81%97%E3%81%A6%E4%BD%BF%E7%94%A8%E3%81%99%E3%82%8B-08800b5f-0d22-4062-978a-73620c09d243)
- **管理者権限とファイアウォールの扱い**：
  - Windows Defender ファイアウォールは既定で外向き通信を許し、未登録プログラムの**内向き待ち受け（inbound listen）を遮断して確認枠を出す**。確認枠で許可規則を追加するには**管理者権限（UAC）**が要り、「プライベート」と「パブリック」が分かれている。また組織管理PC（GPO / Intune）では、モバイルホットスポットや利用者によるファイアウォール規則追加が禁止されている場合がある。
    - 根拠：[Windows Defender Firewall](https://learn.microsoft.com/windows/security/operating-system-security/network-security/windows-firewall/)、[Best practices for configuring Windows Defender Firewall](https://learn.microsoft.com/windows/security/operating-system-security/network-security/windows-firewall/best-practices-configuring)
  - 実行ファイルを固定の場所（`%LOCALAPPDATA%\Programs\clipboardplus\ClipboardPlusForWindows.exe`）で更新する運用では、初回に1度だけ許可すれば同じパスに対して規則が維持される。安全のため、PC側の `TcpListener` は `0.0.0.0`（全インターフェイス）ではなく**小さなWi-Fiの仮想アダプタに付いた自局IPアドレスだけにバインド**し、転送が終わったらすぐ閉じることで、カフェや学校のWi-Fi側には一切待ち受けポートを開かない設計にする。

### 推測（実機で確かめること）

- **仮想アダプタのファイアウォール区分**：一時作成される仮想アダプタは「識別されていないネットワーク（パブリック網）」として扱われる見込みが高いため、初回のWindowsファイアウォール確認枠では「パブリック ネットワーク」側の許可が必要になると見込まれる。
- **①のDHCP応答時間**：①（`WiFiDirectLegacySettings`）でもWindows内部で `192.168.137.1` 系のDHCPが動く例が多い一方、ドライバやICSサービスの状態によってDHCP配布が遅れ、リンクローカル（`169.254.x.x` やIPv6 `fe80::`）確定まで十数秒かかる事例がある。なおiOSのようなレガシーWi-FiクライアントはWi-Fi DirectのP2P交渉を行わないため、`WiFiDirectConnectionListener` ではなく仮想アダプタのIP上で通常のTCP待ち受け（`TcpListener`）を行う。
- **②の通常権限での動作**：②（`NetworkOperatorTetheringManager`）は裏でICSサービス（`icssvc`）を動かすため、非パッケージの通常権限プロセスから設定変更・開始がそのまま通るか、環境により権限エラーにならないかは実機確認が要る。
- **無線チャネルと起動秒数**：単一の無線チップで親Wi-Fiと仮想APを兼ねる場合、親Wi-Fiが5GHzのDFSチャネルにいると仮想APが2.4GHzに制限されるなどのドライバ制約がある。起動秒数は①で約0.5〜3秒、②で約2〜6秒と見込む。
- **Windows側の選び方の方針**：OSのホットスポット設定を書き換えずオフラインでも立つ **① `WiFiDirectAdvertisementPublisher`（レガシーモード）を第一候補** とし、アクセスポイント制御を薄い境界（インターフェイス）で包んでおくことで、実機で①のDHCPが遅い場合やネット断を避けたい場合に②へ差し替え・併用できるようにする。

---

## 2. iOS 側：`NEHotspotConfigurationManager` での参加

### 確かなこと

- **参加時の確認の出方（毎回出るか、`joinOnce` で変わるか）**：
  - `NEHotspotConfigurationManager.shared.apply(_:completionHandler:)` を呼ぶと、**`joinOnce` が `true` でも `false` でも、iOSのシステム確認枠（「"clipboard+"がWi-Fiネットワーク"…"に接続しようとしています」［キャンセル／接続］）が毎回必ず表示される**。アプリ側からこの確認を省略するAPIはない。利用者がキャンセルを押すと `NEHotspotConfigurationError.userDenied` が返り、すでに同じSSIDへ接続中なら `alreadyAssociated` が返る。
    - 根拠：[NEHotspotConfigurationManager](https://developer.apple.com/documentation/networkextension/nehotspotconfigurationmanager)、[apply(_:completionHandler:)](https://developer.apple.com/documentation/networkextension/nehotspotconfigurationmanager/apply(_:completionhandler:))、[NEHotspotConfigurationError](https://developer.apple.com/documentation/networkextension/nehotspotconfigurationerror)
  - **`joinOnce = false` にしても毎回の確認は消せない理由**：`joinOnce = false` にすると承認後に「マイネットワーク」へ保存されるが、いまカフェや学校のWi-Fiにつながっている状態からPCの一時Wi-Fiへ切り替えさせるにはアプリが `apply` を呼ぶしかなく、`apply` を呼べば再び確認枠が出る。さらに設定を残したままにすると、終わったあとに元のWi-Fiへ自動で戻らず（戻すために `removeConfiguration` を呼べば保存も消える）、インターネットのないPC側Wi-Fiへ後から勝手に自動接続して通信が止まる原因になる。したがって **`joinOnce = true` を使い、大容量を送受するときだけ利用者が「接続」を1回押す形** にする。
    - 根拠：[joinOnce](https://developer.apple.com/documentation/networkextension/nehotspotconfiguration/joinonce)
  - **初回だけ出る別の許可（ローカルネットワーク権限）**：参加後にPCのローカルIP（`192.168.137.1` 等）へ `NWConnection` でTCP接続するとき、iOSの「ローカルネットワーク」権限確認が**初回に1回だけ**出る。一度許可されれば2回目以降は出ない。
    - 根拠：[TN3179: Understanding local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
- **要る entitlement と `Info.plist`**：
  - 本体ターゲットの `app/ClipboardPlus/ClipboardPlus.entitlements`（現在はApp Groupのみ設定済み）に **`com.apple.developer.networking.HotspotConfiguration`（真偽値 `true`）** を追加する。このentitlementは通常のApple Developer Programで有効化でき、Appleへの事前特別申請は要らない（キーボード拡張と共有拡張には不要）。
    - 根拠：[Hotspot Configuration Entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.hotspotconfiguration)
  - 本体の `Info.plist`（`app/project.yml`）に **`NSLocalNetworkUsageDescription`** を追加する。BLEでIPとポートを直接渡すためBonjour探索は使わず、`NSBonjourServices` は不要。また現在のSSIDを読み取る処理（`fetchCurrent`）を使わないため、位置情報権限や `Access WiFi Information` も不要である。
    - 根拠：[NSLocalNetworkUsageDescription](https://developer.apple.com/documentation/bundleresources/information_property_list/nslocalnetworkusagedescription)、[TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
- **アプリが裏にいるときに使えるか**：
  - **使えない**。バックグラウンド状態で `apply` を呼ぶと確認枠は出ず、即座に `NEHotspotConfigurationError.applicationIsNotInForeground` で失敗する。
    - 根拠：[NEHotspotConfigurationError](https://developer.apple.com/documentation/networkextension/nehotspotconfigurationerror)
  - また `joinOnce = true` で接続したあとも、**アプリが裏へ移って15秒を超えたとき、端末がスリープしたとき、アプリが終了したとき、または別Wi-Fiへ切り替えたとき**には、iOSが自動的にその一時Wi-Fiを切断して設定を破棄する。
    - 根拠：[joinOnce](https://developer.apple.com/documentation/networkextension/nehotspotconfiguration/joinonce)
- **参加している間のインターネット**：
  - PC側がインターネット共有を持たない方式（`WiFiDirectLegacySettings`、またはオフラインPC）のとき、**Wi-FiモデルのiPadでは参加している数秒〜十数秒の間インターネット通信が止まる**。
  - セルラー通信対応のiPhone・iPadでは、インターネット経路のないWi-Fiと判定されると一般通信がモバイル回線へ逃げる場合がある。その際、PC宛てのTCPソケットまでモバイル回線側へ流れて失敗しないよう、`NWParameters` で **`requiredInterfaceType = .wifi` を明示してWi-Fiインターフェイスへ固定**する。
    - 根拠：[NWParameters.requiredInterfaceType](https://developer.apple.com/documentation/network/nwparameters/requiredinterfacetype)
- **終わったあとの元の Wi-Fi への戻り**：
  - 転送完了（または中断）の直後に `removeConfiguration(forSSID:)` を呼ぶと、`joinOnce = true` の一時Wi-Fiから即座に切断され、iOSが直前まで使っていた既知のWi-Fi（自宅・カフェ・学校など自動接続が有効な網）へ自動でつなぎ直す。万一アプリが途中で落ちた場合も、`joinOnce = true` の仕様により裏へ行って15秒以内または終了時に自動切断されるほか、次回起動時にも残存設定の掃除を呼べる。
    - 根拠：[joinOnce](https://developer.apple.com/documentation/networkextension/nehotspotconfiguration/joinonce)、[removeConfiguration(forSSID:)](https://developer.apple.com/documentation/networkextension/nehotspotconfigurationmanager/removeconfiguration(forssid:))

### 推測（実機で確かめること）

- **iPadの小窓表示での前面判定**：Slide OverやStage Managerでclipboard+が画面に出ているときは前面として通る見込みだが、横に並べた別アプリを操作中でシーンが `foregroundInactive` になっている瞬間に `apply` が通るか、一度clipboard+側を触る必要があるかは実機で確かめる。
- **外出先Wi-Fiへの復帰秒数**：通常のWPA2/WPA3網や802.1X網へは切断後数秒で自動復帰する見込みだが、ログイン画面付きのフリーWi-Fi（キャプティブポータル）で短時間の離脱後に再ログインが要らないかは環境によるため実機で確かめる。

---

## 3. ほかに使える道があるか

「PCが作る小さなWi-Fi」以外の近距離・大容量経路がiPhone・iPadとWindows 11の間で成り立つかを整理する。

| 方式 | iOS / Windows 両対応 | カフェ・学校で使えるか | 毎回の操作 | 見込み速度（推測） | 判定 |
| --- | --- | --- | --- | --- | --- |
| **PCが小さなWi-Fiを作る（本方式）** | **可** | **可** | iOS前面で「接続」1回 | **約 5〜30MB/秒**（＋切替 3〜10秒） | **採用** |
| **Wi-Fi Aware（NAN）** | **不可**（Windows非対応） | （規格上は可） | （初回ペアリングのみ） | ― | 現状は使えない |
| **同じWi-Fi内で直接TCP** | **可** | **不可が多い**（端末間分離） | なし（裏でも自動） | **約 5〜40MB/秒**（切替 0秒） | 自宅用・将来の併用候補 |
| **BLE L2CAP / Classic** | **不可**（片側APIなし） | ― | ― | ― | 使えない |
| **USB有線 / AWDL / クラウド** | 条件付きまたは不可 | ケーブル必須／方針外 | ケーブル接続など | ― | 採用しない |
| **現行のBLE GATT** | **可（実装済み）** | **可** | なし（裏でも自動） | 実測 9〜40KB/秒 | 小項目・予備経路として維持 |

### 確かなこと

- **Wi-Fi Aware（iOS 26 の公開フレームワークと Windows 11 の対応状況）**：
  - **iOS側**：iOS 26 / iPadOS 26以降で公開フレームワーク `WiFiAware` が追加された。iPhone 12以降・iPad Air（第4世代）以降などの対応機（主端末のiPad Air 13インチ・iPadOS 27.2.1を含む）で、アクセスポイントを介さず既存のWi-Fi接続を保ったまま高速なP2P通信ができ、初回に `DeviceDiscoveryUI` 等で組にすれば以後は背景からも接続できる。
    - 根拠：[Wi-Fi Aware framework](https://developer.apple.com/documentation/wifiaware)
  - **Windows側**：**Windows 11にはWi-Fi Aware（Neighbor Awareness Networking / NAN）のOS標準機能および公開API（WinRTの `Windows.Devices.WiFi*` やWin32の `wlanapi.h`）が存在しない**。Windowsが公開している近距離Wi-Fi P2P APIはWi-Fi Directのみであり、Wi-Fi Awareとは別規格で相互接続できない。したがって現時点ではWindowsとの同期には使えない。
    - 根拠：[Windows.Devices.WiFiDirect](https://learn.microsoft.com/uwp/api/windows.devices.wifidirect)、[Native Wifi API](https://learn.microsoft.com/windows/win32/nativewifi/native-wifi-portal)、[wlanapi.h](https://learn.microsoft.com/windows/win32/nativewifi/wlanapi-h)
- **Bluetooth L2CAP / Classic が使えない理由**：
  - iOSにはBLE L2CAPチャンネル（`CBPeripheral.openL2CAPChannel(_:)`）があるが、Windowsの公開WinRT API（`Windows.Devices.Bluetooth`）にBLE L2CAPを待ち受け・開閉するAPIがない。逆にBluetooth Classic（RFCOMM）はiOS側がMFi認証機器向けの `ExternalAccessory` 限定であり汎用PCとは通信できない。
    - 根拠：[openL2CAPChannel(_:)](https://developer.apple.com/documentation/corebluetooth/cbperipheral/openl2capchannel(_:))、[Windows.Devices.Bluetooth](https://learn.microsoft.com/uwp/api/windows.devices.bluetooth)、[ExternalAccessory](https://developer.apple.com/documentation/externalaccessory)
- **同じWi-Fi（同一LAN）での直接TCPとの関係**：
  - 自宅のルーターやスマートフォンのテザリングのように機器間通信が通る網では、BLEでPCのLAN IPとポートを渡して直接TCP接続すれば、Wi-Fiの切り替えも毎回の「接続」確認枠もなしに高速転送できる（[TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)）。ただしカフェや学校のWi-Fiではクライアント分離やVLAN分離で遮断されるため単独では要件を満たせない。なお、後述する「TCP上の暗号ストリーム転送」は同一LAN直接TCPでもそのまま共通部品として使える構造にしておく。

---

## 4. 流れの設計

小さい項目（文章、500KB未満の画像・ファイル）、死活確認、完了確認、およびWi-Fi接続の交渉はすべて**今のBLE暗号セッション（QR共有鍵とHMACで相互認証した `SyncSessionKeys` 上のAES-256-GCMフレーム）**の上で行う。

### BLEで交換するもの（今の暗号のつながりの上で送る）

Wi-Fiの電波上に端末名や利用者名を出さないため、SSIDとパスフレーズは接続のたびに乱数で作る。BLE上には次の制御メッセージを追加する。

| メッセージ | 向き | 含める内容と役割 |
| --- | --- | --- |
| `wifi_request` | iOS → PC | 対象項目の `id`（または一括要求）、方向。iOSが前面にいて参加の確認枠を出せる状態で送る |
| `wifi_ready` | PC → iOS | `session`（16バイト乱数UUID）、一時 `ssid`（`DIRECT-cp-`＋乱数英数字、個人名・機器名を含めない）、一時 `passphrase`（乱数英数字24文字以上）、PCの仮想アダプタ `ip` と待ち受け `port`、32バイトの使い捨て鍵材料 `token`、有効秒数（例：30秒） |
| `wifi_unavailable` | PC → iOS | 理由コード（非対応・競合・起動失敗など）。待たずにすぐBLE転送へ戻すために返す |
| `wifi_cancel` | 双方向 | `session`。利用者がキャンセルしたときやタイムアウト時に送り、PCの小さなWi-Fiと待ち受けポートを即座に閉じさせる |

- **鍵の分離**：`wifi_ready` で渡した32バイトの使い捨て鍵材料 `token`（暗号化されたBLEフレームの中だけで届く）と `session` から、HKDF-SHA256で①TCP接続確認用の認証鍵、②iOS→PC用のTCP暗号鍵、③PC→iOS用のTCP暗号鍵を方向別に派生する。BLE側の送信番号や暗号状態とは完全に切り離す。

### 参加から離脱までの共通の流れ

1. **参加（iOS）**：`wifi_ready` を受けたiOSが、`joinOnce = true` の `NEHotspotConfiguration` を `apply` し、利用者がシステム確認枠の「接続」を1回押す。
2. **TCP接続と相互確認**：
   - PC側は小さなWi-Fiの仮想アダプタIPだけに限定した `TcpListener` で1接続を待ち受ける。
   - iOS側は `requiredInterfaceType = .wifi` を指定した `NWConnection` でPCの `ip:port` へTCP接続する。
   - 接続直後に双方の乱数と `session` に対する方向別HMAC-SHA256を交換し、正規の相手・正規のセッションであることを確かめてから本体の送受信に入る（万一第三者が同じ一時APや同一IPに居合わせても弾く）。
3. **送る（暗号化・途中から再開・SHA-256の確認）**：
   - **暗号化**：既存の `SyncFrameSender` / `SyncFrameReceiver` と同じAES-256-GCMフレーム形式（8バイト単調増加番号＋暗号文＋16バイトタグ、AAD付き）を使う。TCP自身が順序保証・再送・輻輳制御を持つため、BLEのような32KiBごとの往復待ちは行わず、64KiB〜256KiB単位のフレームを連続ストリームで送り出してディスクへ順次書き込む。
   - **途中からの再開**：送信側が既存と同じ見出し `offer`（`id`, `at`, `from`, `kind`, `size`, `sha256`, `name64`, `type`）を送り、受信側は既存の途中保存領域（PCは `partial/`、iOSは `PCSync-v2/`）に一致する部分ファイルがあれば保存済みバイト数 `offset`（なければ `0`）を1回だけ `resume` で返す。送信側は `offset` から末尾までを一気に送る。これにより、BLEで途中まで送っていた残りや、前回Wi-Fiが途中で切れた続きからも無駄なく再開できる。
   - **SHA-256の確認と完了**：全バイトをディスクへ書き終えたら、受信側はファイルをストリームで読み出して全体のSHA-256を検証し、履歴（および設定オンならクリップボード）へ保存したうえで `ack` を返す。不一致なら途中ファイルを消して切断する。
   - **1回の参加でまとめて片付ける**：TCPがつながっている間に、その時点で待ち列にある大容量項目（送り・受けの両方向）を続けてすべて転送してから閉じる。大きな画像を複数件コピーしたときに「接続」確認枠が何度も出るのを防ぐ。
4. **終わったら離れる**：
   - すべての対象項目の `ack` が済んだらTCPを閉じ、iOSは直ちに `removeConfiguration(forSSID:)` を呼んで一時Wi-Fiから離れ、元のWi-Fiへ戻る。
   - PCもTCPの正常終了（または `wifi_cancel`、無通信期限切れ）で直ちに小さなWi-Fiと `TcpListener` を停止する。ログには状態・件数・バイト数・所要時間・速度（KB/秒またはMB/秒）・固定の失敗理由コードだけを残し、鍵・パスフレーズ・SSID・IP・本文・ファイル名は記録しない。

### 方向ごとの動きの違い

- **① iOS から PC へ送る場合（iOS → PC）**：
  - iOSがクリップボードや切り取り・共有拡張から新しい大きな項目を取り込むときは、clipboard+が画面に出ている（前面にある）ときである。
  - 500KB以上の項目が送信待ちに入ったら、iOSがそのままBLEで `wifi_request` を送り、PCが小さなWi-Fiを立てて `wifi_ready` を返し、利用者が「接続」を1回押してTCPで送る。コピー直後に利用者がアプリを裏へ隠していた場合だけ、下のフォールバック規則に従って扱う。
- **② PC から iOS へ送る場合（PC → iOS）**：
  - **iOSのclipboard+が前面に出ているとき（Slide Overの小窓表示など）**：PCがBLEで500KB以上の `offer`（または大容量待機通知）を送ると、前面にいるiOSが自動で `wifi_request` を返し、①と同じく「接続」1タップで受け取る。
  - **iOSのclipboard+が裏にいる・スリープしているとき**：裏では `NEHotspotConfigurationManager` の確認枠を出せないため、PCは小さなWi-Fiを勝手に立てない（iOSから `wifi_request` が来たときだけ立てる）。PCはBLEで見出しの通知（またはキュー保持）までを行って待機し、**利用者がiPad・iPhoneでclipboard+を前に出した時点で `wifi_request` を送って小さなWi-Fiで一気に受け取る**のを基本とする（裏にいる間に何分もBLEで大容量を流し続けてBluetoothイヤホンが途切れるのを防ぐため。「8. 決まったこと」のとおり①を採用）。
  - **1台のPCにiPhoneとiPadの両方がつながっているとき**：PC側の端末別キュー（`SyncRepository`）はそのまま維持し、前に出て `wifi_request` を出した端末とだけその場で小さなWi-Fiを使って受け渡す。もう片方の端末のキューは消さず、その端末が受け取れるときに独立して送る。

---

## 5. 「500KB 以上」の決め方と BLE へ戻る条件

### なぜ 500KB（512,000バイト）を既定の境目にするか

- 実機のBLE速度（9〜40KB/秒）と、小さなWi-Fiの起動・参加・切り替えにかかる固定時間（見込み約 3〜10秒＋「接続」を1回押す手間）を比べると、**200KB以下の小さな画像**はBLEのまま操作なしで約 5〜20秒で届くほうが手軽である。一方、**500KB**ではBLEだと約 13〜55秒かかってBluetoothイヤホンへの影響も出始め、**2MB以上**ではBLEで数分かかるのに対し小さなWi-Fiなら切り替え込みで10秒前後に縮まる。このため既定値を **500KB以上** とするのがちょうどよい境目になる。

### しきい値を設定で変えられるようにするか

- 細かい数値入力は迷いやすいため、設定画面で数段階の選択肢（例：**「500KB以上（既定）」「2MB以上」「使わない（つねにBluetooth）」**）から選べる形にするのが扱いやすい。
- どちらの向きでも実際に「接続」を押すのはiOS側であるため、しきい値の判定と設定をiOS側に持たせる（PC→iOSでも `offer.size` が設定値以上ならiOSが `wifi_request` を出す）ことで、設定の食い違いが起きない。

### Wi-Fi がだめだったときに BLE へ戻る条件と時間

小さなWi-Fiが使えない環境でも同期が止まらないよう、次の条件と制限時間で自動的に今のBLE転送（保存済み `offset` からの再開）へ戻す。

| 段階・場面 | 条件と制限時間 | 戻し方 |
| --- | --- | --- |
| **PC側で起動不可** | アダプタ非対応・無線オフ・ポリシー禁止・モバイルホットスポット競合（即時〜数秒） | PCがすぐ `wifi_unavailable` を返し、待ち時間なしでBLE転送へ移る |
| **利用者がキャンセル / 裏へ移動** | 確認枠で「キャンセル」を押したとき（`userDenied`）、または `applicationIsNotInForeground` のとき（即時） | iOSが `wifi_cancel` を送り、その項目IDには再確認を出さずBLE転送へ移る |
| **PCからの準備応答待ち** | `wifi_request` 送信から **8秒以内** に `wifi_ready` が来ないとき | Wi-Fi交渉を打ち切ってBLE転送へ移る |
| **確認枠の承認待ち** | `wifi_ready` から **30秒以内** に利用者が「接続」を押さないとき | PC・iOS双方で一時Wi-Fiを片付け、BLE転送（または次回前面時）へ戻す |
| **参加後のTCP接続・認証** | 「接続」承認（`apply` 完了）から **10秒以内** にTCP接続とHMAC確認が終わらないとき（DHCP遅延・ファイアウォール遮断など） | 直ちに `removeConfiguration` で元のWi-Fiへ戻し、PCのAPを止めてBLE転送へ移る（PC画面にファイアウォール確認の案内を出す） |
| **TCP転送中の停止** | 転送中に **10秒間** バイトが進まないとき、またはアプリが裏へ行って切断されたとき | 一時Wi-Fiを片付け、ディスクに残った途中ファイルの `offset` からBLE（または次回Wi-Fi）で続きを送る |
| **連続失敗の控え** | 同じ接続セッション中にWi-Fi確立（キャンセルを除く）が **連続2回失敗** したとき | 毎回確認枠が出て失敗するのを防ぐため、設定から再試行するか再接続するまで自動的にBLEを使う |

---

## 6. 審査の扱い

### 確かなこと（ガイドラインと権限要件）

- `NEHotspotConfigurationManager` と `com.apple.developer.networking.HotspotConfiguration` は公開API・標準Capabilityであり、Appleの文書でもローカルホットスポットへの一時参加やMFi / HomeKitを使わない外部機器とのWi-Fi通信が用途として示されている。
  - 根拠：[NEHotspotConfigurationManager](https://developer.apple.com/documentation/networkextension/nehotspotconfigurationmanager)、[Hotspot Configuration Entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.hotspotconfiguration)
- App Store Review Guidelines上の要点：
  - **2.1（Appの完成度）および外部機器連携の確認**：審査担当者の手元にWindows PC側の同期アプリがない状態でも、iPad・iPhone単体のクリップボード履歴・テンプレート・切り取り・専用キーボードがすべて完結して動作する必要がある。また外部機器（PC）と組み合わせる機能については、審査担当者が動作を確認できる説明や映像を用意することが求められる。
  - **5.1.1（権限の用途説明）**：`NSLocalNetworkUsageDescription` に、組にした近くのWindows PCと大きな画像やファイルを直接受け渡すためにローカルネットワークを使う旨を具体的に明記し、インターネットや外部サーバーへ送信しないことと整合させる。
  - 根拠：[App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)

### 審査の担当者への説明の仕方（推測を含む実務上の対策）

- 審査担当者はMac環境で審査することが多く、Windows PCで一時Wi-Fiを立てる相手機を手元で再現できない可能性が高い。`HotspotConfiguration` が有効な理由が画面だけで伝わりにくいと照会（2.1の質問）になりやすいため、段階6の提出時に **App Store Connectの「App Reviewに関する情報（メモ欄）」と実機デモ動画** を添える。
- **審査メモに書く要点（3点）**：
  1. 本アプリの中心機能（クリップボード履歴・テンプレート・切り取り・キーボード拡張）はWindows PCなしですべてそのまま試せること。
  2. 任意の機能である「Windowsと同期」において、端末間通信が遮断された外出先Wi-Fi環境でも500KB以上の画像・ファイルをクラウドを経由せず直接送受するため、QRコードでペアリング済みのWindows PCが一時的なアクセスポイントを立て、`NEHotspotConfigurationManager`（`joinOnce = true`）で利用者の同意のもと数秒間だけ接続し、転送完了直後に `removeConfiguration` で切断して元のWi-Fiへ戻すこと。
  3. 添付（またはURL記載）の実機動画で、①iPadで大きな画像をコピー → ②システム確認枠で「接続」をタップ → ③PCへ数秒で届き、自動で元のWi-Fiへ復帰する一連の動きを確認できること（動画やURLには個人の情報やリポジトリと販売者名を結び付ける情報を含めない）。

---

## 7. 段階の分け方と作業の大きさ・実機で最初に確かめるべきこと

### 実機で最初に確かめるべきこと（本実装の前の小さな検証）

本格的な組み込みの前に、利用者のPCとiPad Air / iPhoneの実機でまず次の5点を確かめる。

1. **PCのWi-Fiアダプタが対応しているか**：自宅や外出先のWi-Fiにつながったまま、非パッケージ・通常権限のWPFアプリから `WiFiDirectAdvertisementPublisher`（レガシーモード）を起動できるか、親Wi-Fiが切れずに同時動作するか、5GHzと2.4GHzのどちらで立つか、開始まで何秒かかるか（あわせて `NetworkOperatorTetheringManager` との違いも比較する）。
2. **DHCPの秒数とファイアウォールの出方**：iPad・iPhoneが参加してからIPv4アドレス（`192.168.137.x`）が付くまで何秒かかるか（リンクローカル待ちで十数秒止まらないか）。またPC側の初回ファイアウォール確認枠でパブリック網を許可すれば、2回目以降は無警告でTCPがつながるか。
3. **iOSの参加確認が何回出るかと元のWi-Fiへの戻り**：初回（ローカルネットワーク許可1回＋Wi-Fi接続確認1回）と2回目以降（Wi-Fi接続確認1回だけ）の出方、Slide Overの小窓表示中にもそのまま押せるか、`removeConfiguration` 後に元のWi-Fiへ何秒で戻り、数秒のネット断が気にならないか。
4. **実際の速さとBluetoothイヤホンへの影響**：2MB〜10MBのデータをTCPで送ったときの「接続タップ〜転送完了〜元のWi-Fi復帰」の合計秒数と実効MB/秒、およびその間にBluetoothイヤホンの音が途切れないこと。
5. **CIの自動署名でのentitlement反映**：`ClipboardPlus.entitlements` に `HotspotConfiguration` を足したとき、既存のTestFlightワークフロー（`-allowProvisioningUpdates`）だけで署名・書き出しが通るか、Apple DeveloperサイトでのApp ID設定変更が要るか。

### 段階の分け方と作業の大きさ

| 段階 | 内容 | Windows 側 | iOS 側 |
| --- | --- | --- | --- |
| **段階A：実機での最小検証** | PCで小さなWi-FiとTCP待ち受けを仮起動し、iPadから参加して数MBを送る試験で上の5点を測り、PC側のAP API（①か②か）を確定する | **小** | **小** |
| **段階B：共通プロトコルとTCPストリーム部品** | Wi-Fi交渉メッセージ、使い捨て鍵のHKDF派生、TCP上のHMAC相互確認と連続AES-256-GCMストリーム（`offer`・`resume`・SHA-256・`ack`）をOS非依存のCore層と `protocol/make-test-vectors.mjs` に作り、両言語の単体テストで固める | **中** | **中** |
| **段階C：Windows側のAP制御とBLE統合** | アクセスポイント起動・停止、仮想アダプタIP限定の `TcpListener`、寿命タイマー、失敗時の即時BLEフォールバック、複数件まとめ送受信を `SyncCoordinator` と `Infrastructure` に組み込む | **中〜大** | ― |
| **段階D：iOS側の参加制御・背景対応・設定** | `NEHotspotConfigurationManager` と `NWConnection`（`.wifi` 固定）の制御、裏にいるときの待機と前面復帰時の受け取り、`removeConfiguration` の確実な片付け、しきい値設定と進捗表示を `PCSyncController` と画面につなぐ | ― | **中〜大** |

- **全体の作業規模**：Windows側 **大**、iOS側 **大**。ただし既存の暗号フレーム（`SyncFrameSender`）と途中保存（`partial/`・`PCSync-v2/`）をそのまま流用できるため、段階Aで実機の癖を先に確かめ、段階Bを単体テストで固めてからC・Dへ進めば手戻りを小さくできる。TestFlightは段階Aの検証時と、段階C・Dがそろったときの最小回数にまとめる。

---

## 8. 決まったこと（2026年11月18日）

利用者の決定（すべて設計書のおすすめどおり）：

1. **PCから送るとき、iPhone・iPadが裏にいる間の動き**：裏にいる間は送らずに待ち、clipboard+を画面に出したときに小さなWi-Fiで一気に受け取る（①を採用）。
2. **接続中の数秒間のインターネット（PC側の方式）**：送っている数秒〜10秒の間、iPadのインターネットが止まるのは許容し、`WiFiDirectAdvertisementPublisher` のレガシーモードを第一候補にする。
3. **しきい値と1件あたりの最大サイズ**：境目は既定で **500KB**（設定画面で変えられる）。1件あたりの上限は、小さなWi-Fiで送れるときは **50MB**、Bluetoothは今の **10MB** のままにする。

## 9. 段階Aの実機の結果（2026年11月22日、ビルド36）

PCの記録（`sync.log` の `wifi probe` の行）から。PCのアクセスポイントの起動は0.5〜0.6秒（端末の参加の確認の時間は含まない）。

| 方式 | 向き | 2MiB | 10MiB |
| --- | --- | --- | --- |
| Wi-Fi Direct（従来機器向け） | 端末→PC | 0.31秒（6.4MB/秒） | 3.3秒（3.0MB/秒） |
| Wi-Fi Direct（従来機器向け） | PC→端末 | 3.2秒（0.63MB/秒） | 58.8秒（0.17MB/秒） |
| モバイルホットスポット | 端末→PC | 3.9秒（0.52MB/秒） | 2.2秒（4.5MB/秒） |
| モバイルホットスポット | PC→端末 | 4.3秒（0.46MB/秒） | 36.4秒（0.27MB/秒） |

- 端末→PCは、BLE（約9〜40KB/秒、2MBで数分）より2桁速い。どちらの方式でもつながった。
- PC→端末は端末→PCより1桁遅い。電波の向きの差より、PCの送り方（小さい書き込みの繰り返し、`NoDelay`）か、iOSの受け取り（最大256KiBずつの `receive`）に原因がありそう（推測）。段階Bの前に、送りの単位を大きくして測り直す。
- 段階Bは、両方の方式を残し、つながった方を使う形で進める。

### 再試験（ビルド37、同じ日）

PCの送り方を直し（256KiBずつ、送りと返事待ちを分けて記録）、10MiBで測り直した。

| PCのWi-Fiの状態 | 方式 | 端末→PC | PC→端末 |
| --- | --- | --- | --- |
| 2.4GHz（6チャンネル）のネットワークにつながったまま | Wi-Fi Direct | 17.4秒（0.58MB/秒） | 91秒（0.11MB/秒、うち書き込み86秒） |
| 同上 | モバイルホットスポット | 14.9秒（0.67MB/秒） | 86秒（0.12MB/秒、うち書き込み81秒） |
| Wi-Fiはオンのまま、ネットワークから切断 | Wi-Fi Direct | 0.39秒（25.8MB/秒） | 0.31秒（32.2MB/秒） |

- 遅さの原因は、PCの無線の部品が1つで、家のWi-Fi（2.4GHz）とPCが作るWi-Fiが同じチャンネルの電波を取り合うことだった（確か）。アプリの作りの問題ではない。
- PCがどこのWi-Fiにもつながっていなければ、往復とも約30MB/秒で、AirDropに近い。
- モバイルホットスポットは、PCがインターネットにつながっていないと始められない（`stage=start` で失敗）。オフラインで使えるのは Wi-Fi Direct（従来機器向け）だけ。
