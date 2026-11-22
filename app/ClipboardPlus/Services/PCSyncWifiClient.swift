import CryptoKit
import Foundation
import Network
#if canImport(NetworkExtension)
import NetworkExtension
#endif

enum PCSyncWifiThreshold: Int, CaseIterable, Identifiable, Equatable, Sendable {
    case kb200 = 204_800
    case kb500 = 512_000
    case mb1 = 1_048_576
    case mb2 = 2_097_152

    static let defaultValue: PCSyncWifiThreshold = .kb500
    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .kb200: return "200KB以上"
        case .kb500: return "500KB以上（既定）"
        case .mb1: return "1MB以上"
        case .mb2: return "2MB以上"
        }
    }
}

enum PCSyncWifiClientError: Error, Equatable, Sendable {
    case invalidEndpoint
    case connectTimeout
    case localNetworkDenied
    case connectFailed
    case readTimeout
    case writeTimeout
    case networkFailed
    case cancelled
}

/// Receive sizing for NWConnection reads backed by WifiEncryptedStream.
/// Small reads (<= 4 KiB) return as soon as 1 byte arrives (handshake/headers/acks);
/// bulk reads (> 4 KiB, where WifiEncryptedStream requests the exact remaining frame body)
/// coalesce 64 KiB .. 512 KiB per callback to match Stage A probe throughput.
enum PCSyncWifiReceivePolicy {
    static let smallReadBoundary = 4_096
    static let minimumBulkBytes = 65_536
    static let maximumBulkBytes = 524_288

    static func receiveLengths(maxLength: Int) -> (minimum: Int, maximum: Int) {
        let clampedMax = max(1, min(maxLength, maximumBulkBytes))
        if maxLength > smallReadBoundary {
            return (minimum: min(clampedMax, minimumBulkBytes), maximum: clampedMax)
        }
        return (minimum: 1, maximum: clampedMax)
    }
}

protocol PCSyncWifiConnection: WifiByteStream {
    func setIdleTimeout(_ seconds: TimeInterval) async
    func close() async
}

protocol PCSyncWifiClient: Sendable {
    func join(ssid: String, passphrase: String, timeoutSeconds: TimeInterval) async -> WifiJoinStatus
    func leave(ssid: String) async
    func connect(
        host: String,
        port: Int,
        timeoutSeconds: TimeInterval,
        initialReadTimeoutSeconds: TimeInterval
    ) async throws -> any PCSyncWifiConnection
}

final class LivePCSyncWifiClient: PCSyncWifiClient {
    private final class JoinState: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<WifiJoinStatus, Never>?
        private var timeoutItem: DispatchWorkItem?
        private var finished = false

