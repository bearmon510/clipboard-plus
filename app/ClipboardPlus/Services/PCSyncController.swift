import Combine
import Foundation
import UIKit

struct PCSyncPairError: Error, Equatable { let message: String }

@MainActor
final class PCSyncController: ObservableObject {
    static let shared: PCSyncController = PCSyncController(monitor: .shared)
    enum Status: Equatable { case unpaired, unsupported, unauthorized, bluetoothOff, searching, connecting, connected }
    @Published private(set) var status: Status = .unpaired
    @Published private(set) var pcName: String?
    @Published private(set) var lastSentAt: Date?
    @Published private(set) var lastReceivedAt: Date?
    @Published var copiesReceivedToPasteboard: Bool {
        didSet { settings.copiesReceivedToPasteboard = copiesReceivedToPasteboard }
    }

    private let settings: PCSyncSettings
    private let keyStore: PCSyncKeyStore
    private let monitor: ClipboardMonitor
    private let makeTransport: (@escaping (String) -> Void) -> PCSyncTransport
    private let now: () -> Date
    private var pairing: SyncPairing?
    private var transport: PCSyncTransport?
    private var handshake: SyncPadHandshake?
    private var sender: SyncFrameSender?
    private var receiver: SyncFrameReceiver?
    private var assembler: SyncPacketAssembler?
    private var peerId: UUID?
    private var writeLimit = 20
    private var pairingGeneration = UUID()
    private var sessionGeneration = UUID()
    private var handshakeStart: Date?
    private var partialStart: Date?
    private var receiveStart: Date?
    private var receiveBytes = 0
    private var writeBlockedSince: Date?
    private var lastActivity: Date?
    private var pingRequestedAt: Date?
    private var pingQueued = false
    private var timer: Timer?
    private var unlockObserver: NSObjectProtocol?
    private var pumping = false
    private var seen: [UUID] = []
    private var receiving: Set<UUID> = []
    private var ackQueue: [UUID] = []
    private var pending: [Pending] = []
    private var sentThisConnection: Set<UUID> = []
    private var sentAt: [UUID: Date] = [:]
    private var controlFrames: [Data] = []
    private var output: Output?
    private struct Pending { let id: UUID; let plaintext: Data; var attempts = 0 }
    private struct Output {
        let packets: [Data]
        var index = 0
        let started: Date
        var progressed: Date
        let id: UUID?
        let isAuth: Bool
        let bytes: Int
    }

