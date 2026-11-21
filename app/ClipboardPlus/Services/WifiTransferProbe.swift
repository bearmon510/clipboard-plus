import Combine
import Foundation
import Network
import Security
import UIKit
#if canImport(NetworkExtension)
import NetworkExtension
#endif

private enum WifiTransferProbeError: Error {
    case simulatorUnsupported
    case hotspot(String)
    case connectTimeout
    case localNetworkDenied
    case invalidEndpoint
    case network(NWError)
    case unexpectedClose
    case rejected(UInt8)

    func userMessage(deviceName: String) -> String {
        switch self {
        case .simulatorUnsupported:
            return "シミュレータでは一時Wi-Fiへの参加を試せません。\(deviceName)の実機でお試しください。"
        case .hotspot(let message):
            return message
        case .connectTimeout:
            return "PCへのTCP接続が時間切れになりました。Windowsファイアウォールの許可枠が出ていないか、PC側の試験が止まっていないか確認してください。"
        case .localNetworkDenied:
            return "この\(deviceName)で「ローカルネットワーク」が許可されていません。設定アプリの「clipboard+」でローカルネットワークをオンにしてから、もう一度試してください。"
        case .invalidEndpoint:
            return "QRコードのIPアドレスまたはポート番号が正しくありません。"
        case .network(let error):
            return "TCP通信に失敗しました（\(error.localizedDescription)）。"
        case .unexpectedClose:
            return "試験データの送受信中にPCとの接続が切れました。"
        case .rejected(let status):
            return WifiProbeWire.rejectionMessage(status: status)
        }
    }
}

enum WifiProbeReceivePolicy {
    static let minimumChunkBytes: Int64 = 65_536
    static let maximumChunkBytes: Int64 = 524_288
    static let progressByteInterval: Int64 = 524_288
    static let progressTimeIntervalNs: UInt64 = 150_000_000

    static func receiveLengths(remaining: Int64) -> (minimum: Int, maximum: Int) {
        let clamped = max(remaining, 1)
        return (
            minimum: Int(min(clamped, minimumChunkBytes)),
            maximum: Int(min(clamped, maximumChunkBytes))
        )
    }

    static func shouldReportProgress(
        received: Int64,
        totalBytes: Int64,
        lastReportedBytes: Int64,
        lastReportTimeNs: UInt64,
        nowNs: UInt64
    ) -> Bool {
        if received >= totalBytes {
            return true
        }
        guard received - lastReportedBytes >= progressByteInterval else {
            return false
        }
        guard nowNs >= lastReportTimeNs else {
            return false
        }
        return (nowNs - lastReportTimeNs) >= progressTimeIntervalNs
    }
}

private final class WifiProbeSocket: @unchecked Sendable {
    private final class DrainState: @unchecked Sendable {
        let totalBytes: Int64
        let onProgress: @MainActor (Int64) -> Void
        var continuation: CheckedContinuation<Int, Error>?
        var received: Int64 = 0
        var lastReportedBytes: Int64 = 0
        var lastReportTimeNs: UInt64
        var receiveCount: Int = 0

        init(
            totalBytes: Int64,
            startTimeNs: UInt64,
            onProgress: @escaping @MainActor (Int64) -> Void,
            continuation: CheckedContinuation<Int, Error>
        ) {
            self.totalBytes = totalBytes
            self.lastReportTimeNs = startTimeNs
            self.onProgress = onProgress
            self.continuation = continuation
        }
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "clipboardplus.wifi-probe.socket", qos: .userInitiated)
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var activeDrain: DrainState?
    private var timeoutItem: DispatchWorkItem?
    private var sawLocalNetworkDenied = false
    private var cancelled = false