        func install(
            continuation: CheckedContinuation<WifiJoinStatus, Never>,
            timeoutItem: DispatchWorkItem
        ) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if finished { return false }
            self.continuation = continuation
            self.timeoutItem = timeoutItem
            return true
        }

        func finish(_ status: WifiJoinStatus) -> Bool {
            lock.lock()
            if finished {
                lock.unlock()
                return false
            }
            finished = true
            let cont = continuation
            continuation = nil
            let item = timeoutItem
            timeoutItem = nil
            lock.unlock()
            item?.cancel()
            cont?.resume(returning: status)
            return true
        }
    }

    private final class ConnectAttempt: @unchecked Sendable {
        let connection: NWConnection
        let queue: DispatchQueue
        private var continuation: CheckedContinuation<Void, Error>?
        private var timeoutItem: DispatchWorkItem?
        private var sawLocalNetworkDenied = false
        private var finished = false

        init(connection: NWConnection, queue: DispatchQueue) {
            self.connection = connection
            self.queue = queue
        }

        func start(timeoutSeconds: TimeInterval, continuation: CheckedContinuation<Void, Error>) {
            queue.async { [self] in
                if finished {
                    continuation.resume(throwing: PCSyncWifiClientError.cancelled)
                    return
                }
                self.continuation = continuation
                let timeout = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    let error: PCSyncWifiClientError = self.sawLocalNetworkDenied ? .localNetworkDenied : .connectTimeout
                    self.connection.cancel()
                    self.complete(.failure(error))
                }
                timeoutItem = timeout
                queue.asyncAfter(deadline: .now() + max(0.05, timeoutSeconds), execute: timeout)

                connection.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.complete(.success(()))
                    case .waiting:
                        if self.connection.currentPath?.unsatisfiedReason == .localNetworkDenied {
                            self.sawLocalNetworkDenied = true
                        }
                    case .failed:
                        let error: PCSyncWifiClientError = self.sawLocalNetworkDenied ? .localNetworkDenied : .connectFailed
                        self.complete(.failure(error))
                    case .cancelled:
                        self.complete(.failure(PCSyncWifiClientError.cancelled))
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        }

        func cancel() {
            queue.async { [self] in
                guard !finished else { return }
                connection.cancel()
                complete(.failure(PCSyncWifiClientError.cancelled))
            }
        }

        private func complete(_ result: Result<Void, Error>) {
            guard !finished else { return }
            finished = true
            timeoutItem?.cancel()
            timeoutItem = nil
            let cont = continuation
            continuation = nil
            connection.stateUpdateHandler = nil
            cont?.resume(with: result)
        }
    }

    private final class LiveConnection: PCSyncWifiConnection, @unchecked Sendable {
        private final class PendingRead: @unchecked Sendable {
            var continuation: CheckedContinuation<Data, Error>?
            var timeoutItem: DispatchWorkItem?

            init(continuation: CheckedContinuation<Data, Error>) {
                self.continuation = continuation
            }
        }

        private final class PendingWrite: @unchecked Sendable {
            var continuation: CheckedContinuation<Void, Error>?
            var timeoutItem: DispatchWorkItem?

            init(continuation: CheckedContinuation<Void, Error>) {
                self.continuation = continuation
            }
        }

        private let connection: NWConnection
        private let queue: DispatchQueue
        private var timeoutSeconds: TimeInterval
        private var closed = false
        private var sawEOF = false
        private var activeRead: PendingRead?
        private var activeWrite: PendingWrite?

        init(connection: NWConnection, queue: DispatchQueue, initialReadTimeoutSeconds: TimeInterval) {
            self.connection = connection
            self.queue = queue
            self.timeoutSeconds = max(0.05, initialReadTimeoutSeconds)
            queue.async { [weak self] in
                guard let self else { return }
                self.connection.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .failed:
                        self.closeOnQueue(error: PCSyncWifiClientError.networkFailed)
                    case .cancelled:
                        self.closeOnQueue(error: PCSyncWifiClientError.cancelled)
                    default:
                        break
                    }
                }
            }
        }

        deinit {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }

        func setIdleTimeout(_ seconds: TimeInterval) async {
            let clamped = max(0.05, seconds)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                queue.async { [self] in
                    timeoutSeconds = clamped
                    continuation.resume()
                }
            }
        }

        func read(maxLength: Int) async throws -> Data {
            guard maxLength > 0 else { return Data() }
            let lengths = PCSyncWifiReceivePolicy.receiveLengths(maxLength: maxLength)
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                    queue.async { [self] in
                        if closed || activeRead != nil {
                            continuation.resume(throwing: PCSyncWifiClientError.cancelled)
                            return
                        }
                        if sawEOF {
                            continuation.resume(returning: Data())
                            return
                        }
                        let pending = PendingRead(continuation: continuation)
                        let timeoutItem = DispatchWorkItem { [weak self, weak pending] in
                            guard let self, let pending else { return }
                            self.failAndCloseRead(pending, error: PCSyncWifiClientError.readTimeout)
                        }
                        pending.timeoutItem = timeoutItem
                        activeRead = pending
                        queue.asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutItem)

                        connection.receive(
                            minimumIncompleteLength: lengths.minimum,
                            maximumLength: lengths.maximum
                        ) { [weak self, weak pending] content, _, isComplete, error in
                            guard let self, let pending else { return }
                            if isComplete {
                                self.sawEOF = true
                            }
                            if let content, !content.isEmpty {
                                self.finishRead(pending, result: .success(content))
                            } else if error != nil {
                                self.finishRead(pending, result: .failure(PCSyncWifiClientError.networkFailed))
                            } else {
                                self.sawEOF = true
                                self.finishRead(pending, result: .success(Data()))
                            }
                        }
                    }
                }
            } onCancel: {
                self.cancelAsync()
            }
        }

        func write(_ data: Data) async throws {
            guard !data.isEmpty else { return }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    queue.async { [self] in
                        if closed || activeWrite != nil {
                            continuation.resume(throwing: PCSyncWifiClientError.cancelled)
                            return
                        }
                        let pending = PendingWrite(continuation: continuation)
                        let timeoutItem = DispatchWorkItem { [weak self, weak pending] in
                            guard let self, let pending else { return }
                            self.failAndCloseWrite(pending, error: PCSyncWifiClientError.writeTimeout)
                        }
                        pending.timeoutItem = timeoutItem
                        activeWrite = pending
                        queue.asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutItem)

                        connection.send(
                            content: data,
                            contentContext: .defaultMessage,
                            isComplete: true,
                            completion: .contentProcessed { [weak self, weak pending] error in
                                guard let self, let pending else { return }
                                if error != nil {
                                    self.finishWrite(pending, result: .failure(PCSyncWifiClientError.networkFailed))
                                } else {
                                    self.finishWrite(pending, result: .success(()))
                                }
                            }
                        )
                    }
                }
            } onCancel: {
                self.cancelAsync()
            }
        }

        func close() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                queue.async { [self] in
                    closeOnQueue(error: PCSyncWifiClientError.cancelled)
                    continuation.resume()
                }
            }
        }

        private func cancelAsync() {
            queue.async { [self] in
                closeOnQueue(error: PCSyncWifiClientError.cancelled)
            }
        }

        private func failAndCloseRead(_ pending: PendingRead, error: Error) {
            guard activeRead === pending, pending.continuation != nil else { return }
            finishRead(pending, result: .failure(error))
            closeOnQueue(error: error)
        }

        private func failAndCloseWrite(_ pending: PendingWrite, error: Error) {
            guard activeWrite === pending, pending.continuation != nil else { return }
            finishWrite(pending, result: .failure(error))
            closeOnQueue(error: error)
        }

        private func finishRead(_ pending: PendingRead, result: Result<Data, Error>) {
            guard let continuation = pending.continuation else { return }
            pending.continuation = nil
            pending.timeoutItem?.cancel()
            pending.timeoutItem = nil
            if activeRead === pending {
                activeRead = nil
            }
            continuation.resume(with: result)
        }

        private func finishWrite(_ pending: PendingWrite, result: Result<Void, Error>) {
            guard let continuation = pending.continuation else { return }
            pending.continuation = nil
            pending.timeoutItem?.cancel()
            pending.timeoutItem = nil
            if activeWrite === pending {
                activeWrite = nil
            }
            continuation.resume(with: result)
        }

        private func closeOnQueue(error: Error) {
            if !closed {
                closed = true
                connection.stateUpdateHandler = nil
                connection.cancel()
            }
            if let pending = activeRead {
                finishRead(pending, result: .failure(error))
            }
            if let pending = activeWrite {
                finishWrite(pending, result: .failure(error))
            }
        }
    }

    init() {}

    func join(ssid: String, passphrase: String, timeoutSeconds: TimeInterval) async -> WifiJoinStatus {
        #if targetEnvironment(simulator)
        return .joinFailed
        #else
        let config = NEHotspotConfiguration(ssid: ssid, passphrase: passphrase, isWEP: false)
        config.joinOnce = true
        return await Self.applyHotspot(config: config, ssid: ssid, timeoutSeconds: timeoutSeconds)
        #endif
    }

    func leave(ssid: String) async {
        #if !targetEnvironment(simulator)
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
        #endif
    }

    func connect(
        host: String,
        port: Int,
        timeoutSeconds: TimeInterval,
        initialReadTimeoutSeconds: TimeInterval
    ) async throws -> any PCSyncWifiConnection {
        guard port >= 1, port <= Int(UInt16.max), let nwPort = Network.NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw PCSyncWifiClientError.invalidEndpoint
        }
        let deadline = Date().addingTimeInterval(max(0.05, timeoutSeconds))
        let maxAttempts = 4
        var attempt = 0
        while true {
            try Task.checkCancellation()
            attempt += 1
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0.05 {
                throw PCSyncWifiClientError.connectTimeout
            }
            do {
                return try await connectOnce(
                    host: host,
                    nwPort: nwPort,
                    timeoutSeconds: remaining,
                    initialReadTimeoutSeconds: initialReadTimeoutSeconds
                )
            } catch PCSyncWifiClientError.connectFailed {
                let left = deadline.timeIntervalSinceNow
                if attempt < maxAttempts && left > 0.5 {
                    try await Task.sleep(nanoseconds: 300_000_000)
                    continue
                }
                throw PCSyncWifiClientError.connectFailed
            }
        }
    }

    private func connectOnce(
        host: String,
        nwPort: Network.NWEndpoint.Port,
        timeoutSeconds: TimeInterval,
        initialReadTimeoutSeconds: TimeInterval
    ) async throws -> LiveConnection {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.requiredInterfaceType = .wifi
        let nwConnection = NWConnection(host: Network.NWEndpoint.Host(host), port: nwPort, using: parameters)
        let queue = DispatchQueue(label: "clipboardplus.wifi-sync.tcp", qos: .userInitiated)
        let attempt = ConnectAttempt(connection: nwConnection, queue: queue)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                attempt.start(timeoutSeconds: timeoutSeconds, continuation: continuation)
            }
        } onCancel: {
            attempt.cancel()
        }

        return LiveConnection(
            connection: nwConnection,
            queue: queue,
            initialReadTimeoutSeconds: initialReadTimeoutSeconds
        )
    }

    #if !targetEnvironment(simulator)
    private static func applyHotspot(
        config: NEHotspotConfiguration,
        ssid: String,
        timeoutSeconds: TimeInterval
    ) async -> WifiJoinStatus {
        let state = JoinState()
        let queue = DispatchQueue(label: "clipboardplus.wifi-sync.join", qos: .userInitiated)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<WifiJoinStatus, Never>) in
                let timeoutItem = DispatchWorkItem {
                    if state.finish(.timeout) {
                        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
                    }
                }
                if !state.install(continuation: continuation, timeoutItem: timeoutItem) {
                    continuation.resume(returning: .joinFailed)
                    return
                }
                let clampedTimeout = max(0.05, timeoutSeconds)
                queue.asyncAfter(deadline: .now() + clampedTimeout, execute: timeoutItem)
                NEHotspotConfigurationManager.shared.apply(config) { error in
                    let status: WifiJoinStatus
                    if let error {
                        status = Self.mapHotspotError(error)
                    } else {
                        status = .joined
                    }
                    if !state.finish(status), status == .joined {
                        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
                    }
                }
            }
        } onCancel: {
            if state.finish(.joinFailed) {
                NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
            }
        }
    }

    private static func mapHotspotError(_ error: Error) -> WifiJoinStatus {
        let nsError = error as NSError
        if nsError.domain == NEHotspotConfigurationErrorDomain,
           let code = NEHotspotConfigurationError(rawValue: nsError.code) {
            switch code {
            case .alreadyAssociated:
                return .joined
            case .userDenied:
                return .userDenied
            case .applicationIsNotInForeground:
                return .notForeground
            default:
                return .joinFailed
            }
        }
        return .joinFailed
    }
    #endif
}

