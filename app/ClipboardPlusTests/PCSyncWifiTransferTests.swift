import Combine
import CryptoKit
import Foundation
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import ClipboardPlus

@MainActor
private final class WifiTestKeys: PCSyncKeyStore {
    var key: Data?
    func read() throws -> Data? { key }
    func write(_ key: Data) throws { self.key = key }
    func delete() throws { key = nil }
}

@MainActor
private final class WifiTestClock {
    var date = Date(timeIntervalSince1970: 1_795_000_000)
}

@MainActor
private final class WifiTestPasteboard: ClipboardPasteboard {
    var changeCount = 0
    private var textValue: String?
    private var dataValue: (Data, String)?
    private var providers: [NSItemProvider] = []
    var string: String? {
        get { textValue }
        set { textValue = newValue; dataValue = nil; providers = []; changeCount += 1 }
    }
    var hasImages: Bool { dataValue != nil }
    var hasStrings: Bool { textValue != nil }
    var types: [String] {
        if let type = dataValue?.1 { return [type] }
        if !providers.isEmpty { return providers.flatMap { $0.registeredTypeIdentifiers } }
        return ["public.utf8-plain-text"]
    }
    var image: UIImage? { nil }
    var itemProviders: [NSItemProvider] { providers }
    func writeFileProviders(_ providers: [NSItemProvider]) -> Bool {
        self.providers = providers; textValue = nil; dataValue = nil; changeCount += 1
        return true
    }
    func data(forPasteboardType pasteboardType: String) -> Data? {
        dataValue?.1 == pasteboardType ? dataValue?.0 : nil
    }
    func setData(_ data: Data, forPasteboardType pasteboardType: String) {
        dataValue = (data, pasteboardType); textValue = nil; providers = []; changeCount += 1
    }
}

@MainActor
private final class WifiTestBleLink: PCSyncTransport {
    var onEvent: ((PCSyncTransportEvent) -> Void)?
    var canSend = true
    var messages: [SyncMessage] = []
    var wifiControlMessages: [WifiControlMessage] = []
    var rejected: [Bool] = []
    var negotiatedVersions: [UInt8] = []
    var rejectHelloWithMismatchVersion: [UInt8: UInt8] = [:]
    var pcSessionKeys: SyncSessionKeys?
    var id = UUID()

    private var pc: SyncPcHandshake?
    private var currentPairing: SyncPairing?
    private var versionRejectedThisConnection = false
    private var assembler: SyncPacketAssembler?
    private var sender: SyncFrameSender?
    private var receiver: SyncFrameReceiver?
    private var limit = 512

    func start(remembered: UUID?) {}
    func stop() {
        canSend = false
        pcSessionKeys = nil
    }
    func authenticated(_ id: UUID) {}

    @discardableResult
    func reconnect(reason: PCSyncDisconnectReason) -> TimeInterval {
        rejected.append(reason == .rejectTenMinutes)
        canSend = false
        pcSessionKeys = nil
        onEvent?(.disconnected(nextReconnectAt: nil))
        return 0
    }

    func disconnect() {
        canSend = false
        pcSessionKeys = nil
        onEvent?(.disconnected(nextReconnectAt: nil))
    }

    func connect(_ pairing: SyncPairing, limit: Int = 512) throws {
        self.limit = limit
        currentPairing = pairing
        versionRejectedThisConnection = false
        pc = try SyncPcHandshake(pairing: pairing)
        assembler = try SyncPacketAssembler(packetLimit: limit)
        sender = nil
        receiver = nil
        pcSessionKeys = nil
        canSend = true
        onEvent?(.ready(id: id, writeLimit: limit, receiveLimit: 512))
    }

    func write(_ packet: Data) {
        XCTAssertTrue(canSend)
        XCTAssertLessThanOrEqual(packet.count, limit)
        do {
            guard let frame = try assembler?.append(packet), let pc else { return }
            if versionRejectedThisConnection { return }
            if frame.first == 1 {
                if frame.count == 50, let advertised = rejectHelloWithMismatchVersion[frame[1]] {
                    versionRejectedThisConnection = true
                    let pcId = currentPairing?.pcId ?? UUID()
                    let mismatch = Data([2, advertised]) + SyncProtocol.idBytes(pcId) + Data(repeating: 0, count: 64)
                    try deliver(mismatch)
                    return
                }
                let welcome = try pc.acceptHello(frame)
                try deliver(welcome)
            } else if frame.first == 3 {
                let keys = try pc.acceptAuth(frame)
                pcSessionKeys = keys
                sender = try SyncFrameSender(key: keys.pcToPad)
                receiver = try SyncFrameReceiver(key: keys.padToPc)
                if let ver = pc.negotiatedVersion {
                    negotiatedVersions.append(ver)
                }
            } else {
                let rx = try XCTUnwrap(receiver)
                let plaintext = try rx.open(frame)
                do {
                    let syncMessage = try SyncMessageCodec.decode(plaintext)
                    if case .device = syncMessage {
                        return
                    }
                    messages.append(syncMessage)
                } catch SyncProtocolError.format {
                    let wifiMessage = try WifiControlMessageCodec.decode(plaintext)
                    wifiControlMessages.append(wifiMessage)
                }
            }
        } catch {
            XCTFail("Fake PC BLE failure: \(error)")
        }
    }

    func send(_ message: SyncMessage) throws {
        let tx = try XCTUnwrap(sender)
        let plaintext = try SyncMessageCodec.encode(message)
        try deliver(try tx.seal(plaintext))
    }

    func send(_ message: WifiControlMessage) throws {
        let tx = try XCTUnwrap(sender)
        let plaintext = try WifiControlMessageCodec.encode(message)
        try deliver(try tx.seal(plaintext))
    }

    func sendLargeOffer(_ offer: SyncOffer) throws {
        let tx = try XCTUnwrap(sender)
        let plaintext = try WifiStreamMessageCodec.encode(.offer(offer))
        try deliver(try tx.seal(plaintext))
    }

    func deliver(_ frame: Data) throws {
        let packets = try SyncPacketizer.split(frame, packetLimit: 182)
        for packet in packets {
            onEvent?(.packet(packet))
        }
    }

    var offers: [SyncOffer] {
        messages.compactMap { msg -> SyncOffer? in
            if case .offer(let offer) = msg { return offer }
            return nil
        }
    }

    var resumes: [(id: UUID, offset: Int)] {
        messages.compactMap { msg -> (id: UUID, offset: Int)? in
            if case let .resume(id, offset) = msg { return (id, offset) }
            return nil
        }
    }

    var ackIDs: [UUID] {
        messages.flatMap { msg -> [UUID] in
            if case .ack(let ids) = msg { return ids }
            return []
        }
    }

    var wifiRequests: [(direction: WifiTransferDirection, ids: [UUID])] {
        wifiControlMessages.compactMap { msg -> (WifiTransferDirection, [UUID])? in
            if case let .request(direction, ids) = msg { return (direction, ids) }
            return nil
        }
    }

    var wifiJoinResults: [(session: UUID, status: WifiJoinStatus)] {
        wifiControlMessages.compactMap { msg -> (UUID, WifiJoinStatus)? in
            if case let .joinResult(session, status) = msg { return (session, status) }
            return nil
        }
    }

    var wifiCancels: [(session: UUID, reason: WifiCancelReason)] {
        wifiControlMessages.compactMap { msg -> (UUID, WifiCancelReason)? in
            if case let .cancel(session, reason) = msg { return (session, reason) }
            return nil
        }
    }
}

