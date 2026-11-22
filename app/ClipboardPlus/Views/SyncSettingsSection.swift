import SwiftUI
import UIKit

/// What the Windows sync section shows. Built from the controller, or by hand for snapshots.
struct SyncDisplay: Equatable {
    var pcName: String? = nil
    var status: PCSyncController.Status = .unpaired
    var requiresPeerUpdate = false
    var requiresRepair = false
    var lastSentAt: Date? = nil
    var lastReceivedAt: Date? = nil
    var pendingCount = 0
    var transfer: PCSyncController.TransferProgress? = nil
    var wifiTransfer: PCSyncController.WifiTransferProgress? = nil
}

extension SyncDisplay {
    @MainActor init(_ sync: PCSyncController) {
        self.init(pcName: sync.pcName, status: sync.status, requiresPeerUpdate: sync.requiresPeerUpdate,
                  requiresRepair: sync.requiresRepair, lastSentAt: sync.lastSentAt, lastReceivedAt: sync.lastReceivedAt,
                  pendingCount: sync.pendingCount, transfer: sync.transferProgress,
                  wifiTransfer: sync.wifiTransferProgress)
    }

    /// Both stops are reported as `.unsupported`, so they are checked before the status.
    func statusLabel(device: DeviceKind) -> (text: String, color: Color) {
        if requiresRepair { return ("組み直しが必要です", .orange) }
        if requiresPeerUpdate { return ("アプリの更新が必要です", .orange) }
        return switch status {
        case .connected: ("つながっています", .green)
        case .connecting: ("つないでいます", .secondary)
        case .searching: ("PCを探しています", .secondary)
        case .bluetoothOff: ("Bluetoothがオフです", .orange)
        case .unauthorized: ("Bluetoothが許可されていません", .orange)
        case .unsupported: ("この\(device.name)では使えません", .orange)
        case .unpaired: ("組んでいません", .secondary)
        }
    }

    static func byteProgress(_ done: Int, of total: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: Int64(done))) / \(formatter.string(fromByteCount: Int64(total)))"
    }
}

/// The controller calls the section makes. Snapshots pass ones that do nothing.
struct SyncSettingsActions {
    var pair: @MainActor (String) throws -> Void
    var unpair: @MainActor () -> Void
    var retryAfterPeerUpdate: @MainActor () -> Void
    var retryAfterRepair: @MainActor () -> Void
}

/// Pairing with the Windows PC and the state of the link.
struct SyncSettingsSection: View {
    @ObservedObject var sync: PCSyncController

    var body: some View {
        SyncSettingsContent(
            display: SyncDisplay(sync),
            copiesReceivedToPasteboard: $sync.copiesReceivedToPasteboard,
            usesWifiForLargeItems: $sync.usesWifiForLargeItems,
            wifiThreshold: $sync.wifiThreshold,
            actions: SyncSettingsActions(
                pair: { try sync.pair(code: $0) },
                unpair: { sync.unpair() },
                retryAfterPeerUpdate: { sync.retryAfterPeerUpdate() },
                retryAfterRepair: { sync.retryAfterRepair() }))
    }
}

struct SyncSettingsContent: View {
    let display: SyncDisplay
    @Binding var copiesReceivedToPasteboard: Bool
    @Binding var usesWifiForLargeItems: Bool
    @Binding var wifiThreshold: PCSyncWifiThreshold
    let actions: SyncSettingsActions
    /// Snapshots run on an iPad and ask for the iPhone wording with this.
    var deviceOverride: DeviceKind? = nil
    @Environment(\.openURL) private var openURL
    @State private var showScanner = false
    @State private var showRescanner = false
    @State private var confirmUnpair = false

    var body: some View {
        Section {
            if let name = display.pcName {
                paired(name)
            } else {
                Text("WindowsのPCに「clipboard+ for Windows」を入れて組にすると、\(device.name)とPCのコピーがBluetoothでつながります。Wi-Fiがなくても、近くにあれば使えます。")
                    .fixedSize(horizontal: false, vertical: true)
                Text("PCのclipboard+に出ているQRコードを読みます。1つのQRコードで、iPhoneとiPadの両方を組めます。")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("QRコードを読む", systemImage: "qrcode.viewfinder") { showScanner = true }
                    .frame(minHeight: 44)
                    .sheet(isPresented: $showScanner) { scanner }
            }
        } header: {
            Text("Windowsと同期")
        } footer: {
            Text("文章・リンク・画像・ファイルを両方向に受け渡します（Bluetoothは1件10MBまで、Wi-Fiは1件50MBまで）。\(device.name)から送れるのは、clipboard+が画面に出ている間に取り込んだものと、clipboard+でコピーしたものです。大きい項目のWi-Fi転送はclipboard+が画面に出ているときだけ行います。")
        }
    }