    init(host: String, port: UInt16) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw WifiTransferProbeError.invalidEndpoint
        }
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.requiredInterfaceType = .wifi
        self.connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
    }

    func connect(timeoutSeconds: Double, onWaiting: @escaping @MainActor (Bool) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                if cancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                connectContinuation = continuation
                let item = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    let denied = self.sawLocalNetworkDenied
                    self.connection.cancel()
                    self.finishConnect(.failure(denied ? WifiTransferProbeError.localNetworkDenied : WifiTransferProbeError.connectTimeout))
                }
                timeoutItem = item
                queue.asyncAfter(deadline: .now() + timeoutSeconds, execute: item)

                connection.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.finishConnect(.success(()))
                    case .waiting:
                        let denied = self.connection.currentPath?.unsatisfiedReason == .localNetworkDenied
                        if denied { self.sawLocalNetworkDenied = true }
                        Task { @MainActor in onWaiting(denied) }
                    case .failed(let error):
                        self.finishConnect(.failure(WifiTransferProbeError.network(error)))
                    case .cancelled:
                        self.finishConnect(.failure(CancellationError()))
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        }
    }

    func send(_ data: Data, isFinal: Bool = false) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                if cancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let context: NWConnection.ContentContext = isFinal ? .finalMessage : .defaultMessage
                connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: WifiTransferProbeError.network(error))
                    } else {
                        continuation.resume()
                    }
                })
            }
        }
    }

    func receiveExact(_ count: Int) async throws -> Data {
        var buffer = Data()
        buffer.reserveCapacity(count)
        while buffer.count < count {
            let remaining = count - buffer.count
            let (content, isComplete) = try await receiveChunk(maximumLength: remaining)
            if let content, !content.isEmpty {
                buffer.append(content)
            } else if isComplete {
                throw WifiTransferProbeError.unexpectedClose
            }
        }
        return buffer
    }

    func drainExact(_ totalBytes: Int64, onProgress: @escaping @MainActor (Int64) -> Void) async throws -> Int {
        if totalBytes <= 0 {
            let snapshot: Int64 = 0
            Task { @MainActor in onProgress(snapshot) }
            return 0
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            queue.async { [self] in
                if cancelled || activeDrain != nil {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let drain = DrainState(
                    totalBytes: totalBytes,
                    startTimeNs: DispatchTime.now().uptimeNanoseconds,
                    onProgress: onProgress,
                    continuation: continuation
                )
                activeDrain = drain
                scheduleNextDrainReceive(drain)
            }
        }
    }

    func cancel() {
        queue.async { [self] in
            cancelled = true
            connection.cancel()
            finishConnect(.failure(CancellationError()))
            if let drain = activeDrain {
                finishDrain(drain, result: .failure(CancellationError()))
            }
        }
    }

    private func scheduleNextDrainReceive(_ drain: DrainState) {
        guard drain.continuation != nil else { return }
        if cancelled {
            finishDrain(drain, result: .failure(CancellationError()))
            return
        }
        let remaining = drain.totalBytes - drain.received
        guard remaining > 0 else {
            finishDrain(drain, result: .success(drain.receiveCount))
            return
        }
        let lengths = WifiProbeReceivePolicy.receiveLengths(remaining: remaining)
        connection.receive(minimumIncompleteLength: lengths.minimum, maximumLength: lengths.maximum) { [self] content, _, isComplete, error in
            handleDrainReceive(drain, content: content, isComplete: isComplete, error: error)
        }
    }

    private func handleDrainReceive(_ drain: DrainState, content: Data?, isComplete: Bool, error: NWError?) {
        guard drain.continuation != nil else { return }
        if cancelled {
            finishDrain(drain, result: .failure(CancellationError()))
            return
        }

        drain.receiveCount += 1

        if let content, !content.isEmpty {
            drain.received += Int64(content.count)
            let nowNs = DispatchTime.now().uptimeNanoseconds
            if WifiProbeReceivePolicy.shouldReportProgress(
                received: drain.received,
                totalBytes: drain.totalBytes,
                lastReportedBytes: drain.lastReportedBytes,
                lastReportTimeNs: drain.lastReportTimeNs,
                nowNs: nowNs
            ) {
                drain.lastReportedBytes = drain.received
                drain.lastReportTimeNs = nowNs
                let snapshot = drain.received
                let onProgress = drain.onProgress
                Task { @MainActor in onProgress(snapshot) }
            }
            if drain.received >= drain.totalBytes {
                finishDrain(drain, result: .success(drain.receiveCount))
                return
            }
        }

        if let error {
            finishDrain(drain, result: .failure(WifiTransferProbeError.network(error)))
            return
        }

        if isComplete {
            finishDrain(drain, result: .failure(WifiTransferProbeError.unexpectedClose))
            return
        }

        scheduleNextDrainReceive(drain)
    }

    private func finishDrain(_ drain: DrainState, result: Result<Int, Error>) {
        guard let continuation = drain.continuation else { return }
        drain.continuation = nil
        if activeDrain === drain {
            activeDrain = nil
        }
        continuation.resume(with: result)
    }

    private func receiveChunk(maximumLength: Int) async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data?, Bool), Error>) in
            queue.async { [self] in
                if cancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { content, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: WifiTransferProbeError.network(error))
                    } else {
                        continuation.resume(returning: (content, isComplete))
                    }
                }
            }
        }
    }

    private func finishConnect(_ result: Result<Void, Error>) {
        guard let continuation = connectContinuation else { return }
        connectContinuation = nil
        timeoutItem?.cancel()
        timeoutItem = nil
        continuation.resume(with: result)
    }
}

