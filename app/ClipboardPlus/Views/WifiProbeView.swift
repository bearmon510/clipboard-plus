import SwiftUI

struct WifiProbeView: View {
    @StateObject private var probe = WifiTransferProbe()
    @State private var selectedSize: WifiProbeSize = .mb10
    @State private var showScanner = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("試験データの大きさ")
                    Picker("試験データの大きさ", selection: $selectedSize) {
                        ForEach(WifiProbeSize.allCases) { size in
                            Text(size.title).tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(probe.isRunning)
                }
                .padding(.vertical, 4)

                Button {
                    showScanner = true
                } label: {
                    Label("QRコードを読んで試験を始める", systemImage: "qrcode.viewfinder")
                }
                .frame(minHeight: 44)
                .disabled(probe.isRunning)

                if let lastQR = probe.lastQR, !probe.isRunning {
                    Button {
                        probe.start(qr: lastQR, size: selectedSize)
                    } label: {
                        Label("同じQRでもう一度試す（\(selectedSize.title)）", systemImage: "arrow.clockwise")
                    }
                    .frame(minHeight: 44)
                }

                if probe.isRunning {
                    Button("試験を中止する", role: .destructive) {
                        probe.cancel()
                    }
                    .frame(minHeight: 44)
                }
            } header: {
                Text("試験の設定")
            } footer: {
                Text("PCの「clipboard+ for Windows」の下にある「Wi-Fi 転送の試験」で出たQRコードを読みます。初回のみこの\(DeviceKind.current.name)でローカルネットワークの許可枠が出ます。")
            }

            Section("状態") {
                HStack(spacing: 10) {
                    if probe.isRunning {
                        ProgressView()
                    }
                    Text(probe.statusMessage)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let progress = probe.progressText {
                    Text(progress)
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if let error = probe.errorMessage {
                    Label {
                        Text(error).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section("各段階の時刻と速さ") {
                ForEach(probe.timeline.rows(restoreNote: probe.restoreNote)) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(row.label)
                            Spacer()
                            Text(row.timeText)
                                .font(.subheadline)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        if let detail = row.detailText {
                            Text(detail)
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("Wi-Fi 転送の試験")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showScanner) {
            PairingScannerView { code in
                do {
                    let qr = try WifiProbeQR.parse(code)
                    probe.start(qr: qr, size: selectedSize)
                    return nil
                } catch let error as WifiProbeQRError {
                    return error.message
                } catch {
                    return "QRコードを読めませんでした。"
                }
            }
        }
        .onDisappear {
            if !showScanner {
                probe.cancel()
            }
        }
    }
}
