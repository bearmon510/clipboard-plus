import UIKit
import XCTest
@testable import ClipboardPlus

@MainActor
private final class SyncTestKeys: PCSyncKeyStore {
    var key: Data?
    var fails = false
    var reads = 0
    func read() throws -> Data? { reads += 1; return key }
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
    var string: String? {
        get { value }
        set { if acceptsWrites { value = newValue; changeCount += 1 } }
    }
    var hasImages: Bool { false }
    var hasStrings: Bool { value != nil }
    var types: [String] { ["public.utf8-plain-text"] }
    var image: UIImage? { nil }
    func data(forPasteboardType: String) -> Data? { nil }
    func setData(_ data: Data, forPasteboardType: String) {}
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
    var packets: [Data] = []
    var authenticatedId: UUID?
    var acceptedPadIds: [UUID] = []
    var corruptWelcome = false
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
                if corruptWelcome { welcome[welcome.count - 1] ^= 1 }
                try deliver(welcome)
            } else if frame.first == 3 {
                let keys = try pc.acceptAuth(frame)
                sender = try SyncFrameSender(key: keys.pcToPad)
                receiver = try SyncFrameReceiver(key: keys.padToPc)
                if let id = pc.authenticatedPadId { acceptedPadIds.append(id) }
            } else {
                let receiver = try XCTUnwrap(receiver, "Data must follow AUTH")
                messages.append(try SyncMessageCodec.decode(receiver.open(frame)))
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
        var creations: Int { link.starts }
        init(test: XCTestCase, prepaired: SyncPairing? = nil, storageFails: Bool = false) throws {
            root = try ImageTestSupport.directory(test)
            let suite = UUID().uuidString
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let defaults = self.defaults
            test.addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
            HistoryRetention.never.save(to: defaults)
            keys = SyncTestKeys(); link = SyncTestLink(); board = SyncTestPasteboard()
            if let prepaired {
                try keys.write(prepaired.key)
                PCSyncSettings(defaults: defaults).save(prepaired)
            }
            let databaseURL = root.appendingPathComponent("history.sqlite")
            let log = MeasurementLog(writer: MeasurementLogWriter(fileURL: root.appendingPathComponent("log.tsv")))
            log.includeTextPreview = true
            monitor = ClipboardMonitor(defaults: defaults, log: log,
                makeDatabase: {
                    if storageFails { throw CocoaError(.fileWriteOutOfSpace) }
                    return try HistoryDatabase(url: databaseURL)
                }, schedulesMaintenance: false,
                imageDirectory: root.appendingPathComponent("images"), pasteboard: board,
                resumesRecordingOnInit: false)
            let link = self.link
            let clock = self.clock
            controller = PCSyncController(monitor: monitor, defaults: defaults, keyStore: keys,
                now: { clock.date }, schedulesTimeouts: false, makeTransport: { _ in link })
        }
    }
    @MainActor
    private func drain(_ fixture: Fixture) async {
        let done = expectation(description: "history and log committed")
        fixture.monitor.pendingDeletion { _ in
            fixture.monitor.log.flush(context: fixture.monitor.logContext()) { done.fulfill() }
        }
        await fulfillment(of: [done], timeout: 5)
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
        // A later local copy of identical text still gets sent.
        f.board.string = secret; f.monitor.pollPasteboard(); await drain(f)
        XCTAssertEqual(f.monitor.entries.first?.collectionCount, 3)
        XCTAssertEqual(f.link.items.count, 1)
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
        XCTAssertEqual(f.link.items.count, 3)
    }

    @MainActor
    func testQueueKeepsNewestFiftyAndClearsOnUnpair() async throws {
        let f = try Fixture(test: self)
        let pairing = try pair(f)
        for index in 0..<52 { f.monitor.saveManually(["item \(index)"], receivedAt: Date()) }
        try f.link.connect(pairing)
        XCTAssertEqual(f.link.items.count, 50)
        if case .item(_, _, _, let text) = f.link.items[0] { XCTAssertEqual(text, "item 2") }
        f.controller.unpair()
        try f.controller.pair(code: pairing.qrString())
        try f.link.connect(pairing)
        XCTAssertEqual(f.link.items.count, 50)
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
            XCTAssertEqual(f.link.packets.map(\.count).max(), min(limit, 512))
            XCTAssertEqual(f.link.items.count, 1)
            await drain(f)
        }
    }
}