private enum WifiPathWatcher {
    private final class WatcherState: @unchecked Sendable {
        var resumed = false
        var sawTransition = false
    }

    static func isWifiSatisfied(timeoutSeconds: Double = 0.35) async -> Bool {
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        let queue = DispatchQueue(label: "clipboardplus.wifi-probe.check", qos: .userInitiated)
        let state = WatcherState()
        return await withCheckedContinuation { continuation in
            let timeoutItem = DispatchWorkItem {
                guard !state.resumed else { return }
                state.resumed = true
                monitor.cancel()
                continuation.resume(returning: false)
            }
            queue.asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutItem)
            monitor.pathUpdateHandler = { path in
                guard !state.resumed else { return }
                state.resumed = true
                timeoutItem.cancel()
                monitor.cancel()
                continuation.resume(returning: path.status == .satisfied)
            }
            monitor.start(queue: queue)
        }
    }

    static func leaveAndWaitForRestore(
        hadWifiBeforeJoin: Bool,
        timeoutSeconds: Double = 15.0,
        removeAction: @escaping @MainActor () -> Void
    ) async -> Bool {
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        let queue = DispatchQueue(label: "clipboardplus.wifi-probe.restore", qos: .userInitiated)
        let state = WatcherState()
        return await withCheckedContinuation { continuation in
            let timeoutItem = DispatchWorkItem {
                guard !state.resumed else { return }
                state.resumed = true
                monitor.cancel()
                continuation.resume(returning: !hadWifiBeforeJoin && state.sawTransition)
            }
            queue.asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutItem)
            monitor.pathUpdateHandler = { path in
                guard !state.resumed else { return }
                if path.status != .satisfied {
                    state.sawTransition = true
                    if !hadWifiBeforeJoin {
                        // Device was not on Wi-Fi originally; leaving temporary Wi-Fi completes restore.
                        state.resumed = true
                        timeoutItem.cancel()
                        monitor.cancel()
                        continuation.resume(returning: true)
                    }
                    return
                }
                if hadWifiBeforeJoin && state.sawTransition && path.status == .satisfied {
                    state.resumed = true
                    timeoutItem.cancel()
                    monitor.cancel()
                    continuation.resume(returning: true)
                }
            }
            monitor.start(queue: queue)
            Task { @MainActor in
                removeAction()
            }
        }
    }
}

