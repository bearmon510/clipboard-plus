import Combine
import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import ClipboardPlus

private final class SyncStorageSwitch {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    var fails: Bool {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); defer { lock.unlock() }; value = newValue }
    }
}

@MainActor
private final class SyncTestKeys: PCSyncKeyStore {
    var key: Data?
    var fails = false
    var readFails = false
    var reads = 0
    func read() throws -> Data? {
        reads += 1
        if readFails { throw SyncProtocolError.state }
        return key
    }
    func write(_ key: Data) throws {
        if fails { throw SyncProtocolError.state }
        self.key = key
    }
    func delete() throws {
        if fails { throw SyncProtocolError.state }
        key = nil
    }
}

@MainActor
private final class SyncTestClock {
    var date = Date()
}

@MainActor
private final class SyncTestPasteboard: ClipboardPasteboard {
    var changeCount = 0
    var acceptsWrites = true
    private var value: String?
    private var dataValue: (Data, String)?
    private var providers: [NSItemProvider] = []
    var string: String? {
        get { value }
        set { if acceptsWrites { value = newValue; dataValue = nil; providers = []; changeCount += 1 } }
    }
    var hasImages: Bool { dataValue != nil }
    var hasStrings: Bool { value != nil }
    var types: [String] {
        if let type = dataValue?.1 { return [type] }
        if !providers.isEmpty { return providers.flatMap { $0.registeredTypeIdentifiers } }
        return ["public.utf8-plain-text"]
    }
    var image: UIImage? { nil }
    var itemProviders: [NSItemProvider] { providers }
    func writeFileProviders(_ providers: [NSItemProvider]) -> Bool {
        if acceptsWrites { self.providers = providers; value = nil; dataValue = nil; changeCount += 1 }
        return true
    }
    func data(forPasteboardType pasteboardType: String) -> Data? {
        dataValue?.1 == pasteboardType ? dataValue?.0 : nil
    }
    func setData(_ data: Data, forPasteboardType pasteboardType: String) {
        if acceptsWrites { dataValue = (data, pasteboardType); value = nil; providers = []; changeCount += 1 }
    }
}

/// A real protocol peer over a fake, flow-controlled GATT connection.
@MainActor
private final class SyncTestLink: PCSyncTransport {
    var onEvent: ((PCSyncTransportEvent) -> Void)?
    var canSend = true
    var remembered: UUID?
    var starts = 0
    var stops = 0
    var rejected: [Bool] = []
    var retryDelays: [TimeInterval] = []
    var messages: [SyncMessage] = []
    var templateMessages: [TemplateSyncMessage] = []
    var decryptedLog: [String] = []
    var devices: [String] = []
    var packets: [Data] = []
    var authenticatedId: UUID?
    var acceptedPadIds: [UUID] = []
    var corruptWelcome = false
    var welcomeVersion: UInt8?
    var welcomePcId: UUID?
    var rejectHelloWithMismatchVersion: [UInt8: UInt8] = [:]
    var receivedHelloVersions: [UInt8] = []
    var negotiatedVersions: [UInt8] = []
    var dropsNotifications = false
    var stopAfterPackets: Int?
    private var pc: SyncPcHandshake?
    private var currentPairing: SyncPairing?
    private var versionRejectedThisConnection = false
    private var assembler: SyncPacketAssembler?
    private var sender: SyncFrameSender?
    private var receiver: SyncFrameReceiver?
    private(set) var limit = 20
    var id = UUID()
    private var activeId: UUID?
    private var verified = false
    private var policy = PCSyncReconnectPolicy()
    private let now: () -> Date
    var isAppActive = true
    init(now: @escaping () -> Date = Date.init) { self.now = now }
    func start(remembered: UUID?) {
        starts += 1
        self.remembered = remembered
        policy.setRemembered(remembered)
    }
    func stop() {
        stops += 1
        canSend = false
        activeId = nil
        verified = false
        policy.reset()
    }
    func authenticated(_ id: UUID) {
        authenticatedId = id
        verified = true
        remembered = id
        policy.recordAuthenticated(id: id)
    }
    @discardableResult
    func reconnect(reason: PCSyncDisconnectReason) -> TimeInterval {
        let peer = activeId ?? id
        let decision = policy.recordDisconnect(id: peer, reason: reason, isActive: isAppActive, now: now())
        rejected.append(reason == .rejectTenMinutes)
        retryDelays.append(decision.delay)
        canSend = false
        activeId = nil
        verified = false
        onEvent?(.disconnected(nextReconnectAt: decision.nextReconnectAt))
        return decision.delay
    }
    func disconnect() {
        canSend = false
        var nextAt: Date?
        if let peer = activeId, !verified {
            nextAt = policy.recordDisconnect(id: peer, reason: .preAuthFailure, isActive: isAppActive, now: now()).nextReconnectAt
        }
        activeId = nil
        verified = false
        onEvent?(.disconnected(nextReconnectAt: nextAt))
    }
    func simulateBluetoothOff() {
        let hadSession = activeId != nil
        canSend = false
        activeId = nil
        verified = false
        if hadSession { onEvent?(.disconnected(nextReconnectAt: nil)) }
        onEvent?(.status(.bluetoothOff))
    }
    func connect(_ pairing: SyncPairing, limit: Int = 20) throws {
        self.limit = limit
        stopAfterPackets = nil
        currentPairing = pairing
        versionRejectedThisConnection = false
        pc = try SyncPcHandshake(pairing: pairing)
        assembler = try SyncPacketAssembler(packetLimit: limit)
        sender = nil; receiver = nil; canSend = true
        activeId = id; verified = false
        onEvent?(.ready(id: id, writeLimit: limit, receiveLimit: 512))
    }
    func connectWithoutWelcome(limit: Int = 512) {
        self.limit = limit
        stopAfterPackets = nil
        pc = nil; assembler = nil; sender = nil; receiver = nil; canSend = true
        activeId = id; verified = false
        onEvent?(.ready(id: id, writeLimit: limit, receiveLimit: 512))
    }
    func resume() { stopAfterPackets = nil; canSend = true; onEvent?(.writable) }
    func write(_ packet: Data) {
        XCTAssertTrue(canSend)
        XCTAssertLessThanOrEqual(packet.count, limit)
        packets.append(packet)
        if let remaining = stopAfterPackets {
            stopAfterPackets = remaining - 1
            if remaining <= 1 { canSend = false }
        }
        do {
            guard let frame = try assembler?.append(packet), let pc else { return }
            if versionRejectedThisConnection { return }
            if frame.first == 1 {
                if frame.count >= 2 {
                    receivedHelloVersions.append(frame[1])
                }
                if frame.count == 50, let advertisedVersion = rejectHelloWithMismatchVersion[frame[1]] {
                    versionRejectedThisConnection = true
                    let pcId = welcomePcId ?? currentPairing?.pcId ?? UUID()
                    let mismatch = Data([2, advertisedVersion]) + SyncProtocol.idBytes(pcId) + Data(repeating: 0, count: 64)
                    try deliver(mismatch)
                    return
                }
                var welcome = try pc.acceptHello(frame)
                if let welcomePcId { welcome.replaceSubrange(2..<18, with: SyncProtocol.idBytes(welcomePcId)) }
                if let welcomeVersion { welcome[1] = welcomeVersion }
                if corruptWelcome { welcome[welcome.count - 1] ^= 1 }
                try deliver(welcome)
            } else if frame.first == 3 {
                let keys = try pc.acceptAuth(frame)
                sender = try SyncFrameSender(key: keys.pcToPad)
                receiver = try SyncFrameReceiver(key: keys.padToPc)
                if let id = pc.authenticatedPadId { acceptedPadIds.append(id) }
                if let ver = pc.negotiatedVersion { negotiatedVersions.append(ver) }
            } else {
                let receiver = try XCTUnwrap(receiver, "Data must follow AUTH")
                let plaintext = try receiver.open(frame)
                do {
                    let message = try SyncMessageCodec.decode(plaintext)
                    if case .device(let kind) = message {
                        devices.append(kind)
                        decryptedLog.append("device")
                    } else {
                        messages.append(message)
                        if case .item(_, _, _, let text) = message {
                            decryptedLog.append("item:\(text)")
                        } else {
                            decryptedLog.append("sync")
                        }
                    }
                } catch SyncProtocolError.format {
                    let decoded = try TemplateSyncMessageCodec.decode(plaintext)
                    templateMessages.append(decoded)
                    switch decoded {
                    case .pull: decryptedLog.append("tpl_pull")
                    case .push: decryptedLog.append("tpl_push")
                    case .state: decryptedLog.append("tpl_state")
                    case .ack: decryptedLog.append("tpl_ack")
                    }
                }
            }
        } catch { XCTFail("Fake PC protocol failure: \(error)") }
    }
    func seal(_ message: SyncMessage) throws -> Data {
        let sender = try XCTUnwrap(sender)
        return try sender.seal(SyncMessageCodec.encode(message))
    }
    func seal(_ message: TemplateSyncMessage) throws -> Data {
        let sender = try XCTUnwrap(sender)
        return try sender.seal(TemplateSyncMessageCodec.encode(message))
    }
    func sealRawPlaintext(_ plaintext: Data) throws -> Data {
        let sender = try XCTUnwrap(sender)
        return try sender.seal(plaintext)
    }
    func send(_ message: SyncMessage) throws {
        let frame = try seal(message)
        if !dropsNotifications { try deliver(frame) }
    }
    func send(_ message: TemplateSyncMessage) throws {
        let frame = try seal(message)
        if !dropsNotifications { try deliver(frame) }
    }
    func sendInvalidPlaintext() throws {
        let sender = try XCTUnwrap(sender)
        try deliver(sender.seal(Data([0, 1, 0x7B])))
    }
    func sendTamperedFrame() throws {
        let sender = try XCTUnwrap(sender)
        var frame = try sender.seal(SyncMessageCodec.encode(.ping))
        frame[frame.count - 1] ^= 1
        try deliver(frame)
    }
    func deliver(_ frame: Data) throws {
        // Notification and write limits need not match.
        for packet in try SyncPacketizer.split(frame, packetLimit: 182) { onEvent?(.packet(packet)) }
    }
    var items: [SyncMessage] { messages.filter { if case .item = $0 { return true }; return false } }
    var offers: [SyncOffer] {
        messages.compactMap { message -> SyncOffer? in
            if case .offer(let offer) = message { return offer }
            return nil
        }
    }
    var chunks: [(id: UUID, offset: Int, data: Data)] {
        messages.compactMap { message -> (id: UUID, offset: Int, data: Data)? in
            if case let .chunk(id, offset, data) = message { return (id, offset, data) }
            return nil
        }
    }
    var ackIDs: [UUID] {
        messages.flatMap { message -> [UUID] in
            if case .ack(let ids) = message { return ids }
            return []
        }
    }
    var templatePushes: [(op: UUID, part: Int, total: Int, page: TemplateSyncPage)] {
        templateMessages.compactMap { message -> (UUID, Int, Int, TemplateSyncPage)? in
            if case let .push(op, part, total, page) = message { return (op, part, total, page) }
            return nil
        }
    }
    var templateAckOps: [UUID] {
        templateMessages.compactMap { message -> UUID? in
            if case .ack(let op) = message { return op }
            return nil
        }
    }
}