    private var device: DeviceKind { deviceOverride ?? .current }

    // A sheet or dialog put on the Section would be put on each of its rows,
    // and the extra presenters close the one on screen. Each sits on its button.
    @ViewBuilder private func paired(_ name: String) -> some View {
        LabeledContent("PC", value: name)
        LabeledContent("状態") {
            let label = display.statusLabel(device: device)
            Text(label.text).foregroundStyle(label.color)
        }
        if display.requiresRepair {
            notice("PCの組にする鍵が変わったため、つなげません。PCに出ているQRコードを読み直してください。")
            Button("QRコードを読み直す", systemImage: "qrcode.viewfinder") { showRescanner = true }
                .frame(minHeight: 44)
                .sheet(isPresented: $showRescanner) { scanner }
            Button("このままもう一度試す", systemImage: "arrow.clockwise") { actions.retryAfterRepair() }
                .frame(minHeight: 44)
        } else if display.requiresPeerUpdate {
            notice("PCとこの\(device.name)で、clipboard+の版が合いません。両方のclipboard+を最新にしてから、もう一度つないでください。")
            Button("もう一度つなぐ", systemImage: "arrow.clockwise") { actions.retryAfterPeerUpdate() }
                .frame(minHeight: 44)
        }
        if display.status == .unauthorized {
            Button("Bluetoothを許可する", systemImage: "gear") { openSettings() }
                .frame(minHeight: 44)
        }
        if let wifi = display.wifiTransfer {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "wifi")
                        .foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                    Text(wifi.summaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if wifi.totalBytes > 0 {
                        Text(SyncDisplay.byteProgress(wifi.bytes, of: wifi.totalBytes))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                if wifi.phase == .sending || wifi.phase == .receiving {
                    ProgressView(
                        value: Double(min(wifi.bytes, wifi.totalBytes)),
                        total: Double(max(wifi.totalBytes, 1))
                    )
                } else {
                    ProgressView()
                }
            }
            .padding(.vertical, 4)
        }
        if let transfer = display.transfer {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(transfer.direction == "send" ? "PCへ送っています" : "PCから受け取っています")
                    Spacer()
                    Text(SyncDisplay.byteProgress(transfer.bytes, of: transfer.totalBytes))
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                ProgressView(value: Double(min(transfer.bytes, transfer.totalBytes)), total: Double(max(transfer.totalBytes, 1)))
            }
            .padding(.vertical, 4)
        }
        if display.pendingCount > 0 {
            LabeledContent("PCへの送信待ち", value: "\(display.pendingCount)件")
        }
        if let date = display.lastSentAt {
            LabeledContent("最後に送った", value: Self.time(date))
        }
        if let date = display.lastReceivedAt {
            LabeledContent("最後に受け取った", value: Self.time(date))
        }
        Toggle("PCのコピーを\(device.name)のクリップボードにも入れる", isOn: $copiesReceivedToPasteboard)
            .frame(minHeight: 44)
        Toggle("大きいものは Wi-Fi で送る", isOn: $usesWifiForLargeItems)
            .frame(minHeight: 44)
        if usesWifiForLargeItems {
            Picker("Wi-Fi を使う大きさ", selection: $wifiThreshold) {
                ForEach(PCSyncWifiThreshold.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.menu)
            .frame(minHeight: 44)
        }
        Button("組を解く", role: .destructive) { confirmUnpair = true }
            .frame(minHeight: 44)
            .confirmationDialog("PCとの組を解きますか？", isPresented: $confirmUnpair, titleVisibility: .visible) {
                Button("組を解く", role: .destructive) { actions.unpair() }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("もう一度使うときは、PCに出るQRコードを読み直します。")
            }
    }

    private var scanner: some View {
        PairingScannerView { code in
            do {
                try actions.pair(code)
                return nil
            } catch let error as PCSyncPairError {
                return error.message
            } catch {
                return "組にできませんでした。PCに出ているQRコードを読んでください。"
            }
        }
    }

    private func notice(_ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private static func time(_ date: Date) -> String {
        date.formatted(date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated, time: .shortened)
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }
}