private final class ManagedFileHandle {
    private var handle: FileHandle?

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    var raw: FileHandle? { handle }

    func close() {
        if let opened = handle {
            handle = nil
            try? opened.close()
        }
    }

    func closeThrowing() throws {
        if let opened = handle {
            handle = nil
            try opened.close()
        }
    }

    deinit {
        close()
    }
}

/// Streams an outgoing attachment from PCSync-v2/<id>.body off the main thread.
actor FileWifiTransferSource: WifiTransferSource {
    let offer: SyncOffer
    private let fileURL: URL
    private var handle: ManagedFileHandle?

    init(offer: SyncOffer, fileURL: URL) {
        self.offer = offer
        self.fileURL = fileURL
    }

    func close() {
        handle?.close()
        handle = nil
    }

    func readChunk(offset: Int, maxLength: Int) async throws -> Data {
        try SyncProtocol.require(offset >= 0 && offset <= offer.size && maxLength >= 1, .state)
        if offset == offer.size {
            close()
            return Data()
        }
        let file: FileHandle
        if let opened = handle?.raw {
            file = opened
        } else {
            let opened = try FileHandle(forReadingFrom: fileURL)
            handle = ManagedFileHandle(opened)
            file = opened
        }
        try file.seek(toOffset: UInt64(offset))
        let want = min(maxLength, offer.size - offset)
        let maybeChunk = try file.read(upToCount: want)
        let chunk = maybeChunk ?? Data()
        if offset + chunk.count >= offer.size {
            close()
        }
        return chunk
    }
}