final class PCSyncControllerTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let monitor: ClipboardMonitor
        let controller: PCSyncController
        let keys: SyncTestKeys
        let link: SyncTestLink
        let board: SyncTestPasteboard
        let defaults: UserDefaults
        let root: URL
        let clock = SyncTestClock()
        let storage: SyncStorageSwitch
        var creations: Int { link.starts }
        init(test: XCTestCase, prepaired: SyncPairing? = nil, storageFails: Bool = false,
             readFails: Bool = false, retention: HistoryRetention = .never,
             beforeInit: ((URL, URL) throws -> Void)? = nil,
             databaseClock: (() -> Date)? = nil,
             keyboardContainerURL: @escaping () -> URL? = { SharedAppGroup.containerURL() }) throws {
            root = try ImageTestSupport.directory(test)
            let suite = UUID().uuidString
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let defaults = self.defaults
            test.addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
            retention.save(to: defaults)
            let clock = self.clock
            keys = SyncTestKeys(); keys.readFails = readFails
            link = SyncTestLink(now: { clock.date }); board = SyncTestPasteboard()
            storage = SyncStorageSwitch(storageFails)
            if let prepaired {
                try keys.write(prepaired.key)
                PCSyncSettings(defaults: defaults).save(prepaired)
            }
            let databaseURL = root.appendingPathComponent("history.sqlite")
            let imageDirectory = root.appendingPathComponent("images")
            let syncDirectory = imageDirectory.appendingPathComponent("PCSync-v2", isDirectory: true)
            try beforeInit?(databaseURL, syncDirectory)
            let log = MeasurementLog(writer: MeasurementLogWriter(fileURL: root.appendingPathComponent("log.tsv")))
            log.includeTextPreview = true
            let storage = self.storage
            monitor = ClipboardMonitor(defaults: defaults, log: log,
                makeDatabase: {
                    if storage.fails { throw CocoaError(.fileWriteOutOfSpace) }
                    return try HistoryDatabase(url: databaseURL, now: databaseClock ?? Date.init)
                }, schedulesMaintenance: false,
                imageDirectory: imageDirectory, pasteboard: board,
                resumesRecordingOnInit: false,
                keyboardContainerURL: keyboardContainerURL)
            let link = self.link
            controller = PCSyncController(monitor: monitor, defaults: defaults, keyStore: keys,
                now: { clock.date }, schedulesTimeouts: false, makeTransport: { _ in link })
        }
    }
    @MainActor
    private func drain(_ fixture: Fixture) async {
        for _ in 0..<2 {
            let done = expectation(description: "history and sync preparation committed")
            fixture.monitor.pendingDeletion { _ in
                fixture.monitor.log.flush(context: fixture.monitor.logContext()) { done.fulfill() }
            }
            await fulfillment(of: [done], timeout: 5)
        }
    }
    @MainActor
    private func awaitSave(_ fixture: Fixture, savedCount: Int, timeout: TimeInterval = 15) async {
        if fixture.monitor.savedCount < savedCount {
            let done = expectation(description: "saved \(savedCount)")
            let cancellable = fixture.monitor.$savedCount.first { $0 >= savedCount }.sink { _ in done.fulfill() }
            await fulfillment(of: [done], timeout: timeout)
            cancellable.cancel()
        }
        await drain(fixture)
    }
    @MainActor
    private func pair(_ fixture: Fixture) throws -> SyncPairing {
        let pairing = try SyncPairing.create(name: "試験PC")
        try fixture.controller.pair(code: pairing.qrString())
        return pairing
    }
    private func itemID(_ message: SyncMessage) throws -> UUID {
        guard case .item(let id, _, _, _) = message else { throw SyncProtocolError.format }
        return id
    }

    @MainActor
    func testPairingValidationLazyBluetoothStorageAndUnpair() async throws {
        let f = try Fixture(test: self)
        XCTAssertEqual(f.controller.status, .unpaired)
        XCTAssertEqual(f.creations, 0)
        XCTAssertEqual(f.keys.reads, 0, "Unpaired initialization must not call Keychain")
        XCTAssertTrue(f.controller.copiesReceivedToPasteboard)
        f.controller.copiesReceivedToPasteboard = false
        XCTAssertFalse(PCSyncSettings(defaults: f.defaults).copiesReceivedToPasteboard)
        for code in ["broken", "", "clipboardplus-pair:1:broken"] {
            XCTAssertThrowsError(try f.controller.pair(code: code)) {
                XCTAssertFalse(($0 as? PCSyncPairError)?.message.isEmpty ?? true)
            }
        }
        XCTAssertEqual(f.creations, 0)
        let pairing = try pair(f)
        XCTAssertEqual(f.keys.key, pairing.key)
        XCTAssertEqual(f.controller.pcName, pairing.name)
        XCTAssertEqual(f.creations, 1)
        XCTAssertThrowsError(try f.controller.pair(code: pairing.qrString() + " "))
        XCTAssertEqual(f.controller.pcName, pairing.name)
        let pad = PCSyncSettings(defaults: f.defaults).padId
        f.controller.unpair()
        XCTAssertNil(f.keys.key)
        XCTAssertNil(f.controller.pcName)
        XCTAssertEqual(f.controller.status, .unpaired)
        XCTAssertEqual(f.link.stops, 1)
        XCTAssertEqual(PCSyncSettings(defaults: f.defaults).padId, pad)
        XCTAssertNil(try PCSyncSettings(defaults: f.defaults).load(key: pairing.key))
    }

    @MainActor
    func testStoredPairingStartsAutomaticallyAndAuthenticatesFreshSessions() async throws {
        let pairing = try SyncPairing.create(name: "PC")
        let f = try Fixture(test: self, prepaired: pairing)
        XCTAssertEqual(f.creations, 1)
        try f.link.connect(pairing)
        XCTAssertEqual(f.controller.status, .connected)
        XCTAssertEqual(PCSyncSettings(defaults: f.defaults).peripheralId, f.link.id)
        let firstHello = Array(f.link.packets.prefix(3))
        f.link.disconnect(); f.link.packets.removeAll()
        try f.link.connect(pairing)
        XCTAssertEqual(f.link.acceptedPadIds.count, 2)
        XCTAssertEqual(f.link.acceptedPadIds.first, f.link.acceptedPadIds.last)
        XCTAssertNotEqual(firstHello, Array(f.link.packets.prefix(3)))
    }

    @MainActor
    func testHandshakeFailureRejectsPeerAndNeverSendsPendingText() async throws {
        let f = try Fixture(test: self)
        let pairing = try pair(f)
        f.monitor.saveManually(["pending"], receivedAt: Date())
        f.link.corruptWelcome = true
        try f.link.connect(pairing)
        XCTAssertEqual(f.link.rejected, [true])
        XCTAssertNil(PCSyncSettings(defaults: f.defaults).peripheralId)
        XCTAssertTrue(f.link.items.isEmpty)
        await drain(f)
    }

    @MainActor
    func testSendAckFlowControlReconnectAndRepeatedCollection() async throws {
        let f = try Fixture(test: self)
        let pairing = try pair(f)
        try f.link.connect(pairing, limit: 20)
        f.link.stopAfterPackets = 2
        let text = String(repeating: "文章", count: 80)
        f.monitor.saveManually([text], receivedAt: Date())
        XCTAssertTrue(f.link.items.isEmpty)
        await drain(f)
        f.link.resume()
        XCTAssertEqual(f.link.items.count, 1)
        let sent = try XCTUnwrap(f.link.items.first)
        let id = try itemID(sent)
        f.link.disconnect()
        try f.link.connect(pairing)
        XCTAssertEqual(f.link.items, [sent, sent])
        try f.link.send(.ack(ids: [id]))
        f.link.disconnect(); try f.link.connect(pairing)
        XCTAssertEqual(f.link.items.count, 2, "ACK removes the retry")
        f.monitor.saveManually([text], receivedAt: Date())
        await drain(f)
        XCTAssertEqual(f.link.items.count, 3)
        XCTAssertNotEqual(try itemID(f.link.items[2]), id)
        XCTAssertNotNil(f.controller.lastSentAt)
        await drain(f)
        XCTAssertEqual(f.monitor.entries.first?.collectionCount, 2)
    }

    @MainActor
    func testReceivedTextIsPCSourceDeduplicatedNotEchoedOrCollectedTwice() async throws {
        let f = try Fixture(test: self)
        let pairing = try pair(f)
        try f.link.connect(pairing)
        f.monitor.updateScene("active"); f.monitor.start()
        defer { f.monitor.stop() }
        let secret = "受信内容SECRET-should-never-appear"
        let id = UUID()
        let message = SyncMessage.item(id: id, at: 0, from: "pc", text: secret)
        try f.link.send(message)
        try f.link.send(message) // Duplicate while the original write is in flight.
        XCTAssertFalse(f.link.ackIDs.contains(id), "ACK must follow storage commit")
        await drain(f)
        XCTAssertEqual(f.monitor.entries.count, 1)
        XCTAssertEqual(f.monitor.entries.first?.source, .pc)
        XCTAssertEqual(f.monitor.entries.first?.collectionCount, 1)
        XCTAssertEqual(f.board.string, secret)
        XCTAssertTrue(f.link.ackIDs.contains(id))
        f.monitor.pollPasteboard()
        try f.link.send(message)
        await drain(f)
        XCTAssertEqual(f.monitor.entries.first?.collectionCount, 1)
        XCTAssertTrue(f.link.items.isEmpty)
        XCTAssertNotNil(f.controller.lastReceivedAt)
        let log = try String(contentsOf: f.root.appendingPathComponent("log.tsv"), encoding: .utf8)
        XCTAssertFalse(log.contains("受信内容SECRET"))
        XCTAssertFalse(log.contains(pairing.key.base64EncodedString()))
        XCTAssertFalse(log.contains(pairing.pcId.uuidString))
        XCTAssertFalse(log.contains(id.uuidString))
        // A NEW item with identical text is a real collection, not an ID replay.
        try f.link.send(.item(id: UUID(), at: 1, from: "pc", text: secret))
        await drain(f)
        XCTAssertEqual(f.monitor.entries.first?.collectionCount, 2)
        // Universal Clipboard readback stays suppressed, including a later foreground read.
        f.board.string = secret; f.monitor.pollPasteboard(); await drain(f)
        XCTAssertEqual(f.monitor.entries.first?.collectionCount, 2)
        XCTAssertEqual(f.link.items.count, 0)
        f.board.string = "different"; f.monitor.pollPasteboard(); await drain(f)
        f.board.string = secret; f.monitor.pollPasteboard(); await drain(f)
        XCTAssertEqual(f.monitor.entries.first { $0.text == secret }?.collectionCount, 3)
        XCTAssertEqual(f.link.items.count, 2)
    }

    @MainActor
    func testRemoteHistoryAndTemplateCardsDoNotEchoLocalCardsDo() async throws {
        let f = try Fixture(test: self)
        let pairing = try pair(f)
        try f.link.connect(pairing)
        try f.link.send(.item(id: UUID(), at: 0, from: "pc", text: "PCのカード"))
        await drain(f)
        f.monitor.copy(try XCTUnwrap(f.monitor.entries.first))
        XCTAssertTrue(f.link.items.isEmpty)
        f.monitor.saveManually(["ローカルカード"], receivedAt: Date())
        await drain(f)
        let local = try XCTUnwrap(f.monitor.entries.first { $0.text == "ローカルカード" })
        f.monitor.copy(local)
        let done = expectation(description: "template")
        f.monitor.createTemplate(text: "定型文", title: nil, tag: nil) { result in
            if case .success(let entry) = result { f.monitor.copy(entry) } else { XCTFail("Template failed") }
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5)
        await drain(f)
        XCTAssertEqual(f.link.items.count, 3)
    }

    @MainActor
    func testQueueKeepsNewestHundredAndClearsOnUnpair() async throws {
        let f = try Fixture(test: self)
        let pairing = try pair(f)
        for index in 0..<102 { f.monitor.saveManually(["item \(index)"], receivedAt: Date()) }
        await drain(f)
        try f.link.connect(pairing)
        XCTAssertEqual(f.link.items.count, 100)
        if case .item(_, _, _, let text) = f.link.items[0] { XCTAssertEqual(text, "item 2") }
        f.controller.unpair()
        try f.controller.pair(code: pairing.qrString())
        try f.link.connect(pairing)
        XCTAssertEqual(f.link.items.count, 100)
        await drain(f)
    }

    @MainActor
    func testReceiveSettingAndRefusedBackgroundWriteStillSaveAndAck() async throws {
        let f = try Fixture(test: self)
        let pairing = try pair(f)
        try f.link.connect(pairing)
        f.controller.copiesReceivedToPasteboard = false
        f.monitor.updateScene("active")
        try f.link.send(.item(id: UUID(), at: 0, from: "pc", text: "設定OFF"))
        await drain(f)
        XCTAssertNil(f.board.string)
        f.controller.copiesReceivedToPasteboard = true
        f.monitor.updateScene("background")
        f.board.acceptsWrites = false
        try f.link.send(.item(id: UUID(), at: 0, from: "pc", text: "背景受信"))
        await drain(f)
        XCTAssertNil(f.board.string)
        XCTAssertEqual(f.monitor.entries.count, 2)
        XCTAssertEqual(f.link.ackIDs.count, 2)
        let log = try String(contentsOf: f.root.appendingPathComponent("log.tsv"), encoding: .utf8)
        XCTAssertTrue(log.contains("書き込みを確認できず"))
        f.board.acceptsWrites = true
        try f.link.send(.item(id: UUID(), at: 0, from: "pc", text: "背景で書ける場合"))
        await drain(f)
        XCTAssertEqual(f.board.string, "背景で書ける場合")
        f.monitor.updateScene("active"); f.monitor.start()
        defer { f.monitor.stop() }
        f.monitor.pollPasteboard(); await drain(f)
        XCTAssertEqual(f.monitor.entries.count, 3)
        XCTAssertTrue(f.link.items.isEmpty)
    }

    @MainActor
    func testMalformedPacketDisconnectsAndFailedKeyDeletionRetries() async throws {
        let f = try Fixture(test: self)
        let pairing = try pair(f)
        try f.link.connect(pairing)
        f.link.onEvent?(.packet(Data([0, 1])))
        XCTAssertEqual(f.link.rejected, [false])
        f.keys.fails = true
        f.controller.unpair()
        XCTAssertTrue(PCSyncSettings(defaults: f.defaults).deletionPending)
        XCTAssertNil(try PCSyncSettings(defaults: f.defaults).load(key: pairing.key))
        f.keys.fails = false
        f.controller.checkTimeouts()
        XCTAssertNil(f.keys.key)
        XCTAssertFalse(PCSyncSettings(defaults: f.defaults).deletionPending)
    }

    @MainActor
    func testTimeoutsDiscardIncompleteFramesAndRetryUnackedItems() async throws {
        let f = try Fixture(test: self)
        let pairing = try pair(f)
        try f.link.connect(pairing)
        f.monitor.saveManually(["ack待ち"], receivedAt: Date())
        await drain(f)
        let item = try XCTUnwrap(f.link.items.first)
        f.clock.date.addTimeInterval(61)
        f.controller.checkTimeouts()
        XCTAssertEqual(f.link.rejected, [false])
        try f.link.connect(pairing)
        XCTAssertEqual(f.link.items, [item, item])
        try f.link.send(.ack(ids: [try itemID(item)]))
        f.link.onEvent?(.packet(Data([1, 0x10, 0])))
        f.clock.date.addTimeInterval(61)
        f.controller.checkTimeouts()
        XCTAssertEqual(f.link.rejected, [false, false])
        try f.link.connect(pairing)
        f.link.canSend = false
        f.monitor.saveManually(["書き込み待ち"], receivedAt: Date())
        await drain(f)
        f.clock.date.addTimeInterval(61)
        f.controller.checkTimeouts()
        XCTAssertEqual(f.link.rejected, [false, false, false])
        await drain(f)
    }

    @MainActor
    func testUnpairedEventsAndFailedKeyWriteNeverStartBluetooth() async throws {
        let f = try Fixture(test: self)
        f.monitor.saveManually(["組にする前"], receivedAt: Date())
        let pairing = try SyncPairing.create(name: "PC")
        f.keys.fails = true
        XCTAssertThrowsError(try f.controller.pair(code: pairing.qrString())) {
            XCTAssertNotNil($0 as? PCSyncPairError)
        }
        XCTAssertEqual(f.creations, 0)
        XCTAssertNil(f.controller.pcName)
        f.keys.fails = false
        try f.controller.pair(code: pairing.qrString())
        try f.link.connect(pairing)
        XCTAssertTrue(f.link.items.isEmpty)
        await drain(f)
    }

    @MainActor
    func testLinksAppearInShortcutsAndExportsContainOnlyHistory() async throws {
        let f = try Fixture(test: self)
        let pairing = try pair(f)
        try f.link.connect(pairing)
        try f.link.send(.item(id: UUID(), at: 0, from: "pc", text: "https://example.com/path"))
        await drain(f)
        let entry = try XCTUnwrap(f.monitor.entries.first)
        XCTAssertEqual(entry.kind, .url)
        XCTAssertEqual(entry.source, .pc)
        XCTAssertEqual(ShortcutContent.entries(f.monitor.entries, filter: .links), [entry])
        XCTAssertEqual(HistoryEntryEntity(entry: entry).text, entry.text)
        let json = try HistoryExport.data(entries: f.monitor.entries, exportedAt: Date())
        let text = try XCTUnwrap(String(data: json, encoding: .utf8))
        XCTAssertFalse(text.contains(pairing.pcId.uuidString))
        XCTAssertFalse(text.contains(pairing.key.base64EncodedString()))
        XCTAssertFalse(text.contains(PCSyncSettings(defaults: f.defaults).padId.uuidString))
        XCTAssertFalse(text.contains(f.link.id.uuidString))
        XCTAssertFalse(text.contains("pcSync"))
    }

    @MainActor
    func testReceiveDeduplicationKeepsTheLatestFiveHundredIDs() async throws {
        let f = try Fixture(test: self)
        let pairing = try pair(f)
        try f.link.connect(pairing)
        f.controller.copiesReceivedToPasteboard = false
        let ids = (0..<501).map { _ in UUID() }
        for start in stride(from: 0, to: ids.count, by: 25) {
            for id in ids[start..<min(start + 25, ids.count)] {
                try f.link.send(.item(id: id, at: 0, from: "pc", text: "同じ本文"))
            }
            await drain(f)
        }
        XCTAssertEqual(f.monitor.entries.first?.collectionCount, 501)
        try f.link.send(.item(id: ids[500], at: 0, from: "pc", text: "同じ本文"))
        await drain(f)
        XCTAssertEqual(f.monitor.entries.first?.collectionCount, 501)
        try f.link.send(.item(id: ids[0], at: 0, from: "pc", text: "同じ本文"))
        await drain(f)
        XCTAssertEqual(f.monitor.entries.first?.collectionCount, 502)
    }

    @MainActor
    func testUnpairDuringSaveDoesNotWritePasteboardOrSendAckToNewPairing() async throws {
        let f = try Fixture(test: self)
        let pairing = try pair(f)
        try f.link.connect(pairing)
        f.monitor.updateScene("active")
        let id = UUID()
        try f.link.send(.item(id: id, at: 0, from: "pc", text: "解除前の受信"))
        f.controller.unpair()
        try f.controller.pair(code: pairing.qrString())
        try f.link.connect(pairing)
        await drain(f)
        XCTAssertNil(f.board.string)
        XCTAssertFalse(f.link.ackIDs.contains(id))
    }

    @MainActor
    func testFailedHistoryCommitDoesNotAckOrWritePasteboard() async throws {
        let f = try Fixture(test: self, storageFails: true)
        let pairing = try pair(f)
        try f.link.connect(pairing)
        f.monitor.updateScene("active")
        let id = UUID()
        try f.link.send(.item(id: id, at: 0, from: "pc", text: "保存に失敗する文章"))
        await drain(f)
        XCTAssertFalse(f.link.ackIDs.contains(id))
        XCTAssertEqual(f.link.rejected, [false])
        XCTAssertNil(f.board.string)
        XCTAssertEqual(f.monitor.pendingSaveCount, 0)
        XCTAssertNotNil(f.monitor.storageError)
    }

    @MainActor
    func testDecryptionMessageAndIdentityFailuresDisconnect() async throws {
        let f = try Fixture(test: self)
        let pairing = try pair(f)
        try f.link.connect(pairing)
        try f.link.sendTamperedFrame()
        XCTAssertEqual(f.link.rejected, [false])
        try f.link.connect(pairing)
        try f.link.sendInvalidPlaintext()
        XCTAssertEqual(f.link.rejected, [false, false])
        let differentPC = try SyncPairing(pcId: UUID(), key: pairing.key, name: pairing.name)
        try f.link.connect(differentPC)
        XCTAssertEqual(f.link.rejected, [false, false, true])
        XCTAssertTrue(f.link.items.isEmpty)
    }

    @MainActor
    func testIdleProbeDetectsLostFirstNotificationAndReconnects() async throws {
        let f = try Fixture(test: self)
        let pairing = try pair(f)
        try f.link.connect(pairing)
        // AUTH is sent, but Windows' first encrypted notification never reaches iPad.
        f.link.dropsNotifications = true
        try f.link.send(.pong)
        f.clock.date.addTimeInterval(29); f.controller.checkTimeouts()
        XCTAssertTrue(f.link.messages.isEmpty)
        f.clock.date.addTimeInterval(1); f.controller.checkTimeouts()
        XCTAssertEqual(f.link.messages, [.ping])
        f.clock.date.addTimeInterval(9); f.controller.checkTimeouts()
        XCTAssertEqual(f.controller.status, .connected)
        f.clock.date.addTimeInterval(1); f.controller.checkTimeouts()
        XCTAssertEqual(f.link.rejected, [false])
        XCTAssertEqual(f.controller.status, .searching)
        f.link.dropsNotifications = false
        try f.link.connect(pairing)
        f.clock.date.addTimeInterval(30); f.controller.checkTimeouts()
        try f.link.send(.pong)
        f.clock.date.addTimeInterval(10); f.controller.checkTimeouts()
        XCTAssertEqual(f.controller.status, .connected)
        XCTAssertEqual(f.link.rejected, [false])
    }

    @MainActor
    func testTrafficDefersPingButOnlyPongSatisfiesProbeAndPingDoesNotEcho() async throws {
        let f = try Fixture(test: self)
        let pairing = try pair(f)
        try f.link.connect(pairing)
        f.clock.date.addTimeInterval(20)
        try f.link.send(.ping)
        XCTAssertTrue(f.link.messages.isEmpty, "iPad must not answer ping")
        f.clock.date.addTimeInterval(29); f.controller.checkTimeouts()
        XCTAssertTrue(f.link.messages.isEmpty)
        f.clock.date.addTimeInterval(1); f.controller.checkTimeouts()
        XCTAssertEqual(f.link.messages, [.ping])
        f.clock.date.addTimeInterval(9)
        try f.link.send(.ping)
        f.controller.checkTimeouts()
        XCTAssertEqual(f.link.messages, [.ping])
        f.clock.date.addTimeInterval(1); f.controller.checkTimeouts()
        XCTAssertEqual(f.link.rejected, [false])
    }

    @MainActor
    func testPongResetsProbeAndDisconnectedSessionDiscardsItsDeadline() async throws {
        let f = try Fixture(test: self)
        let pairing = try pair(f)
        try f.link.connect(pairing)
        f.clock.date.addTimeInterval(30); f.controller.checkTimeouts()
        f.clock.date.addTimeInterval(9); try f.link.send(.pong)
        f.clock.date.addTimeInterval(29); f.controller.checkTimeouts()
        XCTAssertEqual(f.link.messages, [.ping])
        f.clock.date.addTimeInterval(1); f.controller.checkTimeouts()
        XCTAssertEqual(f.link.messages, [.ping, .ping])
        f.link.disconnect(); try f.link.connect(pairing)
        f.clock.date.addTimeInterval(10); f.controller.checkTimeouts()
        XCTAssertEqual(f.controller.status, .connected)
        XCTAssertTrue(f.link.rejected.isEmpty)
    }

    @MainActor
    func testWritesNeverExceed512EvenWhenTransportReportsLargerLimit() async throws {
        for limit in [511, 512, 514] {
            let f = try Fixture(test: self)
            let pairing = try pair(f)
            try f.link.connect(pairing, limit: limit)
            f.link.packets.removeAll()
            f.monitor.saveManually([String(repeating: "x", count: 2000)], receivedAt: Date())
            await drain(f)
            XCTAssertEqual(f.link.packets.map(\.count).max(), min(limit, 512))
            XCTAssertEqual(f.link.items.count, 1)
            await drain(f)
        }
    }

    @MainActor
    func testVersionMismatchStopsReconnectUntilExplicitRetry() async throws {
        let f = try Fixture(test: self), pairing = try pair(f)
        f.link.welcomeVersion = 1
        try f.link.connect(pairing)
        XCTAssertTrue(f.controller.requiresPeerUpdate)
        XCTAssertNotNil(f.controller.compatibilityMessage)
        XCTAssertEqual(f.link.stops, 1)
        f.clock.date.addTimeInterval(600); f.controller.checkTimeouts()
        XCTAssertEqual(f.link.starts, 1)
        f.link.welcomeVersion = nil; f.controller.retryAfterPeerUpdate(); try f.link.connect(pairing)
        XCTAssertEqual(f.controller.status, .connected)
        XCTAssertEqual(f.link.devices.count, 1)
    }

    @MainActor
    func testRemoteFileResumesAndPreservesCopyTimestampWithoutEcho() async throws {
        let f = try Fixture(test: self), pairing = try pair(f)
        try f.link.connect(pairing, limit: 512)
        f.controller.copiesReceivedToPasteboard = false
        let data = Data(repeating: 21, count: SyncProtocol.chunkBytes + 3)
        let offer = SyncOffer(id: UUID(), at: 1_700_000_000_123, from: "pc", kind: "file", size: data.count,
            sha256: SyncEchoGuard.hash(data), name64: Data("秘密のファイル.txt".utf8).base64EncodedString(), type: "public.data")
        try f.link.send(.offer(offer))
        XCTAssertEqual(f.link.messages.last, .resume(id: offer.id, offset: 0))
        try f.link.send(.chunk(id: offer.id, offset: 0, data: data.prefix(SyncProtocol.chunkBytes)))
        XCTAssertFalse(f.link.ackIDs.contains(offer.id))
        f.link.disconnect(); try f.link.connect(pairing)
        try f.link.send(.offer(offer))
        XCTAssertEqual(f.link.messages.last, .resume(id: offer.id, offset: SyncProtocol.chunkBytes))
        try f.link.send(.chunk(id: offer.id, offset: SyncProtocol.chunkBytes, data: data.suffix(3)))
        await drain(f)
        let entry = try XCTUnwrap(f.monitor.entries.first)
        XCTAssertEqual(entry.kind, .file); XCTAssertEqual(entry.source, .pc)
        XCTAssertEqual(entry.lastCollectedAt.timeIntervalSince1970, Double(offer.at) / 1000, accuracy: 0.001)
        let file = try XCTUnwrap(entry.file)
        XCTAssertEqual(try Data(contentsOf: f.monitor.fileURL(file)), data)
        XCTAssertTrue(f.link.ackIDs.contains(offer.id)); XCTAssertEqual(f.controller.pendingCount, 0)
        let log = try String(contentsOf: f.root.appendingPathComponent("log.tsv"), encoding: .utf8)
        XCTAssertFalse(log.contains("秘密のファイル")); XCTAssertFalse(log.contains(offer.sha256))
    }

    @MainActor
    func testCapturedImageAndCopiedImageCardAreQueuedAndDeletedHistoryIsRemoved() async throws {
        let f = try Fixture(test: self), pairing = try pair(f)
        await drain(f)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        f.monitor.saveCaptured(pngData: try XCTUnwrap(image.pngData()))
        await drain(f)
        XCTAssertEqual(f.controller.pendingCount, 1)
        let entry = try XCTUnwrap(f.monitor.entries.first)
        let copied = expectation(description: "copy image")
        f.monitor.copy(entry) { _ in copied.fulfill() }
        await fulfillment(of: [copied], timeout: 5); await drain(f)
        XCTAssertEqual(f.controller.pendingCount, 2)
        try f.link.connect(pairing)
        let offers = f.link.offers
        XCTAssertEqual(offers.count, 1)
        XCTAssertEqual(offers.first?.kind, "image")
        XCTAssertEqual(offers.first?.type, "public.png")
        let removed = expectation(description: "delete queued history")
        f.monitor.delete(entry) { _ in removed.fulfill() }
        await fulfillment(of: [removed], timeout: 5); await drain(f)
        XCTAssertEqual(f.controller.pendingCount, 0)
    }

    private static let oversizedPng: Result<Data, Error> = Result {
        try makeGrayImageData(width: 10_000, height: 4_001, type: .png)
    }

    private static func makeGrayImageData(width: Int, height: Int, type: UTType) throws -> Data {
        let bytes = Data(count: width * height)
        let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
        let cgImage = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output as CFMutableData, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cgImage, nil)
        try SyncProtocol.require(CGImageDestinationFinalize(destination), .format)
        return output as Data
    }

    private func makeFileProvider(in root: URL, bytes: Data, name: String = "item.bin", type: String = "public.data") throws -> NSItemProvider {
        let url = root.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: url)
        let provider = NSItemProvider()
        provider.suggestedName = name
        provider.registerFileRepresentation(forTypeIdentifier: type, fileOptions: [], visibility: .all) { completion in
            completion(url, false, nil)
            return nil
        }
        return provider
    }

    private func makeImageProvider(data: Data, type: String) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: type, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    @MainActor
    func testPreHelloDisconnectsDoNotPauseSync() async throws {
        let f = try Fixture(test: self), pairing = try pair(f)
        for _ in 0..<3 {
            f.link.onEvent?(.status(.connecting))
            f.link.disconnect()
        }
        XCTAssertFalse(f.controller.requiresPeerUpdate)
        XCTAssertEqual(f.controller.status, .searching)
        XCTAssertEqual(f.link.stops, 0)
        try f.link.connect(pairing)
        XCTAssertEqual(f.controller.status, .connected)
    }

    @MainActor
    func testIdentityMismatchDoesNotPauseSyncAndRejectsOnlyWrongPeer() async throws {
        let f = try Fixture(test: self), pairing = try pair(f)
        let differentPC = try SyncPairing(pcId: UUID(), key: pairing.key, name: pairing.name)
        for _ in 0..<3 {
            try f.link.connect(differentPC)
        }
        XCTAssertEqual(f.link.rejected, [true, true, true])
        XCTAssertFalse(f.controller.requiresPeerUpdate)
        XCTAssertEqual(f.controller.status, .searching)
        XCTAssertEqual(f.link.stops, 0)
        try f.link.connect(pairing)
        XCTAssertEqual(f.controller.status, .connected)
    }

    @MainActor
    func testHandshakeTimeoutsAndDisconnectsBackOffWithoutStoppingWhileRepeatedHmacMismatchRequiresRepair() async throws {
        // 1. Repeated HMAC mismatch with matching paired PC ID stops with requiresRepair (not requiresPeerUpdate).
        let f1 = try Fixture(test: self), pairing1 = try pair(f1)
        f1.link.corruptWelcome = true
        for _ in 0..<2 {
            try f1.link.connect(pairing1)
            XCTAssertFalse(f1.controller.requiresPeerUpdate)
            XCTAssertFalse(f1.controller.requiresRepair)
        }
        try f1.link.connect(pairing1)
        XCTAssertTrue(f1.controller.requiresRepair)
        XCTAssertFalse(f1.controller.requiresPeerUpdate)
        XCTAssertEqual(f1.controller.compatibilityMessage, "PCとの組が一致しません。PCのQRコードを読み直して組み直してください")
        XCTAssertEqual(f1.controller.status, .unsupported)
        XCTAssertEqual(f1.link.stops, 1)
        XCTAssertEqual(f1.link.rejected, [true, true])

        f1.link.corruptWelcome = false
        f1.controller.retryAfterRepair()
        XCTAssertFalse(f1.controller.requiresRepair)
        XCTAssertNil(f1.controller.compatibilityMessage)
        try f1.link.connect(pairing1)
        XCTAssertEqual(f1.controller.status, .connected)

        // 2. Handshake timeouts (no WELCOME / blocked write) never stop sync; they back off and reset on auth.
        let f2 = try Fixture(test: self), pairing2 = try pair(f2)
        f2.monitor.saveManually(["再接続後に送る項目"], receivedAt: f2.clock.date)
        await drain(f2)
        for _ in 0..<6 {
            f2.link.connectWithoutWelcome()
            f2.clock.date.addTimeInterval(31)
            f2.controller.checkTimeouts()
            XCTAssertFalse(f2.controller.requiresPeerUpdate)
            XCTAssertFalse(f2.controller.requiresRepair)
            XCTAssertEqual(f2.controller.status, .searching)
            XCTAssertEqual(f2.link.stops, 0)
        }
        XCTAssertEqual(f2.link.rejected, [false, false, false, false, false, false])
        XCTAssertEqual(f2.link.retryDelays, [0, 30, 120, 300, 600, 600])
        XCTAssertEqual(f2.controller.nextReconnectAt, f2.clock.date.addingTimeInterval(600))

        f2.clock.date.addTimeInterval(600)
        try f2.link.connect(pairing2)
        XCTAssertEqual(f2.controller.status, .connected)
        XCTAssertNil(f2.controller.nextReconnectAt)
        XCTAssertEqual(f2.link.items.count, 1)
        try f2.link.send(.ack(ids: [try itemID(try XCTUnwrap(f2.link.items.first))]))

        // After successful authentication, the next handshake timeout starts back at delay 0.
        f2.link.disconnect()
        f2.link.connectWithoutWelcome()
        f2.clock.date.addTimeInterval(31)
        f2.controller.checkTimeouts()
        XCTAssertEqual(f2.link.retryDelays.last, 0)

        // 3. Pre-auth disconnects (before WELCOME) advance backoff without stopping and reset on auth.
        let f3 = try Fixture(test: self), pairing3 = try pair(f3)
        for _ in 0..<3 {
            f3.link.connectWithoutWelcome()
            f3.link.disconnect()
        }
        XCTAssertFalse(f3.controller.requiresPeerUpdate)
        XCTAssertFalse(f3.controller.requiresRepair)
        XCTAssertEqual(f3.controller.nextReconnectAt, f3.clock.date.addingTimeInterval(120))
        try f3.link.connect(pairing3)
        XCTAssertEqual(f3.controller.status, .connected)
        XCTAssertNil(f3.controller.nextReconnectAt)
    }

    @MainActor
    func testOversizedPngAndJpegAreNotQueuedOrSentToPC() async throws {
        let f = try Fixture(test: self), pairing = try pair(f)
        try f.link.connect(pairing, limit: 512)
        let bigPng = try Self.oversizedPng.get()
        let bigJpeg = try Self.makeGrayImageData(width: 10_000, height: 4_001, type: .jpeg)
        f.monitor.saveManually([makeImageProvider(data: bigPng, type: "public.png")], receivedAt: f.clock.date)
        await awaitSave(f, savedCount: 1)
        f.monitor.saveManually([makeImageProvider(data: bigJpeg, type: "public.jpeg")], receivedAt: f.clock.date.addingTimeInterval(1))
        await awaitSave(f, savedCount: 2)
        XCTAssertEqual(f.monitor.entries.count, 2)
        XCTAssertEqual(f.controller.pendingCount, 0)
        XCTAssertTrue(f.link.messages.isEmpty)
        let log = try String(contentsOf: f.root.appendingPathComponent("log.tsv"), encoding: .utf8)
        XCTAssertTrue(log.contains("送信見送り"))
    }

    @MainActor
    func testRejectedIncomingImagesDiscardPartialMarkSeenLogReasonAndAck() async throws {
        let f = try Fixture(test: self), pairing = try pair(f)
        try f.link.connect(pairing, limit: 512)
        f.controller.copiesReceivedToPasteboard = false

        let bigPng = try Self.oversizedPng.get()
        let smallJpeg = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }.jpegData(compressionQuality: 0.8))
        let corruptBytes = Data("not-a-valid-image".utf8)

        let cases: [(data: Data, type: String, expectedReason: String)] = [
            (bigPng, "public.png", SyncContentRejectReason.imageDimensions.rawValue),
            (smallJpeg, "public.png", SyncContentRejectReason.imageFormat.rawValue),
            (corruptBytes, "public.png", SyncContentRejectReason.imageCorrupt.rawValue)
        ]

        for (index, item) in cases.enumerated() {
            let id = UUID()
            let sha = SyncEchoGuard.hash(item.data)
            let offer = SyncOffer(id: id, at: Int64(100 + index), from: "pc", kind: "image",
                size: item.data.count, sha256: sha,
                name64: Data("secret-\(index).png".utf8).base64EncodedString(), type: item.type)
            try f.link.send(.offer(offer))
            var offset = 0
            while offset < item.data.count {
                let end = min(item.data.count, offset + SyncProtocol.chunkBytes)
                try f.link.send(.chunk(id: id, offset: offset, data: item.data.subdata(in: offset..<end)))
                offset = end
            }
            await drain(f)
            XCTAssertEqual(f.controller.status, .connected)
            XCTAssertTrue(f.link.rejected.isEmpty)
            XCTAssertTrue(f.link.ackIDs.contains(id))
            XCTAssertTrue(f.monitor.entries.isEmpty)
            XCTAssertNil(f.monitor.storageError)
            XCTAssertNil(f.controller.transferProgress)
            let files = try FileManager.default.contentsOfDirectory(atPath: f.monitor.syncDirectory.path)
            XCTAssertFalse(files.contains { $0.hasSuffix(".part") })

            // Re-offering the rejected ID immediately ACKs without saving.
            let ackCountBefore = f.link.ackIDs.filter { $0 == id }.count
            try f.link.send(.offer(offer))
            XCTAssertEqual(f.link.ackIDs.filter { $0 == id }.count, ackCountBefore + 1)
            XCTAssertTrue(f.monitor.entries.isEmpty)

            let log = try String(contentsOf: f.root.appendingPathComponent("log.tsv"), encoding: .utf8)
            XCTAssertTrue(log.contains(item.expectedReason))
            XCTAssertFalse(log.contains("secret-\(index)"))
            XCTAssertFalse(log.contains(sha))
        }
    }

    @MainActor
    func testTransientFailureDuringIncomingAttachmentCommitDiscardsPartialAndDisconnects() async throws {
        let f = try Fixture(test: self, storageFails: true), pairing = try pair(f)
        await drain(f)
        try f.link.connect(pairing, limit: 512)
        f.controller.copiesReceivedToPasteboard = false
        let png = ImageTestSupport.png()
        let offer = SyncOffer(id: UUID(), at: 100, from: "pc", kind: "image", size: png.count,
            sha256: SyncEchoGuard.hash(png), name64: "", type: "public.png")
        try f.link.send(.offer(offer))
        XCTAssertEqual(f.link.messages.last, .resume(id: offer.id, offset: 0))
        try f.link.send(.chunk(id: offer.id, offset: 0, data: png))
        await drain(f)
        XCTAssertEqual(f.link.rejected, [false])
        XCTAssertFalse(f.link.ackIDs.contains(offer.id))
        XCTAssertNotNil(f.monitor.storageError)
        let files = try FileManager.default.contentsOfDirectory(atPath: f.monitor.syncDirectory.path)
        XCTAssertFalse(files.contains { $0.hasSuffix(".part") })

        f.storage.fails = false
        try f.link.connect(pairing, limit: 512)
        try f.link.send(.offer(offer))
        XCTAssertEqual(f.link.messages.last, .resume(id: offer.id, offset: 0))
        try f.link.send(.chunk(id: offer.id, offset: 0, data: png))
        await drain(f)
        XCTAssertTrue(f.link.ackIDs.contains(offer.id))
        XCTAssertEqual(f.monitor.entries.count, 1)
        XCTAssertNil(f.monitor.storageError)
    }

    @MainActor
    func testOnlyOneAttachmentTransfersAtATimeWhileAllowingTextAndReplies() async throws {
        let f = try Fixture(test: self), pairing = try pair(f)
        let data1 = Data(repeating: 11, count: SyncProtocol.chunkBytes * 4 + 5)
        let data2 = Data([22, 23, 24])
        // Items older than 24 hours on the fixture clock (which starts now) are pruned from the queue.
        let baseDate = f.clock.date
        f.monitor.saveManually([try makeFileProvider(in: f.root, bytes: data1, name: "one.bin")], receivedAt: baseDate)
        await awaitSave(f, savedCount: 1)
        f.monitor.saveManually(["途中の文章"], receivedAt: baseDate.addingTimeInterval(1))
        await awaitSave(f, savedCount: 2)
        f.monitor.saveManually([try makeFileProvider(in: f.root, bytes: data2, name: "two.bin")], receivedAt: baseDate.addingTimeInterval(2))
        await awaitSave(f, savedCount: 3)

        try f.link.connect(pairing, limit: 512)
        XCTAssertEqual(f.link.offers.count, 1)
        let offer1 = try XCTUnwrap(f.link.offers.first)
        XCTAssertEqual(offer1.filename, "one.bin")
        XCTAssertEqual(f.link.items.count, 1)
        let textId = try itemID(try XCTUnwrap(f.link.items.first))

        // Replies (ACK for incoming item) and chunking for offer1 proceed while offer2 waits.
        let incomingId = UUID()
        f.controller.copiesReceivedToPasteboard = false
        try f.link.send(.item(id: incomingId, at: 0, from: "pc", text: "割り込み受信"))
        await drain(f)
        XCTAssertTrue(f.link.ackIDs.contains(incomingId))
        XCTAssertEqual(f.link.offers.count, 1)

        try f.link.send(.resume(id: offer1.id, offset: 0))
        XCTAssertEqual(f.link.chunks.count, 4)
        XCTAssertEqual(f.link.chunks[0].id, offer1.id)
        XCTAssertEqual(f.link.chunks[0].data.count, SyncProtocol.chunkBytes)
        XCTAssertEqual(f.link.offers.count, 1)

        try f.link.send(.resume(id: offer1.id, offset: SyncProtocol.chunkBytes))
        XCTAssertEqual(f.link.chunks.count, 5)
        XCTAssertEqual(f.link.chunks[4].id, offer1.id)
        XCTAssertEqual(f.link.chunks[4].offset, SyncProtocol.chunkBytes * 4)
        XCTAssertEqual(f.link.chunks[4].data.count, 5)
        XCTAssertEqual(f.link.offers.count, 1)

        try f.link.send(.ack(ids: [textId]))
        XCTAssertEqual(f.link.offers.count, 1)

        try f.link.send(.ack(ids: [offer1.id]))
        XCTAssertEqual(f.link.offers.count, 2)
        let offer2 = f.link.offers[1]
        XCTAssertEqual(offer2.filename, "two.bin")
        try f.link.send(.resume(id: offer2.id, offset: 0))
        try f.link.send(.ack(ids: [offer2.id]))
        XCTAssertEqual(f.controller.pendingCount, 0)

        // Zero-byte attachment also blocks the next offer until ACKed.
        // Incoming PC text above incremented savedCount to 4, so use relative counts.
        let savedBeforeEmpty = f.monitor.savedCount
        f.monitor.saveManually([try makeFileProvider(in: f.root, bytes: Data(), name: "empty.bin")], receivedAt: baseDate.addingTimeInterval(3))
        await awaitSave(f, savedCount: savedBeforeEmpty + 1)
        f.monitor.saveManually([try makeFileProvider(in: f.root, bytes: Data([9]), name: "after.bin")], receivedAt: baseDate.addingTimeInterval(4))
        await awaitSave(f, savedCount: savedBeforeEmpty + 2)
        XCTAssertEqual(f.controller.pendingCount, 2)
        XCTAssertEqual(f.link.offers.count, 3)
        let emptyOffer = f.link.offers[2]
        XCTAssertEqual(emptyOffer.filename, "empty.bin")
        try f.link.send(.ack(ids: [emptyOffer.id]))
        XCTAssertEqual(f.link.offers.count, 4)
        XCTAssertEqual(f.link.offers[3].filename, "after.bin")
    }

    @MainActor
    func testResumeAtOrBeyondItemSizeIsRejectedImmediately() async throws {
        let f = try Fixture(test: self), pairing = try pair(f)
        f.monitor.saveManually([try makeFileProvider(in: f.root, bytes: Data(repeating: 1, count: 10), name: "ten.bin")], receivedAt: f.clock.date)
        await awaitSave(f, savedCount: 1)
        try f.link.connect(pairing, limit: 512)
        let tenOffer = try XCTUnwrap(f.link.offers.first)
        f.link.canSend = false
        try f.link.send(.resume(id: tenOffer.id, offset: 10))
        XCTAssertEqual(f.link.rejected, [false])

        try f.link.connect(pairing, limit: 512)
        f.link.canSend = false
        try f.link.send(.resume(id: tenOffer.id, offset: 11))
        XCTAssertEqual(f.link.rejected, [false, false])

        try f.link.connect(pairing, limit: 512)
        try f.link.send(.ack(ids: [tenOffer.id]))

        f.monitor.saveManually([try makeFileProvider(in: f.root, bytes: Data(), name: "zero.bin")], receivedAt: f.clock.date.addingTimeInterval(1))
        await awaitSave(f, savedCount: 2)
        // Reconnects re-offer ten.bin until acknowledged.
        XCTAssertEqual(f.link.offers.map(\.filename), ["ten.bin", "ten.bin", "ten.bin", "zero.bin"])
        let zeroOffer = try XCTUnwrap(f.link.offers.last)
        XCTAssertEqual(zeroOffer.size, 0)
        f.link.canSend = false
        try f.link.send(.resume(id: zeroOffer.id, offset: 0))
        XCTAssertEqual(f.link.rejected, [false, false, false])

        await drain(f)
        let log = try String(contentsOf: f.root.appendingPathComponent("log.tsv"), encoding: .utf8)
        XCTAssertTrue(log.contains("受信・接続確認失敗"))
        XCTAssertFalse(log.contains("送信フレーム作成失敗"))
    }

    @MainActor
    func testPreUnlockStartupRetriesHistoryLoadAndPrunesDeletedItemsBeforeSending() async throws {
        let pairing = try SyncPairing.create(name: "PC")
        let now = Date()
        let f1 = try Fixture(test: self, prepaired: pairing, storageFails: true, readFails: true) { dbURL, syncDir in
            let db = try HistoryDatabase(url: dbURL)
            let kept = try db.collect("残る項目", source: .manual, at: now)
            let deleted = try db.collect("削除された項目", source: .manual, at: now)
            try db.delete(id: deleted.id)
            let disk = SyncDiskStore(root: syncDir)
            try disk.load(pairId: pairing.pcId, now: now)
            let ms = Int64(now.timeIntervalSince1970 * 1000)
            try disk.enqueue(SyncPending(id: UUID(), historyID: deleted.id, at: ms, offer: nil), bytes: Data("削除された項目".utf8), now: now)
            try disk.enqueue(SyncPending(id: UUID(), historyID: kept.id, at: ms + 1, offer: nil), bytes: Data("残る項目".utf8), now: now)
        }
        XCTAssertEqual(f1.creations, 0)
        await drain(f1)
        f1.keys.readFails = false
        f1.storage.fails = false
        let pruned1 = expectation(description: "f1 pruned after unlock")
        let obs1 = f1.controller.$pendingCount.first { $0 == 1 }.sink { _ in pruned1.fulfill() }
        NotificationCenter.default.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        await fulfillment(of: [pruned1], timeout: 5)
        obs1.cancel()
        await drain(f1)
        XCTAssertEqual(f1.creations, 1)
        try f1.link.connect(pairing)
        XCTAssertEqual(f1.link.items.count, 1)
        if case let .item(_, _, _, text) = try XCTUnwrap(f1.link.items.first) {
            XCTAssertEqual(text, "残る項目")
        }

        let f2 = try Fixture(test: self, prepaired: pairing, storageFails: true, readFails: false) { dbURL, syncDir in
            let db = try HistoryDatabase(url: dbURL)
            let kept = try db.collect("解除後に送る項目", source: .manual, at: now)
            let deleted = try db.collect("解除前に消えた項目", source: .manual, at: now)
            try db.delete(id: deleted.id)
            let disk = SyncDiskStore(root: syncDir)
            try disk.load(pairId: pairing.pcId, now: now)
            let ms = Int64(now.timeIntervalSince1970 * 1000)
            try disk.enqueue(SyncPending(id: UUID(), historyID: deleted.id, at: ms, offer: nil), bytes: Data("解除前に消えた項目".utf8), now: now)
            try disk.enqueue(SyncPending(id: UUID(), historyID: kept.id, at: ms + 1, offer: nil), bytes: Data("解除後に送る項目".utf8), now: now)
        }
        await drain(f2)
        try f2.link.connect(pairing)
        XCTAssertTrue(f2.link.items.isEmpty)
        f2.storage.fails = false
        let pruned2 = expectation(description: "f2 pruned after unlock")
        let obs2 = f2.controller.$pendingCount.first { $0 == 1 }.sink { _ in pruned2.fulfill() }
        NotificationCenter.default.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        await fulfillment(of: [pruned2], timeout: 5)
        obs2.cancel()
        await drain(f2)
        XCTAssertEqual(f2.link.items.count, 1)
        if case let .item(_, _, _, text) = try XCTUnwrap(f2.link.items.first) {
            XCTAssertEqual(text, "解除後に送る項目")
        }
    }

    @MainActor
    func testFailedBackgroundImageAndFileCopyDoesNotAdvanceObservedChangeCount() async throws {
        let f = try Fixture(test: self), pairing = try pair(f)
        try f.link.connect(pairing, limit: 512)
        f.monitor.updateScene("active")
        f.monitor.start()
        defer { f.monitor.stop() }
        f.monitor.updateScene("background")
        f.board.string = "背景中の外部コピー"
        f.board.acceptsWrites = false

        let png = ImageTestSupport.png()
        let imageOffer = SyncOffer(id: UUID(), at: 100, from: "pc", kind: "image", size: png.count,
            sha256: SyncEchoGuard.hash(png), name64: "", type: "public.png")
        try f.link.send(.offer(imageOffer))
        try f.link.send(.chunk(id: imageOffer.id, offset: 0, data: png))
        await drain(f)

        let fileBytes = Data("file-bytes".utf8)
        let fileOffer = SyncOffer(id: UUID(), at: 101, from: "pc", kind: "file", size: fileBytes.count,
            sha256: SyncEchoGuard.hash(fileBytes), name64: Data("remote.txt".utf8).base64EncodedString(), type: "public.data")
        try f.link.send(.offer(fileOffer))
        try f.link.send(.chunk(id: fileOffer.id, offset: 0, data: fileBytes))
        await drain(f)

        f.board.acceptsWrites = true
        f.monitor.updateScene("active")
        f.monitor.pollPasteboard()
        await drain(f)
        XCTAssertTrue(f.monitor.entries.contains { $0.text == "背景中の外部コピー" })
    }

    @MainActor
    func testLocalRecopyOfFuturePCRowStillSendsToPC() async throws {
        let f = try Fixture(test: self), pairing = try pair(f)
        try f.link.connect(pairing, limit: 512)
        f.controller.copiesReceivedToPasteboard = false
        let futureAt = Int64(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        try f.link.send(.item(id: UUID(), at: futureAt, from: "pc", text: "未来の文章"))
        await drain(f)
        XCTAssertEqual(f.monitor.entries.first?.source, .pc)

        f.monitor.saveManually(["別の文章"], receivedAt: Date())
        f.monitor.saveManually(["未来の文章"], receivedAt: Date().addingTimeInterval(1))
        await drain(f)
        let merged = try XCTUnwrap(f.monitor.entries.first { $0.text == "未来の文章" })
        XCTAssertEqual(merged.source, .pc)
        XCTAssertEqual(merged.collectionCount, 2)
        XCTAssertTrue(f.link.items.contains {
            if case let .item(_, _, _, text) = $0 { return text == "未来の文章" }
            return false
        })
    }

    @MainActor
    func testRemovalBeforeInitialHistoryLoadDoesNotPrunePendingItems() async throws {
        let pairing = try SyncPairing.create(name: "PC")
        let now = Date()
        let f = try Fixture(test: self, prepaired: pairing, storageFails: true, readFails: false, retention: .oneDay) { dbURL, syncDir in
            let db = try HistoryDatabase(url: dbURL)
            let kept = try db.collect("残る項目", source: .manual, at: now)
            _ = try db.collect("期限切れ項目", source: .manual, at: now.addingTimeInterval(-2 * 24 * 60 * 60))
            let disk = SyncDiskStore(root: syncDir)
            try disk.load(pairId: pairing.pcId, now: now)
            let ms = Int64(now.timeIntervalSince1970 * 1000)
            try disk.enqueue(SyncPending(id: UUID(), historyID: kept.id, at: ms, offer: nil), bytes: Data("残る項目".utf8), now: now)
        }
        await drain(f)
        XCTAssertTrue(f.monitor.entries.isEmpty)
        XCTAssertEqual(f.controller.pendingCount, 1)

        f.storage.fails = false
        // Foreground transition triggers store.maintain(forceRetention: true), emitting .remove before .replace.
        f.monitor.updateScene("active")
        await drain(f)
        XCTAssertEqual(f.controller.pendingCount, 1)

        try f.link.connect(pairing)
        XCTAssertTrue(f.link.items.isEmpty)

        let sent = expectation(description: "kept item sent after full history load")
        let obs = f.controller.$lastSentAt.first { $0 != nil }.sink { _ in sent.fulfill() }
        NotificationCenter.default.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        await fulfillment(of: [sent], timeout: 5)
        obs.cancel()
        await drain(f)
        XCTAssertEqual(f.link.items.count, 1)
        if case let .item(_, _, _, text) = try XCTUnwrap(f.link.items.first) {
            XCTAssertEqual(text, "残る項目")
        }
    }

    @MainActor
    func testPruneFailureAfterHistoryLoadRetriesInCheckTimeoutsAndStartsSending() async throws {
        let pairing = try SyncPairing.create(name: "PC")
        let now = Date()
        var syncDirectory: URL?
        let f = try Fixture(test: self, prepaired: pairing) { dbURL, syncDir in
            syncDirectory = syncDir
            let db = try HistoryDatabase(url: dbURL)
            let kept = try db.collect("送る項目", source: .manual, at: now)
            let deleted = try db.collect("消えた項目", source: .manual, at: now)
            try db.delete(id: deleted.id)
            let disk = SyncDiskStore(root: syncDir)
            try disk.load(pairId: pairing.pcId, now: now)
            let ms = Int64(now.timeIntervalSince1970 * 1000)
            try disk.enqueue(SyncPending(id: UUID(), historyID: deleted.id, at: ms, offer: nil), bytes: Data("消えた項目".utf8), now: now)
            try disk.enqueue(SyncPending(id: UUID(), historyID: kept.id, at: ms + 1, offer: nil), bytes: Data("送る項目".utf8), now: now)
        }
        let syncDir = try XCTUnwrap(syncDirectory)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: syncDir.path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: syncDir.path)
        await drain(f)

        try f.link.connect(pairing)
        XCTAssertTrue(f.link.items.isEmpty)
        XCTAssertEqual(f.controller.pendingCount, 2)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: syncDir.path)
        f.controller.checkTimeouts()
        XCTAssertEqual(f.controller.pendingCount, 1)
        XCTAssertEqual(f.link.items.count, 1)
        if case let .item(_, _, _, text) = try XCTUnwrap(f.link.items.first) {
            XCTAssertEqual(text, "送る項目")
        }
    }

    @MainActor
    func testUnpairedStartupDoesNotLoadHistoryForSyncAndUnlockDoesNotDuplicateRetry() async throws {
        let unpaired = try Fixture(test: self, storageFails: true)
        await drain(unpaired)
        let unpairedLog = try String(contentsOf: unpaired.root.appendingPathComponent("log.tsv"), encoding: .utf8)
        XCTAssertFalse(unpairedLog.contains("送信待ち確認失敗; 理由=履歴読み込み"))

        let pairing = try SyncPairing.create(name: "PC")
        let locked = try Fixture(test: self, prepaired: pairing, storageFails: true, readFails: true)
        await drain(locked)
        let preUnlockLog = try String(contentsOf: locked.root.appendingPathComponent("log.tsv"), encoding: .utf8)
        XCTAssertFalse(preUnlockLog.contains("送信待ち確認失敗; 理由=履歴読み込み"))

        locked.keys.readFails = false
        let failedOnce = expectation(description: "single post-unlock load failure logged")
        let cancellable = locked.monitor.log.$lines.first { lines in
            lines.contains { $0.fileLine.contains("送信待ち確認失敗; 理由=履歴読み込み") }
        }.sink { _ in failedOnce.fulfill() }
        NotificationCenter.default.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        await fulfillment(of: [failedOnce], timeout: 5)
        cancellable.cancel()
        await drain(locked)
        let postUnlockLog = try String(contentsOf: locked.root.appendingPathComponent("log.tsv"), encoding: .utf8)
        let failures = postUnlockLog.components(separatedBy: "送信待ち確認失敗; 理由=履歴読み込み").count - 1
        XCTAssertEqual(failures, 1)
    }

    @MainActor
    func testFinishIncomingDoesNotClearOutgoingTransferProgress() async throws {
        let f = try Fixture(test: self), pairing = try pair(f)
        f.monitor.saveManually([try makeFileProvider(in: f.root, bytes: Data(repeating: 1, count: 10), name: "local.bin")], receivedAt: f.clock.date)
        await awaitSave(f, savedCount: 1)
        try f.link.connect(pairing, limit: 512)
        f.controller.copiesReceivedToPasteboard = false
        let localOffer = try XCTUnwrap(f.link.offers.first)

        let png = ImageTestSupport.png()
        let remoteOffer = SyncOffer(id: UUID(), at: Int64(f.clock.date.timeIntervalSince1970 * 1000), from: "pc", kind: "image",
            size: png.count, sha256: SyncEchoGuard.hash(png), name64: "", type: "public.png")
        try f.link.send(.offer(remoteOffer))
        try f.link.send(.chunk(id: remoteOffer.id, offset: 0, data: png))
        XCTAssertEqual(f.controller.transferProgress,
            PCSyncController.TransferProgress(direction: "receive", itemID: remoteOffer.id, bytes: png.count, totalBytes: png.count))

        // Outgoing send begins while incoming attachment save is still running on HistoryStore's queue.
        try f.link.send(.resume(id: localOffer.id, offset: 0))
        let expectedSend = PCSyncController.TransferProgress(direction: "send", itemID: localOffer.id, bytes: 10, totalBytes: 10)
        XCTAssertEqual(f.controller.transferProgress, expectedSend)

        await drain(f)
        XCTAssertTrue(f.link.ackIDs.contains(remoteOffer.id))
        XCTAssertEqual(f.controller.transferProgress, expectedSend)

        try f.link.send(.ack(ids: [localOffer.id]))
        XCTAssertNil(f.controller.transferProgress)
    }

    @MainActor
    func testVersionMismatchChecksIdentityBeforeVersionAndIgnoresUnknownOrZeroPcId() async throws {
        let f = try Fixture(test: self), pairing = try pair(f)

        // Different PC returning a mismatched version must be ignored for 10 minutes without stopping sync.
        f.link.welcomePcId = UUID()
        f.link.welcomeVersion = 2
        try f.link.connect(pairing)
        XCTAssertEqual(f.link.rejected, [true])
        XCTAssertFalse(f.controller.requiresPeerUpdate)
        XCTAssertFalse(f.controller.requiresRepair)
        XCTAssertEqual(f.link.stops, 0)
        XCTAssertEqual(f.controller.status, .searching)

        // Legacy all-zero PC ID in a version-mismatch frame also avoids stopping sync.
        f.link.welcomePcId = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        f.link.welcomeVersion = 1
        try f.link.connect(pairing)
        XCTAssertEqual(f.link.rejected, [true, true])
        XCTAssertFalse(f.controller.requiresPeerUpdate)
        XCTAssertEqual(f.link.stops, 0)
        XCTAssertEqual(f.controller.status, .searching)

        // Real paired PC still connects normally.
        f.link.welcomePcId = nil
        f.link.welcomeVersion = nil
        try f.link.connect(pairing)
        XCTAssertEqual(f.controller.status, .connected)

        // Paired PC ID with mismatched version stops sync with requiresPeerUpdate.
        f.link.disconnect()
        f.link.welcomeVersion = 2
        try f.link.connect(pairing)
        XCTAssertTrue(f.controller.requiresPeerUpdate)
        XCTAssertFalse(f.controller.requiresRepair)
        XCTAssertEqual(f.controller.compatibilityMessage, "相手のアプリを更新してください")
        XCTAssertEqual(f.controller.status, .unsupported)
        XCTAssertEqual(f.link.stops, 1)
    }

    @MainActor
    func testV4PadFallsBackToV3ForLegacyV3PcAndRetriesV4OnNextConnection() async throws {
        let f = try Fixture(test: self), pairing = try pair(f)
        let primaryPeerId = f.link.id
        f.controller.copiesReceivedToPasteboard = false

        // Simulate an unmodified v3 PC: rejects v4 HELLO with 0x02 | 0x03 | pcId(16) | zeros(64),
        // and accepts v3 HELLO on reconnect.
        f.link.rejectHelloWithMismatchVersion = [4: 3]
        try f.link.connect(pairing, limit: 512)
        XCTAssertEqual(f.link.receivedHelloVersions, [4])
        XCTAssertTrue(f.link.negotiatedVersions.isEmpty)
        XCTAssertFalse(f.controller.requiresPeerUpdate)
        XCTAssertFalse(f.controller.requiresRepair)
        XCTAssertEqual(f.controller.status, .searching)
        XCTAssertEqual(f.link.stops, 0)
        XCTAssertEqual(f.link.rejected, [false])

        // An unrelated peripheral connecting in between must still be tried at v4 and must not consume the fallback for primaryPeerId.
        f.link.id = UUID()
        let strangerPairing = try SyncPairing(pcId: UUID(), key: pairing.key, name: "Other")
        try f.link.connect(strangerPairing, limit: 512)
        XCTAssertEqual(f.link.receivedHelloVersions, [4, 4])
        XCTAssertEqual(f.link.rejected, [false, true])
        XCTAssertFalse(f.controller.requiresPeerUpdate)

        // Reconnect to the same legacy v3 PC uses protocolVersion: 3 and syncs over BLE without wifi_* messages.
        f.link.id = primaryPeerId
        try f.link.connect(pairing, limit: 512)
        XCTAssertEqual(f.link.receivedHelloVersions, [4, 4, 3])
        XCTAssertEqual(f.link.negotiatedVersions, [3])
        XCTAssertEqual(f.controller.status, .connected)
        XCTAssertFalse(f.controller.requiresPeerUpdate)
        XCTAssertEqual(f.link.devices.count, 1)

        f.monitor.saveManually(["版3で送る項目"], receivedAt: f.clock.date)
        await drain(f)
        XCTAssertEqual(f.link.items.count, 1)
        let sentId = try itemID(try XCTUnwrap(f.link.items.first))
        try f.link.send(.ack(ids: [sentId]))
        XCTAssertEqual(f.controller.pendingCount, 0)

        let pcItemId = UUID()
        try f.link.send(.item(id: pcItemId, at: Int64(f.clock.date.timeIntervalSince1970 * 1000), from: "pc", text: "PCからの版3項目"))
        await drain(f)
        XCTAssertTrue(f.link.ackIDs.contains(pcItemId))
        XCTAssertTrue(f.monitor.entries.contains { $0.source == .pc && $0.text == "PCからの版3項目" })

        // Next connection starts from v4 again (so when PC is updated to v4, it connects at v4).
        f.link.disconnect()
        f.link.rejectHelloWithMismatchVersion = [:]
        try f.link.connect(pairing, limit: 512)
        XCTAssertEqual(f.link.receivedHelloVersions, [4, 4, 3, 4])
        XCTAssertEqual(f.link.negotiatedVersions, [3, 4])
        XCTAssertEqual(f.controller.status, .connected)
        XCTAssertFalse(f.controller.requiresPeerUpdate)
    }

    @MainActor
    func testV3FallbackStopsForUpdateIfReconnectStillFailsVersionCheckAndIgnoresOtherPcV3Mismatch() async throws {
        // 1. A v3-shaped mismatch from a DIFFERENT PC ID must be rejected as .identity without triggering fallback or stopping.
        let fOther = try Fixture(test: self), pairingOther = try pair(fOther)
        fOther.link.welcomePcId = UUID()
        fOther.link.rejectHelloWithMismatchVersion = [4: 3]
        try fOther.link.connect(pairingOther, limit: 512)
        XCTAssertEqual(fOther.link.receivedHelloVersions, [4])
        XCTAssertEqual(fOther.link.rejected, [true])
        XCTAssertFalse(fOther.controller.requiresPeerUpdate)
        XCTAssertEqual(fOther.link.stops, 0)
        XCTAssertEqual(fOther.controller.status, .searching)

        // 2. If v4 falls back to v3 and the v3 reconnect ALSO fails version check, pauseForUpdate() stops without looping.
        let f = try Fixture(test: self), pairing = try pair(f)
        f.link.rejectHelloWithMismatchVersion = [4: 3, 3: 2]
        try f.link.connect(pairing, limit: 512)
        XCTAssertEqual(f.link.receivedHelloVersions, [4])
        XCTAssertFalse(f.controller.requiresPeerUpdate)
        XCTAssertEqual(f.link.stops, 0)
        XCTAssertEqual(f.controller.status, .searching)

        try f.link.connect(pairing, limit: 512)
        XCTAssertEqual(f.link.receivedHelloVersions, [4, 3])
        XCTAssertTrue(f.controller.requiresPeerUpdate)
        XCTAssertFalse(f.controller.requiresRepair)
        XCTAssertEqual(f.controller.compatibilityMessage, "相手のアプリを更新してください")
        XCTAssertEqual(f.controller.status, .unsupported)
        XCTAssertEqual(f.link.stops, 1)

        f.clock.date.addTimeInterval(600)
        f.controller.checkTimeouts()
        XCTAssertEqual(f.link.starts, 1)
        XCTAssertEqual(f.link.receivedHelloVersions, [4, 3])

        // Explicit retry starts from v4 again once PC is updated.
        f.link.rejectHelloWithMismatchVersion = [:]
        f.controller.retryAfterPeerUpdate()
        try f.link.connect(pairing, limit: 512)
        XCTAssertEqual(f.link.receivedHelloVersions, [4, 3, 4])
        XCTAssertEqual(f.link.negotiatedVersions, [4])
        XCTAssertEqual(f.controller.status, .connected)
        XCTAssertFalse(f.controller.requiresPeerUpdate)
    }

    @MainActor
    func testIncomingMultiPacketProgressExtendsAckDeadlineWhileStalledAssemblyTimesOut() async throws {
        let f = try Fixture(test: self), pairing = try pair(f)
        f.controller.copiesReceivedToPasteboard = false
        try f.link.connect(pairing, limit: 512)

        // 1. An in-progress large frame (>64B) extends until that frame completes,
        //    and a SECOND large frame started later ALSO extends until it completes.
        let frame = try f.link.seal(.item(id: UUID(), at: Int64(f.clock.date.timeIntervalSince1970 * 1000),
                                          from: "pc", text: String(repeating: "長", count: 500)))
        let packets = try SyncPacketizer.split(frame, packetLimit: 182)
        XCTAssertGreaterThanOrEqual(packets.count, 5)
        f.link.onEvent?(.packet(packets[0]))

        f.monitor.saveManually(["応答待ち"], receivedAt: f.clock.date)
        await drain(f)
        XCTAssertEqual(f.link.items.count, 1)

        for packet in packets.dropFirst().dropLast() {
            f.clock.date.addTimeInterval(8)
            f.controller.checkTimeouts()
            XCTAssertEqual(f.controller.status, .connected)
            f.link.onEvent?(.packet(packet))
        }
        f.clock.date.addTimeInterval(8)
        f.controller.checkTimeouts()
        XCTAssertEqual(f.controller.status, .connected)
        f.link.onEvent?(.packet(try XCTUnwrap(packets.last)))
        await drain(f)
        XCTAssertEqual(f.controller.status, .connected)

        // Second large frame started after the first finished ALSO extends past 60s,
        // and drops 60s after the last large frame completes if still unacked.
        let frame2 = try f.link.seal(.item(id: UUID(), at: Int64(f.clock.date.timeIntervalSince1970 * 1000),
                                           from: "pc", text: String(repeating: "次", count: 500)))
        let packets2 = try SyncPacketizer.split(frame2, packetLimit: 182)
        XCTAssertGreaterThanOrEqual(packets2.count, 5)
        f.clock.date.addTimeInterval(20)
        f.link.onEvent?(.packet(packets2[0]))
        f.controller.checkTimeouts()
        XCTAssertEqual(f.controller.status, .connected)
        for packet in packets2.dropFirst() {
            f.clock.date.addTimeInterval(8)
            f.link.onEvent?(.packet(packet))
            f.controller.checkTimeouts()
            XCTAssertEqual(f.controller.status, .connected)
        }
        await drain(f)
        f.clock.date.addTimeInterval(59)
        f.controller.checkTimeouts()
        XCTAssertEqual(f.controller.status, .connected)
        f.clock.date.addTimeInterval(2)
        f.controller.checkTimeouts()
        XCTAssertEqual(f.link.rejected, [false])

        // Ack the pending item cleanly before next sub-case.
        try f.link.connect(pairing, limit: 512)
        let pendingId = try itemID(try XCTUnwrap(f.link.items.last))
        try f.link.send(.ack(ids: [pendingId]))
        XCTAssertEqual(f.controller.pendingCount, 0)
        f.link.disconnect()

        // 2. Total extension for one in-progress frame is capped at +3 minutes beyond the 60s deadline (240s total).
        try f.link.connect(pairing, limit: 512)
        let longFrame = try f.link.seal(.item(id: UUID(), at: Int64(f.clock.date.timeIntervalSince1970 * 1000),
                                              from: "pc", text: String(repeating: "上", count: 1500)))
        let longPackets = try SyncPacketizer.split(longFrame, packetLimit: 182)
        XCTAssertGreaterThanOrEqual(longPackets.count, 16)
        f.link.onEvent?(.packet(longPackets[0]))

        f.monitor.saveManually(["上限確認"], receivedAt: f.clock.date)
        await drain(f)
        let sentAt = f.clock.date
        var packetIndex = 1
        while f.clock.date.timeIntervalSince(sentAt) < 220 && packetIndex < longPackets.count - 1 {
            f.clock.date.addTimeInterval(20)
            f.controller.checkTimeouts()
            XCTAssertEqual(f.controller.status, .connected)
            f.link.onEvent?(.packet(longPackets[packetIndex]))
            packetIndex += 1
        }
        f.clock.date = sentAt.addingTimeInterval(239)
        f.controller.checkTimeouts()
        XCTAssertEqual(f.controller.status, .connected)
        f.link.onEvent?(.packet(longPackets[packetIndex]))
        f.clock.date = sentAt.addingTimeInterval(241)
        f.controller.checkTimeouts()
        XCTAssertEqual(f.link.rejected, [false, false])

        try f.link.connect(pairing, limit: 512)
        try f.link.send(.ack(ids: [try itemID(try XCTUnwrap(f.link.items.last))]))
        XCTAssertEqual(f.controller.pendingCount, 0)
        f.link.disconnect()

        // 3. A large frame started AFTER sending an item ALSO extends the 60s reply deadline.
        try f.link.connect(pairing, limit: 512)
        f.monitor.saveManually(["送信後開始"], receivedAt: f.clock.date)
        await drain(f)
        let afterItemId = try itemID(try XCTUnwrap(f.link.items.last))
        let lateFrame = try f.link.seal(.item(id: UUID(), at: Int64(f.clock.date.timeIntervalSince1970 * 1000),
                                              from: "pc", text: String(repeating: "後", count: 500)))
        let latePackets = try SyncPacketizer.split(lateFrame, packetLimit: 182)
        XCTAssertGreaterThanOrEqual(latePackets.count, 5)
        f.clock.date.addTimeInterval(50)
        f.link.onEvent?(.packet(latePackets[0]))
        f.clock.date.addTimeInterval(15) // +65s since send.
        f.controller.checkTimeouts()
        XCTAssertEqual(f.controller.status, .connected)
        for packet in latePackets.dropFirst() {
            f.clock.date.addTimeInterval(15)
            f.link.onEvent?(.packet(packet))
            f.controller.checkTimeouts()
            XCTAssertEqual(f.controller.status, .connected)
        }
        await drain(f)
        try f.link.send(.ack(ids: [afterItemId]))
        XCTAssertEqual(f.controller.pendingCount, 0)
        XCTAssertEqual(f.link.rejected, [false, false])
        f.link.disconnect()

        // 4. Multi-packet ping at 20-byte packet limit (39 bytes = 3 packets) already in progress does NOT extend.
        try f.link.connect(pairing, limit: 20)
        let pingPackets = try SyncPacketizer.split(f.link.seal(.ping), packetLimit: 20)
        XCTAssertEqual(pingPackets.count, 3)
        f.link.onEvent?(.packet(pingPackets[0]))
        f.link.onEvent?(.packet(pingPackets[1]))
        f.monitor.saveManually(["分割ping用"], receivedAt: f.clock.date)
        await drain(f)
        f.clock.date.addTimeInterval(50)
        f.link.onEvent?(.packet(pingPackets[2]))
        f.clock.date.addTimeInterval(11)
        f.controller.checkTimeouts()
        XCTAssertEqual(f.link.rejected, [false, false, false])

        // 5. Stalled partial assembly still drops at 60s.
        try f.link.connect(pairing, limit: 512)
        let stallFrame = try f.link.seal(.item(id: UUID(), at: Int64(f.clock.date.timeIntervalSince1970 * 1000),
                                               from: "pc", text: String(repeating: "止", count: 500)))
        let stallPackets = try SyncPacketizer.split(stallFrame, packetLimit: 182)
        f.link.onEvent?(.packet(stallPackets[0]))
        f.clock.date.addTimeInterval(61)
        f.controller.checkTimeouts()
        XCTAssertEqual(f.link.rejected, [false, false, false, false])
    }

    @MainActor
    func testAttachmentTimeoutReconnectsAndDuplicateUnseenOfferInSameConnectionDisconnects() async throws {
        let f = try Fixture(test: self), pairing = try pair(f)
        f.controller.copiesReceivedToPasteboard = false
        f.monitor.saveManually([try makeFileProvider(in: f.root, bytes: Data(repeating: 1, count: 10), name: "retry.bin")], receivedAt: f.clock.date)
        await awaitSave(f, savedCount: 1)

        try f.link.connect(pairing, limit: 512)
        XCTAssertEqual(f.link.offers.count, 1)
        f.clock.date.addTimeInterval(61)
        f.controller.checkTimeouts()
        XCTAssertEqual(f.link.rejected, [false])

        try f.link.connect(pairing, limit: 512)
        XCTAssertEqual(f.link.offers.count, 2)
        let offer = try XCTUnwrap(f.link.offers.last)
        try f.link.send(.resume(id: offer.id, offset: 0))
        try f.link.send(.ack(ids: [offer.id]))
        XCTAssertEqual(f.controller.pendingCount, 0)

        // Receiving the same unseen offer twice in the same connection disconnects without a second resume.
        let incomingData = Data(repeating: 4, count: 100)
        let incomingOffer = SyncOffer(id: UUID(), at: Int64(f.clock.date.timeIntervalSince1970 * 1000), from: "pc", kind: "file",
            size: incomingData.count, sha256: SyncEchoGuard.hash(incomingData),
            name64: Data("in.bin".utf8).base64EncodedString(), type: "public.data")
        try f.link.send(.offer(incomingOffer))
        XCTAssertEqual(f.link.messages.filter { $0 == .resume(id: incomingOffer.id, offset: 0) }.count, 1)
        try f.link.send(.offer(incomingOffer))
        XCTAssertEqual(f.link.rejected, [false, false])
        XCTAssertEqual(f.link.messages.filter { $0 == .resume(id: incomingOffer.id, offset: 0) }.count, 1)

        // Reconnect resumes cleanly.
        try f.link.connect(pairing, limit: 512)
        try f.link.send(.offer(incomingOffer))
        XCTAssertEqual(f.link.messages.filter { $0 == .resume(id: incomingOffer.id, offset: 0) }.count, 2)
    }

    @MainActor
    func testIncomingItemsOverSixtyFourWhileWriteBlockedBatchIntoSingleAck() async throws {
        let f = try Fixture(test: self), pairing = try pair(f)
        try f.link.connect(pairing, limit: 512)
        f.controller.copiesReceivedToPasteboard = false
        f.link.canSend = false

        let ids = (0..<80).map { _ in UUID() }
        for start in stride(from: 0, to: ids.count, by: 25) {
            for index in start..<min(start + 25, ids.count) {
                try f.link.send(.item(id: ids[index], at: Int64(index), from: "pc", text: "item-\(index)"))
            }
            await drain(f)
        }
        XCTAssertEqual(f.controller.status, .connected)
        XCTAssertTrue(f.link.rejected.isEmpty)

        f.link.resume()
        let ackMessages = f.link.messages.filter { if case .ack = $0 { return true }; return false }
        XCTAssertEqual(ackMessages.count, 1)
        XCTAssertEqual(f.link.ackIDs, ids)

        // Exceed the old 500-item ack limit and verify batching splits at SyncProtocol.maxAckIds (1024).
        f.link.messages.removeAll()
        f.link.canSend = false
        let batchIds = (0..<(SyncProtocol.maxAckIds + 1)).map { index in
            index < ids.count ? ids[index] : UUID()
        }
        for index in 0..<ids.count {
            try f.link.send(.item(id: batchIds[index], at: Int64(index), from: "pc", text: "item-\(index)"))
        }
        for start in stride(from: ids.count, to: batchIds.count, by: 25) {
            for index in start..<min(start + 25, batchIds.count) {
                try f.link.send(.item(id: batchIds[index], at: Int64(index), from: "pc", text: "batch-item"))
            }
            await drain(f)
        }
        XCTAssertEqual(f.controller.status, .connected)
        XCTAssertTrue(f.link.rejected.isEmpty)

        f.link.resume()
        let splitAcks = f.link.messages.compactMap { message -> [UUID]? in
            if case .ack(let ackIds) = message { return ackIds }
            return nil
        }
        XCTAssertEqual(splitAcks.count, 2)
        XCTAssertEqual(splitAcks[0].count, SyncProtocol.maxAckIds)
        XCTAssertEqual(splitAcks[1].count, 1)
        XCTAssertEqual(splitAcks[0] + splitAcks[1], batchIds)
    }

    @MainActor
    func testAttachmentAckBeforeFinalChunkCompletesDisconnectsAndPreservesPending() async throws {
        let f = try Fixture(test: self), pairing = try pair(f)
        let data1 = Data(repeating: 1, count: SyncProtocol.chunkBytes + 7)
        f.monitor.saveManually([try makeFileProvider(in: f.root, bytes: data1, name: "seen.bin")], receivedAt: f.clock.date)
        await awaitSave(f, savedCount: 1)

        // 1. Ack immediately after offer (no resume yet) is accepted.
        try f.link.connect(pairing, limit: 512)
        XCTAssertEqual(f.link.offers.count, 1)
        let seenOffer = try XCTUnwrap(f.link.offers.first)
        try f.link.send(.ack(ids: [seenOffer.id]))
        XCTAssertEqual(f.controller.pendingCount, 0)
        f.link.disconnect()

        // 2. Reject ack after resume before first chunk is sent.
        let data2 = Data(repeating: 2, count: SyncProtocol.chunkBytes * 4 + 9)
        f.monitor.saveManually([try makeFileProvider(in: f.root, bytes: data2, name: "two.bin")], receivedAt: f.clock.date.addingTimeInterval(1))
        await awaitSave(f, savedCount: 2)
        try f.link.connect(pairing, limit: 512)
        XCTAssertEqual(f.link.offers.count, 2)
        let offer2 = try XCTUnwrap(f.link.offers.last)
        f.link.canSend = false
        try f.link.send(.resume(id: offer2.id, offset: 0))
        try f.link.send(.ack(ids: [offer2.id]))
        XCTAssertEqual(f.link.rejected, [false])
        XCTAssertEqual(f.controller.pendingCount, 1)

        // 3. Reconnect (resends offer2, offers.count == 3); reject ack after first 4-chunk window (non-final).
        try f.link.connect(pairing, limit: 512)
        XCTAssertEqual(f.link.offers.count, 3)
        try f.link.send(.resume(id: offer2.id, offset: 0))
        XCTAssertEqual(f.link.chunks.count, 4)
        try f.link.send(.ack(ids: [offer2.id]))
        XCTAssertEqual(f.link.rejected, [false, false])
        XCTAssertEqual(f.controller.pendingCount, 1)

        // 4. Reconnect (limit 20, offers.count == 4); reject ack while final chunk is mid-packet.
        try f.link.connect(pairing, limit: 20)
        XCTAssertEqual(f.link.offers.count, 4)
        try f.link.send(.resume(id: offer2.id, offset: 0))
        XCTAssertEqual(f.link.chunks.count, 8)
        f.link.stopAfterPackets = 1
        try f.link.send(.resume(id: offer2.id, offset: SyncProtocol.chunkBytes))
        XCTAssertFalse(f.link.canSend)
        try f.link.send(.ack(ids: [offer2.id]))
        XCTAssertEqual(f.link.rejected, [false, false, false])
        XCTAssertEqual(f.controller.pendingCount, 1)

        // 5. Reconnect (offers.count == 5), finish final chunk, and ack succeeds.
        try f.link.connect(pairing, limit: 512)
        XCTAssertEqual(f.link.offers.count, 5)
        try f.link.send(.resume(id: offer2.id, offset: 0))
        try f.link.send(.resume(id: offer2.id, offset: SyncProtocol.chunkBytes))
        try f.link.send(.ack(ids: [offer2.id]))
        XCTAssertEqual(f.controller.pendingCount, 0)
    }

    @MainActor
    func testPruningExpiredIncomingPartialAndDeletedPendingClearsTransferProgress() async throws {
        let f = try Fixture(test: self), pairing = try pair(f)
        try f.link.connect(pairing, limit: 512)
        let incomingData = Data(repeating: 3, count: 100)
        let incomingOffer = SyncOffer(id: UUID(), at: Int64(f.clock.date.timeIntervalSince1970 * 1000), from: "pc", kind: "file",
            size: incomingData.count, sha256: SyncEchoGuard.hash(incomingData),
            name64: Data("expire.bin".utf8).base64EncodedString(), type: "public.data")
        try f.link.send(.offer(incomingOffer))
        XCTAssertEqual(f.controller.transferProgress?.direction, "receive")
        XCTAssertEqual(f.controller.transferProgress?.itemID, incomingOffer.id)

        f.clock.date.addTimeInterval(25 * 60 * 60)
        f.controller.checkTimeouts()
        XCTAssertNil(f.controller.transferProgress)

        f.monitor.saveManually([try makeFileProvider(in: f.root, bytes: Data(repeating: 5, count: 10), name: "delete.bin")], receivedAt: f.clock.date)
        await awaitSave(f, savedCount: 1)
        let offer = try XCTUnwrap(f.link.offers.first)
        try f.link.send(.resume(id: offer.id, offset: 0))
        XCTAssertEqual(f.controller.transferProgress?.direction, "send")
        XCTAssertEqual(f.controller.transferProgress?.itemID, offer.id)

        let entry = try XCTUnwrap(f.monitor.entries.first)
        let removed = expectation(description: "delete pending history")
        f.monitor.delete(entry) { _ in removed.fulfill() }
        await fulfillment(of: [removed], timeout: 5)
        await drain(f)
        XCTAssertEqual(f.controller.pendingCount, 0)
        XCTAssertNil(f.controller.transferProgress)
    }

    @MainActor
    func testBackoffIgnoresRejectsBluetoothOffAndSeparatesPeripherals() async throws {
        let f = try Fixture(test: self), pairing = try pair(f)
        let realId = f.link.id
        let otherId = UUID()

        // 1. 10-minute rejects (identity / HMAC mismatch) and Bluetooth OFF must NOT advance pre-auth backoff.
        let differentPC = try SyncPairing(pcId: UUID(), key: pairing.key, name: pairing.name)
        try f.link.connect(differentPC)
        XCTAssertEqual(f.link.rejected.last, true)
        XCTAssertNil(f.controller.nextReconnectAt)

        f.link.corruptWelcome = true
        try f.link.connect(pairing)
        f.link.corruptWelcome = false
        XCTAssertEqual(f.link.rejected.last, true)
        XCTAssertNil(f.controller.nextReconnectAt)

        f.link.connectWithoutWelcome()
        f.link.simulateBluetoothOff()
        XCTAssertEqual(f.controller.status, .bluetoothOff)
        XCTAssertNil(f.controller.nextReconnectAt)

        // 2. Repeated pre-auth failures on another peripheral do NOT inflate backoff for the paired peripheral.
        f.link.id = otherId
        for _ in 0..<5 {
            f.link.connectWithoutWelcome()
            f.clock.date.addTimeInterval(31)
            f.controller.checkTimeouts()
        }
        XCTAssertEqual(f.link.retryDelays.last, 600)
        XCTAssertEqual(f.controller.nextReconnectAt, f.clock.date.addingTimeInterval(600))

        // First pre-auth failure on the real peripheral still starts at delay 0 (not 30 or 600).
        f.link.id = realId
        f.link.connectWithoutWelcome()
        f.clock.date.addTimeInterval(31)
        f.controller.checkTimeouts()
        XCTAssertEqual(f.link.retryDelays.last, 0)
        XCTAssertNil(f.controller.nextReconnectAt)

        // Second failure on the real peripheral advances only the real peripheral to 30s.
        f.link.connectWithoutWelcome()
        f.clock.date.addTimeInterval(31)
        f.controller.checkTimeouts()
        XCTAssertEqual(f.link.retryDelays.last, 30)
        XCTAssertEqual(f.controller.nextReconnectAt, f.clock.date.addingTimeInterval(30))
    }

    @MainActor
    func testSimultaneousSendAfterReconnectExtendsDeadlineUntilLargeIncomingFrameCompletes() async throws {
        let f = try Fixture(test: self), pairing = try pair(f)
        f.controller.copiesReceivedToPasteboard = false
        f.monitor.saveManually(["再接続直後の送信"], receivedAt: f.clock.date)
        await drain(f)

        // On reconnect, iOS sends .device + queued item immediately before PC sends any packet.
        try f.link.connect(pairing, limit: 512)
        let sentId = try itemID(try XCTUnwrap(f.link.items.last))

        let largeIncoming = try f.link.seal(.item(id: UUID(), at: Int64(f.clock.date.timeIntervalSince1970 * 1000),
                                                  from: "pc", text: String(repeating: "同", count: 600)))
        let packets = try SyncPacketizer.split(largeIncoming, packetLimit: 182)
        XCTAssertGreaterThanOrEqual(packets.count, 6)

        for packet in packets {
            f.clock.date.addTimeInterval(15)
            f.link.onEvent?(.packet(packet))
            f.controller.checkTimeouts()
            XCTAssertEqual(f.controller.status, .connected)
        }
        await drain(f)
        try f.link.send(.ack(ids: [sentId]))
        XCTAssertEqual(f.controller.pendingCount, 0)
        XCTAssertTrue(f.link.rejected.isEmpty)
    }

    @MainActor
    func testLargeIncomingFrameStartedAfterSendExtendsAndSupportsConsecutiveLargeFrames() async throws {
        let f = try Fixture(test: self), pairing = try pair(f)
        f.controller.copiesReceivedToPasteboard = false
        try f.link.connect(pairing, limit: 512)

        f.monitor.saveManually(["連続受信待ち"], receivedAt: f.clock.date)
        await drain(f)
        let sentId = try itemID(try XCTUnwrap(f.link.items.last))

        f.clock.date.addTimeInterval(40)
        try f.link.send(.item(id: UUID(), at: Int64(f.clock.date.timeIntervalSince1970 * 1000),
                              from: "pc", text: String(repeating: "単", count: 10)))
        await drain(f)
        f.clock.date.addTimeInterval(25) // +65s since send.
        f.controller.checkTimeouts()
        XCTAssertEqual(f.controller.status, .connected)

        for ch in ["一", "二"] {
            let incoming = try f.link.seal(.item(id: UUID(), at: Int64(f.clock.date.timeIntervalSince1970 * 1000),
                                                 from: "pc", text: String(repeating: ch, count: 400)))
            let packets = try SyncPacketizer.split(incoming, packetLimit: 182)
            for packet in packets {
                f.clock.date.addTimeInterval(10)
                f.link.onEvent?(.packet(packet))
                f.controller.checkTimeouts()
                XCTAssertEqual(f.controller.status, .connected)
            }
            await drain(f)
        }
        try f.link.send(.ack(ids: [sentId]))
        XCTAssertEqual(f.controller.pendingCount, 0)
        XCTAssertTrue(f.link.rejected.isEmpty)
    }

    @MainActor
    func testPingPongOnlyDoesNotExtendAndPaddedPingRevertsOnlyOwnExtension() async throws {
        let f = try Fixture(test: self), pairing = try pair(f)
        f.controller.copiesReceivedToPasteboard = false

        // 1. ping / pong only never extends past 60s.
        try f.link.connect(pairing, limit: 512)
        f.monitor.saveManually(["pingだけ"], receivedAt: f.clock.date)
        await drain(f)
        let firstId = try itemID(try XCTUnwrap(f.link.items.last))

        f.clock.date.addTimeInterval(20)
        try f.link.send(.ping)
        f.clock.date.addTimeInterval(20)
        try f.link.send(.pong)
        f.clock.date.addTimeInterval(15)
        try f.link.send(.ping)
        f.clock.date.addTimeInterval(6) // +61s since send.
        f.controller.checkTimeouts()
        XCTAssertEqual(f.link.rejected, [false])

        // 2. Padded >64B multi-packet ping reverts only its own provisional extension and keeps earlier real extension.
        try f.link.connect(pairing, limit: 512)
        let realFrame = try f.link.seal(.item(id: UUID(), at: Int64(f.clock.date.timeIntervalSince1970 * 1000),
                                              from: "pc", text: String(repeating: "前", count: 400)))
        let realPackets = try SyncPacketizer.split(realFrame, packetLimit: 182)
        f.clock.date.addTimeInterval(20)
        for packet in realPackets {
            f.clock.date.addTimeInterval(5)
            f.link.onEvent?(.packet(packet))
        }
        await drain(f)
        let realCompletedAt = f.clock.date

        let paddedHeader = Data(("{\"t\":\"ping\"" + String(repeating: " ", count: 150) + "}").utf8)
        let paddedPlaintext = Data([UInt8(paddedHeader.count >> 8), UInt8(truncatingIfNeeded: paddedHeader.count)]) + paddedHeader
        let paddedPingPackets = try SyncPacketizer.split(f.link.sealRawPlaintext(paddedPlaintext), packetLimit: 100)
        XCTAssertGreaterThanOrEqual(paddedPingPackets.count, 2)

        f.clock.date = realCompletedAt.addingTimeInterval(20)
        f.link.onEvent?(.packet(paddedPingPackets[0]))
        f.clock.date = realCompletedAt.addingTimeInterval(35)
        for packet in paddedPingPackets.dropFirst() {
            f.link.onEvent?(.packet(packet))
        }
        f.clock.date = realCompletedAt.addingTimeInterval(59)
        f.controller.checkTimeouts()
        XCTAssertEqual(f.controller.status, .connected)
        f.clock.date = realCompletedAt.addingTimeInterval(61)
        f.controller.checkTimeouts()
        XCTAssertEqual(f.link.rejected, [false, false])

        // 3. Padded >64B multi-packet ping with no prior extension reverts back to initial 60s.
        try f.link.connect(pairing, limit: 512)
        let paddedPlaintext3 = Data([UInt8(paddedHeader.count >> 8), UInt8(truncatingIfNeeded: paddedHeader.count)]) + paddedHeader
        let paddedPingPackets3 = try SyncPacketizer.split(f.link.sealRawPlaintext(paddedPlaintext3), packetLimit: 100)
        f.clock.date.addTimeInterval(20)
        f.link.onEvent?(.packet(paddedPingPackets3[0]))
        f.clock.date.addTimeInterval(20)
        for packet in paddedPingPackets3.dropFirst() {
            f.link.onEvent?(.packet(packet))
        }
        f.clock.date.addTimeInterval(21) // +61s since send.
        f.controller.checkTimeouts()
        XCTAssertEqual(f.link.rejected, [false, false, false])

        try f.link.connect(pairing, limit: 512)
        try f.link.send(.ack(ids: [firstId]))
        XCTAssertEqual(f.controller.pendingCount, 0)
    }

    @MainActor
    func testExtensionCapStopsAtThreeMinutesAcrossPostSendLargeFrames() async throws {
        let f = try Fixture(test: self), pairing = try pair(f)
        f.controller.copiesReceivedToPasteboard = false
        try f.link.connect(pairing, limit: 512)

        f.monitor.saveManually(["3分上限"], receivedAt: f.clock.date)
        await drain(f)
        let sentAt = f.clock.date
        f.clock.date = sentAt.addingTimeInterval(10)

        let frames = try ["a", "b", "c", "d"].enumerated().map { index, ch in
            let frame = try f.link.seal(.item(id: UUID(), at: Int64(sentAt.timeIntervalSince1970 * 1000) + Int64(index),
                                              from: "pc", text: String(repeating: ch, count: 1500)))
            return try SyncPacketizer.split(frame, packetLimit: 182)
        }

        var frameIndex = 0
        var packetIndex = 0
        while f.clock.date.timeIntervalSince(sentAt) < 225 {
            f.link.onEvent?(.packet(frames[frameIndex][packetIndex]))
            packetIndex += 1
            if packetIndex == frames[frameIndex].count {
                await drain(f)
                frameIndex += 1
                packetIndex = 0
            }
            f.clock.date.addTimeInterval(12)
            f.controller.checkTimeouts()
            XCTAssertEqual(f.controller.status, .connected)
        }

        f.clock.date = sentAt.addingTimeInterval(239)
        f.controller.checkTimeouts()
        XCTAssertEqual(f.controller.status, .connected)
        f.link.onEvent?(.packet(frames[frameIndex][packetIndex]))
        f.clock.date = sentAt.addingTimeInterval(241)
        f.controller.checkTimeouts()
        XCTAssertEqual(f.link.rejected, [false])
    }

    @MainActor
    func testPipelinedChunksSlideWindowRejectInvalidResumesAndLogThroughput() async throws {
        let f = try Fixture(test: self), pairing = try pair(f)
        f.controller.copiesReceivedToPasteboard = false
        try f.link.connect(pairing, limit: 512)

        let txData = Data((0..<(SyncProtocol.chunkBytes * 6 + 17)).map { UInt8(truncatingIfNeeded: $0 * 7 + 3) })
        f.monitor.saveManually([try makeFileProvider(in: f.root, bytes: txData, name: "secret-send.bin")], receivedAt: f.clock.date)
        await awaitSave(f, savedCount: 1)
        await drain(f)
        let txOffer = try XCTUnwrap(f.link.offers.first)

        // Window size = 4 chunks (128 KiB).
        try f.link.send(.resume(id: txOffer.id, offset: 0))
        XCTAssertEqual(f.link.chunks.count, 4)
        XCTAssertEqual(f.link.chunks.map(\.offset), [0, SyncProtocol.chunkBytes, SyncProtocol.chunkBytes * 2, SyncProtocol.chunkBytes * 3])

        // Sliding by 1 chunk releases chunk 4; coalesced resume releases chunks 5 and 6.
        f.clock.date = f.clock.date.addingTimeInterval(1)
        try f.link.send(.resume(id: txOffer.id, offset: SyncProtocol.chunkBytes))
        XCTAssertEqual(f.link.chunks.count, 5)
        XCTAssertEqual(f.link.chunks[4].offset, SyncProtocol.chunkBytes * 4)

        f.clock.date = f.clock.date.addingTimeInterval(1)
        try f.link.send(.resume(id: txOffer.id, offset: SyncProtocol.chunkBytes * 4))
        XCTAssertEqual(f.link.chunks.count, 7)
        XCTAssertEqual(f.link.chunks[5].offset, SyncProtocol.chunkBytes * 5)
        XCTAssertEqual(f.link.chunks[6].offset, SyncProtocol.chunkBytes * 6)
        XCTAssertEqual(f.link.chunks[6].data.count, 17)

        f.clock.date = f.clock.date.addingTimeInterval(1)
        try f.link.send(.ack(ids: [txOffer.id]))
        XCTAssertEqual(f.controller.pendingCount, 0)

        // Pipelined receive without waiting between chunks.
        let rxData = Data((0..<(SyncProtocol.chunkBytes * 5 + 11)).map { UInt8(truncatingIfNeeded: $0 * 11 + 5) })
        let rxOffer = SyncOffer(
            id: UUID(),
            at: Int64(f.clock.date.timeIntervalSince1970 * 1000),
            from: "pc",
            kind: "file",
            size: rxData.count,
            sha256: SyncEchoGuard.hash(rxData),
            name64: Data("secret-recv.bin".utf8).base64EncodedString(),
            type: "public.data"
        )
        let msgStart = f.link.messages.count
        try f.link.send(.offer(rxOffer))
        XCTAssertEqual(f.link.messages.last, .resume(id: rxOffer.id, offset: 0))

        f.clock.date = f.clock.date.addingTimeInterval(2)
        var offset = 0
        while offset < rxData.count {
            let end = min(rxData.count, offset + SyncProtocol.chunkBytes)
            try f.link.send(.chunk(id: rxOffer.id, offset: offset, data: rxData.subdata(in: offset..<end)))
            offset = end
        }
        await drain(f)

        let rxReplies = Array(f.link.messages.dropFirst(msgStart))
        let resumeCount = rxReplies.filter { if case .resume(id: rxOffer.id, offset: _) = $0 { return true }; return false }.count
        XCTAssertEqual(resumeCount, 6)
        XCTAssertTrue(f.link.ackIDs.contains(rxOffer.id))
        let rxEntry = try XCTUnwrap(f.monitor.entries.first { $0.source == .pc && $0.kind == .file })
        let rxFile = try XCTUnwrap(rxEntry.file)
        XCTAssertEqual(try Data(contentsOf: f.monitor.fileURL(rxFile)), rxData)

        let log = try String(contentsOf: f.root.appendingPathComponent("log.tsv"), encoding: .utf8)
        XCTAssertTrue(log.contains("添付送信完了; バイト数=\(txData.count); 所要ms="))
        XCTAssertTrue(log.contains("添付受信完了; バイト数=\(rxData.count); 所要ms="))
        XCTAssertTrue(log.contains("KB秒="))
        XCTAssertFalse(log.contains("secret-send"))
        XCTAssertFalse(log.contains("secret-recv"))
        XCTAssertFalse(log.contains(rxOffer.sha256))

        // Invalid non-boundary resume inside window is rejected.
        let f2 = try Fixture(test: self), pairing2 = try pair(f2)
        let badData = Data(repeating: 9, count: SyncProtocol.chunkBytes * 2 + 1)
        f2.monitor.saveManually([try makeFileProvider(in: f2.root, bytes: badData, name: "bad-resume.bin")], receivedAt: f2.clock.date)
        await awaitSave(f2, savedCount: 1)
        try f2.link.connect(pairing2, limit: 512)
        let badOffer = try XCTUnwrap(f2.link.offers.first)
        try f2.link.send(.resume(id: badOffer.id, offset: 0))
        try f2.link.send(.resume(id: badOffer.id, offset: 123))
        XCTAssertEqual(f2.link.rejected, [false])
    }

    @MainActor
    func testCompatibleWithOldStopAndWaitPeerInBothDirections() async throws {
        let f = try Fixture(test: self), pairing = try pair(f)
        f.controller.copiesReceivedToPasteboard = false
        try f.link.connect(pairing, limit: 512)

        // Old stop-and-wait sender -> new receiver gets resume after every chunk.
        let rxData = Data((0..<(SyncProtocol.chunkBytes * 2 + 7)).map { UInt8(truncatingIfNeeded: $0) })
        let rxOffer = SyncOffer(
            id: UUID(),
            at: Int64(f.clock.date.timeIntervalSince1970 * 1000),
            from: "pc",
            kind: "file",
            size: rxData.count,
            sha256: SyncEchoGuard.hash(rxData),
            name64: Data("old-sender.bin".utf8).base64EncodedString(),
            type: "public.data"
        )
        try f.link.send(.offer(rxOffer))
        XCTAssertEqual(f.link.messages.last, .resume(id: rxOffer.id, offset: 0))
        try f.link.send(.chunk(id: rxOffer.id, offset: 0, data: rxData.subdata(in: 0..<SyncProtocol.chunkBytes)))
        XCTAssertEqual(f.link.messages.last, .resume(id: rxOffer.id, offset: SyncProtocol.chunkBytes))
        try f.link.send(.chunk(id: rxOffer.id, offset: SyncProtocol.chunkBytes, data: rxData.subdata(in: SyncProtocol.chunkBytes..<(SyncProtocol.chunkBytes * 2))))
        XCTAssertEqual(f.link.messages.last, .resume(id: rxOffer.id, offset: SyncProtocol.chunkBytes * 2))
        try f.link.send(.chunk(id: rxOffer.id, offset: SyncProtocol.chunkBytes * 2, data: rxData.subdata(in: (SyncProtocol.chunkBytes * 2)..<rxData.count)))
        await drain(f)
        XCTAssertTrue(f.link.ackIDs.contains(rxOffer.id))

        // New sender -> old receiver sending resume for every single chunk completes without error.
        let txData = Data((0..<(SyncProtocol.chunkBytes * 5 + 3)).map { UInt8(truncatingIfNeeded: $0 * 3) })
        let expectedSavedCount = f.monitor.savedCount + 1
        f.monitor.saveManually([try makeFileProvider(in: f.root, bytes: txData, name: "to-old.bin")], receivedAt: f.clock.date.addingTimeInterval(1))
        await awaitSave(f, savedCount: expectedSavedCount)
        await drain(f)
        let txOffer = try XCTUnwrap(f.link.offers.last)

        var received = Data()
        var processedChunks = f.link.chunks.count
        try f.link.send(.resume(id: txOffer.id, offset: 0))
        while received.count < txData.count {
            let newChunks = Array(f.link.chunks.dropFirst(processedChunks))
            XCTAssertFalse(newChunks.isEmpty)
            processedChunks += newChunks.count
            for ch in newChunks {
                XCTAssertEqual(ch.offset, received.count)
                received.append(ch.data)
                if received.count < txData.count {
                    try f.link.send(.resume(id: txOffer.id, offset: received.count))
                }
            }
        }
        XCTAssertEqual(received, txData)
        try f.link.send(.ack(ids: [txOffer.id]))
        XCTAssertEqual(f.controller.pendingCount, 0)
    }

    @MainActor
    func testPipelinedResumePreservesConfirmedExtensionAndEnforcesPerChunkCap() async throws {
        let f = try Fixture(test: self), pairing = try pair(f)
        f.controller.copiesReceivedToPasteboard = false
        try f.link.connect(pairing, limit: 512)

        let data = Data(repeating: 4, count: SyncProtocol.chunkBytes * 4 + 100)
        f.monitor.saveManually([try makeFileProvider(in: f.root, bytes: data, name: "ext-ios.bin")], receivedAt: f.clock.date)
        await awaitSave(f, savedCount: 1)
        await drain(f)
        let offer = try XCTUnwrap(f.link.offers.first)

        f.clock.date = f.clock.date.addingTimeInterval(1)
        let windowSentAt = f.clock.date
        try f.link.send(.resume(id: offer.id, offset: 0))
        XCTAssertEqual(f.link.chunks.count, 4)

        let largeIncoming = try f.link.seal(.item(id: UUID(), at: Int64(windowSentAt.timeIntervalSince1970 * 1000),
                                                  from: "pc", text: String(repeating: "延", count: 600)))
        let largePackets = try SyncPacketizer.split(largeIncoming, packetLimit: 182)
        XCTAssertGreaterThanOrEqual(largePackets.count, 6)
        for (index, packet) in largePackets.enumerated() {
            f.clock.date = windowSentAt.addingTimeInterval(Double(index + 1) * 89.0 / Double(largePackets.count))
            f.link.onEvent?(.packet(packet))
            f.controller.checkTimeouts()
            XCTAssertEqual(f.controller.status, .connected)
        }
        await drain(f)

        // At +90s since windowSentAt, resume chunk 0; chunk 1 becomes front and preserves extended deadline.
        f.clock.date = windowSentAt.addingTimeInterval(90)
        try f.link.send(.resume(id: offer.id, offset: SyncProtocol.chunkBytes))
        XCTAssertEqual(f.link.chunks.count, 5)

        f.clock.date = windowSentAt.addingTimeInterval(91)
        f.controller.checkTimeouts()
        XCTAssertEqual(f.controller.status, .connected)

        f.clock.date = windowSentAt.addingTimeInterval(148)
        f.controller.checkTimeouts()
        XCTAssertEqual(f.controller.status, .connected)

        f.clock.date = windowSentAt.addingTimeInterval(151)
        f.controller.checkTimeouts()
        XCTAssertEqual(f.link.rejected, [false])

        // Part 2: New chunk sent after resume gets its own 4-minute cap from its own completion time.
        try f.link.connect(pairing, limit: 512)
        let reoffer = try XCTUnwrap(f.link.offers.last)
        f.clock.date = f.clock.date.addingTimeInterval(1)
        let win2Start = f.clock.date
        try f.link.send(.resume(id: reoffer.id, offset: 0))
        let baseChunkCount = f.link.chunks.count

        var msgIndex = 0
        func nextFramePackets() throws -> [Data] {
            msgIndex += 1
            let ch = ["a", "b", "c", "d", "e", "f"][msgIndex % 6]
            let frame = try f.link.seal(.item(id: UUID(), at: Int64(win2Start.timeIntervalSince1970 * 1000) + Int64(msgIndex),
                                              from: "pc", text: String(repeating: ch, count: 1000)))
            return try SyncPacketizer.split(frame, packetLimit: 182)
        }
        var curPackets: [Data] = []
        var pktIdx = 0
        while f.clock.date.timeIntervalSince(win2Start) < 160 || pktIdx > 0 {
            if pktIdx == 0 {
                curPackets = try nextFramePackets()
            }
            f.link.onEvent?(.packet(curPackets[pktIdx]))
            pktIdx += 1
            if pktIdx == curPackets.count {
                await drain(f)
                pktIdx = 0
            }
            f.clock.date = f.clock.date.addingTimeInterval(10)
            f.controller.checkTimeouts()
            XCTAssertEqual(f.controller.status, .connected)
        }
        XCTAssertLessThan(f.clock.date.timeIntervalSince(win2Start), 240)

        try f.link.send(.resume(id: reoffer.id, offset: SyncProtocol.chunkBytes * 4))
        XCTAssertEqual(f.link.chunks.count, baseChunkCount + 1)
        let chunk4SentAt = f.clock.date

        pktIdx = 0
        while f.clock.date.timeIntervalSince(win2Start) < 250 || pktIdx > 0 {
            if pktIdx == 0 {
                curPackets = try nextFramePackets()
            }
            f.link.onEvent?(.packet(curPackets[pktIdx]))
            pktIdx += 1
            if pktIdx == curPackets.count {
                await drain(f)
                pktIdx = 0
            }
            f.clock.date = f.clock.date.addingTimeInterval(10)
            f.controller.checkTimeouts()
            XCTAssertEqual(f.controller.status, .connected)
        }
        XCTAssertGreaterThan(f.clock.date.timeIntervalSince(win2Start), 240)
        XCTAssertLessThan(f.clock.date.timeIntervalSince(chunk4SentAt), 240)

        try f.link.send(.ack(ids: [reoffer.id]))
        XCTAssertEqual(f.controller.pendingCount, 0)
    }

    @MainActor
    func testResumeBeforeChunkLastPacketHandedOffDisconnectsAndPreservesPending() async throws {
        let f = try Fixture(test: self), pairing = try pair(f)
        let data = Data(repeating: 6, count: SyncProtocol.chunkBytes * 5 + 17)
        f.monitor.saveManually([try makeFileProvider(in: f.root, bytes: data, name: "handoff.bin")], receivedAt: f.clock.date)
        await awaitSave(f, savedCount: 1)

        // 1. Reject resume sent while chunk 0 stopped after its first packet.
        try f.link.connect(pairing, limit: 20)
        let offer1 = try XCTUnwrap(f.link.offers.first)
        f.link.stopAfterPackets = 1
        try f.link.send(.resume(id: offer1.id, offset: 0))
        XCTAssertFalse(f.link.canSend)
        try f.link.send(.resume(id: offer1.id, offset: SyncProtocol.chunkBytes))
        XCTAssertEqual(f.link.rejected, [false])
        XCTAssertEqual(f.controller.pendingCount, 1)

        // 2. Accept resume for handed-off chunk 1 even while chunk 4 is paused mid-packet,
        // and reject resume for chunk 4 before its last packet is handed off.
        try f.link.connect(pairing, limit: 20)
        let offer2 = try XCTUnwrap(f.link.offers.last)
        try f.link.send(.resume(id: offer2.id, offset: 0))
        XCTAssertEqual(f.link.chunks.count, 4)

        f.link.stopAfterPackets = 1
        try f.link.send(.resume(id: offer2.id, offset: SyncProtocol.chunkBytes))
        XCTAssertFalse(f.link.canSend)

        try f.link.send(.resume(id: offer2.id, offset: SyncProtocol.chunkBytes * 2))
        XCTAssertEqual(f.link.rejected.count, 1)
        try f.link.send(.resume(id: offer2.id, offset: SyncProtocol.chunkBytes * 5))
        XCTAssertEqual(f.link.rejected, [false, false])
        XCTAssertEqual(f.controller.pendingCount, 1)
    }

    @MainActor
    func testPeriodicPruneDisconnectsWhenInFlightItemExceedsPendingLifetime() async throws {
        let f = try Fixture(test: self), pairing = try pair(f)
        try f.link.connect(pairing, limit: 20)
        let itemCountBefore = f.link.items.count
        f.link.stopAfterPackets = 1

        f.monitor.saveManually([String(repeating: "切", count: 500)], receivedAt: f.clock.date)
        await drain(f)
        XCTAssertFalse(f.link.canSend)
        XCTAssertEqual(f.controller.pendingCount, 1)

        f.clock.date.addTimeInterval(SyncProtocol.pendingLifetime + 10)
        f.controller.checkTimeouts()
        await drain(f)

        XCTAssertEqual(f.controller.pendingCount, 0)
        XCTAssertEqual(f.link.rejected, [false])
        XCTAssertEqual(f.controller.status, .searching)
        let log = try String(contentsOf: f.root.appendingPathComponent("log.tsv"), encoding: .utf8)
        XCTAssertTrue(log.contains("送信中の期限切れ"))

        try f.link.connect(pairing, limit: 512)
        XCTAssertEqual(f.link.items.count, itemCountBefore)
    }

    @MainActor
    func testAttachmentChunkSendDoesNotEmitPerChunkResendLog() async throws {
        let f = try Fixture(test: self), pairing = try pair(f)
        let data = Data(repeating: 8, count: SyncProtocol.chunkBytes * 4 + 17)
        f.monitor.saveManually([try makeFileProvider(in: f.root, bytes: data, name: "log-once.bin")], receivedAt: f.clock.date)
        await awaitSave(f, savedCount: 1)

        try f.link.connect(pairing, limit: 512)
        let offer = try XCTUnwrap(f.link.offers.first)
        try f.link.send(.resume(id: offer.id, offset: 0))
        try f.link.send(.resume(id: offer.id, offset: SyncProtocol.chunkBytes))
        XCTAssertEqual(f.link.chunks.count, 5)
        await drain(f)

        let logBeforeReconnect = try String(contentsOf: f.root.appendingPathComponent("log.tsv"), encoding: .utf8)
        XCTAssertFalse(logBeforeReconnect.contains("再送または継続"))

        // Disconnect before ack and reconnect: only the re-offered attachment logs resend once (not each chunk).
        f.link.disconnect()
        try f.link.connect(pairing, limit: 512)
        XCTAssertEqual(f.link.offers.count, 2)
        try f.link.send(.resume(id: offer.id, offset: 0))
        try f.link.send(.resume(id: offer.id, offset: SyncProtocol.chunkBytes))
        try f.link.send(.ack(ids: [offer.id]))
        XCTAssertEqual(f.controller.pendingCount, 0)
        await drain(f)

        let logAfterReconnect = try String(contentsOf: f.root.appendingPathComponent("log.tsv"), encoding: .utf8)
        let resendLines = logAfterReconnect.split(separator: "\n").filter { $0.contains("再送または継続") }
        XCTAssertEqual(resendLines.count, 1)
    }

    @MainActor
    func testAttachmentOfferAckIgnoredMidPacketAndAcceptedAfterOfferLastPacketHandedOff() async throws {
        let f = try Fixture(test: self), pairing = try pair(f)
        try f.link.connect(pairing, limit: 20)
        f.link.stopAfterPackets = 1

        let data = Data([10, 20, 30, 40])
        f.monitor.saveManually([try makeFileProvider(in: f.root, bytes: data, name: "mid-offer.bin")], receivedAt: f.clock.date)
        await awaitSave(f, savedCount: 1)
        XCTAssertFalse(f.link.canSend)
        XCTAssertTrue(f.link.offers.isEmpty)

        let syncDir = f.root.appendingPathComponent("images").appendingPathComponent("PCSync-v2", isDirectory: true)
        let stateData = try Data(contentsOf: syncDir.appendingPathComponent("state.json"))
        let savedState = try JSONDecoder().decode(SyncDiskStore.State.self, from: stateData)
        let offerID = try XCTUnwrap(savedState.pending.first?.id)

        // Mid-offer ACK before offer's last packet is handed off is ignored without disconnecting or deleting pending.
        try f.link.send(.ack(ids: [offerID]))
        XCTAssertEqual(f.controller.pendingCount, 1)
        XCTAssertTrue(f.link.rejected.isEmpty)

        // Hand off the remaining packets of offer, then ACK succeeds.
        f.link.resume()
        XCTAssertEqual(f.link.offers.count, 1)
        try f.link.send(.ack(ids: [offerID]))
        XCTAssertEqual(f.controller.pendingCount, 0)

        // Same behavior for a 0-byte attachment offer.
        f.link.stopAfterPackets = 1
        f.monitor.saveManually([try makeFileProvider(in: f.root, bytes: Data(), name: "empty-offer.bin")], receivedAt: f.clock.date.addingTimeInterval(1))
        await awaitSave(f, savedCount: 2)
        XCTAssertFalse(f.link.canSend)
        XCTAssertEqual(f.link.offers.count, 1)

        let emptyStateData = try Data(contentsOf: syncDir.appendingPathComponent("state.json"))
        let emptyState = try JSONDecoder().decode(SyncDiskStore.State.self, from: emptyStateData)
        let emptyOfferID = try XCTUnwrap(emptyState.pending.first?.id)

        try f.link.send(.ack(ids: [emptyOfferID]))
        XCTAssertEqual(f.controller.pendingCount, 1)
        XCTAssertTrue(f.link.rejected.isEmpty)

        f.link.resume()
        XCTAssertEqual(f.link.offers.count, 2)
        try f.link.send(.ack(ids: [emptyOfferID]))
        XCTAssertEqual(f.controller.pendingCount, 0)
    }

    @MainActor
    func testAttachmentOfferResumeIgnoredMidPacketAndAcceptedAfterOfferLastPacketHandedOff() async throws {
        let f = try Fixture(test: self), pairing = try pair(f)
        try f.link.connect(pairing, limit: 20)
        f.link.stopAfterPackets = 1

        let data = Data([10, 20, 30, 40, 50])
        f.monitor.saveManually([try makeFileProvider(in: f.root, bytes: data, name: "mid-offer-resume.bin")], receivedAt: f.clock.date)
        await awaitSave(f, savedCount: 1)
        XCTAssertFalse(f.link.canSend)
        XCTAssertTrue(f.link.offers.isEmpty)

        let syncDir = f.root.appendingPathComponent("images").appendingPathComponent("PCSync-v2", isDirectory: true)
        let stateData = try Data(contentsOf: syncDir.appendingPathComponent("state.json"))
        let savedState = try JSONDecoder().decode(SyncDiskStore.State.self, from: stateData)
        let offerID = try XCTUnwrap(savedState.pending.first?.id)

        // Premature initial resume before offer's last packet is handed off is ignored without disconnecting.
        try f.link.send(.resume(id: offerID, offset: 0))
        XCTAssertEqual(f.controller.pendingCount, 1)
        XCTAssertTrue(f.link.rejected.isEmpty)
        XCTAssertTrue(f.link.chunks.isEmpty)

        // Hand off the remaining packets of offer, then initial resume sends chunk and final ACK succeeds.
        f.link.resume()
        XCTAssertEqual(f.link.offers.count, 1)
        try f.link.send(.resume(id: offerID, offset: 0))
        XCTAssertEqual(f.link.chunks.count, 1)
        XCTAssertEqual(f.link.chunks.first?.data, data)
        try f.link.send(.ack(ids: [offerID]))
        XCTAssertEqual(f.controller.pendingCount, 0)
        XCTAssertTrue(f.link.rejected.isEmpty)
    }

    @MainActor
    func testTemplateSyncErrorStatesAndDeviceSpecificMessages() async throws {
        XCTAssertEqual(TemplateSyncError.unsupported.message(for: .phone), "このiPhoneでは使えません")
        XCTAssertEqual(TemplateSyncError.unsupported.message(for: .pad), "このiPadでは使えません")
        XCTAssertEqual(TemplateSyncError.requiresPeerUpdate.message(for: .phone), "PCとこのiPhoneのclipboard+を更新してください")
        XCTAssertEqual(TemplateSyncError.requiresPeerUpdate.message(for: .pad), "PCとこのiPadのclipboard+を更新してください")
        let skewOutcome = TemplateSyncOutcome(added: 0, updated: 0, deleted: 0, pushedToPCCount: 0, conflictCopyCount: 0,
                                                skippedOversizedCount: 0, skippedOverflowCount: 0, clockSkewSeconds: 400)
        XCTAssertTrue(skewOutcome.toastMessage(for: .phone).contains("iPhoneの時計がずれています"))
        XCTAssertTrue(skewOutcome.toastMessage(for: .pad).contains("iPadの時計がずれています"))

        let f = try Fixture(test: self)
        func runSync() -> Result<TemplateSyncOutcome, TemplateSyncError>? {
            var outcome: Result<TemplateSyncOutcome, TemplateSyncError>?
            f.controller.syncTemplates { outcome = $0 }
            return outcome
        }

        // Unpaired
        XCTAssertEqual(runSync(), .failure(.unpaired))
        XCTAssertFalse(f.controller.isSyncingTemplates)

        // Paired states before connected
        let pairing = try pair(f)
        XCTAssertEqual(runSync(), .failure(.notConnected))
        f.link.simulateBluetoothOff()
        XCTAssertEqual(runSync(), .failure(.bluetoothOff))
        f.link.onEvent?(.status(.unauthorized))
        XCTAssertEqual(runSync(), .failure(.unauthorized))
        f.link.onEvent?(.status(.unsupported))
        XCTAssertEqual(runSync(), .failure(.unsupported))
        f.link.onEvent?(.status(.searching))

        // Peer version mismatch -> requiresPeerUpdate
        f.link.welcomeVersion = 2
        try f.link.connect(pairing)
        XCTAssertEqual(runSync(), .failure(.requiresPeerUpdate))
        f.link.welcomeVersion = nil
        f.controller.retryAfterPeerUpdate()

        // Repeated auth mismatch -> requiresRepair
        f.link.corruptWelcome = true
        for _ in 0..<3 { try f.link.connect(pairing) }
        XCTAssertTrue(f.controller.requiresRepair)
        XCTAssertEqual(runSync(), .failure(.requiresRepair))
    }

    @MainActor
    func testTemplateSyncRoundtripAppliesChangesExportsKeyboardHistoryAndLogsNoSecrets() async throws {
        let root = try ImageTestSupport.directory(self)
        let containerURL = root.appendingPathComponent("group", isDirectory: true)
        let f = try Fixture(test: self, keyboardContainerURL: { containerURL })
        let pairing = try pair(f)

        var entry1: HistoryEntry?
        var entry2: HistoryEntry?
        let createdDone = expectation(description: "templates created")
        createdDone.expectedFulfillmentCount = 2
        f.monitor.createTemplate(text: "秘密本文アルファ", title: "秘密題名", tag: "秘密タグ") {
            if case .success(let e) = $0 { entry1 = e }
            createdDone.fulfill()
        }
        f.monitor.createTemplate(text: "削除される本文", title: nil, tag: nil) {
            if case .success(let e) = $0 { entry2 = e }
            createdDone.fulfill()
        }
        await fulfillment(of: [createdDone], timeout: 5)
        await drain(f)

        try f.link.connect(pairing, limit: 512)

        var completionResult: Result<TemplateSyncOutcome, TemplateSyncError>?
        let finished = expectation(description: "syncTemplates finished")
        f.controller.syncTemplates {
            completionResult = $0
            finished.fulfill()
        }
        XCTAssertTrue(f.controller.isSyncingTemplates)

        // Second tap while active fails immediately with alreadyInProgress.
        var concurrent: Result<TemplateSyncOutcome, TemplateSyncError>?
        f.controller.syncTemplates { concurrent = $0 }
        XCTAssertEqual(concurrent, .failure(.alreadyInProgress))

        await drain(f)
        let push = try XCTUnwrap(f.link.templatePushes.last)
        XCTAssertEqual(push.part, 0)
        XCTAssertEqual(push.total, 1)
        XCTAssertEqual(push.page.version, 1)
        XCTAssertEqual(push.page.templates.count, 2)
        let id1 = try XCTUnwrap(push.page.templates.first { $0.text == "秘密本文アルファ" }?.id)
        let id2 = try XCTUnwrap(push.page.templates.first { $0.text == "削除される本文" }?.id)

        let pcAddedID = UUID()
        let nowMs = Int64(f.clock.date.timeIntervalSince1970 * 1000)
        try f.link.send(.state(
            op: push.op, part: 0, total: 1,
            page: TemplateSyncPage(
                version: 1,
                sentAt: nowMs,
                templates: [
                    TemplateSyncItem(id: id1, kind: .text, text: "同期後本文", title: "更新済題", tag: "別タグ", order: 0, updatedAt: nowMs + 100),
                    TemplateSyncItem(id: pcAddedID, kind: .url, text: "https://pc-added.example", title: "PC側", tag: "Web", order: 0, updatedAt: nowMs + 200),
                ],
                tombstones: [
                    TemplateSyncTombstone(id: id2, deletedAt: nowMs + 100)
                ]
            )
        ))

        await fulfillment(of: [finished], timeout: 5)
        let outcome = try XCTUnwrap(completionResult?.get())
        XCTAssertEqual(outcome.added, 1)
        XCTAssertEqual(outcome.updated, 1)
        XCTAssertEqual(outcome.deleted, 1)
        XCTAssertFalse(f.controller.isSyncingTemplates)
        XCTAssertEqual(f.link.templateAckOps, [push.op])

        // UI list and keyboard-history.json both reflect synced templates with integer ID preserved.
        await drain(f)
        let templates = f.monitor.entries.filter(\.isTemplate)
        XCTAssertEqual(templates.first { $0.id == entry1?.id }?.text, "同期後本文")
        XCTAssertNil(templates.first { $0.id == entry2?.id })
        XCTAssertTrue(templates.contains { $0.text == "https://pc-added.example" && $0.kind == .url })

        let keyboard = try XCTUnwrap(KeyboardHistoryFile.read(from: SharedAppGroup.keyboardHistoryURL(in: containerURL)))
        XCTAssertTrue(keyboard.entries.contains { $0.isTemplate && $0.text == "同期後本文" })
        XCTAssertTrue(keyboard.entries.contains { $0.isTemplate && $0.text == "https://pc-added.example" })
        XCTAssertFalse(keyboard.entries.contains { $0.text == "削除される本文" })

        // Logs contain no plaintext, titles, tags, URLs, keys, or UUIDs.
        let logDone = expectation(description: "logs flushed")
        f.monitor.log.flush(context: f.monitor.logContext()) { logDone.fulfill() }
        await fulfillment(of: [logDone], timeout: 5)
        let logText = try String(contentsOf: f.root.appendingPathComponent("log.tsv"), encoding: .utf8)
        for secret in ["秘密本文アルファ", "秘密題名", "秘密タグ", "削除される本文", "同期後本文",
                       "pc-added.example", id1.uuidString, id2.uuidString, pcAddedID.uuidString, push.op.uuidString,
                       pairing.key.base64EncodedString()] {
            XCTAssertFalse(logText.contains(secret), "Unexpected sensitive token in log: \(secret)")
        }
    }

    @MainActor
    func testTemplateSyncDisconnectAndTimeoutAndLargeFrameExtension() async throws {
        let f = try Fixture(test: self)
        let pairing = try pair(f)
        let tDone = expectation(description: "template ready")
        f.monitor.createTemplate(text: "切断試験", title: nil, tag: nil) { _ in tDone.fulfill() }
        await fulfillment(of: [tDone], timeout: 5)
        await drain(f)

        // 1. Mid-sync disconnect (while partial tpl_state already started) resolves failure & clears partial assembler.
        try f.link.connect(pairing, limit: 512)
        var res1: Result<TemplateSyncOutcome, TemplateSyncError>?
        let exp1 = expectation(description: "disconnect fails")
        f.controller.syncTemplates { res1 = $0; exp1.fulfill() }
        await drain(f)
        let op1 = try XCTUnwrap(f.link.templatePushes.last?.op)
        let partialItem = TemplateSyncItem(id: UUID(), kind: .text, text: "part1", title: nil, tag: nil, order: 0,
                                           updatedAt: Int64(f.clock.date.timeIntervalSince1970 * 1000))
        try f.link.send(.state(op: op1, part: 0, total: 2,
                               page: TemplateSyncPage(version: 1,
                                                      sentAt: Int64(f.clock.date.timeIntervalSince1970 * 1000),
                                                      templates: [partialItem], tombstones: [])))
        f.link.disconnect()
        await fulfillment(of: [exp1], timeout: 5)
        XCTAssertEqual(res1, .failure(.disconnected))
        XCTAssertFalse(f.controller.isSyncingTemplates)

        // 2. Reconnect, ignore the stale continuation, and time out the next sync after 30s.
        try f.link.connect(pairing, limit: 512)
        try f.link.send(.state(op: op1, part: 1, total: 2,
                               page: TemplateSyncPage(templates: [partialItem], tombstones: [])))
        XCTAssertEqual(f.controller.status, .connected)
        XCTAssertTrue(f.link.templateAckOps.isEmpty)
        var res2: Result<TemplateSyncOutcome, TemplateSyncError>?
        let exp2 = expectation(description: "timeout")
        f.controller.syncTemplates { res2 = $0; exp2.fulfill() }
        await drain(f)
        let op2 = try XCTUnwrap(f.link.templatePushes.last?.op)
        XCTAssertNotEqual(op2, op1)

        // Padded >64B multi-packet ping must revert provisional extension so 30s timeout still fires at +31s.
        let paddedHeader = Data(("{\"t\":\"ping\"" + String(repeating: " ", count: 150) + "}").utf8)
        let paddedPlaintext = Data([UInt8(paddedHeader.count >> 8), UInt8(truncatingIfNeeded: paddedHeader.count)]) + paddedHeader
        let pingPackets = try SyncPacketizer.split(f.link.sealRawPlaintext(paddedPlaintext), packetLimit: 100)
        f.clock.date.addTimeInterval(15)
        f.link.onEvent?(.packet(pingPackets[0]))
        f.clock.date.addTimeInterval(10)
        for packet in pingPackets.dropFirst() { f.link.onEvent?(.packet(packet)) }
        f.clock.date.addTimeInterval(6) // +31s since op2 start
        f.controller.checkTimeouts()
        await fulfillment(of: [exp2], timeout: 5)
        XCTAssertEqual(res2, .failure(.timedOut))
        XCTAssertFalse(f.controller.isSyncingTemplates)
        XCTAssertTrue(f.link.rejected.isEmpty)
        XCTAssertEqual(f.controller.status, .connected)

        // 3. Large incoming tpl_state frame extends deadline beyond 30s so multi-packet delivery succeeds.
        try f.link.connect(pairing, limit: 512)
        var res3: Result<TemplateSyncOutcome, TemplateSyncError>?
        let exp3 = expectation(description: "extended succeeds")
        f.controller.syncTemplates { res3 = $0; exp3.fulfill() }
        await drain(f)
        let op3 = try XCTUnwrap(f.link.templatePushes.last?.op)
        let push3 = try XCTUnwrap(f.link.templatePushes.last?.page.templates.first)
        let bigText = String(repeating: "延", count: 350)
        let nowMs = Int64(f.clock.date.timeIntervalSince1970 * 1000)
        let bigState = try f.link.seal(.state(
            op: op3, part: 0, total: 1,
            page: TemplateSyncPage(version: 1, sentAt: nowMs,
                                   templates: [TemplateSyncItem(id: push3.id, kind: .text, text: bigText, title: nil, tag: nil, order: 0, updatedAt: nowMs)],
                                   tombstones: [])
        ))
        let packets = try SyncPacketizer.split(bigState, packetLimit: 182)
        XCTAssertGreaterThanOrEqual(packets.count, 3)
        f.clock.date.addTimeInterval(20)
        for packet in packets {
            f.clock.date.addTimeInterval(10) // exceeds 30s baseline before completion
            f.link.onEvent?(.packet(packet))
            f.controller.checkTimeouts()
            XCTAssertEqual(f.controller.status, .connected)
        }
        await fulfillment(of: [exp3], timeout: 5)
        XCTAssertEqual(try XCTUnwrap(res3).get().updated, 1)
    }

    @MainActor
    func testTemplateSyncPrioritizedBeforePendingHistoryAndHandlesMultiPagePCPullAndUnpair() async throws {
        var dbNow = Date(timeIntervalSince1970: 10_000)
        let f = try Fixture(test: self, databaseClock: { dbNow })
        f.clock.date = dbNow
        let pairing = try pair(f)

        // Create 5 large templates (~60 KiB each -> >256 KiB JSON -> multi-page tpl_push).
        for idx in 0..<5 {
            let done = expectation(description: "big template \(idx)")
            let prefix = "T\(idx)-"
            let body = prefix + String(repeating: "A", count: 60_000 - prefix.utf8.count)
            f.monitor.createTemplate(text: body, title: nil, tag: nil) { _ in done.fulfill() }
            await fulfillment(of: [done], timeout: 5)
        }
        await drain(f)

        // Connect, start a history item mid-frame so a second history item queues behind it, then receive tpl_pull.
        try f.link.connect(pairing, limit: 512)
        f.link.stopAfterPackets = 1
        f.monitor.saveManually(["先頭フレーム"], receivedAt: f.clock.date)
        await drain(f)
        f.monitor.saveManually(["後ろになる履歴"], receivedAt: f.clock.date.addingTimeInterval(1))
        await drain(f)

        let pcOp = UUID()
        try f.link.send(.pull(op: pcOp))
        await drain(f)

        // Resume BLE flow control so queued output, templateOutgoing, and pending history all drain.
        f.link.resume()
        let pushes = f.link.templatePushes.filter { $0.op == pcOp }
        XCTAssertGreaterThanOrEqual(pushes.count, 2)
        XCTAssertEqual(pushes.map(\.part), Array(0..<pushes.count))
        XCTAssertEqual(pushes.first?.page.version, 1)
        XCTAssertEqual(pushes.first?.page.sentAt, Int64(dbNow.timeIntervalSince1970 * 1000))
        XCTAssertTrue(pushes.dropFirst().allSatisfy { $0.page.version == nil && $0.page.sentAt == nil })

        // All tpl_push pages must precede the queued pending history item.
        let lastPushIdx = try XCTUnwrap(f.link.decryptedLog.lastIndex(of: "tpl_push"))
        let queuedHistoryIdx = try XCTUnwrap(f.link.decryptedLog.firstIndex(of: "item:後ろになる履歴"))
        XCTAssertLessThan(lastPushIdx, queuedHistoryIdx)

        // PC replies with multi-page tpl_state for pcOp, clearing 4 templates and updating remaining one.
        let kept = try XCTUnwrap(pushes.first?.page.templates.first)
        let nowMs = Int64(f.clock.date.timeIntervalSince1970 * 1000)
        dbNow = dbNow.addingTimeInterval(10)
        try f.link.send(.state(
            op: pcOp, part: 0, total: 2,
            page: TemplateSyncPage(version: 1, sentAt: nowMs,
                                   templates: [TemplateSyncItem(id: kept.id, kind: .text, text: "PC配信結果", title: "共有", tag: nil, order: 0, updatedAt: nowMs)],
                                   tombstones: [])
        ))
        let page2Item = TemplateSyncItem(id: UUID(), kind: .text, text: "PC追加2ページ目", title: nil, tag: nil, order: 1, updatedAt: nowMs)
        try f.link.send(.state(
            op: pcOp, part: 1, total: 2,
            page: TemplateSyncPage(templates: [page2Item], tombstones: [])
        ))
        await drain(f)
        XCTAssertTrue(f.link.templateAckOps.contains(pcOp))
        XCTAssertTrue(f.monitor.entries.contains { $0.isTemplate && $0.text == "PC配信結果" })
        XCTAssertTrue(f.monitor.entries.contains { $0.isTemplate && $0.text == "PC追加2ページ目" })

        // Deleting a synced template creates a tombstone; unpair clears tombstones & baseHash while keeping templates.
        let syncedTarget = try XCTUnwrap(f.monitor.entries.first { $0.isTemplate && $0.text == "PC配信結果" })
        let delExp = expectation(description: "deleted synced template")
        f.monitor.delete(syncedTarget) { _ in delExp.fulfill() }
        await fulfillment(of: [delExp], timeout: 5)
        await drain(f)

        f.controller.unpair()
        await drain(f)
        let remain = try XCTUnwrap(f.monitor.entries.first { $0.isTemplate && $0.text == "PC追加2ページ目" })
        let db = try HistoryDatabase(url: f.root.appendingPathComponent("history.sqlite"))
        XCTAssertTrue(try db.templateTombstones().isEmpty)
        let metaAfterUnpair = try XCTUnwrap(try db.templateSyncMetadata(id: remain.id))
        XCTAssertNil(metaAfterUnpair.baseHash)
    }

    @MainActor
    func testTemplateSyncLargePushExceeding30SecondsDoesNotTimeoutWhileSending() async throws {
        let f = try Fixture(test: self)
        let pairing = try pair(f)

        // 1. Single-page large push over 20B MTU taking >30s must NOT time out while actively sending.
        let created1 = expectation(description: "single-page large template")
        f.monitor.createTemplate(text: String(repeating: "送", count: 400), title: "長文", tag: nil) { _ in created1.fulfill() }
        await fulfillment(of: [created1], timeout: 5)
        await drain(f)

        try f.link.connect(pairing, limit: 20)
        f.link.stopAfterPackets = 1
        var res1: Result<TemplateSyncOutcome, TemplateSyncError>?
        let exp1 = expectation(description: "slow single-page push succeeds")
        f.controller.syncTemplates { res1 = $0; exp1.fulfill() }
        await drain(f)
        XCTAssertFalse(f.link.canSend)
        XCTAssertTrue(f.link.templatePushes.isEmpty)

        // Advance past 30s (40s total) while making steady BLE packet progress.
        for _ in 0..<4 {
            f.clock.date.addTimeInterval(10)
            f.controller.checkTimeouts()
            XCTAssertEqual(f.controller.status, .connected)
            XCTAssertTrue(f.controller.isSyncingTemplates)
            XCTAssertNil(res1)
            f.link.stopAfterPackets = 10
            f.link.canSend = true
            f.link.onEvent?(.writable)
        }
        XCTAssertTrue(f.link.templatePushes.isEmpty)
        XCTAssertTrue(f.link.rejected.isEmpty)

        // Finish sending and receive tpl_state after >40s since sync start.
        f.link.resume()
        let push1 = try XCTUnwrap(f.link.templatePushes.last)
        let pushedItem1 = try XCTUnwrap(push1.page.templates.first)
        f.clock.date.addTimeInterval(10)
        f.controller.checkTimeouts()
        XCTAssertEqual(f.controller.status, .connected)
        XCTAssertTrue(f.controller.isSyncingTemplates)
        let nowMs1 = Int64(f.clock.date.timeIntervalSince1970 * 1000)
        try f.link.send(.state(
            op: push1.op, part: 0, total: 1,
            page: TemplateSyncPage(
                version: 1, sentAt: nowMs1,
                templates: [TemplateSyncItem(id: pushedItem1.id, kind: .text, text: "PC返答", title: "長文", tag: nil, order: 0, updatedAt: nowMs1)],
                tombstones: []
            )
        ))
        await fulfillment(of: [exp1], timeout: 5)
        XCTAssertEqual(try XCTUnwrap(res1).get().updated, 1)
        XCTAssertTrue(f.link.templateAckOps.contains(push1.op))

        // 2. Multi-page push taking >30s also succeeds without disconnecting or dropping result.
        for idx in 0..<5 {
            let done = expectation(description: "multi-page template \(idx)")
            let prefix = "M\(idx)-"
            f.monitor.createTemplate(text: prefix + String(repeating: "B", count: 60_000 - prefix.utf8.count), title: nil, tag: nil) { _ in done.fulfill() }
            await fulfillment(of: [done], timeout: 5)
        }
        await drain(f)

        try f.link.connect(pairing, limit: 512)
        let pushesBefore2 = f.link.templatePushes.count
        f.link.stopAfterPackets = 1
        var res2: Result<TemplateSyncOutcome, TemplateSyncError>?
        let exp2 = expectation(description: "slow multi-page push succeeds")
        f.controller.syncTemplates { res2 = $0; exp2.fulfill() }
        await drain(f)
        for _ in 0..<4 {
            f.clock.date.addTimeInterval(10)
            f.controller.checkTimeouts()
            XCTAssertEqual(f.controller.status, .connected)
            XCTAssertTrue(f.controller.isSyncingTemplates)
            f.link.stopAfterPackets = 20
            f.link.canSend = true
            f.link.onEvent?(.writable)
        }
        f.link.resume()
        let pushes2 = Array(f.link.templatePushes.dropFirst(pushesBefore2))
        XCTAssertGreaterThanOrEqual(pushes2.count, 2)
        let op2 = try XCTUnwrap(pushes2.first?.op)
        let nowMs2 = Int64(f.clock.date.timeIntervalSince1970 * 1000)
        try f.link.send(.state(
            op: op2, part: 0, total: 1,
            page: TemplateSyncPage(version: 1, sentAt: nowMs2, templates: [TemplateSyncItem(id: pushedItem1.id, kind: .text, text: "複数頁完了", title: nil, tag: nil, order: 0, updatedAt: nowMs2)], tombstones: [])
        ))
        await fulfillment(of: [exp2], timeout: 5)
        XCTAssertEqual(try XCTUnwrap(res2).get().updated, 1)
        XCTAssertTrue(f.link.templateAckOps.contains(op2))

        // 3. Post-send 30s timeout still fires once all push packets were handed off.
        var res3: Result<TemplateSyncOutcome, TemplateSyncError>?
        let exp3 = expectation(description: "post-send timeout")
        f.controller.syncTemplates { res3 = $0; exp3.fulfill() }
        await drain(f)
        f.clock.date.addTimeInterval(31)
        f.controller.checkTimeouts()
        await fulfillment(of: [exp3], timeout: 5)
        XCTAssertEqual(res3, .failure(.timedOut))
        XCTAssertEqual(f.controller.status, .connected)

        // 4. Genuine 60s BLE send stall mid-frame disconnects cleanly instead of leaking partial output.
        try f.link.connect(pairing, limit: 20)
        f.link.stopAfterPackets = 1
        var res4: Result<TemplateSyncOutcome, TemplateSyncError>?
        let exp4 = expectation(description: "60s send stall disconnects")
        f.controller.syncTemplates { res4 = $0; exp4.fulfill() }
        await drain(f)
        XCTAssertFalse(f.link.canSend)
        f.clock.date.addTimeInterval(61)
        f.controller.checkTimeouts()
        await fulfillment(of: [exp4], timeout: 5)
        XCTAssertEqual(res4, .failure(.disconnected))
        XCTAssertEqual(f.controller.status, .searching)
        XCTAssertFalse(f.link.rejected.isEmpty)
    }

    @MainActor
    func testDisconnectBeforeTemplateStatePersistsPushedHashesSoDeleteDoesNotResurrectOnResync() async throws {
        let f = try Fixture(test: self)
        let pairing = try pair(f)

        // 1. Create and complete initial sync for baseEntry ("旧本文").
        var baseEntry: HistoryEntry?
        let createBase = expectation(description: "create base template")
        f.monitor.createTemplate(text: "旧本文", title: "同期済", tag: "仕事") {
            if case .success(let entry) = $0 { baseEntry = entry }
            createBase.fulfill()
        }
        await fulfillment(of: [createBase], timeout: 5)
        await drain(f)
        let syncedEntry = try XCTUnwrap(baseEntry)

        try f.link.connect(pairing, limit: 512)
        let initSyncDone = expectation(description: "initial sync")
        f.controller.syncTemplates { _ in initSyncDone.fulfill() }
        await drain(f)
        let initPush = try XCTUnwrap(f.link.templatePushes.last)
        let nowMs1 = Int64(f.clock.date.timeIntervalSince1970 * 1000)
        try f.link.send(.state(
            op: initPush.op, part: 0, total: 1,
            page: TemplateSyncPage(version: 1, sentAt: nowMs1, templates: initPush.page.templates, tombstones: [])
        ))
        await fulfillment(of: [initSyncDone], timeout: 5)
        await drain(f)

        // 2. Edit syncedEntry ("旧本文" -> "編集済本文") and create a brand-new template ("新規本文").
        let editDone = expectation(description: "edit template")
        f.monitor.updateTemplate(syncedEntry, text: "編集済本文", title: "同期済", tag: "仕事") { _ in editDone.fulfill() }
        await fulfillment(of: [editDone], timeout: 5)
        var newEntry: HistoryEntry?
        let createNew = expectation(description: "create new template")
        f.monitor.createTemplate(text: "新規本文", title: "新規", tag: nil) {
            if case .success(let entry) = $0 { newEntry = entry }
            createNew.fulfill()
        }
        await fulfillment(of: [createNew], timeout: 5)
        await drain(f)
        let createdNew = try XCTUnwrap(newEntry)

        // 3. Push both to PC; PC merges and saves them, then BLE disconnects BEFORE tpl_state arrives.
        var pushResult: Result<TemplateSyncOutcome, TemplateSyncError>?
        let disconnectExp = expectation(description: "sync fails on disconnect")
        f.controller.syncTemplates { pushResult = $0; disconnectExp.fulfill() }
        await drain(f)
        let droppedPush = try XCTUnwrap(f.link.templatePushes.last)
        let pcSavedAfterDrop = try TemplateSyncMerge.merge(
            pc: TemplateSyncState(templates: initPush.page.templates, tombstones: []),
            remote: TemplateSyncState(templates: droppedPush.page.templates, tombstones: droppedPush.page.tombstones),
            nowMillis: Int64(f.clock.date.timeIntervalSince1970 * 1000),
            remoteSentAtMillis: droppedPush.page.sentAt
        )
        XCTAssertEqual(pcSavedAfterDrop.templates.count, 2)
        f.link.disconnect()
        await fulfillment(of: [disconnectExp], timeout: 5)
        XCTAssertEqual(pushResult, .failure(.disconnected))

        // 4. Delete both templates on iOS while disconnected, then reconnect and sync again.
        let latestEdited = try XCTUnwrap(f.monitor.entries.first { $0.id == syncedEntry.id })
        let del1 = expectation(description: "delete edited")
        f.monitor.delete(latestEdited) { _ in del1.fulfill() }
        await fulfillment(of: [del1], timeout: 5)
        let del2 = expectation(description: "delete new")
        f.monitor.delete(createdNew) { _ in del2.fulfill() }
        await fulfillment(of: [del2], timeout: 5)
        await drain(f)

        try f.link.connect(pairing, limit: 512)
        let resyncDone = expectation(description: "resync completes")
        f.controller.syncTemplates { _ in resyncDone.fulfill() }
        await drain(f)
        let resyncPush = try XCTUnwrap(f.link.templatePushes.last)
        let mergedAfterDelete = try TemplateSyncMerge.merge(
            pc: TemplateSyncState(templates: pcSavedAfterDrop.templates, tombstones: pcSavedAfterDrop.tombstones),
            remote: TemplateSyncState(templates: resyncPush.page.templates, tombstones: resyncPush.page.tombstones),
            nowMillis: Int64(f.clock.date.timeIntervalSince1970 * 1000),
            remoteSentAtMillis: resyncPush.page.sentAt
        )
        XCTAssertTrue(mergedAfterDelete.templates.isEmpty)
        XCTAssertEqual(mergedAfterDelete.tombstones.count, 2)

        try f.link.send(.state(
            op: resyncPush.op, part: 0, total: 1,
            page: TemplateSyncPage(
                version: 1,
                sentAt: Int64(f.clock.date.timeIntervalSince1970 * 1000),
                templates: mergedAfterDelete.templates,
                tombstones: mergedAfterDelete.tombstones
            )
        ))
        await fulfillment(of: [resyncDone], timeout: 5)
        await drain(f)
        XCTAssertTrue(f.monitor.entries.filter(\.isTemplate).isEmpty)
    }
}
