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
    struct TransferProgress: Equatable {
        let direction: String
        let itemID: UUID
        let bytes: Int
        let totalBytes: Int
    }
    @Published private(set) var transferProgress: TransferProgress?
    @Published private(set) var pendingCount = 0
    @Published private(set) var requiresPeerUpdate = false
    @Published private(set) var compatibilityMessage: String?
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
    private var receiveLimit = 512
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
    private let disk: SyncDiskStore
    private var seen: [UUID] { disk.state.seen }
    private var offsets: [UUID: Int] = [:]
    private var awaitingOffsets: [UUID: Int] = [:]
    private var replies: [SyncMessage] = []
    private var attempted: Set<UUID> = []
    private var handshakeFailures = 0
    private var historyReady = false
    private var historyLoaded = false
    private var historyLoading = false
    private var needsHistoryRetry = false
    private var receiving: Set<UUID> = []
    private var ackQueue: [UUID] = []
    private var pending: [SyncPending] { disk.state.pending }
    private var sentThisConnection: Set<UUID> = []
    private var sentAt: [UUID: Date] = [:]
    private var controlFrames: [Data] = []
    private var output: Output?
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
        self.disk = SyncDiskStore(root: monitor.syncDirectory)
        self.settings = PCSyncSettings(defaults: defaults)
        self.keyStore = keyStore ?? PCSyncKeychain()
        self.now = now
        self.makeTransport = makeTransport ?? { PCSyncBluetooth(log: $0) }
        copiesReceivedToPasteboard = settings.copiesReceivedToPasteboard
        monitor.onLocalEntryForPC = { [weak self] entry, date in self?.enqueue(entry, at: date) }
        monitor.onHistoryIDsForPC = { [weak self] ids in
            guard let self else { return }
            self.historyLoaded = true
            self.pruneWithHistoryIDs(ids)
        }
        restorePairing()
        if !historyLoaded { loadHistoryForSync() }
        unlockObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleProtectedDataAvailable() }
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
        catch { throw PCSyncPairError(message: "組にする鍵を保存できませんでした。\(DeviceKind.current.name)のロックを解除して、もう一度お試しください。") }
        stopPairing()
        settings.save(value)
        pairing = value; pcName = value.name
        try disk.load(pairId: value.pcId, now: now()); refreshPending()
        if historyLoaded {
            pruneWithHistoryIDs(Set(monitor.entries.map(\.id)))
        } else {
            loadHistoryForSync()
        }
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
    private func handleProtectedDataAvailable() {
        restorePairing()
        if pairing != nil, !historyReady { loadHistoryForSync(retryOnUnlock: true) }
    }
    private func loadHistoryForSync(retryOnUnlock: Bool = false) {
        if historyLoading {
            if retryOnUnlock { needsHistoryRetry = true }
            return
        }
        historyLoading = true
        needsHistoryRetry = false
        Task { [weak self] in
            guard let self else { return }
            do {
                let entries = try await self.monitor.historyForShortcuts()
                self.historyLoading = false
                self.needsHistoryRetry = false
                self.historyLoaded = true
                if self.pairing != nil { self.pruneWithHistoryIDs(Set(entries.map(\.id))) }
            } catch {
                self.historyLoading = false
                self.record("送信待ち確認失敗; 理由=履歴読み込み")
                if self.needsHistoryRetry {
                    self.needsHistoryRetry = false
                    self.loadHistoryForSync()
                }
            }
        }
    }
    private func pruneWithHistoryIDs(_ ids: Set<Int>) {
        guard pairing != nil else { return }
        do {
            try disk.prune(now: now(), historyIDs: ids); refreshPending()
            historyReady = true
            if let id = output?.id, !pending.contains(where: { $0.id == id }) {
                fail(reject: false, reason: "送信中の履歴削除")
            } else { pump() }
        } catch { record("送信待ち保存失敗; 件数=1") }
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
            historyReady = false
            try disk.load(pairId: value.pcId, now: now()); refreshPending()
            pairing = value; pcName = value.name
            if historyLoaded {
                pruneWithHistoryIDs(Set(monitor.entries.map(\.id)))
            } else {
                loadHistoryForSync()
            }
            requiresPeerUpdate = settings.requiresPeerUpdate
            if requiresPeerUpdate { compatibilityMessage = "相手のアプリを更新してください"; status = .unsupported }
            else { startTransport() }
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
        pairing = nil; pcName = nil; status = .unpaired; historyReady = false
        try? disk.clear(); monitor.clearPCFingerprints(); refreshPending(); receiving.removeAll()
        requiresPeerUpdate = false; settings.requiresPeerUpdate = false; compatibilityMessage = nil; handshakeFailures = 0
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
        offsets.removeAll(); awaitingOffsets.removeAll(); replies.removeAll(); transferProgress = nil
    }

    private func handle(_ event: PCSyncTransportEvent) {
        guard pairing != nil, !requiresPeerUpdate else { return }
        switch event {
        case .status(let value):
            if status != .connected { status = value }
        case let .ready(id, limit, receiveLimit):
            resetSession()
            do {
                guard let pairing else { return }
                writeLimit = min(512, limit); peerId = id
                self.receiveLimit = min(512, receiveLimit)
                assembler = try SyncPacketAssembler(packetLimit: self.receiveLimit, frameLimit: 82)
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

    private func refreshPending() {
        pendingCount = pending.count
        let ids = Set(pending.map(\.id))
        sentThisConnection.formIntersection(ids)
        sentAt = sentAt.filter { ids.contains($0.key) }
        offsets = offsets.filter { ids.contains($0.key) }
        awaitingOffsets = awaitingOffsets.filter { ids.contains($0.key) }
    }
    private func enqueue(_ entry: HistoryEntry, at date: Date) {
        guard pairing != nil else { return }
        let generation = pairingGeneration
        monitor.prepareForPC(entry) { [weak self] result in
            guard let self, self.pairing != nil, self.pairingGeneration == generation,
                  self.monitor.entries.contains(where: { $0.id == entry.id }) else { return }
            do {
                let body = try result.get(), id = UUID()
                let at = Int64(date.timeIntervalSince1970 * 1000)
                let offer: SyncOffer?
                if body.kind == "text" {
                    _ = try SyncMessageCodec.encode(.item(id: id, at: at, from: "pad", text: String(decoding: body.data, as: UTF8.self)))
                    offer = nil
                } else {
                    offer = SyncOffer(id: id, at: at, from: "pad", kind: body.kind, size: body.data.count,
                        sha256: body.hash, name64: Data(body.name.utf8).base64EncodedString(), type: body.type)
                    try offer!.validate()
                }
                try self.disk.enqueue(SyncPending(id: id, historyID: entry.id, at: at, offer: offer), bytes: body.data, now: self.now())
                self.refreshPending(); self.pump()
            } catch { self.record("送信見送り; 理由=サイズ・形式・保存; 件数=1") }
        }
    }
    func retryAfterPeerUpdate() {
        guard pairing != nil else { return }
        requiresPeerUpdate = false; settings.requiresPeerUpdate = false; compatibilityMessage = nil; handshakeFailures = 0
        startTransport()
    }
    private func pauseForUpdate() {
        resetSession(); requiresPeerUpdate = true; settings.requiresPeerUpdate = true
        compatibilityMessage = "相手のアプリを更新してください（接続確認ができない場合はPCの状態も確認してください）"
        status = .unsupported
        transport?.onEvent = nil; transport?.stop(); transport = nil
        record("接続停止; 理由=通信の版または接続確認の不一致")
    }

    private func nextPendingItem() -> SyncPending? {
        guard status == .connected, historyReady else { return nil }
        let attachmentBusy = !awaitingOffsets.isEmpty || !offsets.isEmpty
        return pending.first {
            !sentThisConnection.contains($0.id) &&
            ($0.offer == nil || !attachmentBusy || offsets[$0.id] != nil)
        }
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
                        } else if !replies.isEmpty {
                            frame = try sender.seal(SyncMessageCodec.encode(replies.removeFirst()))
                        } else if pingQueued {
                            pingQueued = false
                            frame = try sender.seal(SyncMessageCodec.encode(.ping))
                        } else if let item = nextPendingItem() {
                            id = item.id
                            let message: SyncMessage
                            if let offer = item.offer {
                                if let offset = offsets.removeValue(forKey: item.id) {
                                    try SyncProtocol.require(offset < offer.size, .state)
                                    let file = try FileHandle(forReadingFrom: disk.body(item.id))
                                    defer { try? file.close() }
                                    try file.seek(toOffset: UInt64(offset))
                                    let data = try file.read(upToCount: min(SyncProtocol.chunkBytes, offer.size - offset)) ?? Data()
                                    try SyncProtocol.require(!data.isEmpty)
                                    message = .chunk(id: item.id, offset: offset, data: data)
                                    awaitingOffsets[item.id] = offset + data.count
                                    transferProgress = TransferProgress(direction: "send", itemID: item.id, bytes: offset + data.count, totalBytes: offer.size)
                                } else { message = .offer(offer); awaitingOffsets[item.id] = -1 }
                            } else {
                                let data = try Data(contentsOf: disk.body(item.id))
                                message = .item(id: item.id, at: item.at, from: "pad", text: String(decoding: data, as: UTF8.self))
                                transferProgress = TransferProgress(direction: "send", itemID: item.id, bytes: data.count, totalBytes: data.count)
                            }
                            sentThisConnection.insert(item.id)
                            frame = try sender.seal(SyncMessageCodec.encode(message))
                            if !attempted.insert(item.id).inserted { record("再送または継続; 件数=1") }
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
                        status = .connected; handshakeStart = nil; handshake = nil; handshakeFailures = 0
                        replies.insert(.device(kind: UIDevice.current.userInterfaceIdiom == .phone ? "phone" : "pad"), at: 0)
                        record("接続確認成功")
                        if let peerId { settings.peripheralId = peerId; transport.authenticated(peerId) }
                    }
                    if current.id != nil {
                        record("送信; 件数=1; バイト数=\(current.bytes); 所要ms=\(milliseconds(since: current.started))")
                    }
                }
            }
            if writeBlockedSince == nil,
               output != nil || !controlFrames.isEmpty || !ackQueue.isEmpty || !replies.isEmpty || pingQueued ||
                nextPendingItem() != nil {
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
                self.assembler = try SyncPacketAssembler(packetLimit: receiveLimit)
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
            case let .item(id, at, from, text):
                guard from == "pc" else { throw SyncProtocolError.format }
                if seen.contains(id) { queueAck(id); record("重複受信; 件数=1"); return }
                // No premature ACK while the first occurrence is still being committed.
                guard !receiving.contains(id) else { return }
                guard receiving.count < 50 else { throw SyncProtocolError.limit }
                receiving.insert(id)
                let generation = pairingGeneration
                monitor.receiveFromPC(text, copyToPasteboard: copiesReceivedToPasteboard, at: Date(timeIntervalSince1970: Double(at) / 1000),
                    isCurrentPairing: { [weak self] in self?.pairingGeneration == generation }) { [weak self] success in
                    guard let self, self.pairingGeneration == generation else { return }
                    self.receiving.remove(id)
                    guard success else { self.fail(reject: false, reason: "受信履歴保存失敗"); return }
                    do { try self.disk.markSeen(id) } catch { self.fail(reject: false, reason: "受信確認保存失敗"); return }
                    self.lastReceivedAt = self.now()
                    self.record("受信; 件数=1; バイト数=\(bytes); 所要ms=\(self.milliseconds(since: start))")
                    if self.status == .connected { self.queueAck(id) }
                }
            case .offer(let offer):
                guard offer.from == "pc" else { throw SyncProtocolError.format }
                // The authenticated header can arrive before Apple shares the completed copy from another device.
                monitor.rememberIncomingPC(kind: offer.kind, hash: offer.sha256)
                if seen.contains(offer.id) { queueAck(offer.id); return }
                guard !receiving.contains(offer.id) else { return }
                let offset = try disk.begin(offer, now: now())
                transferProgress = TransferProgress(direction: "receive", itemID: offer.id, bytes: offset, totalBytes: offer.size)
                if offset == offer.size { try finishIncoming(offer) }
                else { try queueReply(.resume(id: offer.id, offset: offset)) }
            case let .chunk(id, offset, data):
                if seen.contains(id) { queueAck(id); return }
                guard !receiving.contains(id) else { return }
                guard let offer = disk.state.partials.first(where: { $0.offer.id == id })?.offer else { throw SyncProtocolError.state }
                let saved = try disk.append(id: id, offset: offset, data: data)
                transferProgress = TransferProgress(direction: "receive", itemID: id, bytes: saved, totalBytes: offer.size)
                if saved == offer.size { try finishIncoming(offer) }
                else { try queueReply(.resume(id: id, offset: saved)) }
            case let .resume(id, offset):
                guard let item = pending.first(where: { $0.id == id }) else { return }
                guard let offer = item.offer, offset < offer.size, let expected = awaitingOffsets[id],
                      expected < 0 || expected == offset else { throw SyncProtocolError.state }
                awaitingOffsets.removeValue(forKey: id); offsets[id] = offset
                sentAt.removeValue(forKey: id); sentThisConnection.remove(id); pump()
            case .ack(let ids):
                let accepted = Set(ids.filter { sentAt[$0] != nil })
                try disk.ack(accepted); refreshPending()
                if let progress = transferProgress, progress.direction == "send", accepted.contains(progress.itemID) {
                    transferProgress = nil
                }
                pump()
            case .device: throw SyncProtocolError.format
            case .ping: break
            case .pong:
                if !pingQueued { pingRequestedAt = nil }
            }
        } catch SyncProtocolError.version { pauseForUpdate() }
        catch SyncProtocolError.identity { fail(reject: true, reason: "別のPC") }
        catch {
            let duringHandshake = handshakeStart != nil && status != .connected
            fail(reject: duringHandshake, countFailure: duringHandshake, reason: "受信・接続確認失敗")
        }
    }
    private func finishIncoming(_ offer: SyncOffer) throws {
        let url: URL
        do { url = try disk.verified(offer) }
        catch {
            try? disk.discard(offer.id)
            transferProgress = nil
            throw error
        }
        receiving.insert(offer.id)
        let generation = pairingGeneration
        monitor.receiveFromPC(offer, url: url, copyToPasteboard: copiesReceivedToPasteboard,
            isCurrentPairing: { [weak self] in self?.pairingGeneration == generation }) { [weak self] outcome in
            guard let self, self.pairingGeneration == generation else { return }
            self.receiving.remove(offer.id)
            switch outcome {
            case .saved, .rejected:
                do { try self.disk.markSeen(offer.id); try self.disk.discard(offer.id) }
                catch {
                    try? self.disk.discard(offer.id)
                    self.transferProgress = nil
                    self.fail(reject: false, reason: "受信確認保存失敗")
                    return
                }
                self.transferProgress = nil
                if case .rejected(let reason) = outcome {
                    self.record("受信見送り; 理由=\(reason.rawValue); 件数=1")
                } else {
                    self.lastReceivedAt = self.now()
                }
                if self.status == .connected { self.queueAck(offer.id) }
            case .failed:
                try? self.disk.discard(offer.id)
                self.transferProgress = nil
                self.fail(reject: false, reason: "受信履歴保存失敗")
            }
        }
    }
    private func queueReply(_ message: SyncMessage) throws {
        try SyncProtocol.require(replies.count < 64, .limit)
        replies.append(message); pump()
    }
    private func queueAck(_ id: UUID) {
        if !ackQueue.contains(id) { ackQueue.append(id) }
        if ackQueue.count > 500 { fail(reject: false, reason: "ack待ち上限"); return }
        pump()
    }
    private func fail(reject: Bool, countFailure: Bool = false, reason: String) {
        if countFailure { handshakeFailures += 1; if handshakeFailures >= 3 { pauseForUpdate(); return } }
        record("切断; 理由=\(reason); 相手を10分無視=\(reject)")
        resetSession(); status = pairing == nil ? .unpaired : .searching
        transport?.reconnect(rejectForTenMinutes: reject)
    }
    func checkTimeouts() {
        deleteKeyIfPending()
        let date = now()
        if pairing != nil { do { try disk.prune(now: date); refreshPending() } catch { record("送信待ち保存失敗") } }
        if let start = handshakeStart, date.timeIntervalSince(start) > 30 {
            fail(reject: true, countFailure: true, reason: "接続確認期限")
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
