import Combine
import Foundation
import UIKit

struct PCSyncPairError: Error, Equatable { let message: String }

enum TemplateSyncError: Error, Equatable {
    case unpaired
    case bluetoothOff
    case unauthorized
    case unsupported
    case requiresPeerUpdate
    case requiresRepair
    case notConnected
    case alreadyInProgress
    case disconnected
    case timedOut
    case limitExceeded
    case saveFailed

    func message(for device: DeviceKind) -> String {
        switch self {
        case .unpaired:
            return "PCと組んでいません"
        case .bluetoothOff:
            return "Bluetoothがオフです"
        case .unauthorized:
            return "Bluetoothが許可されていません"
        case .unsupported:
            return "この\(device.name)では使えません"
        case .requiresPeerUpdate:
            return "PCとこの\(device.name)のclipboard+を更新してください"
        case .requiresRepair:
            return "PCとの組み直しが必要です。設定で確認してください"
        case .notConnected:
            return "PCとつながっていません。PCの近くで試してください"
        case .alreadyInProgress:
            return "テンプレートを同期しています"
        case .disconnected:
            return "途中でPCとの接続が切れました"
        case .timedOut:
            return "PCからの応答がありませんでした"
        case .limitExceeded:
            return "テンプレートの件数または容量が上限を超えています"
        case .saveFailed:
            return "テンプレートを保存できませんでした"
        }
    }
}

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
    @Published private(set) var isSyncingTemplates = false
    @Published private(set) var requiresPeerUpdate = false
    @Published private(set) var requiresRepair = false
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
    private struct PendingChunk {
        let endOffset: Int
        var handedOffLastPacket = false
        var reply: PendingReply?
    }
    private struct AttachmentTransfer {
        let id: UUID
        let size: Int
        var awaitingInitialResume = true
        var handedOffOfferLastPacket = false
        var nextSendOffset = 0
        var ackedOffset = 0
        let startedAt: Date
        var startOffset = 0
        var chunks: [PendingChunk] = []
        var canSendChunk: Bool {
            !awaitingInitialResume && nextSendOffset < size && chunks.count < PCSyncController.maxAttachmentChunksInFlight
        }
    }
    private static let maxAttachmentChunksInFlight = 4
    private var activeAttachment: AttachmentTransfer?
    private var activeReadHandle: (id: UUID, handle: FileHandle)?
    private var attachmentReceives: [UUID: (startedAt: Date, startOffset: Int)] = [:]
    private var replies: [SyncMessage] = []
    private var attempted: Set<UUID> = []
    private static let replyTimeout: TimeInterval = 60
    private static let templateSyncTimeout: TimeInterval = 30
    private static let maxReplyExtension: TimeInterval = 180
    private static let minExtendableFrameBytes = 64
    private var authenticationFailures = 0
    private(set) var nextReconnectAt: Date?
    private var offeredThisConnection: Set<UUID> = []
    private var resumedAttachments: Set<UUID> = []
    private var finalChunkSentAttachments: Set<UUID> = []
    private var historyReady = false
    private var historyLoaded = false
    private var historyLoading = false
    private var needsHistoryRetry = false
    private var receiving: Set<UUID> = []
    private var ackQueue: [UUID] = []
    private var pending: [SyncPending] { disk.state.pending }
    private var sentThisConnection: Set<UUID> = []
    private struct PendingReply {
        var initialSentAt: Date
        var deadline: Date
        var baselineDeadline: Date
        var activeFrameToken: UInt64?
    }
    private var sentAt: [UUID: PendingReply] = [:]
    private struct ActiveTemplateSync {
        let op: UUID
        var reply: PendingReply
        var pushed: LocalTemplateSyncSnapshot?
        var awaitingSendCompletion = true
        var isApplying = false
        let completion: @MainActor (Result<TemplateSyncOutcome, TemplateSyncError>) -> Void
    }
    private var activeTemplateSync: ActiveTemplateSync?
    private var templateAckQueue: [UUID] = []
    private var templateOutgoing: [TemplateSyncMessage] = []
    private struct TemplateReception {
        let op: UUID
        let assembler: TemplateSyncPageAssembler
        let start: Date
        var bytes = 0
    }
    private var templateReception: TemplateReception?
    private var inFlightTemplatePulls: Set<UUID> = []
    private var pendingPushedSnapshots: [(op: UUID, snapshot: LocalTemplateSyncSnapshot)] = []
    private var nextIncomingFrameToken: UInt64 = 0
    private var currentIncomingFrameToken: UInt64?
    private var incomingFrameBytes = 0
    private var controlFrames: [Data] = []
    private var output: Output?
    private struct Output {
        let packets: [Data]
        var index = 0
        let started: Date
        var progressed: Date
        let id: UUID?
        let isAuth: Bool
        let chunkEndOffset: Int?
        let finishesAttachment: Bool
        let templatePushOp: UUID?
        let finishesTemplatePush: Bool
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
        let wasPaired = pairing != nil
        stopPairing()
        if wasPaired { monitor.resetTemplateSyncState() }
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
        monitor.resetTemplateSyncState()
        record("組を解除")
    }

    func syncTemplates(completion: @escaping @MainActor (Result<TemplateSyncOutcome, TemplateSyncError>) -> Void) {
        guard status != .unpaired else {
            completion(.failure(.unpaired))
            return
        }
        guard !isSyncingTemplates else {
            completion(.failure(.alreadyInProgress))
            return
        }
        if requiresRepair {
            completion(.failure(.requiresRepair))
            return
        }
        if requiresPeerUpdate {
            completion(.failure(.requiresPeerUpdate))
            return
        }
        switch status {
        case .unpaired:
            completion(.failure(.unpaired))
            return
        case .bluetoothOff:
            completion(.failure(.bluetoothOff))
            return
        case .unauthorized:
            completion(.failure(.unauthorized))
            return
        case .unsupported:
            completion(.failure(.unsupported))
            return
        case .searching, .connecting:
            completion(.failure(.notConnected))
            return
        case .connected:
            guard pairing != nil, sender != nil else {
                completion(.failure(.notConnected))
                return
            }
        }

        let op = UUID()
        let startedAt = now()
        let initialDeadline = startedAt.addingTimeInterval(Self.templateSyncTimeout)
        isSyncingTemplates = true
        activeTemplateSync = ActiveTemplateSync(
            op: op,
            reply: PendingReply(
                initialSentAt: startedAt,
                deadline: initialDeadline,
                baselineDeadline: initialDeadline,
                activeFrameToken: nil
            ),
            pushed: nil,
            awaitingSendCompletion: true,
            isApplying: false,
            completion: completion
        )
        let pairingGen = pairingGeneration
        let sessionGen = sessionGeneration
        monitor.readTemplateSyncSnapshot { [weak self] result in
            guard let self, self.pairingGeneration == pairingGen, self.sessionGeneration == sessionGen,
                  var active = self.activeTemplateSync, active.op == op else { return }
            guard self.status == .connected else {
                self.activeTemplateSync = nil
                self.isSyncingTemplates = false
                active.completion(.failure(.disconnected))
                return
            }
            switch result {
            case .failure:
                self.activeTemplateSync = nil
                self.isSyncingTemplates = false
                self.record("テンプレート同期の読み込み失敗")
                active.completion(.failure(.saveFailed))
            case .success(let local):
                do {
                    let pages = try TemplateSyncMessageCodec.splitPages(op: op, snapshot: local.snapshot, isState: false)
                    let pushNow = self.now()
                    let pushDeadline = pushNow.addingTimeInterval(Self.templateSyncTimeout)
                    active.pushed = local
                    active.reply.initialSentAt = pushNow
                    active.reply.deadline = pushDeadline
                    active.reply.baselineDeadline = pushDeadline
                    self.activeTemplateSync = active
                    self.templateOutgoing.append(contentsOf: pages)
                    self.record("テンプレート同期開始; 件数=\(local.snapshot.templates.count); 墓標=\(local.snapshot.tombstones.count)")
                    self.pump()
                } catch {
                    self.activeTemplateSync = nil
                    self.isSyncingTemplates = false
                    self.record("テンプレート同期送信失敗")
                    active.completion(.failure(.limitExceeded))
                }
            }
        }
    }
    private func deleteKeyIfPending() {
        guard settings.deletionPending else { return }
        do { try keyStore.delete(); settings.deletionPending = false }
        catch { record("鍵の削除待ち; ロック解除後に再試行") }
    }
    private func handleProtectedDataAvailable() {
        let wasPaired = pairing != nil
        restorePairing()
        guard wasPaired, pairing != nil, !historyReady else { return }
        if historyLoaded {
            pruneWithHistoryIDs(Set(monitor.entries.map(\.id)))
        } else {
            loadHistoryForSync(retryOnUnlock: true)
        }
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
                _ = try await self.monitor.historyForShortcuts()
                self.historyLoading = false
                self.needsHistoryRetry = false
                self.historyLoaded = true
                if self.pairing != nil, !self.historyReady {
                    self.pruneWithHistoryIDs(Set(self.monitor.entries.map(\.id)))
                }
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
            requiresRepair = settings.requiresRepair
            if requiresPeerUpdate {
                compatibilityMessage = "相手のアプリを更新してください"; status = .unsupported
            } else if requiresRepair {
                compatibilityMessage = "PCとの組が一致しません。PCのQRコードを読み直して組み直してください"; status = .unsupported
            } else {
                startTransport()
            }
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
        try? disk.clear(); monitor.clearPCFingerprints(); attempted.removeAll(); refreshPending(); receiving.removeAll()
        requiresPeerUpdate = false; settings.requiresPeerUpdate = false
        requiresRepair = false; settings.requiresRepair = false
        compatibilityMessage = nil; authenticationFailures = 0; nextReconnectAt = nil
        lastSentAt = nil; lastReceivedAt = nil
    }
    private func resetSession() {
        if let assembler {
            do { try assembler.finish() } catch { record("受信組み立てを破棄") }
        }
        if let templateReception {
            do { try templateReception.assembler.finish() } catch { record("テンプレート受信組み立てを破棄") }
        }
        assembler = nil; templateReception = nil; handshake = nil; sender = nil; receiver = nil; peerId = nil
        sessionGeneration = UUID()
        handshakeStart = nil; partialStart = nil; receiveStart = nil; receiveBytes = 0
        nextIncomingFrameToken = 0; currentIncomingFrameToken = nil; incomingFrameBytes = 0
        writeBlockedSince = nil
        lastActivity = nil; pingRequestedAt = nil; pingQueued = false
        output = nil; controlFrames.removeAll(); ackQueue.removeAll()
        templateAckQueue.removeAll(); templateOutgoing.removeAll()
        inFlightTemplatePulls.removeAll(); pendingPushedSnapshots.removeAll()
        sentThisConnection.removeAll(); sentAt.removeAll()
        closeReadHandle()
        activeAttachment = nil; attachmentReceives.removeAll(); replies.removeAll()
        offeredThisConnection.removeAll(); resumedAttachments.removeAll(); finalChunkSentAttachments.removeAll()
        transferProgress = nil
        if let active = activeTemplateSync {
            activeTemplateSync = nil
            isSyncingTemplates = false
            active.completion(.failure(.disconnected))
        }
    }

    private func handle(_ event: PCSyncTransportEvent) {
        guard pairing != nil, !requiresPeerUpdate, !requiresRepair else { return }
        switch event {
        case .status(let value):
            if status != .connected { status = value }
            if value == .bluetoothOff || value == .unauthorized || value == .unsupported {
                nextReconnectAt = nil
            }
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
            } catch { fail(reject: false, countBackoff: true, reason: "接続確認の開始失敗") }
        case .packet(let packet): receive(packet)
        case .writable: pump()
        case .disconnected(let nextReconnectAt):
            resetSession(); status = .searching; self.nextReconnectAt = nextReconnectAt
        }
    }

    private func closeReadHandle(for id: UUID? = nil) {
        if let active = activeReadHandle, id == nil || active.id == id {
            try? active.handle.close()
            activeReadHandle = nil
        }
    }

    private func refreshPending() {
        pendingCount = pending.count
        let ids = Set(pending.map(\.id))
        sentThisConnection.formIntersection(ids)
        attempted.formIntersection(ids)
        sentAt = sentAt.filter { ids.contains($0.key) }
        if let active = activeAttachment, !ids.contains(active.id) {
            closeReadHandle(for: active.id)
            activeAttachment = nil
        }
        resumedAttachments.formIntersection(ids)
        finalChunkSentAttachments.formIntersection(ids)
        if let progress = transferProgress {
            if progress.direction == "send", !ids.contains(progress.itemID) {
                transferProgress = nil
            } else if progress.direction == "receive",
                      !disk.state.partials.contains(where: { $0.offer.id == progress.itemID }),
                      !receiving.contains(progress.itemID) {
                transferProgress = nil
            }
        }
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
        requiresPeerUpdate = false; settings.requiresPeerUpdate = false
        if !requiresRepair { compatibilityMessage = nil }
        authenticationFailures = 0; nextReconnectAt = nil
        startTransport()
    }
    func retryAfterRepair() {
        guard pairing != nil else { return }
        requiresRepair = false; settings.requiresRepair = false
        if !requiresPeerUpdate { compatibilityMessage = nil }
        authenticationFailures = 0; nextReconnectAt = nil
        startTransport()
    }
    private func pauseForUpdate() {
        resetSession(); requiresPeerUpdate = true; settings.requiresPeerUpdate = true
        requiresRepair = false; settings.requiresRepair = false
        compatibilityMessage = "相手のアプリを更新してください"
        status = .unsupported
        transport?.onEvent = nil; transport?.stop(); transport = nil
        record("接続停止; 理由=通信の版が不一致")
    }
    private func pauseForRepair() {
        resetSession(); requiresRepair = true; settings.requiresRepair = true
        requiresPeerUpdate = false; settings.requiresPeerUpdate = false
        compatibilityMessage = "PCとの組が一致しません。PCのQRコードを読み直して組み直してください"
        status = .unsupported
        transport?.onEvent = nil; transport?.stop(); transport = nil
        record("接続停止; 理由=認証の不一致")
    }

    private func nextPendingItem() -> SyncPending? {
        guard status == .connected, historyReady else { return nil }
        return pending.first { item in
            if item.offer == nil {
                return !sentThisConnection.contains(item.id)
            }
            if let active = activeAttachment {
                return active.id == item.id && active.canSendChunk
            }
            return !sentThisConnection.contains(item.id)
        }
    }

    private var isMidTemplatePush: Bool {
        guard let first = templateOutgoing.first, case let .push(_, part, _, _) = first else { return false }
        return part > 0
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
                    var chunkEndOffset: Int?
                    var finishesAttachment = false
                    var templatePushOp: UUID?
                    var finishesTemplatePush = false
                    if !controlFrames.isEmpty {
                        frame = controlFrames.removeFirst(); isAuth = frame.first == 3
                    } else if status == .connected, let sender {
                        if !ackQueue.isEmpty {
                            let ids = Array(ackQueue.prefix(SyncProtocol.maxAckIds))
                            ackQueue.removeFirst(ids.count)
                            frame = try sender.seal(SyncMessageCodec.encode(.ack(ids: ids)))
                        } else if !replies.isEmpty {
                            frame = try sender.seal(SyncMessageCodec.encode(replies.removeFirst()))
                        } else if !templateAckQueue.isEmpty, !isMidTemplatePush {
                            let ackOp = templateAckQueue.removeFirst()
                            frame = try sender.seal(TemplateSyncMessageCodec.encode(.ack(op: ackOp)))
                        } else if !templateOutgoing.isEmpty {
                            let tplMessage = templateOutgoing.removeFirst()
                            if case let .push(op, part, total, _) = tplMessage {
                                templatePushOp = op
                                finishesTemplatePush = (part + 1 == total)
                            }
                            frame = try sender.seal(TemplateSyncMessageCodec.encode(tplMessage))
                        } else if pingQueued {
                            pingQueued = false
                            frame = try sender.seal(SyncMessageCodec.encode(.ping))
                        } else if let item = nextPendingItem() {
                            id = item.id
                            let message: SyncMessage
                            if let offer = item.offer {
                                if var active = activeAttachment, active.id == item.id {
                                    let offset = active.nextSendOffset
                                    try SyncProtocol.require(offset < offer.size, .state)
                                    let file: FileHandle
                                    if let opened = activeReadHandle, opened.id == item.id {
                                        file = opened.handle
                                    } else {
                                        closeReadHandle()
                                        let opened = try FileHandle(forReadingFrom: disk.body(item.id))
                                        activeReadHandle = (item.id, opened)
                                        file = opened
                                    }
                                    try file.seek(toOffset: UInt64(offset))
                                    let data = try file.read(upToCount: min(SyncProtocol.chunkBytes, offer.size - offset)) ?? Data()
                                    try SyncProtocol.require(!data.isEmpty)
                                    let end = offset + data.count
                                    if end == offer.size { closeReadHandle(for: item.id) }
                                    message = .chunk(id: item.id, offset: offset, data: data)
                                    active.nextSendOffset = end
                                    active.chunks.append(PendingChunk(endOffset: end))
                                    activeAttachment = active
                                    chunkEndOffset = end
                                    finishesAttachment = end == offer.size
                                    transferProgress = TransferProgress(direction: "send", itemID: item.id, bytes: end, totalBytes: offer.size)
                                } else {
                                    message = .offer(offer)
                                    activeAttachment = AttachmentTransfer(id: item.id, size: offer.size, startedAt: now())
                                    finishesAttachment = offer.size == 0
                                }
                            } else {
                                let data = try Data(contentsOf: disk.body(item.id))
                                message = .item(id: item.id, at: item.at, from: "pad", text: String(decoding: data, as: UTF8.self))
                                transferProgress = TransferProgress(direction: "send", itemID: item.id, bytes: data.count, totalBytes: data.count)
                                sentThisConnection.insert(item.id)
                            }
                            frame = try sender.seal(SyncMessageCodec.encode(message))
                            if chunkEndOffset == nil, !attempted.insert(item.id).inserted { record("再送または継続; 件数=1") }
                        } else { return }
                    } else { return }
                    let packets = try SyncPacketizer.split(frame, packetLimit: writeLimit)
                    output = Output(packets: packets, started: now(), progressed: now(), id: id,
                                    isAuth: isAuth, chunkEndOffset: chunkEndOffset,
                                    finishesAttachment: finishesAttachment,
                                    templatePushOp: templatePushOp,
                                    finishesTemplatePush: finishesTemplatePush,
                                    bytes: packets.reduce(0) { $0 + $1.count })
                }
                guard var current = output else { return }
                let packet = current.packets[current.index]
                current.index += 1; current.progressed = now()
                let finished = current.index == current.packets.count
                output = finished ? nil : current
                let session = sessionGeneration
                // Record completion before handing off; test transports may answer synchronously.
                if finished, let id = current.id {
                    let completedNow = now()
                    if pending.contains(where: { $0.id == id }) {
                        let initialDeadline = completedNow.addingTimeInterval(Self.replyTimeout)
                        let reply = PendingReply(
                            initialSentAt: completedNow,
                            deadline: initialDeadline,
                            baselineDeadline: initialDeadline,
                            activeFrameToken: nil
                        )
                        if let endOffset = current.chunkEndOffset {
                            if var active = activeAttachment, active.id == id,
                               let idx = active.chunks.firstIndex(where: { $0.endOffset == endOffset }) {
                                active.chunks[idx].handedOffLastPacket = true
                                active.chunks[idx].reply = reply
                                activeAttachment = active
                            }
                        } else if activeAttachment == nil || activeAttachment?.id != id || activeAttachment?.awaitingInitialResume == true || activeAttachment?.size == 0 {
                            sentAt[id] = reply
                            if var active = activeAttachment, active.id == id, active.awaitingInitialResume {
                                active.handedOffOfferLastPacket = true
                                activeAttachment = active
                            }
                        }
                    }
                    if current.finishesAttachment { finalChunkSentAttachments.insert(id) }
                    lastSentAt = completedNow
                }
                if finished, let pushOp = current.templatePushOp, current.finishesTemplatePush {
                    let completedNow = now()
                    if var active = activeTemplateSync, active.op == pushOp {
                        let deadline = completedNow.addingTimeInterval(Self.templateSyncTimeout)
                        active.awaitingSendCompletion = false
                        active.reply.initialSentAt = completedNow
                        active.reply.deadline = deadline
                        active.reply.baselineDeadline = deadline
                        active.reply.activeFrameToken = nil
                        activeTemplateSync = active
                    }
                }
                lastActivity = now()
                transport.write(packet)
                guard sessionGeneration == session else { return }
                if finished {
                    if current.isAuth {
                        status = .connected; handshakeStart = nil; handshake = nil
                        authenticationFailures = 0; nextReconnectAt = nil
                        replies.insert(.device(kind: UIDevice.current.userInterfaceIdiom == .phone ? "phone" : "pad"), at: 0)
                        record("接続確認成功")
                        if let peerId { settings.peripheralId = peerId; transport.authenticated(peerId) }
                    }
                    if current.id != nil && current.chunkEndOffset == nil {
                        record("送信; 件数=1; バイト数=\(current.bytes); 所要ms=\(milliseconds(since: current.started))")
                    }
                    if current.templatePushOp != nil && current.finishesTemplatePush {
                        record("テンプレート同期送信; バイト数=\(current.bytes); 所要ms=\(milliseconds(since: current.started))")
                    }
                }
            }
            if writeBlockedSince == nil,
               output != nil || !controlFrames.isEmpty || !ackQueue.isEmpty || !replies.isEmpty ||
                !templateAckQueue.isEmpty || !templateOutgoing.isEmpty || pingQueued || nextPendingItem() != nil {
                writeBlockedSince = now()
            }
        } catch { fail(reject: false, countBackoff: handshakeStart != nil && status != .connected, reason: "送信フレーム作成失敗") }
    }

    private enum IncomingMessage {
        case sync(SyncMessage)
        case template(TemplateSyncMessage)
    }

    private func receive(_ packet: Data) {
        guard let assembler else { fail(reject: true, reason: "準備前の受信"); return }
        do {
            if receiveStart == nil { receiveStart = now(); receiveBytes = 0 }
            receiveBytes += packet.count
            let wasPartial = assembler.hasPartialFrame
            let frame = try assembler.append(packet)
            let current = now()
            lastActivity = current
            partialStart = assembler.hasPartialFrame ? current : nil
            let frameToken: UInt64
            let frameBytes: Int
            let payloadCount = max(0, packet.count - 1)
            if !wasPartial {
                nextIncomingFrameToken &+= 1
                frameToken = nextIncomingFrameToken
                frameBytes = payloadCount
                if assembler.hasPartialFrame {
                    currentIncomingFrameToken = frameToken
                    incomingFrameBytes = payloadCount
                }
            } else if assembler.hasPartialFrame {
                incomingFrameBytes += payloadCount
                frameToken = currentIncomingFrameToken ?? nextIncomingFrameToken
                frameBytes = incomingFrameBytes
            } else {
                incomingFrameBytes += payloadCount
                frameToken = currentIncomingFrameToken ?? nextIncomingFrameToken
                frameBytes = incomingFrameBytes
                currentIncomingFrameToken = nil
                incomingFrameBytes = 0
            }
            if status == .connected, frame == nil, frameBytes > Self.minExtendableFrameBytes {
                extendReplyDeadlines(for: frameToken, at: current)
            }
            guard let frame else { return }
            let start = receiveStart ?? current, bytes = receiveBytes
            receiveStart = nil; receiveBytes = 0
            if receiver == nil {
                guard let handshake else { throw SyncProtocolError.state }
                let result = try handshake.acceptWelcome(frame)
                authenticationFailures = 0
                self.assembler = try SyncPacketAssembler(packetLimit: receiveLimit)
                sender = try SyncFrameSender(key: result.keys.padToPc)
                receiver = try SyncFrameReceiver(key: result.keys.pcToPad)
                controlFrames.append(result.auth)
                pump()
                return
            }
            // AUTH must already have been handed to Bluetooth before application data arrives.
            guard status == .connected, let receiver else { throw SyncProtocolError.state }
            let plaintext = try receiver.open(frame)
            let incoming: IncomingMessage
            do {
                incoming = .sync(try SyncMessageCodec.decode(plaintext))
            } catch SyncProtocolError.format {
                incoming = .template(try TemplateSyncMessageCodec.decode(plaintext))
            }
            switch incoming {
            case .sync(.ping), .sync(.pong):
                revertReplyExtension(for: frameToken)
            case .template(.state(let op, _, _, _)) where !isAwaitingTemplateState(op):
                // An old response must not change the current sync or its deadline.
                revertReplyExtension(for: frameToken)
                return
            default:
                if frameBytes > Self.minExtendableFrameBytes {
                    extendReplyDeadlines(for: frameToken, at: current)
                }
                confirmReplyExtension(for: frameToken)
            }
            switch incoming {
            case .template(let templateMessage):
                try handleTemplateMessage(templateMessage, bytes: bytes, start: start, current: current)
            case .sync(let message):
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
                    guard offeredThisConnection.insert(offer.id).inserted else { throw SyncProtocolError.state }
                    guard !receiving.contains(offer.id) else { return }
                    let offerNow = now()
                    let offset = try disk.begin(offer, now: offerNow)
                    transferProgress = TransferProgress(direction: "receive", itemID: offer.id, bytes: offset, totalBytes: offer.size)
                    attachmentReceives[offer.id] = (startedAt: offerNow, startOffset: offset)
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
                    guard let offer = item.offer, offset < offer.size,
                          var active = activeAttachment, active.id == id else { throw SyncProtocolError.state }
                    if active.awaitingInitialResume {
                        guard active.handedOffOfferLastPacket else { return }
                        active.awaitingInitialResume = false
                        active.ackedOffset = offset
                        active.nextSendOffset = offset
                        active.startOffset = offset
                        sentAt.removeValue(forKey: id)
                        finalChunkSentAttachments.remove(id)
                    } else {
                        guard let idx = active.chunks.firstIndex(where: { $0.endOffset == offset }),
                              active.chunks[idx].handedOffLastPacket else {
                            throw SyncProtocolError.state
                        }
                        active.chunks.removeFirst(idx + 1)
                        active.ackedOffset = offset
                    }
                    activeAttachment = active
                    resumedAttachments.insert(id)
                    pump()
                case .ack(let ids):
                    for id in ids {
                        if resumedAttachments.contains(id) && !finalChunkSentAttachments.contains(id) {
                            throw SyncProtocolError.state
                        }
                    }
                    let accepted = Set(ids.filter { id in
                        if let active = activeAttachment, active.id == id {
                            return active.handedOffOfferLastPacket &&
                                (sentAt[id] != nil || finalChunkSentAttachments.contains(id))
                        }
                        return sentAt[id] != nil
                    })
                    if let active = activeAttachment, accepted.contains(active.id) {
                        closeReadHandle(for: active.id)
                        let ms = milliseconds(since: active.startedAt)
                        let transferred = resumedAttachments.contains(active.id) ? max(0, active.size - active.startOffset) : 0
                        let kbps = ms > 0 ? (Double(transferred) / 1024.0) / (Double(ms) / 1000.0) : 0.0
                        record("添付送信完了; バイト数=\(active.size); 所要ms=\(ms); KB秒=\(String(format: "%.1f", kbps))")
                        activeAttachment = nil
                    }
                    try disk.ack(accepted); refreshPending()
                    resumedAttachments.subtract(accepted)
                    finalChunkSentAttachments.subtract(accepted)
                    if let progress = transferProgress, progress.direction == "send", accepted.contains(progress.itemID) {
                        transferProgress = nil
                    }
                    pump()
                case .device: throw SyncProtocolError.format
                case .ping: break
                case .pong:
                    if !pingQueued { pingRequestedAt = nil }
                }
            }
        } catch SyncProtocolError.version { pauseForUpdate() }
        catch SyncProtocolError.identity { fail(reject: true, countBackoff: false, reason: "別のPC") }
        catch SyncProtocolError.authentication where receiver == nil {
            authenticationFailures += 1
            if authenticationFailures >= 3 { pauseForRepair(); return }
            fail(reject: true, countBackoff: false, reason: "接続確認の認証不一致")
        }
        catch {
            let duringHandshake = handshakeStart != nil && status != .connected
            fail(reject: false, countBackoff: duringHandshake, reason: "受信・接続確認失敗")
        }
    }

    private func rememberPushedSnapshot(_ snapshot: LocalTemplateSyncSnapshot, for op: UUID) {
        pendingPushedSnapshots.removeAll { $0.op == op }
        pendingPushedSnapshots.append((op: op, snapshot: snapshot))
        if pendingPushedSnapshots.count > 8 {
            pendingPushedSnapshots.removeFirst(pendingPushedSnapshots.count - 8)
        }
    }

    private func takePushedSnapshot(for op: UUID) -> LocalTemplateSyncSnapshot? {
        guard let index = pendingPushedSnapshots.firstIndex(where: { $0.op == op }) else { return nil }
        return pendingPushedSnapshots.remove(at: index).snapshot
    }

    private func isAwaitingTemplateState(_ op: UUID) -> Bool {
        if let active = activeTemplateSync, active.op == op {
            return active.pushed != nil && !active.isApplying
        }
        return pendingPushedSnapshots.contains { $0.op == op }
    }

    private func handleTemplateMessage(_ message: TemplateSyncMessage, bytes: Int, start: Date, current: Date) throws {
        switch message {
        case .pull(let op):
            guard !inFlightTemplatePulls.contains(op) else { return }
            guard inFlightTemplatePulls.count < 16 else { throw SyncProtocolError.limit }
            inFlightTemplatePulls.insert(op)
            let pairingGen = pairingGeneration
            let sessionGen = sessionGeneration
            monitor.readTemplateSyncSnapshot { [weak self] result in
                guard let self, self.pairingGeneration == pairingGen, self.sessionGeneration == sessionGen else { return }
                self.inFlightTemplatePulls.remove(op)
                guard self.status == .connected else { return }
                switch result {
                case .failure:
                    self.record("テンプレート同期の読み込み失敗")
                    self.fail(reject: false, reason: "テンプレート同期の読み込み失敗")
                case .success(let local):
                    do {
                        let pages = try TemplateSyncMessageCodec.splitPages(op: op, snapshot: local.snapshot, isState: false)
                        self.rememberPushedSnapshot(local, for: op)
                        self.templateOutgoing.append(contentsOf: pages)
                        self.record("テンプレート要求に応答; 件数=\(local.snapshot.templates.count); 墓標=\(local.snapshot.tombstones.count)")
                        self.pump()
                    } catch {
                        self.record("テンプレート同期送信失敗")
                    }
                }
            }
        case .state(let op, _, _, _):
            var reception = templateReception ?? TemplateReception(
                op: op, assembler: TemplateSyncPageAssembler(expectedOp: op, expectedIsState: true), start: start
            )
            reception.bytes += bytes
            guard let snapshot = try reception.assembler.append(message) else {
                templateReception = reception
                if var active = activeTemplateSync, active.op == op {
                    let candidate = current.addingTimeInterval(Self.templateSyncTimeout)
                    let maxDeadline = active.reply.initialSentAt.addingTimeInterval(Self.templateSyncTimeout + Self.maxReplyExtension)
                    let updated = min(candidate, maxDeadline)
                    if updated > active.reply.deadline {
                        active.reply.deadline = updated
                        active.reply.baselineDeadline = updated
                    }
                    activeTemplateSync = active
                }
                return
            }
            try reception.assembler.finish()
            templateReception = nil

            let pushed: LocalTemplateSyncSnapshot?
            if var active = activeTemplateSync, active.op == op {
                active.isApplying = true
                activeTemplateSync = active
                pushed = active.pushed
            } else {
                pushed = takePushedSnapshot(for: op)
            }

            let pairingGen = pairingGeneration
            let sessionGen = sessionGeneration
            monitor.applySyncedTemplates(snapshot, pushed: pushed) { [weak self, totalBytes = reception.bytes, totalStart = reception.start] result in
                guard let self, self.pairingGeneration == pairingGen else { return }
                let completion: (@MainActor (Result<TemplateSyncOutcome, TemplateSyncError>) -> Void)?
                if let active = self.activeTemplateSync, active.op == op, self.sessionGeneration == sessionGen {
                    self.activeTemplateSync = nil
                    self.isSyncingTemplates = false
                    completion = active.completion
                } else {
                    completion = nil
                }
                switch result {
                case .failure:
                    self.record("テンプレート同期保存失敗")
                    if self.sessionGeneration == sessionGen {
                        self.fail(reject: false, reason: "テンプレート同期保存失敗")
                    }
                    completion?(.failure(.saveFailed))
                case .success(let outcome):
                    let excludedCount = outcome.skippedOversizedCount + outcome.skippedOverflowCount
                    self.record("テンプレート同期完了; 追加=\(outcome.added); 更新=\(outcome.updated); 削除=\(outcome.deleted); 反映=\(outcome.pushedToPCCount); 競合写し=\(outcome.conflictCopyCount); 対象外=\(excludedCount); バイト数=\(totalBytes); 所要ms=\(self.milliseconds(since: totalStart))")
                    if let skew = outcome.clockSkewSeconds {
                        self.record("PCとの時刻差を検知; ずれ秒=\(skew)")
                    }
                    if self.status == .connected && self.sessionGeneration == sessionGen {
                        if !self.templateAckQueue.contains(op) {
                            self.templateAckQueue.append(op)
                        }
                        self.pump()
                    }
                    completion?(.success(outcome))
                }
            }
        case .push, .ack:
            throw SyncProtocolError.format
        }
    }
    private func finishIncoming(_ offer: SyncOffer) throws {
        let rxInfo = attachmentReceives.removeValue(forKey: offer.id)
        let url: URL
        do { url = try disk.verified(offer) }
        catch {
            try? disk.discard(offer.id)
            clearReceiveProgress(for: offer.id)
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
                    self.clearReceiveProgress(for: offer.id)
                    self.fail(reject: false, reason: "受信確認保存失敗")
                    return
                }
                self.clearReceiveProgress(for: offer.id)
                if case .rejected(let reason) = outcome {
                    self.record("受信見送り; 理由=\(reason.rawValue); 件数=1")
                } else {
                    let finishNow = self.now()
                    self.lastReceivedAt = finishNow
                    let ms = rxInfo.map { Int(max(0, finishNow.timeIntervalSince($0.startedAt)) * 1000) } ?? 0
                    let transferred = rxInfo.map { max(0, offer.size - $0.startOffset) } ?? offer.size
                    let kbps = ms > 0 ? (Double(transferred) / 1024.0) / (Double(ms) / 1000.0) : 0.0
                    self.record("添付受信完了; バイト数=\(offer.size); 所要ms=\(ms); KB秒=\(String(format: "%.1f", kbps))")
                }
                if self.status == .connected { self.queueAck(offer.id) }
            case .failed:
                try? self.disk.discard(offer.id)
                self.clearReceiveProgress(for: offer.id)
                self.fail(reject: false, reason: "受信履歴保存失敗")
            }
        }
    }
    private func clearReceiveProgress(for id: UUID) {
        if transferProgress?.direction == "receive", transferProgress?.itemID == id {
            transferProgress = nil
        }
    }
    private func queueReply(_ message: SyncMessage) throws {
        try SyncProtocol.require(replies.count < 64, .limit)
        replies.append(message); pump()
    }
    private func queueAck(_ id: UUID) {
        if !ackQueue.contains(id) { ackQueue.append(id) }
        if ackQueue.count > SyncProtocol.maxAckIds * 4 { fail(reject: false, reason: "ack待ち上限"); return }
        pump()
    }
    private func transformReplies(_ transform: (inout PendingReply) -> Void) {
        for id in Array(sentAt.keys) {
            guard var entry = sentAt[id] else { continue }
            transform(&entry)
            sentAt[id] = entry
        }
        if var active = activeAttachment {
            for idx in active.chunks.indices {
                guard var reply = active.chunks[idx].reply else { continue }
                transform(&reply)
                active.chunks[idx].reply = reply
            }
            activeAttachment = active
        }
    }
    private func extendReplyDeadlines(for frameToken: UInt64, at now: Date) {
        let candidate = now.addingTimeInterval(Self.replyTimeout)
        transformReplies { entry in
            if entry.activeFrameToken != frameToken {
                entry.baselineDeadline = entry.deadline
                entry.activeFrameToken = frameToken
            }
            let maxDeadline = entry.initialSentAt.addingTimeInterval(Self.replyTimeout + Self.maxReplyExtension)
            let updated = min(candidate, maxDeadline)
            if updated > entry.deadline {
                entry.deadline = updated
            }
        }
        if var active = activeTemplateSync, !active.isApplying, !active.awaitingSendCompletion {
            let tplCandidate = now.addingTimeInterval(Self.templateSyncTimeout)
            if active.reply.activeFrameToken != frameToken {
                active.reply.baselineDeadline = active.reply.deadline
                active.reply.activeFrameToken = frameToken
            }
            let maxDeadline = active.reply.initialSentAt.addingTimeInterval(Self.templateSyncTimeout + Self.maxReplyExtension)
            let updated = min(tplCandidate, maxDeadline)
            if updated > active.reply.deadline {
                active.reply.deadline = updated
            }
            activeTemplateSync = active
        }
    }
    private func revertReplyExtension(for frameToken: UInt64) {
        transformReplies { entry in
            guard entry.activeFrameToken == frameToken else { return }
            entry.deadline = entry.baselineDeadline
            entry.activeFrameToken = nil
        }
        if var active = activeTemplateSync, active.reply.activeFrameToken == frameToken {
            active.reply.deadline = active.reply.baselineDeadline
            active.reply.activeFrameToken = nil
            activeTemplateSync = active
        }
    }
    private func confirmReplyExtension(for frameToken: UInt64) {
        transformReplies { entry in
            guard entry.activeFrameToken == frameToken else { return }
            entry.baselineDeadline = entry.deadline
            entry.activeFrameToken = nil
        }
        if var active = activeTemplateSync, active.reply.activeFrameToken == frameToken {
            active.reply.baselineDeadline = active.reply.deadline
            active.reply.activeFrameToken = nil
            activeTemplateSync = active
        }
    }
    private func fail(reject: Bool, countBackoff: Bool = false, reason: String) {
        let disconnectReason: PCSyncDisconnectReason = reject ? .rejectTenMinutes : (countBackoff ? .preAuthFailure : .immediate)
        resetSession(); status = pairing == nil ? .unpaired : .searching
        let delay = transport?.reconnect(reason: disconnectReason) ?? 0
        record("切断; 理由=\(reason); 相手を10分無視=\(reject); 再接続待ち秒=\(Int(delay))")
    }
    func checkTimeouts() {
        deleteKeyIfPending()
        let date = now()
        if pairing != nil {
            if historyLoaded, !historyReady {
                pruneWithHistoryIDs(Set(monitor.entries.map(\.id)))
            } else {
                let hadActive = activeAttachment != nil
                do { try disk.prune(now: date); refreshPending() } catch { record("送信待ち保存失敗") }
                if let id = output?.id, !pending.contains(where: { $0.id == id }) {
                    fail(reject: false, reason: "送信中の期限切れ")
                    return
                }
                if hadActive && activeAttachment == nil && status == .connected { pump() }
            }
        }
        if let start = handshakeStart, date.timeIntervalSince(start) > 30 {
            fail(reject: false, countBackoff: true, reason: "接続確認期限")
        } else if let start = partialStart, date.timeIntervalSince(start) > 60 {
            fail(reject: false, countBackoff: handshakeStart != nil && status != .connected, reason: "受信組み立て期限")
        } else if let current = output, date.timeIntervalSince(current.progressed) > 60 {
            fail(reject: false, countBackoff: handshakeStart != nil && status != .connected, reason: "送信停止期限")
        } else if let start = writeBlockedSince, date.timeIntervalSince(start) > 60 {
            fail(reject: false, countBackoff: handshakeStart != nil && status != .connected, reason: "送信準備待ち期限")
        } else if sentAt.values.contains(where: { date > $0.deadline }) ||
                  (activeAttachment?.chunks.contains(where: { chunk in chunk.reply.map { date > $0.deadline } ?? false }) ?? false) {
            fail(reject: false, reason: "ack期限")
        } else if let active = activeTemplateSync, !active.isApplying,
                  !(active.pushed != nil && active.awaitingSendCompletion),
                  date > active.reply.deadline {
            let hasRemainingPages = templateOutgoing.contains { msg in
                if case let .push(op, _, _, _) = msg { return op == active.op }
                return false
            }
            let startedSendingThisOp = output?.templatePushOp == active.op ||
                (active.pushed != nil && hasRemainingPages &&
                 !templateOutgoing.contains { if case let .push(op, part, _, _) = $0 { return op == active.op && part == 0 }; return false })
            activeTemplateSync = nil
            isSyncingTemplates = false
            if templateReception?.op == active.op { templateReception = nil }
            if output?.templatePushOp == active.op || (startedSendingThisOp && hasRemainingPages) {
                fail(reject: false, reason: "テンプレート同期期限")
                active.completion(.failure(.timedOut))
            } else {
                templateOutgoing.removeAll { msg in
                    if case let .push(op, _, _, _) = msg { return op == active.op }
                    return false
                }
                if output == nil && controlFrames.isEmpty && ackQueue.isEmpty && replies.isEmpty &&
                    templateAckQueue.isEmpty && templateOutgoing.isEmpty && !pingQueued && nextPendingItem() == nil {
                    writeBlockedSince = nil
                }
                record("テンプレート同期期限")
                active.completion(.failure(.timedOut))
            }
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
