import SwiftUI
import UIKit

/// Pairing with the Windows PC and the state of the link. A trial for now: text and links only.
struct SyncSettingsSection: View {
    @ObservedObject var sync: PCSyncController
    @Environment(\.openURL) private var openURL
    @State private var showScanner = false
    @State private var confirmUnpair = false

    var body: some View {
        Section {
            if let name = sync.pcName {
                LabeledContent("PC", value: name)
                LabeledContent("状態") { status }
                if sync.status == .unauthorized {
                    Button("Bluetoothを許可する", systemImage: "gear") { openSettings() }
                        .frame(minHeight: 44)
                }
                if let date = sync.lastSentAt {
                    LabeledContent("最後に送った", value: Self.time(date))
                }
                if let date = sync.lastReceivedAt {
                    LabeledContent("最後に受け取った", value: Self.time(date))
                }
                Toggle("PCのコピーを\(device.name)のクリップボードにも入れる", isOn: $sync.copiesReceivedToPasteboard)
                    .frame(minHeight: 44)
                // A sheet or dialog put on the Section would be put on each of its rows,
                // and the extra presenters close the one on screen. Each sits on its button.
                Button("組を解く", role: .destructive) { confirmUnpair = true }
                    .frame(minHeight: 44)
                    .confirmationDialog("PCとの組を解きますか？", isPresented: $confirmUnpair, titleVisibility: .visible) {
                        Button("組を解く", role: .destructive) { sync.unpair() }
                        Button("キャンセル", role: .cancel) {}
                    } message: {
                        Text("もう一度使うときは、PCに出るQRコードを読み直します。")
                    }
            } else {
                Text("WindowsのPCに「clipboard+ for Windows」を入れて組にすると、\(device.name)とPCのコピーがBluetoothでつながります。Wi-Fiがなくても、近くにあれば使えます。")
                    .fixedSize(horizontal: false, vertical: true)
                Button("QRコードを読む", systemImage: "qrcode.viewfinder") { showScanner = true }
                    .frame(minHeight: 44)
                    .sheet(isPresented: $showScanner) {
                        PairingScannerView { code in
                            do {
                                try sync.pair(code: code)
                                return nil
                            } catch let error as PCSyncPairError {
                                return error.message
                            } catch {
                                return "組にできませんでした。PCに出ているQRコードを読んでください。"
                            }
                        }
                    }
            }
        } header: {
            Text("Windowsと同期（試作）")
        } footer: {
            Text("文章とリンクを両方向に受け渡します。\(device.name)から送れるのは、clipboard+が画面に出ている間に取り込んだものと、clipboard+でコピーしたものです。PCでのコピーは、clipboard+が裏にいても受け取ります。")
        }
    }

    private var device: DeviceKind { .current }

    private var status: some View {
        let (text, color): (String, Color) = switch sync.status {
        case .connected: ("つながっています", .green)
        case .connecting: ("つないでいます", .secondary)
        case .searching: ("PCを探しています", .secondary)
        case .bluetoothOff: ("Bluetoothがオフです", .orange)
        case .unauthorized: ("Bluetoothが許可されていません", .orange)
        case .unsupported: ("この\(device.name)では使えません", .orange)
        case .unpaired: ("組んでいません", .secondary)
        }
        return Text(text).foregroundStyle(color)
    }

    private static func time(_ date: Date) -> String {
        date.formatted(date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated, time: .shortened)
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }
}