private enum FakePipeFault: Sendable {
    case none
    case cutAfterBytes(Int)
    case stallAllReads
    case stallAfterBytes(Int)
}

private actor FakeByteChannel {
    private let fault: FakePipeFault
    private var queue: [Data] = []
    private var waiter: CheckedContinuation<Data, Never>?
    private var closed = false
    private var writtenBytes = 0
    private var readBytes = 0

    init(fault: FakePipeFault = .none) {
        self.fault = fault
    }

    func close() {
        guard !closed else { return }
        closed = true
        if let cont = waiter {
            waiter = nil
            cont.resume(returning: Data())
        }
    }

    func write(_ raw: Data) throws {
        if closed { throw SyncProtocolError.packet }
        let data = Data(raw)
        switch fault {
        case .none, .stallAllReads, .stallAfterBytes:
            enqueue(data)
        case let .cutAfterBytes(limit):
            let remaining = limit - writtenBytes
            if remaining <= 0 {
                close()
                throw SyncProtocolError.packet
            }
            if data.count >= remaining {
                let prefix = Data(data.prefix(remaining))
                writtenBytes += prefix.count
                enqueue(prefix)
                close()
                return
            }
            writtenBytes += data.count
            enqueue(data)
        }
    }

    private func enqueue(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        if let cont = waiter {
            waiter = nil
            cont.resume(returning: chunk)
        } else {
            queue.append(chunk)
        }
    }

    func read(maxLength: Int) async -> Data {
        switch fault {
        case .stallAllReads:
            if closed { return Data() }
            return await waitUntilClosedOrData()
        case let .stallAfterBytes(limit):
            if readBytes >= limit {
                if closed { return Data() }
                return await waitUntilClosedOrData()
            }
            let allowed = min(maxLength, limit - readBytes)
            let chunk = await popOrWait(maxLength: allowed)
            readBytes += chunk.count
            return chunk
        case .none, .cutAfterBytes:
            return await popOrWait(maxLength: maxLength)
        }
    }

    private func waitUntilClosedOrData() async -> Data {
        if closed { return Data() }
        return await withCheckedContinuation { (cont: CheckedContinuation<Data, Never>) in
            if closed {
                cont.resume(returning: Data())
            } else {
                waiter = cont
            }
        }
    }

    private func popOrWait(maxLength: Int) async -> Data {
        if !queue.isEmpty {
            return sliceHead(maxLength: maxLength)
        }
        if closed {
            return Data()
        }
        let received = await withCheckedContinuation { (cont: CheckedContinuation<Data, Never>) in
            if !queue.isEmpty {
                cont.resume(returning: queue.removeFirst())
            } else if closed {
                cont.resume(returning: Data())
            } else {
                waiter = cont
            }
        }
        if received.count <= maxLength {
            return received
        }
        let prefix = Data(received.prefix(maxLength))
        let rest = Data(received.dropFirst(maxLength))
        queue.insert(rest, at: 0)
        return prefix
    }

    private func sliceHead(maxLength: Int) -> Data {
        let head = queue.removeFirst()
        if head.count <= maxLength {
            return head
        }
        let prefix = Data(head.prefix(maxLength))
        let rest = Data(head.dropFirst(maxLength))
        queue.insert(rest, at: 0)
        return prefix
    }
}

private actor FakeWifiConnection: PCSyncWifiConnection {
    private enum ReadOutcome: Sendable {
        case data(Data)
        case timedOut
    }

    private let incoming: FakeByteChannel
    private let outgoing: FakeByteChannel
    private var timeoutSeconds: TimeInterval
    private(set) var timeoutHistory: [TimeInterval]
    private(set) var isClosed = false

    init(incoming: FakeByteChannel, outgoing: FakeByteChannel, initialReadTimeout: TimeInterval) {
        self.incoming = incoming
        self.outgoing = outgoing
        self.timeoutSeconds = initialReadTimeout
        self.timeoutHistory = [initialReadTimeout]
    }

    func setIdleTimeout(_ seconds: TimeInterval) async {
        timeoutSeconds = seconds
        timeoutHistory.append(seconds)
    }

    func close() async {
        isClosed = true
        await incoming.close()
        await outgoing.close()
    }

    func read(maxLength: Int) async throws -> Data {
        if isClosed { throw PCSyncWifiClientError.cancelled }
        let limitSeconds = timeoutSeconds
        let channel = incoming
        let outcome = try await withThrowingTaskGroup(of: ReadOutcome.self) { group in
            group.addTask {
                let bytes = await channel.read(maxLength: maxLength)
                return .data(bytes)
            }
            group.addTask {
                let nanos = UInt64(max(0.01, limitSeconds) * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanos)
                return .timedOut
            }
            guard let first = try await group.next() else {
                group.cancelAll()
                throw PCSyncWifiClientError.cancelled
            }
            group.cancelAll()
            if case .timedOut = first {
                await channel.close()
            }
            return first
        }
        switch outcome {
        case .data(let data):
            return data
        case .timedOut:
            throw PCSyncWifiClientError.readTimeout
        }
    }

    func write(_ data: Data) async throws {
        if isClosed { throw PCSyncWifiClientError.cancelled }
        try await outgoing.write(data)
    }
}

private struct FakePcStreamEnd: WifiByteStream {
    let incoming: FakeByteChannel
    let outgoing: FakeByteChannel

    func read(maxLength: Int) async throws -> Data {
        await incoming.read(maxLength: maxLength)
    }

    func write(_ data: Data) async throws {
        try await outgoing.write(data)
    }

    func close() async {
        await incoming.close()
        await outgoing.close()
    }
}

private actor FakeWifiClient: PCSyncWifiClient {
    struct ConnectRecord: Equatable, Sendable {
        let host: String
        let port: Int
        let initialReadTimeout: TimeInterval
    }

    private var joinStatuses: [WifiJoinStatus] = []
    private var defaultJoinStatus: WifiJoinStatus = .joined
    private var connectHandler: (@Sendable (String, Int, TimeInterval) async throws -> any PCSyncWifiConnection)?
    private(set) var joinedSSIDs: [String] = []
    private(set) var leftSSIDs: [String] = []
    private(set) var connectRecords: [ConnectRecord] = []

    func enqueueJoinStatus(_ status: WifiJoinStatus) {
        joinStatuses.append(status)
    }

    func setDefaultJoinStatus(_ status: WifiJoinStatus) {
        defaultJoinStatus = status
    }

    func setConnectHandler(_ handler: (@Sendable (String, Int, TimeInterval) async throws -> any PCSyncWifiConnection)?) {
        connectHandler = handler
    }

    func join(ssid: String, passphrase: String, timeoutSeconds: TimeInterval) async -> WifiJoinStatus {
        joinedSSIDs.append(ssid)
        if !joinStatuses.isEmpty {
            return joinStatuses.removeFirst()
        }
        return defaultJoinStatus
    }

    func leave(ssid: String) async {
        leftSSIDs.append(ssid)
    }

    func connect(
        host: String,
        port: Int,
        timeoutSeconds: TimeInterval,
        initialReadTimeoutSeconds: TimeInterval
    ) async throws -> any PCSyncWifiConnection {
        connectRecords.append(ConnectRecord(host: host, port: port, initialReadTimeout: initialReadTimeoutSeconds))
        if let handler = connectHandler {
            return try await handler(host, port, initialReadTimeoutSeconds)
        }
        throw PCSyncWifiClientError.connectFailed
    }
}

