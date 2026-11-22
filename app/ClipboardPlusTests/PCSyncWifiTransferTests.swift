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
        if case .stallAllReads = fault {
            queue.append(chunk)
            return
        }
        if case let .stallAfterBytes(limit) = fault, readBytes >= limit {
            queue.append(chunk)
            return
        }
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
    private let readSleeper: ControlledWifiSleeper?
    private var timeoutSeconds: TimeInterval
    private(set) var timeoutHistory: [TimeInterval]
    private(set) var isClosed = false

    init(
        incoming: FakeByteChannel,
        outgoing: FakeByteChannel,
        initialReadTimeout: TimeInterval,
        readSleeper: ControlledWifiSleeper? = nil
    ) {
        self.incoming = incoming
        self.outgoing = outgoing
        self.readSleeper = readSleeper
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
        let sleeper = readSleeper
        let outcome = try await withThrowingTaskGroup(of: ReadOutcome.self) { group in
            group.addTask {
                let bytes = await channel.read(maxLength: maxLength)
                return .data(bytes)
            }
            group.addTask {
                if let sleeper {
                    try await sleeper.sleep(limitSeconds)
                } else {
                    let nanos = UInt64(max(0.01, limitSeconds) * 1_000_000_000)
                    try await Task.sleep(nanoseconds: nanos)
                }
                return .timedOut
            }
            do {
                guard let first = try await group.next() else {
                    group.cancelAll()
                    await channel.close()
                    throw PCSyncWifiClientError.cancelled
                }
                group.cancelAll()
                if case .timedOut = first {
                    await channel.close()
                }
                return first
            } catch {
                group.cancelAll()
                await channel.close()
                throw error
            }
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
    private var joinHandler: (@Sendable (String, String, TimeInterval) async -> WifiJoinStatus)?
    private var connectHandler: (@Sendable (String, Int, TimeInterval) async throws -> any PCSyncWifiConnection)?
    private(set) var joinedSSIDs: [String] = []
    private(set) var joinTimeouts: [TimeInterval] = []
    private(set) var leftSSIDs: [String] = []
    private(set) var connectRecords: [ConnectRecord] = []

    func enqueueJoinStatus(_ status: WifiJoinStatus) {
        joinStatuses.append(status)
    }

    func setDefaultJoinStatus(_ status: WifiJoinStatus) {
        defaultJoinStatus = status
    }

    func setJoinHandler(_ handler: (@Sendable (String, String, TimeInterval) async -> WifiJoinStatus)?) {
        joinHandler = handler
    }

    func setConnectHandler(_ handler: (@Sendable (String, Int, TimeInterval) async throws -> any PCSyncWifiConnection)?) {
        connectHandler = handler
    }

    func join(ssid: String, passphrase: String, timeoutSeconds: TimeInterval) async -> WifiJoinStatus {
        joinedSSIDs.append(ssid)
        joinTimeouts.append(timeoutSeconds)
        if let handler = joinHandler {
            return await handler(ssid, passphrase, timeoutSeconds)
        }
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

private final class ControlledWifiSleeper: @unchecked Sendable {
    final class PendingSleep: @unchecked Sendable {
        let duration: TimeInterval
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private var finished = false

        init(duration: TimeInterval) {
            self.duration = duration
        }

        var isFinished: Bool {
            lock.lock()
            defer { lock.unlock() }
            return finished
        }

        func install(_ continuation: CheckedContinuation<Void, Error>) -> Bool {
            lock.lock()
            if finished {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return false
            }
            self.continuation = continuation
            lock.unlock()
            return true
        }

        func fire() {
            lock.lock()
            if finished {
                lock.unlock()
                return
            }
            finished = true
            let cont = continuation
            continuation = nil
            lock.unlock()
            cont?.resume(returning: ())
        }

        func cancel() {
            lock.lock()
            if finished {
                lock.unlock()
                return
            }
            finished = true
            let cont = continuation
            continuation = nil
            lock.unlock()
            cont?.resume(throwing: CancellationError())
        }
    }

    private let lock = NSLock()
    private var waits: [PendingSleep] = []
    private var waiters: [(duration: TimeInterval, continuation: CheckedContinuation<PendingSleep, Never>)] = []

    func sleep(_ duration: TimeInterval) async throws {
        try Task.checkCancellation()
        let pending = PendingSleep(duration: duration)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard pending.install(continuation) else { return }
                var matchedWaiter: CheckedContinuation<PendingSleep, Never>?
                self.lock.lock()
                self.waits.append(pending)
                if let idx = self.waiters.firstIndex(where: { abs($0.duration - duration) < 0.001 }) {
                    matchedWaiter = self.waiters.remove(at: idx).continuation
                }
                self.lock.unlock()
                matchedWaiter?.resume(returning: pending)
            }
        } onCancel: {
            pending.cancel()
        }
    }

    func waitForSleep(duration: TimeInterval) async -> PendingSleep {
        await withCheckedContinuation { (continuation: CheckedContinuation<PendingSleep, Never>) in
            self.lock.lock()
            if let existing = self.waits.last(where: { !$0.isFinished && abs($0.duration - duration) < 0.001 }) {
                self.lock.unlock()
                continuation.resume(returning: existing)
            } else {
                self.waiters.append((duration: duration, continuation: continuation))
                self.lock.unlock()
            }
        }
    }

    func cancelAll() {
        lock.lock()
        let pendingList = waits
        lock.unlock()
        for pending in pendingList {
            pending.cancel()
        }
    }
}

private actor TestWifiGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        guard !opened else { return }
        opened = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }

    func wait() async {
        if opened { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if opened {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
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
        let sleeper: ControlledWifiSleeper?
        let monitor: ClipboardMonitor
        let controller: PCSyncController

        init(
            test: XCTestCase,
            timeouts: PCSyncController.WifiTransferTimeouts = PCSyncController.WifiTransferTimeouts(),
            sleeper: ControlledWifiSleeper? = nil
        ) throws {
            self.sleeper = sleeper
            root = try ImageTestSupport.directory(test)
            let suite = UUID().uuidString
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let defaultsRef = self.defaults
            test.addTeardownBlock { defaultsRef.removePersistentDomain(forName: suite) }
            if let sleeperRef = sleeper {
                test.addTeardownBlock {
                    sleeperRef.cancelAll()
                }
            }
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
            let sleepClosure: (@Sendable (TimeInterval) async throws -> Void)?
            if let sleeper {
                sleepClosure = { duration in
                    try await sleeper.sleep(duration)
                }
            } else {
                sleepClosure = nil
            }
            controller = PCSyncController(
                monitor: monitor,
                defaults: defaults,
                keyStore: keys,
                now: { clockRef.date },
                schedulesTimeouts: false,
                makeTransport: { _ in linkRef },
                wifiClient: wifiClient,
                wifiTimeouts: timeouts,
                wifiSleep: sleepClosure
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

    @MainActor
    private func waitUntilAsync(timeoutSeconds: TimeInterval = 5, _ condition: @MainActor () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
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
        f.monitor.updateScene("active")
        try f.link.connect(pairing, limit: 512)

        // Pause BLE writeability briefly so 2 outgoing items and 1 incoming offer batch into one `.both` request.
        f.link.canSend = false
        let out1 = makeDeterministicBytes(count: 550_000, seed: 11)
        let out2 = makeDeterministicBytes(count: 520_000, seed: 22)
        f.monitor.saveManually([try makeFileProvider(in: f.root, bytes: out1, name: "secret-out1.bin")], receivedAt: f.clock.date)
        await awaitSave(f, savedCount: 1)
        f.monitor.saveManually([try makeFileProvider(in: f.root, bytes: out2, name: "secret-out2.bin")], receivedAt: f.clock.date.addingTimeInterval(1))
        await awaitSave(f, savedCount: 2)

        let inData = makeDeterministicBytes(count: 610_000, seed: 33)
        let inOffer = makeOffer(from: "pc", data: inData, name: "secret-incoming.bin")
        try f.link.send(.offer(inOffer))

        XCTAssertTrue(f.link.offers.isEmpty)
        XCTAssertTrue(f.link.resumes.isEmpty)

        // Flush BLE queue: a single combined `.both` wifi_request is sent with all 3 IDs.
        f.link.canSend = true
        f.link.onEvent?(.writable)
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
        let padConn = FakeWifiConnection(incoming: pcToPad, outgoing: padToPc, initialReadTimeout: 5)
        let pcEnd = FakePcStreamEnd(incoming: padToPc, outgoing: pcToPad)

        await f.wifiClient.setConnectHandler { _, _, initialTimeout in
            XCTAssertEqual(initialTimeout, 5, accuracy: 0.001)
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
        XCTAssertEqual(timeoutHistory, [5, 10])

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
        let padConn = FakeWifiConnection(incoming: pcToPad, outgoing: padToPc, initialReadTimeout: 5)
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
        XCTAssertEqual(f.link.wifiRequests.count, 1)
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
        let defaultTimeouts = PCSyncController.WifiTransferTimeouts()
        XCTAssertEqual(defaultTimeouts.readySeconds, 20)
        XCTAssertEqual(defaultTimeouts.joinSeconds, 75)
        XCTAssertEqual(defaultTimeouts.preAuthReadSeconds, 5)
        XCTAssertEqual(defaultTimeouts.idleSeconds, 10)
        XCTAssertEqual(defaultTimeouts.busyRetrySeconds, 5)
        XCTAssertEqual(defaultTimeouts.maxBusyRetries, 6)
        XCTAssertEqual(defaultTimeouts.readyTimeoutHoldSeconds, 2)

        // 1. Ready timeout (20s) fires on deadline without relying on periodic checkTimeouts().
        let sleeper1 = ControlledWifiSleeper()
        let f1 = try Fixture(test: self, sleeper: sleeper1)
        let p1 = try pair(f1)
        f1.monitor.updateScene("active")
        try f1.link.connect(p1, limit: 512)
        let d1 = makeDeterministicBytes(count: 520_000, seed: 1)
        f1.monitor.saveManually([try makeFileProvider(in: f1.root, bytes: d1, name: "t-ready.bin")], receivedAt: f1.clock.date)
        await awaitSave(f1, savedCount: 1)
        XCTAssertEqual(f1.link.wifiRequests.count, 1)
        XCTAssertTrue(f1.link.offers.isEmpty)
        let readyWait = await sleeper1.waitForSleep(duration: 20)
        readyWait.fire()
        let fellBack1 = await waitUntil { f1.link.offers.count == 1 }
        XCTAssertTrue(fellBack1)

        // 2. Join timeout uses 75s (< PC's 90s TTL).
        let f2 = try Fixture(test: self)
        let p2 = try pair(f2)
        f2.monitor.updateScene("active")
        try f2.link.connect(p2, limit: 512)
        let d2 = makeDeterministicBytes(count: 520_000, seed: 2)
        f2.monitor.saveManually([try makeFileProvider(in: f2.root, bytes: d2, name: "t-join.bin")], receivedAt: f2.clock.date)
        await awaitSave(f2, savedCount: 1)
        await f2.wifiClient.enqueueJoinStatus(.timeout)
        try f2.link.send(.ready(makeReadyPayload(ttlSeconds: 90)))
        let fellBack2 = await waitUntil { f2.link.offers.count == 1 }
        XCTAssertTrue(fellBack2)
        XCTAssertEqual(f2.link.wifiJoinResults.last?.status, .timeout)
        let joinTimeouts2 = await f2.wifiClient.joinTimeouts
        XCTAssertEqual(joinTimeouts2, [75])

        // 3. Pre-auth TCP read timeout (stalled TCP_WELCOME) driven by controlled sleeper without wall-clock waiting.
        let sleeper3 = ControlledWifiSleeper()
        let connSleeper3 = ControlledWifiSleeper()
        addTeardownBlock { connSleeper3.cancelAll() }
        let f3 = try Fixture(test: self, sleeper: sleeper3)
        let p3 = try pair(f3)
        f3.monitor.updateScene("active")
        try f3.link.connect(p3, limit: 512)
        let d3 = makeDeterministicBytes(count: 520_000, seed: 3)
        f3.monitor.saveManually([try makeFileProvider(in: f3.root, bytes: d3, name: "t-auth.bin")], receivedAt: f3.clock.date)
        await awaitSave(f3, savedCount: 1)
        XCTAssertEqual(f3.link.wifiRequests.count, 1)
        let ready3 = makeReadyPayload()
        let stallConn3 = FakeWifiConnection(
            incoming: FakeByteChannel(fault: .stallAllReads),
            outgoing: FakeByteChannel(),
            initialReadTimeout: defaultTimeouts.preAuthReadSeconds,
            readSleeper: connSleeper3
        )
        await f3.wifiClient.setConnectHandler { _, _, _ in stallConn3 }
        try f3.link.send(.ready(ready3))
        let preAuthWait = await connSleeper3.waitForSleep(duration: defaultTimeouts.preAuthReadSeconds)
        preAuthWait.fire()
        let fellBack3 = await waitUntil(timeoutSeconds: 5) { f3.link.offers.count == 1 }
        XCTAssertTrue(fellBack3)
        XCTAssertEqual(f3.link.wifiRequests.count, 1)
        XCTAssertEqual(f3.link.wifiCancels.last?.reason, .timeout)
        let connectRecords3 = await f3.wifiClient.connectRecords
        XCTAssertEqual(connectRecords3.map(\.initialReadTimeout), [defaultTimeouts.preAuthReadSeconds])
        let left3 = await f3.wifiClient.leftSSIDs
        XCTAssertEqual(left3, [ready3.ssid])

        // 4. Post-auth idle read timeout (PC authenticates then stalls without replying to offer).
        let sleeper4 = ControlledWifiSleeper()
        let connSleeper4 = ControlledWifiSleeper()
        addTeardownBlock { connSleeper4.cancelAll() }
        let f4 = try Fixture(test: self, sleeper: sleeper4)
        let p4 = try pair(f4)
        f4.monitor.updateScene("active")
        try f4.link.connect(p4, limit: 512)
        let d4 = makeDeterministicBytes(count: 520_000, seed: 4)
        f4.monitor.saveManually([try makeFileProvider(in: f4.root, bytes: d4, name: "t-idle.bin")], receivedAt: f4.clock.date)
        await awaitSave(f4, savedCount: 1)
        XCTAssertEqual(f4.link.wifiRequests.count, 1)
        let ready4 = makeReadyPayload()
        let bleKeys4 = try XCTUnwrap(f4.link.pcSessionKeys)
        let pcKeys4 = try WifiTransferKeys.derive(bleKeys: bleKeys4, token: ready4.token, session: ready4.session)
        let padToPc4 = FakeByteChannel()
        let pcToPad4 = FakeByteChannel()
        let padConn4 = FakeWifiConnection(
            incoming: pcToPad4,
            outgoing: padToPc4,
            initialReadTimeout: defaultTimeouts.preAuthReadSeconds,
            readSleeper: connSleeper4
        )
        let pcEnd4 = FakePcStreamEnd(incoming: padToPc4, outgoing: pcToPad4)
        await f4.wifiClient.setConnectHandler { _, _, _ in padConn4 }
        let stallPcTask = Task {
            let guard4 = try WifiSessionReplayGuard()
            _ = try await WifiEncryptedStream.acceptAsPc(stream: pcEnd4, keys: pcKeys4, replayGuard: guard4)
            // Intentionally leave the stream open without replying to the offer.
        }
        try f4.link.send(.ready(ready4))
        let idleWait = await connSleeper4.waitForSleep(duration: defaultTimeouts.idleSeconds)
        idleWait.fire()
        let fellBack4 = await waitUntil(timeoutSeconds: 5) { f4.link.offers.count == 1 }
        try await stallPcTask.value
        XCTAssertTrue(fellBack4)
        XCTAssertEqual(f4.link.wifiRequests.count, 1)
        XCTAssertEqual(f4.link.wifiCancels.last?.reason, .timeout)
        let left4 = await f4.wifiClient.leftSSIDs
        XCTAssertEqual(left4, [ready4.ssid])
        let timeouts4 = await padConn4.timeoutHistory
        XCTAssertEqual(timeouts4, [defaultTimeouts.preAuthReadSeconds, defaultTimeouts.idleSeconds])
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
        let padConn1 = FakeWifiConnection(incoming: pcToPad1, outgoing: padToPc1, initialReadTimeout: 5)
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
        XCTAssertEqual(f.link.wifiRequests.count, 2)
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
        let padConn1 = FakeWifiConnection(incoming: pcToPad1, outgoing: padToPc1, initialReadTimeout: 5)
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
        XCTAssertEqual(f1.link.wifiRequests.count, 1)
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
        let padConn2 = FakeWifiConnection(incoming: pcToPad2, outgoing: padToPc2, initialReadTimeout: 5)
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
        XCTAssertEqual(f2.link.wifiRequests.count, 1)
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
    func testBackgroundUsesBleFor10MiBAndUnderWithoutLoopAndDefersOnlyOver10MiB() async throws {
        // 1. Background PC->iOS large (<= 10 MiB) offer replies immediately with BLE resume (no 60s timeout loop)
        //    and finishes over BLE even after returning to foreground.
        let f1 = try Fixture(test: self)
        let p1 = try pair(f1)
        f1.controller.copiesReceivedToPasteboard = false
        f1.monitor.updateScene("background")
        try f1.link.connect(p1, limit: 512)

        let inData = makeDeterministicBytes(count: 600_000, seed: 12)
        let inOffer = makeOffer(from: "pc", data: inData, name: "bg-in.bin")
        try f1.link.send(.offer(inOffer))
        XCTAssertTrue(f1.link.wifiRequests.isEmpty)
        XCTAssertEqual(f1.link.resumes.count, 1)
        XCTAssertEqual(f1.link.resumes.first?.id, inOffer.id)
        XCTAssertEqual(f1.link.resumes.first?.offset, 0)

        // Start receiving over BLE, then move to foreground: must finish over BLE without starting Wi-Fi.
        let firstEnd = min(inData.count, SyncProtocol.chunkBytes)
        try f1.link.send(.chunk(id: inOffer.id, offset: 0, data: inData.subdata(in: 0..<firstEnd)))
        f1.monitor.updateScene("active")
        XCTAssertTrue(f1.link.wifiRequests.isEmpty)

        var rxOffset = firstEnd
        while rxOffset < inData.count {
            let end = min(inData.count, rxOffset + SyncProtocol.chunkBytes)
            try f1.link.send(.chunk(id: inOffer.id, offset: rxOffset, data: inData.subdata(in: rxOffset..<end)))
            rxOffset = end
        }
        await drain(f1)
        XCTAssertTrue(f1.link.wifiRequests.isEmpty)
        XCTAssertTrue(f1.link.ackIDs.contains(inOffer.id))
        let savedIn = try XCTUnwrap(f1.monitor.entries.first { $0.source == .pc && $0.kind == .file })
        let savedInFile = try XCTUnwrap(savedIn.file)
        let savedInBytes = try Data(contentsOf: f1.monitor.fileURL(savedInFile))
        XCTAssertEqual(savedInBytes, inData)

        // 2. Background iOS->PC large (<= 10 MiB) item sends over BLE and finishes over BLE after returning to foreground.
        let f2 = try Fixture(test: self)
        let p2 = try pair(f2)
        f2.monitor.updateScene("background")
        try f2.link.connect(p2, limit: 512)

        let outData = makeDeterministicBytes(count: 550_000, seed: 13)
        f2.monitor.saveManually([try makeFileProvider(in: f2.root, bytes: outData, name: "bg-out.bin")], receivedAt: f2.clock.date)
        await awaitSave(f2, savedCount: 1)
        XCTAssertTrue(f2.link.wifiRequests.isEmpty)
        XCTAssertEqual(f2.link.offers.count, 1)
        let bleOutOffer = try XCTUnwrap(f2.link.offers.first)

        try f2.link.send(.resume(id: bleOutOffer.id, offset: 0))
        f2.monitor.updateScene("active")
        XCTAssertTrue(f2.link.wifiRequests.isEmpty)

        var txAcked = 0
        var processedIndex = 0
        while txAcked < outData.count {
            let before = processedIndex
            while processedIndex < f2.link.messages.count {
                let msg = f2.link.messages[processedIndex]
                processedIndex += 1
                if case let .chunk(id, offset, chunkData) = msg, id == bleOutOffer.id {
                    XCTAssertEqual(offset, txAcked)
                    txAcked += chunkData.count
                    if txAcked < outData.count {
                        try f2.link.send(.resume(id: bleOutOffer.id, offset: txAcked))
                    }
                }
            }
            if processedIndex == before {
                XCTFail("Expected BLE chunks to progress")
                break
            }
        }
        try f2.link.send(.ack(ids: [bleOutOffer.id]))
        XCTAssertEqual(f2.controller.pendingCount, 0)
        XCTAssertTrue(f2.link.wifiRequests.isEmpty)

        // 3. Background > 10 MiB waits until foreground; not_foreground ready keeps it waiting and retries on foreground.
        let f3 = try Fixture(test: self)
        let p3 = try pair(f3)
        f3.monitor.updateScene("background")
        try f3.link.connect(p3, limit: 512)

        let over10Size = SyncProtocol.maxItemBytes + 1_024
        let over10Out = makeDeterministicBytes(count: over10Size, seed: 14)
        f3.monitor.saveManually([try makeFileProvider(in: f3.root, bytes: over10Out, name: "bg-over10.bin")], receivedAt: f3.clock.date)
        await awaitSave(f3, savedCount: 1)
        XCTAssertEqual(f3.controller.pendingCount, 1)
        XCTAssertTrue(f3.link.wifiRequests.isEmpty)
        XCTAssertTrue(f3.link.offers.isEmpty)

        // Enter foreground -> wifi_request sent.
        f3.monitor.updateScene("active")
        XCTAssertEqual(f3.link.wifiRequests.count, 1)

        // Move back to background BEFORE wifi_ready arrives -> replies not_foreground without dropping or BLE fallback.
        f3.monitor.updateScene("background")
        let ready1 = makeReadyPayload()
        try f3.link.send(.ready(ready1))
        XCTAssertEqual(f3.link.wifiJoinResults.last?.session, ready1.session)
        XCTAssertEqual(f3.link.wifiJoinResults.last?.status, .notForeground)
        XCTAssertEqual(f3.controller.pendingCount, 1)
        XCTAssertTrue(f3.link.offers.isEmpty)
        let joinCountBefore = await f3.wifiClient.joinedSSIDs.count
        XCTAssertEqual(joinCountBefore, 0)

        // Return to foreground -> immediately sends fresh wifi_request.
        f3.monitor.updateScene("active")
        XCTAssertEqual(f3.link.wifiRequests.count, 2)
    }

    @MainActor
    func testBusyRetriesUpToSixTimesAfterFiveSecondsWithoutDroppingOver10MiB() async throws {
        // Part 1: Transient busy does not drop > 10 MiB item; retries after 5s and succeeds.
        let sleeper1 = ControlledWifiSleeper()
        let f1 = try Fixture(test: self, sleeper: sleeper1)
        let p1 = try pair(f1)
        f1.monitor.updateScene("active")
        try f1.link.connect(p1, limit: 512)

        let over10Size = SyncProtocol.maxItemBytes + 1_024
        let over10Data = makeDeterministicBytes(count: over10Size, seed: 21)
        f1.monitor.saveManually([try makeFileProvider(in: f1.root, bytes: over10Data, name: "busy-over10.bin")], receivedAt: f1.clock.date)
        await awaitSave(f1, savedCount: 1)
        XCTAssertEqual(f1.link.wifiRequests.count, 1)
        let over10ID1 = try XCTUnwrap(f1.link.wifiRequests.first?.ids.first)

        try f1.link.send(.unavailable(reason: .busy))
        XCTAssertEqual(f1.controller.pendingCount, 1)
        XCTAssertTrue(f1.link.offers.isEmpty)
        XCTAssertEqual(f1.link.wifiRequests.count, 1)

        let retryWait = await sleeper1.waitForSleep(duration: 5)
        retryWait.fire()
        let retried = await waitUntil { f1.link.wifiRequests.count == 2 }
        XCTAssertTrue(retried)
        XCTAssertEqual(f1.link.wifiRequests.last?.ids, [over10ID1])

        let ready1 = makeReadyPayload()
        let bleKeys1 = try XCTUnwrap(f1.link.pcSessionKeys)
        let pcKeys1 = try WifiTransferKeys.derive(bleKeys: bleKeys1, token: ready1.token, session: ready1.session)
        let pcGuard1 = try WifiSessionReplayGuard()
        let pcSink1 = InMemoryWifiTransferSink()
        let padToPc1 = FakeByteChannel()
        let pcToPad1 = FakeByteChannel()
        let padConn1 = FakeWifiConnection(incoming: pcToPad1, outgoing: padToPc1, initialReadTimeout: 5)
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
        let pcReceived = await pcSink1.completedData(for: over10ID1)
        XCTAssertEqual(pcReceived, over10Data)

        // Part 2: 6 consecutive busy retries (7 busy replies total) -> <= 10 MiB falls back to BLE,
        //         > 10 MiB stays pending (not dropped) and waits until returning to foreground.
        let sleeper2 = ControlledWifiSleeper()
        let f2 = try Fixture(test: self, sleeper: sleeper2)
        let p2 = try pair(f2)
        f2.monitor.updateScene("active")
        try f2.link.connect(p2, limit: 512)

        f2.link.canSend = false
        let bleData = makeDeterministicBytes(count: 550_000, seed: 22)
        f2.monitor.saveManually([try makeFileProvider(in: f2.root, bytes: bleData, name: "busy-ble.bin")], receivedAt: f2.clock.date)
        await awaitSave(f2, savedCount: 1)
        f2.monitor.saveManually([try makeFileProvider(in: f2.root, bytes: over10Data, name: "busy-wait-fg.bin")], receivedAt: f2.clock.date.addingTimeInterval(1))
        await awaitSave(f2, savedCount: 2)
        f2.link.canSend = true
        f2.link.onEvent?(.writable)

        XCTAssertEqual(f2.link.wifiRequests.count, 1)
        let firstReqIDs = try XCTUnwrap(f2.link.wifiRequests.first?.ids)
        XCTAssertEqual(firstReqIDs.count, 2)
        let bleID = firstReqIDs[0]
        let over10ID2 = firstReqIDs[1]

        // Initial busy + 6 retries (5s each).
        for retryIndex in 1...6 {
            try f2.link.send(.unavailable(reason: .busy))
            XCTAssertEqual(f2.controller.pendingCount, 2)
            XCTAssertTrue(f2.link.offers.isEmpty)
            let wait5 = await sleeper2.waitForSleep(duration: 5)
            wait5.fire()
            let sentRetry = await waitUntil { f2.link.wifiRequests.count == retryIndex + 1 }
            XCTAssertTrue(sentRetry)
        }

        // 7th busy reply (after 6 retries) exhausts busy retries.
        try f2.link.send(.unavailable(reason: .busy))
        XCTAssertEqual(f2.link.offers.count, 1)
        XCTAssertEqual(f2.link.offers.first?.id, bleID)
        XCTAssertEqual(f2.controller.pendingCount, 2)

        // Complete BLE item; > 10 MiB item stays pending and does not retry while still in foreground.
        try f2.link.send(.ack(ids: [bleID]))
        XCTAssertEqual(f2.controller.pendingCount, 1)
        f2.controller.checkTimeouts()
        XCTAssertEqual(f2.link.wifiRequests.count, 7)

        // Move to background and back to foreground -> retries > 10 MiB item via Wi-Fi.
        f2.monitor.updateScene("background")
        XCTAssertEqual(f2.controller.pendingCount, 1)
        XCTAssertEqual(f2.link.wifiRequests.count, 7)
        f2.monitor.updateScene("active")
        XCTAssertEqual(f2.link.wifiRequests.count, 8)
        XCTAssertEqual(f2.link.wifiRequests.last?.ids, [over10ID2])
    }

    @MainActor
    func testLateWifiReadyAfterReadyTimeoutSendsSupersededAndWaitsTwoSecondsOrLateReply() async throws {
        // Part 1: After 20s ready_timeout, new request holds until late wifi_ready arrives (answered with superseded).
        let sleeper1 = ControlledWifiSleeper()
        let f1 = try Fixture(test: self, sleeper: sleeper1)
        let p1 = try pair(f1)
        f1.monitor.updateScene("active")
        try f1.link.connect(p1, limit: 512)

        let dataA = makeDeterministicBytes(count: 520_000, seed: 31)
        f1.monitor.saveManually([try makeFileProvider(in: f1.root, bytes: dataA, name: "late-a.bin")], receivedAt: f1.clock.date)
        await awaitSave(f1, savedCount: 1)
        XCTAssertEqual(f1.link.wifiRequests.count, 1)

        let readyTimeout1 = await sleeper1.waitForSleep(duration: 20)
        readyTimeout1.fire()
        let aFellBack = await waitUntil { f1.link.offers.count == 1 }
        XCTAssertTrue(aFellBack)
        _ = await sleeper1.waitForSleep(duration: 2)

        // New large item B arrives during the 2s post-timeout hold: must NOT send wifi_request #2 yet.
        let dataB = makeDeterministicBytes(count: 530_000, seed: 32)
        f1.monitor.saveManually([try makeFileProvider(in: f1.root, bytes: dataB, name: "late-b.bin")], receivedAt: f1.clock.date.addingTimeInterval(1))
        await awaitSave(f1, savedCount: 2)
        XCTAssertEqual(f1.link.wifiRequests.count, 1)
        XCTAssertEqual(f1.link.offers.count, 1)

        // Late wifi_ready for request #1 arrives -> replied with wifi_cancel(superseded), never joined, and unlocks request #2.
        let staleReady = makeReadyPayload()
        try f1.link.send(.ready(staleReady))
        XCTAssertEqual(f1.link.wifiCancels.count, 1)
        XCTAssertEqual(f1.link.wifiCancels.first?.session, staleReady.session)
        XCTAssertEqual(f1.link.wifiCancels.first?.reason, .superseded)
        let joinedCount1 = await f1.wifiClient.joinedSSIDs.count
        XCTAssertEqual(joinedCount1, 0)
        XCTAssertEqual(f1.link.wifiRequests.count, 2)

        // Part 2: If no late reply arrives, 2s hold expires and then sends wifi_request #2.
        let sleeper2 = ControlledWifiSleeper()
        let f2 = try Fixture(test: self, sleeper: sleeper2)
        let p2 = try pair(f2)
        f2.monitor.updateScene("active")
        try f2.link.connect(p2, limit: 512)

        f2.monitor.saveManually([try makeFileProvider(in: f2.root, bytes: dataA, name: "hold-a.bin")], receivedAt: f2.clock.date)
        await awaitSave(f2, savedCount: 1)
        XCTAssertEqual(f2.link.wifiRequests.count, 1)

        let readyTimeout2 = await sleeper2.waitForSleep(duration: 20)
        readyTimeout2.fire()
        let aFellBack2 = await waitUntil { f2.link.offers.count == 1 }
        XCTAssertTrue(aFellBack2)
        let holdWait2 = await sleeper2.waitForSleep(duration: 2)

        f2.monitor.saveManually([try makeFileProvider(in: f2.root, bytes: dataB, name: "hold-b.bin")], receivedAt: f2.clock.date.addingTimeInterval(1))
        await awaitSave(f2, savedCount: 2)
        XCTAssertEqual(f2.link.wifiRequests.count, 1)

        holdWait2.fire()
        let sentSecond = await waitUntil { f2.link.wifiRequests.count == 2 }
        XCTAssertTrue(sentSecond)
        XCTAssertEqual(f2.link.offers.count, 1)

        // An unexpected late wifi_ready when no request is awaiting ready still returns wifi_cancel(superseded).
        try f2.link.send(.unavailable(reason: .startFailed))
        let strayReady = makeReadyPayload()
        try f2.link.send(.ready(strayReady))
        XCTAssertEqual(f2.link.wifiCancels.last?.session, strayReady.session)
        XCTAssertEqual(f2.link.wifiCancels.last?.reason, .superseded)
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
        let padConn1 = FakeWifiConnection(incoming: pcToPad1, outgoing: padToPc1, initialReadTimeout: 5)
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

    @MainActor
    func testBackgroundDuringTransferCancelsSessionKeepsOver10MiBAndContinuesBleWithoutCooldown() async throws {
        let over10Size = SyncProtocol.maxItemBytes + 1_024
        let over10Data = makeDeterministicBytes(count: over10Size, seed: 41)

        // Part 1: Entering background mid-sending cancels active Wi-Fi session, keeps > 10 MiB,
        //         moves <= 10 MiB (both outgoing and incoming) to BLE, and retries > 10 MiB immediately on foreground.
        let connSleeper1 = ControlledWifiSleeper()
        addTeardownBlock { connSleeper1.cancelAll() }
        let f1 = try Fixture(test: self)
        let p1 = try pair(f1)
        f1.controller.copiesReceivedToPasteboard = false
        f1.monitor.updateScene("active")
        try f1.link.connect(p1, limit: 512)

        f1.link.canSend = false
        let bleOutData1 = makeDeterministicBytes(count: 550_000, seed: 42)
        let savedBeforeOut1 = f1.monitor.savedCount
        f1.monitor.saveManually([try makeFileProvider(in: f1.root, bytes: bleOutData1, name: "bg-mid-ble-out.bin")], receivedAt: f1.clock.date)
        await awaitSave(f1, savedCount: savedBeforeOut1 + 1)

        let savedBeforeOver10Out1 = f1.monitor.savedCount
        f1.monitor.saveManually([try makeFileProvider(in: f1.root, bytes: over10Data, name: "bg-mid-over10-out.bin")], receivedAt: f1.clock.date.addingTimeInterval(1))
        await awaitSave(f1, savedCount: savedBeforeOver10Out1 + 1)

        let bleInData1 = makeDeterministicBytes(count: 600_000, seed: 43)
        let bleInOffer1 = makeOffer(from: "pc", data: bleInData1, name: "bg-mid-ble-in.bin")
        try f1.link.send(.offer(bleInOffer1))

        f1.link.canSend = true
        f1.link.onEvent?(.writable)
        XCTAssertEqual(f1.link.wifiRequests.count, 1)
        let req1 = try XCTUnwrap(f1.link.wifiRequests.first)
        XCTAssertEqual(req1.direction, .both)
        XCTAssertEqual(req1.ids.count, 3)
        let bleOutID1 = req1.ids[0]
        let over10OutID1 = req1.ids[1]
        XCTAssertEqual(req1.ids[2], bleInOffer1.id)

        let ready1 = makeReadyPayload()
        let bleKeys1 = try XCTUnwrap(f1.link.pcSessionKeys)
        let pcKeys1 = try WifiTransferKeys.derive(bleKeys: bleKeys1, token: ready1.token, session: ready1.session)
        let pcGuard1 = try WifiSessionReplayGuard()
        let padToPc1 = FakeByteChannel()
        let pcToPad1 = FakeByteChannel()
        let padConn1 = FakeWifiConnection(
            incoming: pcToPad1,
            outgoing: padToPc1,
            initialReadTimeout: 5,
            readSleeper: connSleeper1
        )
        let pcEnd1 = FakePcStreamEnd(incoming: padToPc1, outgoing: pcToPad1)
        await f1.wifiClient.setConnectHandler { _, _, _ in padConn1 }

        let midSendGate1 = TestWifiGate()
        let pcTask1 = Task {
            do {
                let pcChannel = try await WifiEncryptedStream.acceptAsPc(stream: pcEnd1, keys: pcKeys1, replayGuard: pcGuard1)
                let firstMessage = try await pcChannel.receiveMessage()
                guard case let .offer(firstOffer) = firstMessage, firstOffer.id == bleOutID1 else {
                    throw SyncProtocolError.state
                }
                try await pcChannel.sendMessage(.resume(id: bleOutID1, offset: 0))
                let firstChunk = try await pcChannel.receiveMessage()
                guard case .chunk = firstChunk else {
                    throw SyncProtocolError.state
                }
                await midSendGate1.open()
            } catch {
                await midSendGate1.open()
                throw error
            }
        }

        try f1.link.send(.ready(ready1))
        await midSendGate1.wait()
        try await pcTask1.value
        XCTAssertNotNil(f1.controller.wifiTransferProgress)

        // Move to background during active transfer -> self-cancels Wi-Fi, leaves SSID, keeps > 10 MiB, moves <= 10 MiB to BLE.
        f1.monitor.updateScene("background")
        XCTAssertEqual(f1.link.wifiCancels.count, 1)
        XCTAssertEqual(f1.link.wifiCancels.first?.session, ready1.session)
        XCTAssertEqual(f1.link.wifiCancels.first?.reason, .userCancelled)
        XCTAssertNil(f1.controller.wifiTransferProgress)
        XCTAssertEqual(f1.controller.pendingCount, 2)
        XCTAssertEqual(f1.link.offers.map(\.id), [bleOutID1])
        XCTAssertTrue(f1.link.resumes.contains(where: { $0.id == bleInOffer1.id && $0.offset == 0 }))
        let leftAfterBg1 = await waitUntilAsync { await f1.wifiClient.leftSSIDs == [ready1.ssid] }
        XCTAssertTrue(leftAfterBg1)

        // Continue <= 10 MiB incoming over BLE while in background.
        let savedBeforeBleIn1 = f1.monitor.savedCount
        var rxOffset1 = 0
        while rxOffset1 < bleInData1.count {
            let end = min(bleInData1.count, rxOffset1 + SyncProtocol.chunkBytes)
            try f1.link.send(.chunk(id: bleInOffer1.id, offset: rxOffset1, data: bleInData1.subdata(in: rxOffset1..<end)))
            rxOffset1 = end
        }
        await awaitSave(f1, savedCount: savedBeforeBleIn1 + 1)
        XCTAssertTrue(f1.link.ackIDs.contains(bleInOffer1.id))

        // Continue <= 10 MiB outgoing over BLE while in background.
        try f1.link.send(.resume(id: bleOutID1, offset: 0))
        var txAcked1 = 0
        var processedMsgIndex1 = 0
        while txAcked1 < bleOutData1.count {
            let before = processedMsgIndex1
            while processedMsgIndex1 < f1.link.messages.count {
                let msg = f1.link.messages[processedMsgIndex1]
                processedMsgIndex1 += 1
                if case let .chunk(id, offset, chunkData) = msg, id == bleOutID1 {
                    XCTAssertEqual(offset, txAcked1)
                    txAcked1 += chunkData.count
                    if txAcked1 < bleOutData1.count {
                        try f1.link.send(.resume(id: bleOutID1, offset: txAcked1))
                    }
                }
            }
            if processedMsgIndex1 == before {
                XCTFail("Expected <= 10 MiB outgoing item to progress over BLE")
                break
            }
        }
        try f1.link.send(.ack(ids: [bleOutID1]))
        XCTAssertEqual(f1.controller.pendingCount, 1)
        XCTAssertEqual(f1.link.wifiRequests.count, 1)

        // Return to foreground WITHOUT advancing clock -> > 10 MiB retries over Wi-Fi immediately (no 10-minute cooldown).
        f1.monitor.updateScene("active")
        XCTAssertEqual(f1.link.wifiRequests.count, 2)
        XCTAssertEqual(f1.link.wifiRequests.last?.direction, .send)
        XCTAssertEqual(f1.link.wifiRequests.last?.ids, [over10OutID1])

        let ready2 = makeReadyPayload(ssid: "DIRECT-cp-SECONDSSID")
        let pcKeys2 = try WifiTransferKeys.derive(bleKeys: bleKeys1, token: ready2.token, session: ready2.session)
        let pcGuard2 = try WifiSessionReplayGuard()
        let pcSink2 = InMemoryWifiTransferSink()
        let padToPc2 = FakeByteChannel()
        let pcToPad2 = FakeByteChannel()
        let padConn2 = FakeWifiConnection(incoming: pcToPad2, outgoing: padToPc2, initialReadTimeout: 5)
        let pcEnd2 = FakePcStreamEnd(incoming: padToPc2, outgoing: pcToPad2)
        await f1.wifiClient.setConnectHandler { _, _, _ in padConn2 }
        let pcTask2 = Task {
            try await WifiTransferEngine.runPcSession(
                stream: pcEnd2,
                keys: pcKeys2,
                outgoing: [],
                sink: pcSink2,
                replayGuard: pcGuard2
            )
        }
        try f1.link.send(.ready(ready2))
        let sentOver10 = await waitUntil(timeoutSeconds: 10) {
            f1.controller.pendingCount == 0 && f1.controller.wifiTransferProgress == nil
        }
        XCTAssertTrue(sentOver10)
        _ = try await pcTask2.value
        let receivedOver10OnPc = await pcSink2.completedData(for: over10OutID1)
        XCTAssertEqual(receivedOver10OnPc, over10Data)

        let log1 = try await readLog(f1)
        XCTAssertTrue(log1.contains("Wi-Fi転送中断; 理由=background"))
        let forbidden1 = [
            ready1.ssid,
            ready1.passphrase,
            ready1.ip,
            WifiControlMessageCodec.lowerHex(ready1.token),
            ready1.session.uuidString,
            bleOutID1.uuidString,
            over10OutID1.uuidString,
            bleInOffer1.id.uuidString,
            "bg-mid-ble-out",
            "bg-mid-over10-out",
            "bg-mid-ble-in",
            p1.pcId.uuidString,
            p1.key.base64EncodedString(),
        ]
        for secret in forbidden1 {
            XCTAssertFalse(log1.contains(secret), "Sensitive value leaked into log: \(secret)")
        }

        // Part 2: Entering background mid-receiving continues <= 10 MiB from saved partial over BLE
        //         and keeps > 10 MiB incoming until returning to foreground.
        let connSleeper2 = ControlledWifiSleeper()
        addTeardownBlock { connSleeper2.cancelAll() }
        let f2 = try Fixture(test: self)
        let p2 = try pair(f2)
        f2.controller.copiesReceivedToPasteboard = false
        f2.monitor.updateScene("active")
        try f2.link.connect(p2, limit: 512)

        f2.link.canSend = false
        let bleInData2 = makeDeterministicBytes(count: 700_000, seed: 44)
        let bleInOffer2 = makeOffer(from: "pc", data: bleInData2, name: "bg-rx-ble.bin")
        let over10InOffer2 = makeOffer(from: "pc", data: over10Data, name: "bg-rx-over10.bin")
        try f2.link.send(.offer(bleInOffer2))
        try f2.link.sendLargeOffer(over10InOffer2)
        f2.link.canSend = true
        f2.link.onEvent?(.writable)

        XCTAssertEqual(f2.link.wifiRequests.count, 1)
        XCTAssertEqual(f2.link.wifiRequests.first?.direction, .receive)
        XCTAssertEqual(f2.link.wifiRequests.first?.ids, [bleInOffer2.id, over10InOffer2.id])

        let readyRx1 = makeReadyPayload(ssid: "DIRECT-cp-RXFIRST")
        let bleKeys2 = try XCTUnwrap(f2.link.pcSessionKeys)
        let pcKeysRx1 = try WifiTransferKeys.derive(bleKeys: bleKeys2, token: readyRx1.token, session: readyRx1.session)
        let pcGuardRx1 = try WifiSessionReplayGuard()
        let padToPcRx1 = FakeByteChannel()
        let pcToPadRx1 = FakeByteChannel()
        let padConnRx1 = FakeWifiConnection(
            incoming: pcToPadRx1,
            outgoing: padToPcRx1,
            initialReadTimeout: 5,
            readSleeper: connSleeper2
        )
        let pcEndRx1 = FakePcStreamEnd(incoming: padToPcRx1, outgoing: pcToPadRx1)
        await f2.wifiClient.setConnectHandler { _, _, _ in padConnRx1 }

        let firstChunkBytes = SyncProtocol.maxWifiChunkBytes
        let firstChunkGate = TestWifiGate()
        let pcTaskRx1 = Task {
            do {
                let pcChannel = try await WifiEncryptedStream.acceptAsPc(stream: pcEndRx1, keys: pcKeysRx1, replayGuard: pcGuardRx1)
                let padDone = try await pcChannel.receiveMessage()
                guard case .done = padDone else { throw SyncProtocolError.state }
                try await pcChannel.sendMessage(.offer(bleInOffer2))
                let resumeReply = try await pcChannel.receiveMessage()
                guard case let .resume(resumeID, offset) = resumeReply, resumeID == bleInOffer2.id, offset == 0 else {
                    throw SyncProtocolError.state
                }
                let firstChunk = bleInData2.subdata(in: 0..<firstChunkBytes)
                try await pcChannel.sendMessage(.chunk(id: bleInOffer2.id, offset: 0, data: firstChunk))
                await firstChunkGate.open()
            } catch {
                await firstChunkGate.open()
                throw error
            }
        }

        try f2.link.send(.ready(readyRx1))
        await firstChunkGate.wait()
        try await pcTaskRx1.value
        let wroteFirstChunk = await waitUntil {
            f2.controller.wifiTransferProgress?.phase == .receiving
                && f2.controller.wifiTransferProgress?.bytes == firstChunkBytes
        }
        XCTAssertTrue(wroteFirstChunk)

        f2.monitor.updateScene("background")
        XCTAssertEqual(f2.link.wifiCancels.last?.session, readyRx1.session)
        XCTAssertEqual(f2.link.wifiCancels.last?.reason, .userCancelled)
        let leftAfterBg2 = await waitUntilAsync { await f2.wifiClient.leftSSIDs == [readyRx1.ssid] }
        XCTAssertTrue(leftAfterBg2)
        XCTAssertTrue(f2.link.resumes.contains(where: { $0.id == bleInOffer2.id && $0.offset == firstChunkBytes }))
        XCTAssertFalse(f2.link.resumes.contains(where: { $0.id == over10InOffer2.id }))
        XCTAssertFalse(f2.link.ackIDs.contains(over10InOffer2.id))

        let savedBeforeBleIn2 = f2.monitor.savedCount
        var rxOffset2 = firstChunkBytes
        while rxOffset2 < bleInData2.count {
            let end = min(bleInData2.count, rxOffset2 + SyncProtocol.chunkBytes)
            try f2.link.send(.chunk(id: bleInOffer2.id, offset: rxOffset2, data: bleInData2.subdata(in: rxOffset2..<end)))
            rxOffset2 = end
        }
        await awaitSave(f2, savedCount: savedBeforeBleIn2 + 1)
        XCTAssertTrue(f2.link.ackIDs.contains(bleInOffer2.id))

        // Return to foreground -> > 10 MiB incoming retries immediately over Wi-Fi and succeeds.
        f2.monitor.updateScene("active")
        XCTAssertEqual(f2.link.wifiRequests.count, 2)
        XCTAssertEqual(f2.link.wifiRequests.last?.direction, .receive)
        XCTAssertEqual(f2.link.wifiRequests.last?.ids, [over10InOffer2.id])

        let readyRx2 = makeReadyPayload(ssid: "DIRECT-cp-RXSECOND")
        let pcKeysRx2 = try WifiTransferKeys.derive(bleKeys: bleKeys2, token: readyRx2.token, session: readyRx2.session)
        let pcGuardRx2 = try WifiSessionReplayGuard()
        let padToPcRx2 = FakeByteChannel()
        let pcToPadRx2 = FakeByteChannel()
        let padConnRx2 = FakeWifiConnection(incoming: pcToPadRx2, outgoing: padToPcRx2, initialReadTimeout: 5)
        let pcEndRx2 = FakePcStreamEnd(incoming: padToPcRx2, outgoing: pcToPadRx2)
        await f2.wifiClient.setConnectHandler { _, _, _ in padConnRx2 }
        let pcTaskRx2 = Task {
            try await WifiTransferEngine.runPcSession(
                stream: pcEndRx2,
                keys: pcKeysRx2,
                outgoing: [InMemoryWifiTransferSource(offer: over10InOffer2, payload: over10Data)],
                sink: InMemoryWifiTransferSink(),
                replayGuard: pcGuardRx2
            )
        }
        let savedBeforeOver10In2 = f2.monitor.savedCount
        try f2.link.send(.ready(readyRx2))
        await awaitSave(f2, savedCount: savedBeforeOver10In2 + 1)
        let doneRx2 = await waitUntil(timeoutSeconds: 10) { f2.controller.wifiTransferProgress == nil }
        XCTAssertTrue(doneRx2)
        let pcResultRx2 = try await pcTaskRx2.value
        XCTAssertEqual(pcResultRx2.sent.count, 1)
        XCTAssertTrue(f2.link.ackIDs.contains(over10InOffer2.id))
        let savedOver10Entry = try XCTUnwrap(f2.monitor.entries.first {
            $0.source == .pc && $0.kind == .file && $0.attachmentByteCount == over10Data.count
        })
        let savedOver10File = try XCTUnwrap(savedOver10Entry.file)
        let savedOver10Bytes = try Data(contentsOf: f2.monitor.fileURL(savedOver10File))
        XCTAssertEqual(savedOver10Bytes, over10Data)

        // Part 3: Entering background during .joining cancels with wifi_cancel, keeps > 10 MiB,
        //         moves <= 10 MiB to BLE, and applies NO 10-minute cooldown to either item.
        let joinSleeper3 = ControlledWifiSleeper()
        addTeardownBlock { joinSleeper3.cancelAll() }
        let f3 = try Fixture(test: self)
        let p3 = try pair(f3)
        f3.monitor.updateScene("active")
        try f3.link.connect(p3, limit: 512)

        f3.link.canSend = false
        let bleOutData3 = makeDeterministicBytes(count: 550_000, seed: 45)
        let savedBeforeOut3 = f3.monitor.savedCount
        f3.monitor.saveManually([try makeFileProvider(in: f3.root, bytes: bleOutData3, name: "bg-join-ble.bin")], receivedAt: f3.clock.date)
        await awaitSave(f3, savedCount: savedBeforeOut3 + 1)
        let savedBeforeOver10Out3 = f3.monitor.savedCount
        f3.monitor.saveManually([try makeFileProvider(in: f3.root, bytes: over10Data, name: "bg-join-over10.bin")], receivedAt: f3.clock.date.addingTimeInterval(1))
        await awaitSave(f3, savedCount: savedBeforeOver10Out3 + 1)
        f3.link.canSend = true
        f3.link.onEvent?(.writable)

        XCTAssertEqual(f3.link.wifiRequests.count, 1)
        let req3 = try XCTUnwrap(f3.link.wifiRequests.first)
        XCTAssertEqual(req3.ids.count, 2)
        let bleOutID3 = req3.ids[0]
        let over10OutID3 = req3.ids[1]

        await f3.wifiClient.setJoinHandler { _, _, _ in
            do {
                try await joinSleeper3.sleep(99)
                return .joined
            } catch {
                return .joinFailed
            }
        }
        let readyJoin = makeReadyPayload(ssid: "DIRECT-cp-JOINBG")
        try f3.link.send(.ready(readyJoin))
        let joinWait = await joinSleeper3.waitForSleep(duration: 99)

        f3.monitor.updateScene("background")
        let joinCancelled = await waitUntil { joinWait.isFinished }
        XCTAssertTrue(joinCancelled)
        XCTAssertEqual(f3.link.wifiCancels.last?.session, readyJoin.session)
        XCTAssertEqual(f3.link.wifiCancels.last?.reason, .userCancelled)
        XCTAssertTrue(f3.link.wifiJoinResults.isEmpty)
        XCTAssertEqual(f3.controller.pendingCount, 2)
        XCTAssertEqual(f3.link.offers.map(\.id), [bleOutID3])

        // Reconnect in foreground without advancing clock: neither item has a 10-minute cooldown.
        await f3.wifiClient.setJoinHandler(nil)
        f3.link.disconnect()
        f3.monitor.updateScene("active")
        try f3.link.connect(p3, limit: 512)
        XCTAssertEqual(f3.link.wifiRequests.count, 2)
        XCTAssertEqual(f3.link.wifiRequests.last?.ids, [bleOutID3, over10OutID3])
    }

    @MainActor
    func testNonForegroundWifiCancelAndFailureKeepOver10MiBWithoutCooldown() async throws {
        let over10Size = SyncProtocol.maxItemBytes + 1_024
        let over10Data = makeDeterministicBytes(count: over10Size, seed: 51)
        let bleOutData = makeDeterministicBytes(count: 550_000, seed: 52)
        let defaultTimeouts = PCSyncController.WifiTransferTimeouts()

        // Part 1: Receiving wifi_cancel(timeout) while !isForeground keeps > 10 MiB and moves <= 10 MiB to BLE.
        let connSleeper1 = ControlledWifiSleeper()
        addTeardownBlock { connSleeper1.cancelAll() }
        let f1 = try Fixture(test: self)
        let p1 = try pair(f1)
        f1.monitor.updateScene("active")
        try f1.link.connect(p1, limit: 512)

        f1.link.canSend = false
        let savedBefore1A = f1.monitor.savedCount
        f1.monitor.saveManually([try makeFileProvider(in: f1.root, bytes: bleOutData, name: "cancel-bg-ble.bin")], receivedAt: f1.clock.date)
        await awaitSave(f1, savedCount: savedBefore1A + 1)
        let savedBefore1B = f1.monitor.savedCount
        f1.monitor.saveManually([try makeFileProvider(in: f1.root, bytes: over10Data, name: "cancel-bg-over10.bin")], receivedAt: f1.clock.date.addingTimeInterval(1))
        await awaitSave(f1, savedCount: savedBefore1B + 1)
        f1.link.canSend = true
        f1.link.onEvent?(.writable)

        let req1 = try XCTUnwrap(f1.link.wifiRequests.first)
        XCTAssertEqual(req1.ids.count, 2)
        let bleOutID1 = req1.ids[0]
        let over10OutID1 = req1.ids[1]

        let ready1 = makeReadyPayload(ssid: "DIRECT-cp-CANCELBG")
        let bleKeys1 = try XCTUnwrap(f1.link.pcSessionKeys)
        let pcKeys1 = try WifiTransferKeys.derive(bleKeys: bleKeys1, token: ready1.token, session: ready1.session)
        let pcGuard1 = try WifiSessionReplayGuard()
        let padToPc1 = FakeByteChannel()
        let pcToPad1 = FakeByteChannel()
        let padConn1 = FakeWifiConnection(
            incoming: pcToPad1,
            outgoing: padToPc1,
            initialReadTimeout: defaultTimeouts.preAuthReadSeconds,
            readSleeper: connSleeper1
        )
        let pcEnd1 = FakePcStreamEnd(incoming: padToPc1, outgoing: pcToPad1)
        await f1.wifiClient.setConnectHandler { _, _, _ in padConn1 }

        let authGate1 = TestWifiGate()
        let pcTask1 = Task {
            do {
                _ = try await WifiEncryptedStream.acceptAsPc(stream: pcEnd1, keys: pcKeys1, replayGuard: pcGuard1)
                await authGate1.open()
            } catch {
                await authGate1.open()
                throw error
            }
        }
        try f1.link.send(.ready(ready1))
        await authGate1.wait()
        try await pcTask1.value
        _ = await connSleeper1.waitForSleep(duration: defaultTimeouts.idleSeconds)

        // Scene becomes non-foreground (inactive) before PC's wifi_cancel(timeout) arrives.
        f1.monitor.updateScene("inactive")
        try f1.link.send(.cancel(session: ready1.session, reason: .timeout))

        XCTAssertEqual(f1.link.offers.map(\.id), [bleOutID1])
        XCTAssertEqual(f1.controller.pendingCount, 2)
        let left1 = await waitUntilAsync { await f1.wifiClient.leftSSIDs == [ready1.ssid] }
        XCTAssertTrue(left1)

        try f1.link.send(.ack(ids: [bleOutID1]))
        XCTAssertEqual(f1.controller.pendingCount, 1)

        // Return to foreground without advancing clock -> > 10 MiB retries over Wi-Fi immediately.
        f1.monitor.updateScene("active")
        XCTAssertEqual(f1.link.wifiRequests.count, 2)
        XCTAssertEqual(f1.link.wifiRequests.last?.ids, [over10OutID1])

        // Part 2: Local TCP idle timeout failure while !isForeground keeps > 10 MiB and moves <= 10 MiB to BLE.
        let connSleeper2 = ControlledWifiSleeper()
        addTeardownBlock { connSleeper2.cancelAll() }
        let f2 = try Fixture(test: self)
        let p2 = try pair(f2)
        f2.monitor.updateScene("active")
        try f2.link.connect(p2, limit: 512)

        f2.link.canSend = false
        let savedBefore2A = f2.monitor.savedCount
        f2.monitor.saveManually([try makeFileProvider(in: f2.root, bytes: bleOutData, name: "fail-bg-ble.bin")], receivedAt: f2.clock.date)
        await awaitSave(f2, savedCount: savedBefore2A + 1)
        let savedBefore2B = f2.monitor.savedCount
        f2.monitor.saveManually([try makeFileProvider(in: f2.root, bytes: over10Data, name: "fail-bg-over10.bin")], receivedAt: f2.clock.date.addingTimeInterval(1))
        await awaitSave(f2, savedCount: savedBefore2B + 1)
        f2.link.canSend = true
        f2.link.onEvent?(.writable)

        let req2 = try XCTUnwrap(f2.link.wifiRequests.first)
        XCTAssertEqual(req2.ids.count, 2)
        let bleOutID2 = req2.ids[0]
        let over10OutID2 = req2.ids[1]

        let ready2 = makeReadyPayload(ssid: "DIRECT-cp-FAILBG")
        let bleKeys2 = try XCTUnwrap(f2.link.pcSessionKeys)
        let pcKeys2 = try WifiTransferKeys.derive(bleKeys: bleKeys2, token: ready2.token, session: ready2.session)
        let pcGuard2 = try WifiSessionReplayGuard()
        let padToPc2 = FakeByteChannel()
        let pcToPad2 = FakeByteChannel()
        let padConn2 = FakeWifiConnection(
            incoming: pcToPad2,
            outgoing: padToPc2,
            initialReadTimeout: defaultTimeouts.preAuthReadSeconds,
            readSleeper: connSleeper2
        )
        let pcEnd2 = FakePcStreamEnd(incoming: padToPc2, outgoing: pcToPad2)
        await f2.wifiClient.setConnectHandler { _, _, _ in padConn2 }

        let pcTask2 = Task {
            _ = try await WifiEncryptedStream.acceptAsPc(stream: pcEnd2, keys: pcKeys2, replayGuard: pcGuard2)
        }
        try f2.link.send(.ready(ready2))
        let idleWait2 = await connSleeper2.waitForSleep(duration: defaultTimeouts.idleSeconds)
        try await pcTask2.value

        f2.monitor.updateScene("inactive")
        idleWait2.fire()

        let fellBack2 = await waitUntil { f2.link.offers.contains(where: { $0.id == bleOutID2 }) }
        XCTAssertTrue(fellBack2)
        XCTAssertEqual(f2.link.offers.map(\.id), [bleOutID2])
        XCTAssertEqual(f2.controller.pendingCount, 2)
        XCTAssertEqual(f2.link.wifiCancels.last?.session, ready2.session)
        XCTAssertEqual(f2.link.wifiCancels.last?.reason, .timeout)
        let left2 = await f2.wifiClient.leftSSIDs
        XCTAssertEqual(left2, [ready2.ssid])

        try f2.link.send(.ack(ids: [bleOutID2]))
        XCTAssertEqual(f2.controller.pendingCount, 1)

        f2.monitor.updateScene("active")
        XCTAssertEqual(f2.link.wifiRequests.count, 2)
        XCTAssertEqual(f2.link.wifiRequests.last?.ids, [over10OutID2])

        // Part 3: ready_timeout while in background keeps > 10 MiB instead of dropping it.
        let sleeper3 = ControlledWifiSleeper()
        let f3 = try Fixture(test: self, sleeper: sleeper3)
        let p3 = try pair(f3)
        f3.monitor.updateScene("active")
        try f3.link.connect(p3, limit: 512)

        let savedBefore3 = f3.monitor.savedCount
        f3.monitor.saveManually([try makeFileProvider(in: f3.root, bytes: over10Data, name: "ready-timeout-bg-over10.bin")], receivedAt: f3.clock.date)
        await awaitSave(f3, savedCount: savedBefore3 + 1)
        XCTAssertEqual(f3.link.wifiRequests.count, 1)
        let over10OutID3 = try XCTUnwrap(f3.link.wifiRequests.first?.ids.first)

        let readyWait3 = await sleeper3.waitForSleep(duration: defaultTimeouts.readySeconds)
        f3.monitor.updateScene("background")
        readyWait3.fire()
        let holdWait3 = await sleeper3.waitForSleep(duration: defaultTimeouts.readyTimeoutHoldSeconds)

        XCTAssertEqual(f3.controller.pendingCount, 1)
        XCTAssertTrue(f3.link.offers.isEmpty)

        f3.monitor.updateScene("active")
        holdWait3.fire()
        let retried3 = await waitUntil { f3.link.wifiRequests.count == 2 }
        XCTAssertTrue(retried3)
        XCTAssertEqual(f3.link.wifiRequests.last?.ids, [over10OutID3])
    }

    @MainActor
    func testNotForegroundJoinResultWhileForegroundFallsBackToBleWithoutStalling() async throws {
        // Part 1: Incoming <= 10 MiB gets not_foreground while still in foreground -> immediately sends BLE resume and finishes over BLE.
        let f1 = try Fixture(test: self)
        let p1 = try pair(f1)
        f1.controller.copiesReceivedToPasteboard = false
        f1.monitor.updateScene("active")
        try f1.link.connect(p1, limit: 512)

        let inData1 = makeDeterministicBytes(count: 600_000, seed: 61)
        let inOffer1 = makeOffer(from: "pc", data: inData1, name: "fg-notfg-in.bin")
        try f1.link.send(.offer(inOffer1))
        XCTAssertEqual(f1.link.wifiRequests.count, 1)
        XCTAssertEqual(f1.link.wifiRequests.first?.direction, .receive)
        XCTAssertTrue(f1.link.resumes.isEmpty)

        await f1.wifiClient.enqueueJoinStatus(.notForeground)
        let ready1 = makeReadyPayload(ssid: "DIRECT-cp-FGNOTFG1")
        try f1.link.send(.ready(ready1))

        let resumed1 = await waitUntil { f1.link.resumes.contains(where: { $0.id == inOffer1.id }) }
        XCTAssertTrue(resumed1)
        XCTAssertEqual(f1.link.wifiJoinResults.last?.session, ready1.session)
        XCTAssertEqual(f1.link.wifiJoinResults.last?.status, .notForeground)
        XCTAssertEqual(f1.link.resumes.first?.offset, 0)
        XCTAssertEqual(f1.link.wifiRequests.count, 1)

        let savedBefore1 = f1.monitor.savedCount
        var offset1 = 0
        while offset1 < inData1.count {
            let end = min(inData1.count, offset1 + SyncProtocol.chunkBytes)
            try f1.link.send(.chunk(id: inOffer1.id, offset: offset1, data: inData1.subdata(in: offset1..<end)))
            offset1 = end
        }
        await awaitSave(f1, savedCount: savedBefore1 + 1)
        XCTAssertTrue(f1.link.ackIDs.contains(inOffer1.id))
        XCTAssertEqual(f1.link.wifiRequests.count, 1)
        let savedEntry1 = try XCTUnwrap(f1.monitor.entries.first { $0.source == .pc && $0.kind == .file })
        let savedFile1 = try XCTUnwrap(savedEntry1.file)
        let savedBytes1 = try Data(contentsOf: f1.monitor.fileURL(savedFile1))
        XCTAssertEqual(savedBytes1, inData1)

        // Part 2: Foreground not_foreground with mixed <= 10 MiB and > 10 MiB items moves <= 10 MiB to BLE without loop
        //         and defers > 10 MiB until leaving and returning to foreground.
        let f2 = try Fixture(test: self)
        let p2 = try pair(f2)
        f2.controller.copiesReceivedToPasteboard = false
        f2.monitor.updateScene("active")
        try f2.link.connect(p2, limit: 512)

        f2.link.canSend = false
        let bleOutData2 = makeDeterministicBytes(count: 550_000, seed: 62)
        let over10Size = SyncProtocol.maxItemBytes + 1_024
        let over10Data = makeDeterministicBytes(count: over10Size, seed: 63)

        let savedBefore2A = f2.monitor.savedCount
        f2.monitor.saveManually([try makeFileProvider(in: f2.root, bytes: bleOutData2, name: "fg-notfg-ble-out.bin")], receivedAt: f2.clock.date)
        await awaitSave(f2, savedCount: savedBefore2A + 1)

        let savedBefore2B = f2.monitor.savedCount
        f2.monitor.saveManually([try makeFileProvider(in: f2.root, bytes: over10Data, name: "fg-notfg-over10-out.bin")], receivedAt: f2.clock.date.addingTimeInterval(1))
        await awaitSave(f2, savedCount: savedBefore2B + 1)

        let over10InOffer2 = makeOffer(from: "pc", data: over10Data, name: "fg-notfg-over10-in.bin")
        try f2.link.sendLargeOffer(over10InOffer2)

        f2.link.canSend = true
        f2.link.onEvent?(.writable)
        XCTAssertEqual(f2.link.wifiRequests.count, 1)
        let req2 = try XCTUnwrap(f2.link.wifiRequests.first)
        XCTAssertEqual(req2.direction, .both)
        XCTAssertEqual(req2.ids.count, 3)
        let bleOutID2 = req2.ids[0]
        let over10OutID2 = req2.ids[1]
        XCTAssertEqual(req2.ids[2], over10InOffer2.id)

        await f2.wifiClient.enqueueJoinStatus(.notForeground)
        let ready2 = makeReadyPayload(ssid: "DIRECT-cp-FGNOTFG2")
        try f2.link.send(.ready(ready2))

        let fellBackBle2 = await waitUntil { f2.link.offers.contains(where: { $0.id == bleOutID2 }) }
        XCTAssertTrue(fellBackBle2)
        XCTAssertEqual(f2.link.wifiJoinResults.last?.status, .notForeground)
        XCTAssertEqual(f2.link.offers.map(\.id), [bleOutID2])
        XCTAssertTrue(f2.link.resumes.isEmpty)
        XCTAssertFalse(f2.link.ackIDs.contains(over10InOffer2.id))
        XCTAssertEqual(f2.controller.pendingCount, 2)
        XCTAssertEqual(f2.link.wifiRequests.count, 1)

        try f2.link.send(.ack(ids: [bleOutID2]))
        XCTAssertEqual(f2.controller.pendingCount, 1)
        f2.controller.checkTimeouts()
        XCTAssertEqual(f2.link.wifiRequests.count, 1)

        // Leaving and returning to foreground retries the deferred > 10 MiB items over Wi-Fi.
        f2.monitor.updateScene("background")
        XCTAssertEqual(f2.controller.pendingCount, 1)
        XCTAssertFalse(f2.link.ackIDs.contains(over10InOffer2.id))
        f2.monitor.updateScene("active")
        XCTAssertEqual(f2.link.wifiRequests.count, 2)
        XCTAssertEqual(f2.link.wifiRequests.last?.direction, .both)
        XCTAssertEqual(f2.link.wifiRequests.last?.ids, [over10OutID2, over10InOffer2.id])
    }
}