    // Dependency injection is internal; the screen-facing API above stays as requested.
    init(monitor: ClipboardMonitor, defaults: UserDefaults = .standard,
         keyStore: PCSyncKeyStore? = nil, now: @escaping () -> Date = Date.init,
         schedulesTimeouts: Bool = true,
         makeTransport: ((@escaping (String) -> Void) -> PCSyncTransport)? = nil) {
        self.monitor = monitor
        self.settings = PCSyncSettings(defaults: defaults)
        self.keyStore = keyStore ?? PCSyncKeychain()
        self.now = now
        self.makeTransport = makeTransport ?? { PCSyncBluetooth(log: $0) }
        copiesReceivedToPasteboard = settings.copiesReceivedToPasteboard
        monitor.onLocalTextForPC = { [weak self] text in self?.enqueue(text) }
        restorePairing()
        unlockObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.restorePairing() }
        }
        if schedulesTimeouts {
            timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkTimeouts() }
            }
        }
    }

    func pair(code: String) throws {
        let value: SyncPairing
        do { value = try SyncPairing.parse(code) }
        catch { throw PCSyncPairError(message: "組にするコードを読み取れませんでした。PCに表示されたQRコードを読み直してください。") }
        do { try keyStore.write(value.key) }
        catch { throw PCSyncPairError(message: "組にする鍵を保存できませんでした。iPadのロックを解除して、もう一度お試しください。") }
        stopPairing()
        settings.save(value)
        pairing = value; pcName = value.name
        record("組にする情報を保存")
        startTransport()
    }

    func unpair() {
        stopPairing()
        settings.deletionPending = true
        settings.clearPairing()
        deleteKeyIfPending()
        record("組を解除")
    }
    private func deleteKeyIfPending() {
        guard settings.deletionPending else { return }
        do { try keyStore.delete(); settings.deletionPending = false }
        catch { record("鍵の削除待ち; ロック解除後に再試行") }
    }
    private func restorePairing() {
        deleteKeyIfPending()
        guard pairing == nil, !settings.deletionPending else { return }
        pcName = settings.pcName
        // A fresh install (including the snapshot test host) has no pairing to restore.
        // Avoid synchronous Keychain IPC and Bluetooth initialization in that case.
        guard pcName != nil else { status = .unpaired; return }
        if pcName != nil { status = .searching }
        do {
            guard let key = try keyStore.read(), let value = try settings.load(key: key) else {
                settings.clearPairing(); pcName = nil; status = .unpaired
                return
            }
            pairing = value; pcName = value.name
            startTransport()
        } catch { record("組にする情報の読み込み待ち; ロック解除後に再試行") }
    }
    private func startTransport() {
        guard pairing != nil, transport == nil else { return }
        status = .searching
        let link = makeTransport { [weak self] details in self?.record(details) }
        transport = link
        link.onEvent = { [weak self] event in self?.handle(event) }
        link.start(remembered: settings.peripheralId)
    }
    private func stopPairing() {
        transport?.onEvent = nil; transport?.stop(); transport = nil
        resetSession()
        pairingGeneration = UUID()
        pairing = nil; pcName = nil; status = .unpaired
        pending.removeAll(); seen.removeAll(); receiving.removeAll()
        lastSentAt = nil; lastReceivedAt = nil
    }
    private func resetSession() {
        if let assembler {
            do { try assembler.finish() } catch { record("受信組み立てを破棄") }
        }
        assembler = nil; handshake = nil; sender = nil; receiver = nil; peerId = nil
        sessionGeneration = UUID()
        handshakeStart = nil; partialStart = nil; receiveStart = nil; receiveBytes = 0
        writeBlockedSince = nil
        lastActivity = nil; pingRequestedAt = nil; pingQueued = false
        output = nil; controlFrames.removeAll(); ackQueue.removeAll()
        sentThisConnection.removeAll(); sentAt.removeAll()
    }

    private func handle(_ event: PCSyncTransportEvent) {
        guard pairing != nil else { return }
        switch event {
        case .status(let value):
            if status != .connected { status = value }
        case let .ready(id, limit, receiveLimit):
            resetSession()
            do {
                guard let pairing else { return }
                writeLimit = min(512, limit); peerId = id
                assembler = try SyncPacketAssembler(packetLimit: receiveLimit)
                handshake = try SyncPadHandshake(pairing: pairing, padId: settings.padId)
                handshakeStart = now(); status = .connecting
                controlFrames.append(try handshake!.createHello())
                record("接続確認開始; GATT値上限=\(limit)")
                pump()
            } catch { fail(reject: true, reason: "接続確認の開始失敗") }
        case .packet(let packet): receive(packet)
        case .writable: pump()
        case .disconnected:
            resetSession(); status = .searching
        }
    }

    private func enqueue(_ text: String) {
        guard pairing != nil else { return }
        let id = UUID()
        do {
            let message = SyncMessage.item(id: id, at: Int64(now().timeIntervalSince1970 * 1000), from: "pad", text: text)
            let plaintext = try SyncMessageCodec.encode(message)
            pending.append(Pending(id: id, plaintext: plaintext))
            if pending.count > 50 {
                let removed = pending.removeFirst()
                sentAt.removeValue(forKey: removed.id)
                sentThisConnection.remove(removed.id)
                record("送信待ち上限; 最古の1件を破棄")
            }
            pump()
        } catch { record("送信見送り; 理由=通信サイズ上限") }
    }

    /// Only one frame is materialized at a time; AUTH always precedes encrypted data.
    private func pump() {
        guard !pumping, let transport else { return }
        pumping = true
        defer { pumping = false }
        do {
            while transport.canSend {
                writeBlockedSince = nil
                if output == nil {
                    let frame: Data
                    var id: UUID?
                    var isAuth = false
                    if !controlFrames.isEmpty {
                        frame = controlFrames.removeFirst(); isAuth = frame.first == 3
                    } else if status == .connected, let sender {
                        if !ackQueue.isEmpty {
                            let ids = Array(ackQueue.prefix(SyncProtocol.maxAckIds))
                            ackQueue.removeFirst(ids.count)
                            frame = try sender.seal(SyncMessageCodec.encode(.ack(ids: ids)))
                        } else if pingQueued {
                            pingQueued = false
                            frame = try sender.seal(SyncMessageCodec.encode(.ping))
                        } else if let index = pending.firstIndex(where: { !sentThisConnection.contains($0.id) }) {
                            id = pending[index].id
                            let retry = pending[index].attempts > 0
                            pending[index].attempts += 1
                            sentThisConnection.insert(pending[index].id)
                            frame = try sender.seal(pending[index].plaintext)
                            if retry { record("再送; 件数=1; バイト数=\(pending[index].plaintext.count)") }
                        } else { return }
                    } else { return }
                    let packets = try SyncPacketizer.split(frame, packetLimit: writeLimit)
                    output = Output(packets: packets, started: now(), progressed: now(), id: id,
                                    isAuth: isAuth, bytes: packets.reduce(0) { $0 + $1.count })
                }
                guard var current = output else { return }
                let packet = current.packets[current.index]
                current.index += 1; current.progressed = now()
                let finished = current.index == current.packets.count
                output = finished ? nil : current
                let session = sessionGeneration
                // Record completion before handing off; test transports may answer synchronously.
                if finished, let id = current.id {
                    if pending.contains(where: { $0.id == id }) { sentAt[id] = now() }
                    lastSentAt = now()
                }
                lastActivity = now()
                transport.write(packet)
                guard sessionGeneration == session else { return }
                if finished {
                    if current.isAuth {
                        status = .connected; handshakeStart = nil; handshake = nil
                        record("接続確認成功")
                        if let peerId { settings.peripheralId = peerId; transport.authenticated(peerId) }
                    }
                    if current.id != nil {
                        record("送信; 件数=1; バイト数=\(current.bytes); 所要ms=\(milliseconds(since: current.started))")
                    }
                }
            }
            if writeBlockedSince == nil,
               output != nil || !controlFrames.isEmpty || !ackQueue.isEmpty || pingQueued ||
                (status == .connected && pending.contains(where: { !sentThisConnection.contains($0.id) })) {
                writeBlockedSince = now()
            }
        } catch { fail(reject: false, reason: "送信フレーム作成失敗") }
    }

    private func receive(_ packet: Data) {
        guard let assembler else { fail(reject: true, reason: "準備前の受信"); return }
        do {
            if receiveStart == nil { receiveStart = now(); receiveBytes = 0 }
            receiveBytes += packet.count
            let frame = try assembler.append(packet)
            lastActivity = now()
            partialStart = assembler.hasPartialFrame ? now() : nil
            guard let frame else { return }
            let start = receiveStart ?? now(), bytes = receiveBytes
            receiveStart = nil; receiveBytes = 0
            if receiver == nil {
                guard let handshake else { throw SyncProtocolError.state }
                let result = try handshake.acceptWelcome(frame)
                sender = try SyncFrameSender(key: result.keys.padToPc)
                receiver = try SyncFrameReceiver(key: result.keys.pcToPad)
                controlFrames.append(result.auth)
                pump()
                return
            }
            // AUTH must already have been handed to Bluetooth before application data arrives.
            guard status == .connected, let receiver else { throw SyncProtocolError.state }
            let message = try SyncMessageCodec.decode(receiver.open(frame))
            switch message {
            case let .item(id, _, from, text):
                guard from == "pc" else { throw SyncProtocolError.format }
                if seen.contains(id) { queueAck(id); record("重複受信; 件数=1"); return }
                // No premature ACK while the first occurrence is still being committed.
                guard !receiving.contains(id) else { return }
                guard receiving.count < 50 else { throw SyncProtocolError.limit }
                receiving.insert(id)
                let generation = pairingGeneration
                monitor.receiveFromPC(text, copyToPasteboard: copiesReceivedToPasteboard,
                    isCurrentPairing: { [weak self] in self?.pairingGeneration == generation }) { [weak self] success in
                    guard let self, self.pairingGeneration == generation else { return }
                    self.receiving.remove(id)
                    guard success else { self.fail(reject: false, reason: "受信履歴保存失敗"); return }
                    self.seen.append(id)
                    if self.seen.count > 500 { self.seen.removeFirst(self.seen.count - 500) }
                    self.lastReceivedAt = self.now()
                    self.record("受信; 件数=1; バイト数=\(bytes); 所要ms=\(self.milliseconds(since: start))")
                    if self.status == .connected { self.queueAck(id) }
                }
            case .ack(let ids):
                for id in Set(ids) {
                    guard let index = pending.firstIndex(where: { $0.id == id }), sentAt[id] != nil else { continue }
                    if let start = sentAt.removeValue(forKey: id) { record("ack; 件数=1; 所要ms=\(milliseconds(since: start))") }
                    pending.remove(at: index); sentThisConnection.remove(id)
                }
            case .ping: break
            case .pong:
                if !pingQueued { pingRequestedAt = nil }
            }
        } catch { fail(reject: status != .connected, reason: "受信・接続確認失敗") }
    }
    private func queueAck(_ id: UUID) {
        if !ackQueue.contains(id) { ackQueue.append(id) }
        if ackQueue.count > 500 { fail(reject: false, reason: "ack待ち上限"); return }
        pump()
    }
    private func fail(reject: Bool, reason: String) {
        record("切断; 理由=\(reason); 相手を10分無視=\(reject)")
        resetSession(); status = pairing == nil ? .unpaired : .searching
        transport?.reconnect(rejectForTenMinutes: reject)
    }
    func checkTimeouts() {
        deleteKeyIfPending()
        let date = now()
        if let start = handshakeStart, date.timeIntervalSince(start) > 30 {
            fail(reject: true, reason: "接続確認期限")
        } else if let start = partialStart, date.timeIntervalSince(start) > 60 {
            fail(reject: false, reason: "受信組み立て期限")
        } else if let current = output, date.timeIntervalSince(current.progressed) > 60 {
            fail(reject: false, reason: "送信停止期限")
        } else if let start = writeBlockedSince, date.timeIntervalSince(start) > 60 {
            fail(reject: false, reason: "送信準備待ち期限")
        } else if sentAt.values.contains(where: { date.timeIntervalSince($0) > 60 }) {
            fail(reject: false, reason: "ack期限")
        } else if let start = pingRequestedAt, date.timeIntervalSince(start) >= 10 {
            fail(reject: false, reason: "pong期限")
        } else if status == .connected, pingRequestedAt == nil,
                  let lastActivity, date.timeIntervalSince(lastActivity) >= 30 {
            // Start the deadline before pump: even a synchronous test reply can clear it.
            // A stalled write queue must not leave a liveness probe pending indefinitely.
            pingRequestedAt = date; pingQueued = true
            pump()
        }
    }
    private func milliseconds(since date: Date) -> Int { Int(max(0, now().timeIntervalSince(date)) * 1000) }
    private func record(_ details: String) {
        monitor.log.append(MeasurementEvent(kind: "PC同期", changeCount: -1, scene: monitor.sceneState, details: details))
    }
    deinit {
        timer?.invalidate()
        if let unlockObserver { NotificationCenter.default.removeObserver(unlockObserver) }
    }
}