enum WifiDiskSinkError: Error, Equatable, Sendable {
    case storageFailed
    case cancelled
}

enum WifiSinkBeginOutcome: Sendable {
    case alreadyCompleted
    case resume(offset: Int, partialURL: URL)
}

/// Receives PC->iOS attachments over Wi-Fi into PCSync-v2/, verifying SHA-256 off the main thread
/// and rejecting any offer not explicitly requested in `wifi_request`.
actor DiskWifiTransferSink: WifiTransferSink {
    private let allowedIDs: Set<UUID>
    private let beginHook: @MainActor @Sendable (SyncOffer) async throws -> WifiSinkBeginOutcome
    private let commitHook: @MainActor @Sendable (SyncOffer, URL) async throws -> Void
    private let discardHook: @MainActor @Sendable (UUID) async throws -> Void
    private var activeOffer: SyncOffer?
    private var activeURL: URL?
    private var activeHandle: ManagedFileHandle?
    private var activeOffset = 0

    init(
        allowedIDs: Set<UUID>,
        beginHook: @escaping @MainActor @Sendable (SyncOffer) async throws -> WifiSinkBeginOutcome,
        commitHook: @escaping @MainActor @Sendable (SyncOffer, URL) async throws -> Void,
        discardHook: @escaping @MainActor @Sendable (UUID) async throws -> Void
    ) {
        self.allowedIDs = allowedIDs
        self.beginHook = beginHook
        self.commitHook = commitHook
        self.discardHook = discardHook
    }

    func closeHandle() {
        activeHandle?.close()
        activeHandle = nil
    }

    func beginOffer(_ offer: SyncOffer) async throws -> WifiOfferDecision {
        try SyncProtocol.require(allowedIDs.contains(offer.id), .state)
        try offer.validate(maxSize: SyncProtocol.maxWifiItemBytes)
        closeHandle()
        activeOffer = nil
        activeURL = nil
        activeOffset = 0

        let outcome = try await beginHook(offer)
        switch outcome {
        case .alreadyCompleted:
            return .alreadyCompleted
        case let .resume(offset, partialURL):
            try SyncProtocol.require(offset >= 0 && offset <= offer.size, .state)
            activeOffer = offer
            activeURL = partialURL
            activeOffset = offset
            return .resume(offset: offset)
        }
    }

    func appendChunk(id: UUID, offset: Int, data: Data) async throws -> Int {
        guard let offer = activeOffer, offer.id == id, let url = activeURL else {
            throw SyncProtocolError.state
        }
        try SyncProtocol.require(offset == activeOffset && data.count <= offer.size - activeOffset, .format)
        let handle: FileHandle
        if let opened = activeHandle?.raw {
            handle = opened
        } else {
            let opened = try FileHandle(forWritingTo: url)
            let fileSize = try opened.seekToEnd()
            try SyncProtocol.require(fileSize == UInt64(offset), .state)
            activeHandle = ManagedFileHandle(opened)
            handle = opened
        }
        try handle.write(contentsOf: data)
        activeOffset += data.count
        return activeOffset
    }

    func verifyAndComplete(_ offer: SyncOffer) async throws {
        guard let current = activeOffer, current == offer, let url = activeURL else {
            throw SyncProtocolError.state
        }
        if let managed = activeHandle {
            activeHandle = nil
            try managed.closeThrowing()
        }
        activeOffer = nil
        activeURL = nil
        activeOffset = 0

        let verified = try Self.verifySha256(at: url, expectedSize: offer.size, expectedSha256: offer.sha256)
        if !verified {
            try? await discardHook(offer.id)
            throw SyncProtocolError.authentication
        }

        try await commitHook(offer, url)
    }

    func discardPartial(id: UUID) async throws {
        if activeOffer?.id == id {
            closeHandle()
            activeOffer = nil
            activeURL = nil
            activeOffset = 0
        }
        try await discardHook(id)
    }

    private static func verifySha256(at url: URL, expectedSize: Int, expectedSha256: String) throws -> Bool {
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        var hasher = SHA256()
        var total = 0
        let readChunkBytes = 256 * 1024
        while true {
            let part = try reader.read(upToCount: readChunkBytes)
            guard let part, !part.isEmpty else { break }
            hasher.update(data: part)
            total += part.count
            if total > expectedSize {
                return false
            }
        }
        if total != expectedSize {
            return false
        }
        let digest = Data(hasher.finalize())
        let hashHex = WifiControlMessageCodec.lowerHex(digest)
        return hashHex == expectedSha256
    }
}

final class WifiProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var lastItemID: UUID?
    private var lastReportedBytes = 0
    private var lastReportTimeNs: UInt64 = 0
    private static let minByteStep = 131_072
    private static let minTimeStepNs: UInt64 = 100_000_000

    func shouldEmit(itemID: UUID, done: Int, total: Int) -> Bool {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        defer { lock.unlock() }
        if lastItemID != itemID || done <= 0 || done >= total {
            lastItemID = itemID
            lastReportedBytes = done
            lastReportTimeNs = nowNs
            return true
        }
        let byteDelta = done - lastReportedBytes
        guard byteDelta >= Self.minByteStep else { return false }
        guard nowNs >= lastReportTimeNs, (nowNs - lastReportTimeNs) >= Self.minTimeStepNs else { return false }
        lastReportedBytes = done
        lastReportTimeNs = nowNs
        return true
    }
}
