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
    var messages: [SyncMessage] = []
    var devices: [String] = []
    var packets: [Data] = []
    var authenticatedId: UUID?
    var acceptedPadIds: [UUID] = []
    var corruptWelcome = false
    var welcomeVersion: UInt8?
    var dropsNotifications = false
    var stopAfterPackets: Int?
    private var pc: SyncPcHandshake?
    private var assembler: SyncPacketAssembler?
    private var sender: SyncFrameSender?
    private var receiver: SyncFrameReceiver?
    private(set) var limit = 20
    let id = UUID()
    func start(remembered: UUID?) { starts += 1; self.remembered = remembered }
    func stop() { stops += 1; canSend = false }
    func authenticated(_ id: UUID) { authenticatedId = id }
    func reconnect(rejectForTenMinutes: Bool) {
        rejected.append(rejectForTenMinutes); disconnect()
    }
    func disconnect() { canSend = false; onEvent?(.disconnected) }
    func connect(_ pairing: SyncPairing, limit: Int = 20) throws {
        self.limit = limit
        pc = try SyncPcHandshake(pairing: pairing)
        assembler = try SyncPacketAssembler(packetLimit: limit)
        sender = nil; receiver = nil; canSend = true
        onEvent?(.ready(id: id, writeLimit: limit, receiveLimit: 512))
    }
    func connectWithoutWelcome(limit: Int = 512) {
        self.limit = limit
        pc = nil; assembler = nil; sender = nil; receiver = nil; canSend = true
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
            if frame.first == 1 {
                var welcome = try pc.acceptHello(frame)
                if let welcomeVersion { welcome[1] = welcomeVersion }
                if corruptWelcome { welcome[welcome.count - 1] ^= 1 }
                try deliver(welcome)
            } else if frame.first == 3 {
                let keys = try pc.acceptAuth(frame)
                sender = try SyncFrameSender(key: keys.pcToPad)
                receiver = try SyncFrameReceiver(key: keys.padToPc)
                if let id = pc.authenticatedPadId { acceptedPadIds.append(id) }
            } else {
                let receiver = try XCTUnwrap(receiver, "Data must follow AUTH")
                let message = try SyncMessageCodec.decode(receiver.open(frame))
                if case .device(let kind) = message { devices.append(kind) } else { messages.append(message) }
            }
        } catch { XCTFail("Fake PC protocol failure: \(error)") }
    }
    func send(_ message: SyncMessage) throws {
        let sender = try XCTUnwrap(sender)
        let frame = try sender.seal(SyncMessageCodec.encode(message))
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
             readFails: Bool = false, beforeInit: ((URL, URL) throws -> Void)? = nil) throws {
            root = try ImageTestSupport.directory(test)
            let suite = UUID().uuidString
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let defaults = self.defaults
            test.addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
            HistoryRetention.never.save(to: defaults)
            keys = SyncTestKeys(); keys.readFails = readFails
            link = SyncTestLink(); board = SyncTestPasteboard()
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
                    return try HistoryDatabase(url: databaseURL)
                }, schedulesMaintenance: false,
                imageDirectory: imageDirectory, pasteboard: board,
                resumesRecordingOnInit: false)
            let link = self.link
            let clock = self.clock
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
    private func awaitSave(_ fixture: Fixture, savedCount: Int) async {
        if fixture.monitor.savedCount < savedCount {
            let done = expectation(description: "saved \(savedCount)")
            let cancellable = fixture.monitor.$savedCount.first { $0 >= savedCount }.sink { _ in done.fulfill() }
            await fulfillment(of: [done], timeout: 5)
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

    private func makeGrayImageData(width: Int, height: Int, type: UTType) throws -> Data {
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
        XCTAssertTrue(CGImageDestinationFinalize(destination))
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
    func testThreeHandshakeFailuresAndTimeoutsPauseForUpdateAndPostHelloDisconnectDoesNot() async throws {
        let f1 = try Fixture(test: self), pairing1 = try pair(f1)
        f1.link.corruptWelcome = true
        for _ in 0..<2 {
            try f1.link.connect(pairing1)
            XCTAssertFalse(f1.controller.requiresPeerUpdate)
        }
        try f1.link.connect(pairing1)
        XCTAssertTrue(f1.controller.requiresPeerUpdate)
        XCTAssertEqual(f1.controller.status, .unsupported)
        XCTAssertEqual(f1.link.stops, 1)
        XCTAssertEqual(f1.link.rejected, [true, true])

        f1.link.corruptWelcome = false
        f1.controller.retryAfterPeerUpdate()
        try f1.link.connect(pairing1)
        XCTAssertEqual(f1.controller.status, .connected)

        let f2 = try Fixture(test: self), _ = try pair(f2)
        for _ in 0..<2 {
            f2.link.connectWithoutWelcome()
            f2.clock.date.addTimeInterval(31)
            f2.controller.checkTimeouts()
            XCTAssertFalse(f2.controller.requiresPeerUpdate)
        }
        f2.link.connectWithoutWelcome()
        f2.clock.date.addTimeInterval(31)
        f2.controller.checkTimeouts()
        XCTAssertTrue(f2.controller.requiresPeerUpdate)
        XCTAssertEqual(f2.controller.status, .unsupported)
        XCTAssertEqual(f2.link.stops, 1)

        let f3 = try Fixture(test: self), pairing3 = try pair(f3)
        for _ in 0..<3 {
            f3.link.connectWithoutWelcome()
            f3.link.disconnect()
        }
        XCTAssertFalse(f3.controller.requiresPeerUpdate)
        try f3.link.connect(pairing3)
        XCTAssertEqual(f3.controller.status, .connected)
    }

    @MainActor
    func testOversizedPngAndJpegAreNotQueuedOrSentToPC() async throws {
        let f = try Fixture(test: self), pairing = try pair(f)
        try f.link.connect(pairing, limit: 512)
        let bigPng = try makeGrayImageData(width: 10_000, height: 4_001, type: .png)
        let bigJpeg = try makeGrayImageData(width: 10_000, height: 4_001, type: .jpeg)
        f.monitor.saveManually([makeImageProvider(data: bigPng, type: "public.png")], receivedAt: Date())
        await awaitSave(f, savedCount: 1)
        f.monitor.saveManually([makeImageProvider(data: bigJpeg, type: "public.jpeg")], receivedAt: Date().addingTimeInterval(1))
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

        let bigPng = try makeGrayImageData(width: 10_000, height: 4_001, type: .png)
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
        let data1 = Data(repeating: 11, count: SyncProtocol.chunkBytes + 5)
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
        XCTAssertEqual(f.link.chunks.count, 1)
        XCTAssertEqual(f.link.chunks[0].id, offer1.id)
        XCTAssertEqual(f.link.chunks[0].data.count, SyncProtocol.chunkBytes)
        XCTAssertEqual(f.link.offers.count, 1)

        try f.link.send(.resume(id: offer1.id, offset: SyncProtocol.chunkBytes))
        XCTAssertEqual(f.link.chunks.count, 2)
        XCTAssertEqual(f.link.chunks[1].id, offer1.id)
        XCTAssertEqual(f.link.chunks[1].data.count, 5)
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
        f.monitor.saveManually([try makeFileProvider(in: f.root, bytes: Data(), name: "empty.bin")], receivedAt: baseDate.addingTimeInterval(3))
        await awaitSave(f, savedCount: 4)
        f.monitor.saveManually([try makeFileProvider(in: f.root, bytes: Data([9]), name: "after.bin")], receivedAt: baseDate.addingTimeInterval(4))
        await awaitSave(f, savedCount: 5)
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
        f.monitor.saveManually([try makeFileProvider(in: f.root, bytes: Data(repeating: 1, count: 10), name: "ten.bin")], receivedAt: Date())
        await awaitSave(f, savedCount: 1)
        try f.link.connect(pairing, limit: 512)
        let tenOffer = try XCTUnwrap(f.link.offers.first)
        try f.link.send(.resume(id: tenOffer.id, offset: 10))
        XCTAssertEqual(f.link.rejected, [false])
        try f.link.connect(pairing, limit: 512)
        try f.link.send(.ack(ids: [tenOffer.id]))

        f.monitor.saveManually([try makeFileProvider(in: f.root, bytes: Data(), name: "zero.bin")], receivedAt: Date().addingTimeInterval(1))
        await awaitSave(f, savedCount: 2)
        // The reconnect offers ten.bin again, because it was not acknowledged before the drop.
        XCTAssertEqual(f.link.offers.map(\.filename), ["ten.bin", "ten.bin", "zero.bin"])
        let zeroOffer = try XCTUnwrap(f.link.offers.last)
        XCTAssertEqual(zeroOffer.size, 0)
        try f.link.send(.resume(id: zeroOffer.id, offset: 0))
        XCTAssertEqual(f.link.rejected, [false, false])
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
}