final class PCSyncWifiTransferTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let root: URL
        let defaults: UserDefaults
        let keys = WifiTestKeys()
        let clock = WifiTestClock()
        let board = WifiTestPasteboard()
        let link = WifiTestBleLink()
        let wifiClient = FakeWifiClient()
        let monitor: ClipboardMonitor
        let controller: PCSyncController

        init(
            test: XCTestCase,
            timeouts: PCSyncController.WifiTransferTimeouts = PCSyncController.WifiTransferTimeouts(
                readySeconds: 8,
                tcpConnectSeconds: 1,
                preAuthReadSeconds: 0.15,
                idleSeconds: 0.25,
                cooldownSeconds: 600
            )
        ) throws {
            root = try ImageTestSupport.directory(test)
            let suite = UUID().uuidString
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let defaultsRef = self.defaults
            test.addTeardownBlock { defaultsRef.removePersistentDomain(forName: suite) }
            HistoryRetention.never.save(to: defaults)

            let dbURL = root.appendingPathComponent("history.sqlite")
            let imageDir = root.appendingPathComponent("images")
            let log = MeasurementLog(writer: MeasurementLogWriter(fileURL: root.appendingPathComponent("log.tsv")))
            log.includeTextPreview = true

            monitor = ClipboardMonitor(
                defaults: defaults,
                log: log,
                makeDatabase: { try HistoryDatabase(url: dbURL) },
                schedulesMaintenance: false,
                imageDirectory: imageDir,
                pasteboard: board,
                resumesRecordingOnInit: false
            )
            let clockRef = self.clock
            let linkRef = self.link
            controller = PCSyncController(
                monitor: monitor,
                defaults: defaults,
                keyStore: keys,
                now: { clockRef.date },
                schedulesTimeouts: false,
                makeTransport: { _ in linkRef },
                wifiClient: wifiClient,
                wifiTimeouts: timeouts
            )
        }
    }

    @MainActor
    private func pair(_ f: Fixture) throws -> SyncPairing {
        let pairing = try SyncPairing.create(name: "試験PC")
        try f.controller.pair(code: pairing.qrString())
        return pairing
    }

    @MainActor
    private func drain(_ f: Fixture) async {
        for _ in 0..<2 {
            let done = expectation(description: "drain")
            f.monitor.pendingDeletion { _ in
                f.monitor.log.flush(context: f.monitor.logContext()) { done.fulfill() }
            }
            await fulfillment(of: [done], timeout: 5)
        }
    }

    @MainActor
    private func awaitSave(_ f: Fixture, savedCount: Int) async {
        if f.monitor.savedCount < savedCount {
            let done = expectation(description: "saved \(savedCount)")
            let cancellable = f.monitor.$savedCount.first { $0 >= savedCount }.sink { _ in done.fulfill() }
            await fulfillment(of: [done], timeout: 15)
            cancellable.cancel()
        }
        await drain(f)
    }

    @MainActor
    private func waitUntil(timeoutSeconds: TimeInterval = 5, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private func makeFileProvider(in root: URL, bytes: Data, name: String) throws -> NSItemProvider {
        let url = root.appendingPathComponent("\(UUID().uuidString)-\(name)")
        try bytes.write(to: url)
        let provider = NSItemProvider()
        provider.suggestedName = name
        provider.registerFileRepresentation(forTypeIdentifier: "public.data", fileOptions: [], visibility: .all) { handler in
            handler(url, false, nil)
            return nil
        }
        return provider
    }

    private func makeDeterministicBytes(count: Int, seed: UInt8) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        for index in 0..<count {
            bytes[index] = UInt8(truncatingIfNeeded: (index &* 29) &+ Int(seed))
        }
        return Data(bytes)
    }

    private func makeOffer(id: UUID = UUID(), from: String, data: Data, name: String) -> SyncOffer {
        SyncOffer(
            id: id,
            at: 1_795_000_000_123,
            from: from,
            kind: "file",
            size: data.count,
            sha256: SyncEchoGuard.hash(data),
            name64: Data(name.utf8).base64EncodedString(),
            type: "public.data"
        )
    }

    private func makeReadyPayload(
        session: UUID = UUID(),
        ssid: String = "DIRECT-cp-SECRETSSID",
        passphrase: String = "SecretPassphrase1234567890!",
        ip: String = "192.168.137.1",
        port: Int = 49152,
        ttlSeconds: Int = 90
    ) -> WifiReadyPayload {
        let token = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        return WifiReadyPayload(
            session: session,
            ssid: ssid,
            passphrase: passphrase,
            ip: ip,
            port: port,
            token: token,
            ttlSeconds: ttlSeconds
        )
    }

    private func readLog(_ f: Fixture) async throws -> String {
        await drain(f)
        return try String(contentsOf: f.root.appendingPathComponent("log.tsv"), encoding: .utf8)
    }

    func testReceivePolicySmallAndBulkSizes() {
        let headerRead = PCSyncWifiReceivePolicy.receiveLengths(maxLength: 4_096)
        XCTAssertEqual(headerRead.minimum, 1)
        XCTAssertEqual(headerRead.maximum, 4_096)

        let tinyRead = PCSyncWifiReceivePolicy.receiveLengths(maxLength: 86)
        XCTAssertEqual(tinyRead.minimum, 1)
        XCTAssertEqual(tinyRead.maximum, 86)

        let midBulk = PCSyncWifiReceivePolicy.receiveLengths(maxLength: 20_000)
        XCTAssertEqual(midBulk.minimum, 20_000)
        XCTAssertEqual(midBulk.maximum, 20_000)

        let chunkRead = PCSyncWifiReceivePolicy.receiveLengths(maxLength: 258_100)
        XCTAssertEqual(chunkRead.minimum, 65_536)
        XCTAssertEqual(chunkRead.maximum, 258_100)

        let hugeRead = PCSyncWifiReceivePolicy.receiveLengths(maxLength: 1_000_000)
        XCTAssertEqual(hugeRead.minimum, 65_536)
        XCTAssertEqual(hugeRead.maximum, 524_288)

        let multiSend = PCSyncController.WifiTransferProgress(phase: .sending, itemIndex: 1, itemCount: 3, bytes: 450_000, totalBytes: 1_000_000)
        XCTAssertEqual(multiSend.percent, 45)
        XCTAssertEqual(multiSend.summaryText, "Wi-Fi で送っています（3件のうち1件、45%）")

        let singleSend = PCSyncController.WifiTransferProgress(phase: .sending, itemIndex: 1, itemCount: 1, bytes: 500_000, totalBytes: 1_000_000)
        XCTAssertEqual(singleSend.summaryText, "Wi-Fi で送っています（50%）")

        let singleRecv = PCSyncController.WifiTransferProgress(phase: .receiving, itemIndex: 1, itemCount: 1, bytes: 0, totalBytes: 0)
        XCTAssertEqual(singleRecv.percent, 100)
        XCTAssertEqual(singleRecv.summaryText, "Wi-Fi で受け取っています（100%）")

        let joining = PCSyncController.WifiTransferProgress(phase: .joining, itemIndex: 0, itemCount: 2, bytes: 0, totalBytes: 0)
        XCTAssertEqual(joining.summaryText, "一時Wi-Fiへつないでいます")
    }

    @MainActor
    func testSettingsDefaultsPersistenceAndThresholdSelection() async throws {
        let f = try Fixture(test: self)
        XCTAssertTrue(f.controller.usesWifiForLargeItems)
        XCTAssertEqual(f.controller.wifiThreshold, .kb500)
        XCTAssertEqual(PCSyncWifiThreshold.kb500.rawValue, SyncProtocol.defaultWifiThresholdBytes)
        XCTAssertEqual(PCSyncWifiThreshold.kb500.rawValue, 512_000)

        f.controller.wifiThreshold = .kb200
        f.controller.usesWifiForLargeItems = false
        let reloaded = PCSyncSettings(defaults: f.defaults)
        XCTAssertFalse(reloaded.usesWifiForLargeItems)
        XCTAssertEqual(reloaded.wifiThreshold, .kb200)

        let pairing = try pair(f)
        f.monitor.updateScene("active")
        try f.link.connect(pairing, limit: 512)

        // With Wi-Fi disabled, a 600 KB item goes over BLE directly.
        let data600 = makeDeterministicBytes(count: 600_000, seed: 1)
        f.monitor.saveManually([try makeFileProvider(in: f.root, bytes: data600, name: "ble600.bin")], receivedAt: f.clock.date)
        await awaitSave(f, savedCount: 1)
        XCTAssertTrue(f.link.wifiRequests.isEmpty)
        XCTAssertEqual(f.link.offers.count, 1)
        let bleOffer = try XCTUnwrap(f.link.offers.first)
        try f.link.send(.ack(ids: [bleOffer.id]))
        XCTAssertEqual(f.controller.pendingCount, 0)

        // Enable Wi-Fi with 200 KB threshold: a 250 KB item triggers wifi_request.
        f.controller.usesWifiForLargeItems = true
        f.controller.wifiThreshold = .kb200
        let data250 = makeDeterministicBytes(count: 250_000, seed: 2)
        f.monitor.saveManually([try makeFileProvider(in: f.root, bytes: data250, name: "wifi250.bin")], receivedAt: f.clock.date.addingTimeInterval(1))
        await awaitSave(f, savedCount: 2)
        XCTAssertEqual(f.link.wifiRequests.count, 1)
        XCTAssertEqual(f.link.wifiRequests.first?.direction, .send)
        XCTAssertEqual(f.link.offers.count, 1)
    }

    @MainActor
    func testBidirectionalWifiTransferRoundtripUpdatesHistoryClearsPendingAndRedactsLogs() async throws {
        let f = try Fixture(test: self)
        let pairing = try pair(f)
        f.controller.copiesReceivedToPasteboard = true
        f.monitor.updateScene("background")
        try f.link.connect(pairing, limit: 512)

        let out1 = makeDeterministicBytes(count: 550_000, seed: 11)
        let out2 = makeDeterministicBytes(count: 520_000, seed: 22)
        f.monitor.saveManually([try makeFileProvider(in: f.root, bytes: out1, name: "secret-out1.bin")], receivedAt: f.clock.date)
        await awaitSave(f, savedCount: 1)
        f.monitor.saveManually([try makeFileProvider(in: f.root, bytes: out2, name: "secret-out2.bin")], receivedAt: f.clock.date.addingTimeInterval(1))
        await awaitSave(f, savedCount: 2)

        let inData = makeDeterministicBytes(count: 610_000, seed: 33)
        let inOffer = makeOffer(from: "pc", data: inData, name: "secret-incoming.bin")
        try f.link.send(.offer(inOffer))

        // Still in background: no wifi_request and no BLE offer/resume.
        XCTAssertTrue(f.link.wifiRequests.isEmpty)
        XCTAssertTrue(f.link.offers.isEmpty)
        XCTAssertTrue(f.link.resumes.isEmpty)

        // Move to foreground: a single combined `.both` wifi_request is sent with all 3 IDs.
        f.monitor.updateScene("active")
        XCTAssertEqual(f.link.wifiRequests.count, 1)
        let req = try XCTUnwrap(f.link.wifiRequests.first)
        XCTAssertEqual(req.direction, .both)
        XCTAssertEqual(req.ids.count, 3)
        XCTAssertTrue(req.ids.contains(inOffer.id))

        let ready = makeReadyPayload()
        let bleKeys = try XCTUnwrap(f.link.pcSessionKeys)
        let pcTransferKeys = try WifiTransferKeys.derive(bleKeys: bleKeys, token: ready.token, session: ready.session)
        let pcReplayGuard = try WifiSessionReplayGuard()
        let pcSink = InMemoryWifiTransferSink()
        let pcOutgoing: [any WifiTransferSource] = [InMemoryWifiTransferSource(offer: inOffer, payload: inData)]

        let padToPc = FakeByteChannel()
        let pcToPad = FakeByteChannel()
        let padConn = FakeWifiConnection(incoming: pcToPad, outgoing: padToPc, initialReadTimeout: 0.15)
        let pcEnd = FakePcStreamEnd(incoming: padToPc, outgoing: pcToPad)

        await f.wifiClient.setConnectHandler { _, _, initialTimeout in
            XCTAssertEqual(initialTimeout, 0.15, accuracy: 0.001)
            return padConn
        }

        let pcTask = Task {
            try await WifiTransferEngine.runPcSession(
                stream: pcEnd,
                keys: pcTransferKeys,
                outgoing: pcOutgoing,
                sink: pcSink,
                replayGuard: pcReplayGuard
            )
        }

        try f.link.send(.ready(ready))

        let finished = await waitUntil(timeoutSeconds: 10) {
            f.controller.pendingCount == 0 && f.monitor.entries.contains(where: { $0.source == .pc && $0.kind == .file }) && f.controller.wifiTransferProgress == nil
        }
        XCTAssertTrue(finished)
        let pcResult = try await pcTask.value

        XCTAssertEqual(pcResult.received.count, 2)
        XCTAssertEqual(pcResult.sent.count, 1)
        let outId1 = req.ids[0]
        let outId2 = req.ids[1]
        let pcData1 = await pcSink.completedData(for: outId1)
        let pcData2 = await pcSink.completedData(for: outId2)
        XCTAssertEqual(pcData1, out1)
        XCTAssertEqual(pcData2, out2)

        let receivedEntry = try XCTUnwrap(f.monitor.entries.first { $0.source == .pc && $0.kind == .file })
        let receivedFile = try XCTUnwrap(receivedEntry.file)
        XCTAssertEqual(try Data(contentsOf: f.monitor.fileURL(receivedFile)), inData)
        XCTAssertEqual(f.controller.pendingCount, 0)
        XCTAssertTrue(f.link.ackIDs.contains(inOffer.id))
        XCTAssertEqual(f.link.wifiJoinResults.count, 1)
        XCTAssertEqual(f.link.wifiJoinResults.first?.status, .joined)
        XCTAssertTrue(f.link.wifiCancels.isEmpty)
        XCTAssertNotNil(f.controller.lastSentAt)
        XCTAssertNotNil(f.controller.lastReceivedAt)

        let joinedSSIDs = await f.wifiClient.joinedSSIDs
        let leftSSIDs = await f.wifiClient.leftSSIDs
        let timeoutHistory = await padConn.timeoutHistory
        XCTAssertEqual(joinedSSIDs, [ready.ssid])
        XCTAssertEqual(leftSSIDs, [ready.ssid])
        XCTAssertEqual(timeoutHistory, [0.15, 0.25])

        let log = try await readLog(f)
        XCTAssertTrue(log.contains("Wi-Fi転送要求"))
        XCTAssertTrue(log.contains("Wi-Fi参加; 状態=joined"))
        XCTAssertTrue(log.contains("Wi-Fi転送完了"))
        XCTAssertTrue(log.contains("MB秒="))
        let forbidden = [
            ready.ssid,
            ready.passphrase,
            ready.ip,
            WifiControlMessageCodec.lowerHex(ready.token),
            ready.session.uuidString,
            inOffer.id.uuidString,
            outId1.uuidString,
            outId2.uuidString,
            "secret-out1",
            "secret-out2",
            "secret-incoming",
            pairing.pcId.uuidString,
            pairing.key.base64EncodedString(),
        ]
        for secret in forbidden {
            XCTAssertFalse(log.contains(secret), "Sensitive value leaked into log: \(secret)")
        }
    }

    @MainActor
    func testUserDeniedJoinFallsBackToBleAndEnforcesTenMinuteCooldown() async throws {
        let f = try Fixture(test: self)
        let pairing = try pair(f)
        f.monitor.updateScene("active")
        try f.link.connect(pairing, limit: 512)

        let outData = makeDeterministicBytes(count: 550_000, seed: 4)
        f.monitor.saveManually([try makeFileProvider(in: f.root, bytes: outData, name: "deny-out.bin")], receivedAt: f.clock.date)
        await awaitSave(f, savedCount: 1)

        XCTAssertEqual(f.link.wifiRequests.count, 1)
        let outId = try XCTUnwrap(f.link.wifiRequests.first?.ids.first)
        XCTAssertTrue(f.link.offers.isEmpty)

        await f.wifiClient.enqueueJoinStatus(.userDenied)
        let ready = makeReadyPayload()
        try f.link.send(.ready(ready))

        let fellBack = await waitUntil { f.link.offers.contains(where: { $0.id == outId }) }
        XCTAssertTrue(fellBack)
        XCTAssertEqual(f.link.wifiJoinResults.last?.status, .userDenied)
        let connectCount = await f.wifiClient.connectRecords.count
        XCTAssertEqual(connectCount, 0)
        let leftCount = await f.wifiClient.leftSSIDs.count
        XCTAssertEqual(leftCount, 0)

        // Reconnect before 10 minutes: the same item must stay on BLE (no Wi-Fi loop).
        f.clock.date.addTimeInterval(599)
        f.link.disconnect()
        let requestsBeforeReconnect = f.link.wifiRequests.count
        let offersBeforeReconnect = f.link.offers.count
        try f.link.connect(pairing, limit: 512)
        XCTAssertEqual(f.link.wifiRequests.count, requestsBeforeReconnect)
        XCTAssertEqual(f.link.offers.count, offersBeforeReconnect + 1)

        // After 10 minutes (> 600s), reconnecting makes the same item eligible for Wi-Fi again.
        f.clock.date.addTimeInterval(5)
        f.link.disconnect()
        try f.link.connect(pairing, limit: 512)
        XCTAssertEqual(f.link.wifiRequests.count, requestsBeforeReconnect + 1)
        XCTAssertEqual(f.link.wifiRequests.last?.ids, [outId])
    }

    @MainActor
    func testWifiUnavailableFallsBackToBleForIncomingAndOutgoing() async throws {
        let f = try Fixture(test: self)
        let pairing = try pair(f)
        f.monitor.updateScene("active")
        try f.link.connect(pairing, limit: 512)

        let inData = makeDeterministicBytes(count: 540_000, seed: 5)
        let inOffer = makeOffer(from: "pc", data: inData, name: "unavail-in.bin")
        try f.link.send(.offer(inOffer))

        XCTAssertEqual(f.link.wifiRequests.count, 1)
        XCTAssertEqual(f.link.wifiRequests.first?.direction, .receive)
        XCTAssertTrue(f.link.resumes.isEmpty)

        try f.link.send(.unavailable(reason: .startFailed))
        XCTAssertEqual(f.link.resumes.count, 1)
        XCTAssertEqual(f.link.resumes.first?.id, inOffer.id)
        XCTAssertEqual(f.link.resumes.first?.offset, 0)

        let log = try await readLog(f)
        XCTAssertTrue(log.contains("Wi-Fi転送不可; 理由=start_failed"))
    }

    @MainActor
    func testMidTransferDisconnectResumesPartialOverBleFallbackAndLeavesWifi() async throws {
        let f = try Fixture(test: self)
        let pairing = try pair(f)
        f.controller.copiesReceivedToPasteboard = false
        f.monitor.updateScene("active")
        try f.link.connect(pairing, limit: 512)

        let inData = makeDeterministicBytes(count: 700_000, seed: 7)
        let inOffer = makeOffer(from: "pc", data: inData, name: "mid-cut.bin")
        try f.link.send(.offer(inOffer))
        XCTAssertEqual(f.link.wifiRequests.count, 1)

        let ready = makeReadyPayload()
        let bleKeys = try XCTUnwrap(f.link.pcSessionKeys)
        let pcTransferKeys = try WifiTransferKeys.derive(bleKeys: bleKeys, token: ready.token, session: ready.session)
        let pcReplayGuard = try WifiSessionReplayGuard()
        let pcSink = InMemoryWifiTransferSink()
        let pcOutgoing: [any WifiTransferSource] = [InMemoryWifiTransferSource(offer: inOffer, payload: inData)]

        // Cut PC->iOS stream after ~300 KB (after handshake + offer + 1 chunk written to PCSync-v2/).
        let padToPc = FakeByteChannel()
        let pcToPad = FakeByteChannel(fault: .cutAfterBytes(300_000))
        let padConn = FakeWifiConnection(incoming: pcToPad, outgoing: padToPc, initialReadTimeout: 0.15)
        let pcEnd = FakePcStreamEnd(incoming: padToPc, outgoing: pcToPad)

        await f.wifiClient.setConnectHandler { _, _, _ in padConn }

        let pcTask = Task {
            try? await WifiTransferEngine.runPcSession(
                stream: pcEnd,
                keys: pcTransferKeys,
                outgoing: pcOutgoing,
                sink: pcSink,
                replayGuard: pcReplayGuard
            )
        }

        try f.link.send(.ready(ready))

        let resumedOnBle = await waitUntil(timeoutSeconds: 10) {
            f.link.resumes.contains(where: { $0.id == inOffer.id })
        }
        XCTAssertTrue(resumedOnBle)
        _ = await pcTask.value

        let resume = try XCTUnwrap(f.link.resumes.first(where: { $0.id == inOffer.id }))
        XCTAssertGreaterThan(resume.offset, 0)
        XCTAssertLessThan(resume.offset, inData.count)
        XCTAssertEqual(f.link.wifiCancels.first?.reason, .tcpFailed)
        let leftSSIDs = await f.wifiClient.leftSSIDs
        XCTAssertEqual(leftSSIDs, [ready.ssid])

        // Finish the remaining bytes over BLE starting at the saved partial offset.
        var offset = resume.offset
        while offset < inData.count {
            let end = min(inData.count, offset + SyncProtocol.chunkBytes)
            try f.link.send(.chunk(id: inOffer.id, offset: offset, data: inData.subdata(in: offset..<end)))
            offset = end
        }
        await drain(f)
        let entry = try XCTUnwrap(f.monitor.entries.first { $0.source == .pc && $0.kind == .file })
        let file = try XCTUnwrap(entry.file)
        XCTAssertEqual(try Data(contentsOf: f.monitor.fileURL(file)), inData)
        XCTAssertTrue(f.link.ackIDs.contains(inOffer.id))
    }

    @MainActor
    func testTimeoutsReadyJoinPreAuthAndIdleFallbackToBle() async throws {
        // 1. Ready timeout (> 8s)
        let f1 = try Fixture(test: self)
        let p1 = try pair(f1)
        f1.monitor.updateScene("active")
        try f1.link.connect(p1, limit: 512)
        let d1 = makeDeterministicBytes(count: 520_000, seed: 1)
        f1.monitor.saveManually([try makeFileProvider(in: f1.root, bytes: d1, name: "t-ready.bin")], receivedAt: f1.clock.date)
        await awaitSave(f1, savedCount: 1)
        XCTAssertEqual(f1.link.wifiRequests.count, 1)
        XCTAssertTrue(f1.link.offers.isEmpty)
        f1.clock.date.addTimeInterval(9)
        f1.controller.checkTimeouts()
        XCTAssertEqual(f1.link.offers.count, 1)

        // 2. Join timeout
        let f2 = try Fixture(test: self)
        let p2 = try pair(f2)
        f2.monitor.updateScene("active")
        try f2.link.connect(p2, limit: 512)
        let d2 = makeDeterministicBytes(count: 520_000, seed: 2)
        f2.monitor.saveManually([try makeFileProvider(in: f2.root, bytes: d2, name: "t-join.bin")], receivedAt: f2.clock.date)
        await awaitSave(f2, savedCount: 1)
        await f2.wifiClient.enqueueJoinStatus(.timeout)
        try f2.link.send(.ready(makeReadyPayload()))
        let fellBack2 = await waitUntil { f2.link.offers.count == 1 }
        XCTAssertTrue(fellBack2)
        XCTAssertEqual(f2.link.wifiJoinResults.last?.status, .timeout)

        // 3. Pre-auth TCP read timeout (stalled TCP_WELCOME)
        let f3 = try Fixture(test: self)
        let p3 = try pair(f3)
        f3.monitor.updateScene("active")
        try f3.link.connect(p3, limit: 512)
        let d3 = makeDeterministicBytes(count: 520_000, seed: 3)
        f3.monitor.saveManually([try makeFileProvider(in: f3.root, bytes: d3, name: "t-auth.bin")], receivedAt: f3.clock.date)
        await awaitSave(f3, savedCount: 1)
        let ready3 = makeReadyPayload()
        let stallConn3 = FakeWifiConnection(
            incoming: FakeByteChannel(fault: .stallAllReads),
            outgoing: FakeByteChannel(),
            initialReadTimeout: 0.05
        )
        await f3.wifiClient.setConnectHandler { _, _, _ in stallConn3 }
        try f3.link.send(.ready(ready3))
        let fellBack3 = await waitUntil(timeoutSeconds: 5) { f3.link.offers.count == 1 }
        XCTAssertTrue(fellBack3)
        XCTAssertEqual(f3.link.wifiCancels.last?.reason, .timeout)
        let left3 = await f3.wifiClient.leftSSIDs
        XCTAssertEqual(left3, [ready3.ssid])

        // 4. Post-auth idle read timeout (PC authenticates then stalls without replying to offer)
        let f4 = try Fixture(test: self)
        let p4 = try pair(f4)
        f4.monitor.updateScene("active")
        try f4.link.connect(p4, limit: 512)
        let d4 = makeDeterministicBytes(count: 520_000, seed: 4)
        f4.monitor.saveManually([try makeFileProvider(in: f4.root, bytes: d4, name: "t-idle.bin")], receivedAt: f4.clock.date)
        await awaitSave(f4, savedCount: 1)
        let ready4 = makeReadyPayload()
        let bleKeys4 = try XCTUnwrap(f4.link.pcSessionKeys)
        let pcKeys4 = try WifiTransferKeys.derive(bleKeys: bleKeys4, token: ready4.token, session: ready4.session)
        let padToPc4 = FakeByteChannel()
        let pcToPad4 = FakeByteChannel()
        let padConn4 = FakeWifiConnection(incoming: pcToPad4, outgoing: padToPc4, initialReadTimeout: 0.15)
        let pcEnd4 = FakePcStreamEnd(incoming: padToPc4, outgoing: pcToPad4)
        await f4.wifiClient.setConnectHandler { _, _, _ in padConn4 }
        let stallPcTask = Task {
            let guard4 = try WifiSessionReplayGuard()
            _ = try await WifiEncryptedStream.acceptAsPc(stream: pcEnd4, keys: pcKeys4, replayGuard: guard4)
            // Intentionally stall without reading or replying.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        try f4.link.send(.ready(ready4))
        let fellBack4 = await waitUntil(timeoutSeconds: 5) { f4.link.offers.count == 1 }
        stallPcTask.cancel()
        XCTAssertTrue(fellBack4)
        XCTAssertEqual(f4.link.wifiCancels.last?.reason, .timeout)
        let left4 = await f4.wifiClient.leftSSIDs
        XCTAssertEqual(left4, [ready4.ssid])
        let timeouts4 = await padConn4.timeoutHistory
        XCTAssertEqual(timeouts4, [0.15, 0.25])
    }

    @MainActor
    func testReplayGuardRejectsReusedSessionUuid() async throws {
        let f = try Fixture(test: self)
        let pairing = try pair(f)
        f.monitor.updateScene("active")
        try f.link.connect(pairing, limit: 512)

        // Session 1 succeeds and consumes sessionA.
        let data1 = makeDeterministicBytes(count: 520_000, seed: 10)
        f.monitor.saveManually([try makeFileProvider(in: f.root, bytes: data1, name: "s1.bin")], receivedAt: f.clock.date)
        await awaitSave(f, savedCount: 1)

        let sessionA = UUID()
        let ready1 = makeReadyPayload(session: sessionA)
        let bleKeys = try XCTUnwrap(f.link.pcSessionKeys)
        let pcKeys1 = try WifiTransferKeys.derive(bleKeys: bleKeys, token: ready1.token, session: sessionA)
        let pcGuard1 = try WifiSessionReplayGuard()
        let padToPc1 = FakeByteChannel()
        let pcToPad1 = FakeByteChannel()
        let padConn1 = FakeWifiConnection(incoming: pcToPad1, outgoing: padToPc1, initialReadTimeout: 0.15)
        let pcEnd1 = FakePcStreamEnd(incoming: padToPc1, outgoing: pcToPad1)
        await f.wifiClient.setConnectHandler { _, _, _ in padConn1 }
        let pcTask1 = Task {
            try await WifiTransferEngine.runPcSession(
                stream: pcEnd1,
                keys: pcKeys1,
                outgoing: [],
                sink: InMemoryWifiTransferSink(),
                replayGuard: pcGuard1
            )
        }
        try f.link.send(.ready(ready1))
        let done1 = await waitUntil { f.controller.pendingCount == 0 && f.controller.wifiTransferProgress == nil }
        XCTAssertTrue(done1)
        _ = try await pcTask1.value

        // Session 2: PC replays the exact same sessionA UUID -> iOS rejects without joining/connecting.
        let data2 = makeDeterministicBytes(count: 520_000, seed: 11)
        f.monitor.saveManually([try makeFileProvider(in: f.root, bytes: data2, name: "s2.bin")], receivedAt: f.clock.date.addingTimeInterval(1))
        await awaitSave(f, savedCount: 2)
        XCTAssertEqual(f.link.wifiRequests.count, 2)

        let joinsBefore = await f.wifiClient.joinedSSIDs.count
        let readyReplay = makeReadyPayload(session: sessionA)
        try f.link.send(.ready(readyReplay))
        let fellBack = await waitUntil { f.link.offers.count == 1 }
        XCTAssertTrue(fellBack)
        let joinsAfter = await f.wifiClient.joinedSSIDs.count
        XCTAssertEqual(joinsAfter, joinsBefore)
        XCTAssertEqual(f.link.wifiCancels.last?.session, sessionA)
        XCTAssertEqual(f.link.wifiCancels.last?.reason, .protocolError)
    }

    @MainActor
    func testUnrequestedOfferAndSha256MismatchAreRejectedAndPartialDeleted() async throws {
        // Part A: PC sends an offer ID over Wi-Fi that was NOT in wifi_request.ids.
        let f1 = try Fixture(test: self)
        let p1 = try pair(f1)
        f1.controller.copiesReceivedToPasteboard = false
        f1.monitor.updateScene("active")
        try f1.link.connect(p1, limit: 512)

        let requestedData = makeDeterministicBytes(count: 530_000, seed: 1)
        let requestedOffer = makeOffer(from: "pc", data: requestedData, name: "req.bin")
        let unrequestedData = makeDeterministicBytes(count: 530_000, seed: 2)
        let unrequestedOffer = makeOffer(from: "pc", data: unrequestedData, name: "sneaky.bin")
        try f1.link.send(.offer(requestedOffer))
        XCTAssertEqual(f1.link.wifiRequests.count, 1)

        let ready1 = makeReadyPayload()
        let bleKeys1 = try XCTUnwrap(f1.link.pcSessionKeys)
        let pcKeys1 = try WifiTransferKeys.derive(bleKeys: bleKeys1, token: ready1.token, session: ready1.session)
        let pcGuard1 = try WifiSessionReplayGuard()
        let padToPc1 = FakeByteChannel()
        let pcToPad1 = FakeByteChannel()
        let padConn1 = FakeWifiConnection(incoming: pcToPad1, outgoing: padToPc1, initialReadTimeout: 0.15)
        let pcEnd1 = FakePcStreamEnd(incoming: padToPc1, outgoing: pcToPad1)
        await f1.wifiClient.setConnectHandler { _, _, _ in padConn1 }
        let pcTask1 = Task {
            try? await WifiTransferEngine.runPcSession(
                stream: pcEnd1,
                keys: pcKeys1,
                outgoing: [InMemoryWifiTransferSource(offer: unrequestedOffer, payload: unrequestedData)],
                sink: InMemoryWifiTransferSink(),
                replayGuard: pcGuard1
            )
        }
        try f1.link.send(.ready(ready1))
        let rejectedUnrequested = await waitUntil {
            f1.link.wifiCancels.count == 1 && f1.link.resumes.contains(where: { $0.id == requestedOffer.id })
        }
        _ = await pcTask1.value
        XCTAssertTrue(rejectedUnrequested)
        XCTAssertEqual(f1.link.wifiCancels.first?.reason, .protocolError)
        XCTAssertTrue(f1.monitor.entries.isEmpty)

        // Part B: SHA-256 mismatch deletes partial file from PCSync-v2/ and never saves or acks.
        let f2 = try Fixture(test: self)
        let p2 = try pair(f2)
        f2.controller.copiesReceivedToPasteboard = false
        f2.monitor.updateScene("active")
        try f2.link.connect(p2, limit: 512)

        let corruptPayload = makeDeterministicBytes(count: 530_000, seed: 3)
        let badOffer = SyncOffer(
            id: UUID(),
            at: 1_795_000_000_123,
            from: "pc",
            kind: "file",
            size: corruptPayload.count,
            sha256: String(repeating: "0", count: 64),
            name64: Data("corrupt.bin".utf8).base64EncodedString(),
            type: "public.data"
        )
        try f2.link.send(.offer(badOffer))
        XCTAssertEqual(f2.link.wifiRequests.count, 1)

        let ready2 = makeReadyPayload()
        let bleKeys2 = try XCTUnwrap(f2.link.pcSessionKeys)
        let pcKeys2 = try WifiTransferKeys.derive(bleKeys: bleKeys2, token: ready2.token, session: ready2.session)
        let pcGuard2 = try WifiSessionReplayGuard()
        let padToPc2 = FakeByteChannel()
        let pcToPad2 = FakeByteChannel()
        let padConn2 = FakeWifiConnection(incoming: pcToPad2, outgoing: padToPc2, initialReadTimeout: 0.15)
        let pcEnd2 = FakePcStreamEnd(incoming: padToPc2, outgoing: pcToPad2)
        await f2.wifiClient.setConnectHandler { _, _, _ in padConn2 }
        let pcTask2 = Task {
            try? await WifiTransferEngine.runPcSession(
                stream: pcEnd2,
                keys: pcKeys2,
                outgoing: [InMemoryWifiTransferSource(offer: badOffer, payload: corruptPayload)],
                sink: InMemoryWifiTransferSink(),
                replayGuard: pcGuard2
            )
        }
        try f2.link.send(.ready(ready2))
        let sawCancel2 = await waitUntil {
            f2.link.wifiCancels.count == 1 && f2.link.resumes.contains(where: { $0.id == badOffer.id })
        }
        _ = await pcTask2.value
        XCTAssertTrue(sawCancel2)
        XCTAssertEqual(f2.link.wifiCancels.first?.reason, .protocolError)
        XCTAssertTrue(f2.monitor.entries.isEmpty)
        XCTAssertFalse(f2.link.ackIDs.contains(badOffer.id))
        // After SHA-256 mismatch, fallback BLE resume starts from 0 (partial was deleted).
        let bleResume = try XCTUnwrap(f2.link.resumes.first(where: { $0.id == badOffer.id }))
        XCTAssertEqual(bleResume.offset, 0)
        let log2 = try await readLog(f2)
        XCTAssertTrue(log2.contains("sha256_mismatch"))
    }

    @MainActor
    func testV3ConnectionNeverUsesWifiAndRejectsWifiControlMessages() async throws {
        let f = try Fixture(test: self)
        let pairing = try pair(f)
        f.monitor.updateScene("active")

        // Force v4 -> v3 fallback.
        f.link.rejectHelloWithMismatchVersion = [4: 3]
        try f.link.connect(pairing, limit: 512)
        XCTAssertEqual(f.controller.status, .searching)
        try f.link.connect(pairing, limit: 512)
        XCTAssertEqual(f.controller.status, .connected)
        XCTAssertEqual(f.link.negotiatedVersions, [3])

        // Large outgoing item on v3 goes straight to BLE offer (zero wifi_request).
        let outData = makeDeterministicBytes(count: 600_000, seed: 8)
        f.monitor.saveManually([try makeFileProvider(in: f.root, bytes: outData, name: "v3-out.bin")], receivedAt: f.clock.date)
        await awaitSave(f, savedCount: 1)
        XCTAssertTrue(f.link.wifiRequests.isEmpty)
        XCTAssertEqual(f.link.offers.count, 1)

        // Large incoming offer on v3 gets immediate BLE resume (zero wifi_request).
        let inData = makeDeterministicBytes(count: 600_000, seed: 9)
        let inOffer = makeOffer(from: "pc", data: inData, name: "v3-in.bin")
        try f.link.send(.offer(inOffer))
        XCTAssertTrue(f.link.wifiRequests.isEmpty)
        XCTAssertEqual(f.link.resumes.last?.id, inOffer.id)

        // Unexpected Wi-Fi control message on v3 is rejected as format error and disconnects.
        let rejectedBefore = f.link.rejected.count
        try f.link.send(.unavailable(reason: .disabled))
        XCTAssertEqual(f.link.rejected.count, rejectedBefore + 1)
        XCTAssertEqual(f.controller.status, .searching)
    }

    @MainActor
    func testBackgroundDefersWifiAndNotForegroundReadyRetriesOnForeground() async throws {
        let f = try Fixture(test: self)
        let pairing = try pair(f)
        f.monitor.updateScene("background")
        try f.link.connect(pairing, limit: 512)

        // Small text still sends over BLE in background, while large item waits.
        f.monitor.saveManually(["裏で送る文章"], receivedAt: f.clock.date)
        await drain(f)
        XCTAssertEqual(f.link.messages.filter { if case .item = $0 { return true }; return false }.count, 1)

        let outData = makeDeterministicBytes(count: 550_000, seed: 12)
        f.monitor.saveManually([try makeFileProvider(in: f.root, bytes: outData, name: "bg-wait.bin")], receivedAt: f.clock.date.addingTimeInterval(1))
        await awaitSave(f, savedCount: 2)
        XCTAssertTrue(f.link.wifiRequests.isEmpty)
        XCTAssertTrue(f.link.offers.isEmpty)

        // Enter foreground -> wifi_request sent.
        f.monitor.updateScene("active")
        XCTAssertEqual(f.link.wifiRequests.count, 1)

        // Move back to background BEFORE wifi_ready arrives -> replies not_foreground without cooldown/BLE fallback.
        f.monitor.updateScene("background")
        let ready1 = makeReadyPayload()
        try f.link.send(.ready(ready1))
        XCTAssertEqual(f.link.wifiJoinResults.last?.session, ready1.session)
        XCTAssertEqual(f.link.wifiJoinResults.last?.status, .notForeground)
        XCTAssertTrue(f.link.offers.isEmpty)
        let joinCountBefore = await f.wifiClient.joinedSSIDs.count
        XCTAssertEqual(joinCountBefore, 0)

        // Return to foreground -> immediately sends fresh wifi_request (no 10-minute cooldown applied).
        f.monitor.updateScene("active")
        XCTAssertEqual(f.link.wifiRequests.count, 2)
    }

    @MainActor
    func testItemsOver10MiBUseWifiOnlyAndDropWhenWifiUnavailableOrDisabled() async throws {
        // 1. Outgoing > 10 MiB succeeds over Wi-Fi.
        let f1 = try Fixture(test: self)
        let p1 = try pair(f1)
        f1.monitor.updateScene("active")
        try f1.link.connect(p1, limit: 512)

        let over10Size = SyncProtocol.maxItemBytes + 1_024
        let over10Data = makeDeterministicBytes(count: over10Size, seed: 15)
        f1.monitor.saveManually([try makeFileProvider(in: f1.root, bytes: over10Data, name: "over10-out.bin")], receivedAt: f1.clock.date)
        await awaitSave(f1, savedCount: 1)

        XCTAssertEqual(f1.link.wifiRequests.count, 1)
        XCTAssertTrue(f1.link.offers.isEmpty)
        let outId = try XCTUnwrap(f1.link.wifiRequests.first?.ids.first)

        let ready1 = makeReadyPayload()
        let bleKeys1 = try XCTUnwrap(f1.link.pcSessionKeys)
        let pcKeys1 = try WifiTransferKeys.derive(bleKeys: bleKeys1, token: ready1.token, session: ready1.session)
        let pcGuard1 = try WifiSessionReplayGuard()
        let pcSink1 = InMemoryWifiTransferSink()
        let padToPc1 = FakeByteChannel()
        let pcToPad1 = FakeByteChannel()
        let padConn1 = FakeWifiConnection(incoming: pcToPad1, outgoing: padToPc1, initialReadTimeout: 0.5)
        let pcEnd1 = FakePcStreamEnd(incoming: padToPc1, outgoing: pcToPad1)
        await f1.wifiClient.setConnectHandler { _, _, _ in padConn1 }
        let pcTask1 = Task {
            try await WifiTransferEngine.runPcSession(
                stream: pcEnd1,
                keys: pcKeys1,
                outgoing: [],
                sink: pcSink1,
                replayGuard: pcGuard1
            )
        }
        try f1.link.send(.ready(ready1))
        let done1 = await waitUntil(timeoutSeconds: 10) { f1.controller.pendingCount == 0 && f1.controller.wifiTransferProgress == nil }
        XCTAssertTrue(done1)
        _ = try await pcTask1.value
        let receivedOnPc = await pcSink1.completedData(for: outId)
        XCTAssertEqual(receivedOnPc?.count, over10Size)
        XCTAssertEqual(receivedOnPc, over10Data)

        // 2. Outgoing > 10 MiB when Wi-Fi is unavailable drops as oversized (never sent over BLE).
        let f2 = try Fixture(test: self)
        let p2 = try pair(f2)
        f2.monitor.updateScene("active")
        try f2.link.connect(p2, limit: 512)
        f2.monitor.saveManually([try makeFileProvider(in: f2.root, bytes: over10Data, name: "over10-drop.bin")], receivedAt: f2.clock.date)
        await awaitSave(f2, savedCount: 1)
        XCTAssertEqual(f2.link.wifiRequests.count, 1)
        try f2.link.send(.unavailable(reason: .disabled))
        XCTAssertEqual(f2.controller.pendingCount, 0)
        XCTAssertTrue(f2.link.offers.isEmpty)

        // 3. Outgoing > 10 MiB when Wi-Fi setting is OFF is rejected at enqueue time.
        f2.controller.usesWifiForLargeItems = false
        f2.monitor.saveManually([try makeFileProvider(in: f2.root, bytes: over10Data, name: "over10-off.bin")], receivedAt: f2.clock.date.addingTimeInterval(1))
        await awaitSave(f2, savedCount: 2)
        XCTAssertEqual(f2.controller.pendingCount, 0)
        XCTAssertTrue(f2.link.offers.isEmpty)

        // 4. Incoming > 10 MiB BLE offer on v4 uses Wi-Fi; when Wi-Fi unavailable, never sends BLE resume and drops cleanly.
        let f3 = try Fixture(test: self)
        let p3 = try pair(f3)
        f3.controller.copiesReceivedToPasteboard = false
        f3.monitor.updateScene("active")
        try f3.link.connect(p3, limit: 512)

        let over10Incoming = makeOffer(from: "pc", data: over10Data, name: "over10-in.bin")
        try f3.link.sendLargeOffer(over10Incoming)
        XCTAssertEqual(f3.link.wifiRequests.count, 1)
        XCTAssertEqual(f3.link.wifiRequests.first?.ids, [over10Incoming.id])
        XCTAssertTrue(f3.link.resumes.isEmpty)

        try f3.link.send(.unavailable(reason: .unsupported))
        XCTAssertTrue(f3.link.resumes.isEmpty)
        XCTAssertTrue(f3.link.ackIDs.contains(over10Incoming.id))
        XCTAssertTrue(f3.monitor.entries.isEmpty)
    }
}