@MainActor
final class WifiTransferProbe: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var statusMessage = "PCの「Wi-Fi 転送の試験」で出たQRコードを読んでください。"
    @Published private(set) var errorMessage: String?
    @Published private(set) var progressText: String?
    @Published private(set) var timeline = WifiProbeTimeline()
    @Published private(set) var lastQR: WifiProbeQR?
    @Published private(set) var restoreNote: String?

    private var runTask: Task<Void, Never>?
    private var activeRunID: UUID?
    private var activeSocket: WifiProbeSocket?
    private var joinedSSID: String?

    func start(qr: WifiProbeQR, size: WifiProbeSize) {
        cancel()
        let runID = UUID()
        activeRunID = runID
        lastQR = qr
        errorMessage = nil
        progressText = nil
        restoreNote = nil
        timeline = WifiProbeTimeline(payloadBytes: size.byteCount)
        isRunning = true
        statusMessage = "現在のWi-Fi状態を確認しています…"

        runTask = Task { [weak self] in
            await self?.execute(runID: runID, qr: qr, size: size)
        }
    }

    func cancel() {
        activeRunID = nil
        runTask?.cancel()
        runTask = nil
        activeSocket?.cancel()
        activeSocket = nil
        if let ssid = joinedSSID {
            removeHotspot(ssid: ssid)
            joinedSSID = nil
        }
        if isRunning {
            isRunning = false
            progressText = nil
            statusMessage = "試験を中止しました。"
        }
    }

    private func execute(runID: UUID, qr: WifiProbeQR, size: WifiProbeSize) async {
        let deviceName = DeviceKind.current.name
        let hadWifiBefore = await WifiPathWatcher.isWifiSatisfied()
        guard activeRunID == runID, !Task.isCancelled else { return }

        var socket: WifiProbeSocket?
        do {
            timeline.joinPromptedAt = Date()
            statusMessage = "一時Wi-Fiへの参加確認を出しています…"
            try await applyHotspot(ssid: qr.ssid, passphrase: qr.passphrase, deviceName: deviceName)
            if activeRunID != runID || Task.isCancelled {
                removeHotspot(ssid: qr.ssid)
                return
            }
            joinedSSID = qr.ssid
            timeline.joinedAt = Date()

            statusMessage = "PCへTCP接続しています（初回はローカルネットワーク許可が出ます）…"
            let createdSocket = try WifiProbeSocket(host: qr.ip, port: qr.port)
            socket = createdSocket
            activeSocket = createdSocket

            try await createdSocket.connect(timeoutSeconds: 25) { [weak self] localNetworkDenied in
                guard let self, self.activeRunID == runID, self.isRunning else { return }
                self.statusMessage = localNetworkDenied
                    ? "ローカルネットワーク許可を待っています。許可枠が出たら「許可」を押してください。"
                    : "Wi-FiのIP割り当てとPCへの接続を待っています…"
            }
            guard activeRunID == runID else { throw CancellationError() }
            timeline.connectedAt = Date()
            try Task.checkCancellation()

            statusMessage = "合言葉を確認しています…"
            let header = try WifiProbeWire.encodeHeader(token: qr.token, payloadBytes: size.byteCount)
            try await createdSocket.send(header)
            let authAck = try await createdSocket.receiveExact(1)
            if authAck[0] != WifiProbeWire.ackOK {
                throw WifiTransferProbeError.rejected(authAck[0])
            }
            guard activeRunID == runID else { throw CancellationError() }
            try Task.checkCancellation()

            timeline.uploadStartedAt = Date()
            statusMessage = "\(size.title) の試験データをPCへ送っています…"
            try await sendRandomPayload(totalBytes: size.byteCount, socket: createdSocket) { [weak self] sent in
                guard let self, self.activeRunID == runID else { return }
                self.progressText = "送信: \(WifiProbeMetrics.formatBytes(sent)) / \(size.title)"
            }
            let uploadAck = try await createdSocket.receiveExact(1)
            if uploadAck[0] != WifiProbeWire.ackOK {
                throw WifiTransferProbeError.rejected(uploadAck[0])
            }
            guard activeRunID == runID else { throw CancellationError() }
            timeline.sentAt = Date()
            try Task.checkCancellation()

            statusMessage = "\(size.title) の返送データをPCから受け取っています…"
            progressText = "受信: 0 B / \(size.title)"
            let receiveCount = try await createdSocket.drainExact(size.byteCount) { [weak self] received in
                guard let self, self.activeRunID == runID, self.timeline.receivedAt == nil else { return }
                self.progressText = "受信: \(WifiProbeMetrics.formatBytes(received)) / \(size.title)"
            }
            guard activeRunID == runID else { throw CancellationError() }
            timeline.receivedAt = Date()
            timeline.receiveCallCount = receiveCount

            // Wait for .contentProcessed of the final ack before closing the connection.
            try? await createdSocket.send(Data([WifiProbeWire.ackOK]), isFinal: true)
            createdSocket.cancel()
            activeSocket = nil
            socket = nil

            progressText = nil
            timeline.restoreStartedAt = Date()
            statusMessage = "一時Wi-Fiから離れて元のWi-Fiへ戻っています…"
            let restored = await WifiPathWatcher.leaveAndWaitForRestore(hadWifiBeforeJoin: hadWifiBefore) { [weak self] in
                self?.removeHotspot(ssid: qr.ssid)
                if self?.activeRunID == runID {
                    self?.joinedSSID = nil
                }
            }
            guard activeRunID == runID, !Task.isCancelled else { return }
            if restored {
                timeline.restoredAt = Date()
                restoreNote = hadWifiBefore ? nil : "一時Wi-Fiを切断しました（試験前はWi-Fi未接続）"
            } else {
                restoreNote = "15秒以内に元のWi-Fiへの復帰を確認できませんでした"
            }

            isRunning = false
            statusMessage = "試験が終わりました。"
        } catch is CancellationError {
            socket?.cancel()
            guard activeRunID == runID else { return }
            activeSocket = nil
            if let ssid = joinedSSID {
                removeHotspot(ssid: ssid)
                joinedSSID = nil
            }
            isRunning = false
            progressText = nil
        } catch {
            socket?.cancel()
            guard activeRunID == runID else { return }
            activeSocket = nil
            if let ssid = joinedSSID {
                timeline.restoreStartedAt = timeline.restoreStartedAt ?? Date()
                let ssidToRemove = ssid
                _ = await WifiPathWatcher.leaveAndWaitForRestore(hadWifiBeforeJoin: hadWifiBefore, timeoutSeconds: 8) { [weak self] in
                    self?.removeHotspot(ssid: ssidToRemove)
                    if self?.activeRunID == runID {
                        self?.joinedSSID = nil
                    }
                }
            }
            guard activeRunID == runID, !Task.isCancelled else { return }
            isRunning = false
            progressText = nil
            statusMessage = "試験に失敗しました。"
            if let probeError = error as? WifiTransferProbeError {
                errorMessage = probeError.userMessage(deviceName: deviceName)
            } else {
                errorMessage = "試験に失敗しました（\(error.localizedDescription)）。"
            }
        }
    }

    private func sendRandomPayload(
        totalBytes: Int64,
        socket: WifiProbeSocket,
        onProgress: @escaping @MainActor (Int64) -> Void
    ) async throws {
        let chunkSize = 262_144
        var sent: Int64 = 0
        var lastReported: Int64 = 0
        while sent < totalBytes {
            try Task.checkCancellation()
            let count = Int(min(totalBytes - sent, Int64(chunkSize)))
            let chunk = Self.makeRandomChunk(size: count)
            try await socket.send(chunk)
            sent += Int64(count)
            if sent - lastReported >= 524_288 || sent == totalBytes {
                lastReported = sent
                onProgress(sent)
            }
        }
    }

    private static func makeRandomChunk(size: Int) -> Data {
        var data = Data(count: size)
        let status = data.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, size, baseAddress)
        }
        if status != errSecSuccess {
            var rng = SystemRandomNumberGenerator()
            for index in data.indices {
                data[index] = UInt8.random(in: 0...255, using: &rng)
            }
        }
        return data
    }

    private func applyHotspot(ssid: String, passphrase: String, deviceName: String) async throws {
        #if targetEnvironment(simulator)
        throw WifiTransferProbeError.simulatorUnsupported
        #else
        let config = NEHotspotConfiguration(ssid: ssid, passphrase: passphrase, isWEP: false)
        config.joinOnce = true
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                NEHotspotConfigurationManager.shared.apply(config) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } catch {
            let nsError = error as NSError
            if nsError.domain == NEHotspotConfigurationErrorDomain,
               let code = NEHotspotConfigurationError(rawValue: nsError.code) {
                if code == .alreadyAssociated {
                    return
                }
                throw WifiTransferProbeError.hotspot(Self.describeHotspotError(code, deviceName: deviceName))
            }
            throw WifiTransferProbeError.hotspot("一時Wi-Fiへ参加できませんでした（\(error.localizedDescription)）。")
        }
        #endif
    }

    private func removeHotspot(ssid: String) {
        #if !targetEnvironment(simulator)
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
        #endif
    }

    #if !targetEnvironment(simulator)
    private static func describeHotspotError(_ code: NEHotspotConfigurationError, deviceName: String) -> String {
        switch code {
        case .userDenied:
            return "Wi-Fiへの接続確認で「キャンセル」が選ばれました。"
        case .applicationIsNotInForeground:
            return "clipboard+ が前面に出ていないため、Wi-Fi接続の確認を出せませんでした。"
        case .invalidSSID, .invalidSSIDPrefix:
            return "QRコードのWi-Fi名（SSID）が無効です。"
        case .invalidWPAPassphrase:
            return "QRコードのパスフレーズが無効です。"
        case .internal:
            return "iOSのWi-Fi機能でエラーが起きました（\(deviceName)のWi-Fiがオンか、Hotspot権限が有効か確認してください）。"
        case .pending:
            return "別のWi-Fi接続確認が進行中です。少し待ってからもう一度試してください。"
        case .systemConfiguration:
            return "システム構成のエラーでWi-Fiへ接続できませんでした。"
        default:
            return "一時Wi-Fiへ接続できませんでした（エラー番号: \(code.rawValue)）。"
        }
    }
    #endif
}
