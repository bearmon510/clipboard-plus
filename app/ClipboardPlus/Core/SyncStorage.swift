import Foundation
import CryptoKit

/// Content fingerprints only, persisted across app termination. No timer expires them.
final class SyncEchoGuard {
    private let lock = NSLock()
    private let defaults: UserDefaults
    private let key = "pcSync.remoteFingerprints.v2"
    init(defaults: UserDefaults) { self.defaults = defaults }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    func remember(kind: String, hash: String) {
        lock.lock(); defer { lock.unlock() }
        var values = defaults.stringArray(forKey: key) ?? []
        let value = kind + ":" + hash
        values.removeAll { $0 == value }
        values.append(value)
        values = Array(values.suffix(500))
        defaults.set(values, forKey: key)
    }
    func observe(kind: String, hash: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let values = defaults.stringArray(forKey: key) ?? []
        if values.contains(kind + ":" + hash) { return true }
        defaults.removeObject(forKey: key)
        return false
    }
    func clear() { lock.lock(); defer { lock.unlock() }; defaults.removeObject(forKey: key) }
}

struct SyncPending: Codable {
    let id: UUID
    let historyID: Int
    let at: Int64
    let offer: SyncOffer?
    var attempts = 0
}

/// One small chunk is read/written at a time; manifests never embed attachment bytes.
/// The controller owns this instance on its actor. History conversion runs on HistoryStore's queue.
final class SyncDiskStore {
    struct Partial: Codable { let offer: SyncOffer; let created: Date }
    struct State: Codable {
        var pairId: UUID?
        var pending: [SyncPending] = []
        var seen: [UUID] = []
        var partials: [Partial] = []
    }
    let root: URL
    private(set) var state = State()
    private var durable: Data?
    init(root: URL) { self.root = root }
    func load(pairId: UUID, now: Date) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var resource = root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try resource.setResourceValues(values)
        let manifest = root.appendingPathComponent("state.json")
        if FileManager.default.fileExists(atPath: manifest.path) {
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: manifest))
            durable = try JSONEncoder().encode(state)
        }
        if state.pairId != pairId { state = State(); state.pairId = pairId }
        try prune(now: now)
    }
    func body(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".body") }
    func partial(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".part") }
    func save() throws {
        do {
            let bytes = try JSONEncoder().encode(state)
            try bytes.write(to: root.appendingPathComponent("state.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            durable = bytes
        } catch {
            state = durable.flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
            throw error
        }
    }
    func clear() throws { state = State(); try save(); try cleanup() }
    func enqueue(_ value: SyncPending, bytes: Data, now: Date) throws {
        try bytes.write(to: body(value.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        state.pending.append(value); try prune(now: now)
    }
    private func regularFileSize(at url: URL) -> Int? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize else { return nil }
        return size
    }
    private func validBody(_ item: SyncPending) -> Bool {
        guard let size = regularFileSize(at: body(item.id)) else { return false }
        if let offer = item.offer { return size == offer.size }
        return size <= SyncProtocol.maxPlaintextBytes
    }
    private func validPartial(_ item: Partial) -> Bool {
        guard let size = regularFileSize(at: partial(item.offer.id)) else { return false }
        return size <= item.offer.size
    }
    func prune(now: Date, historyIDs: Set<Int>? = nil) throws {
        let cutoff = Int64(now.addingTimeInterval(-SyncProtocol.pendingLifetime).timeIntervalSince1970 * 1000)
        state.pending = Array(state.pending.filter {
            $0.at >= cutoff && (historyIDs == nil || historyIDs!.contains($0.historyID)) && validBody($0)
        }.sorted { $0.at < $1.at }.suffix(SyncProtocol.maxPending))
        state.partials.removeAll { now.timeIntervalSince($0.created) > SyncProtocol.pendingLifetime || !validPartial($0) }
        try save(); try cleanup()
    }
    func ack(_ ids: Set<UUID>) throws { state.pending.removeAll { ids.contains($0.id) }; try save(); try cleanup() }
    func markSeen(_ id: UUID) throws {
        state.seen.removeAll { $0 == id }; state.seen.append(id)
        state.seen = Array(state.seen.suffix(500)); try save()
    }
    func begin(_ offer: SyncOffer, now: Date, maxSize: Int = SyncProtocol.maxItemBytes) throws -> Int {
        try offer.validate(maxSize: maxSize)
        if let old = state.partials.first(where: { $0.offer.id == offer.id }) {
            try SyncProtocol.require(old.offer == offer)
        } else {
            let file = partial(offer.id)
            try Data().write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var evictedIDs: [UUID] = []
            while state.partials.count >= SyncProtocol.maxPending {
                guard let oldestIndex = state.partials.indices.min(by: { state.partials[$0].created < state.partials[$1].created }) else { break }
                evictedIDs.append(state.partials.remove(at: oldestIndex).offer.id)
            }
            state.partials.append(Partial(offer: offer, created: now))
            do { try save() }
            catch {
                try? FileManager.default.removeItem(at: file)
                throw error
            }
            for oldID in evictedIDs { try? FileManager.default.removeItem(at: partial(oldID)) }
        }
        let size = try partial(offer.id).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        try SyncProtocol.require(size <= offer.size, .limit); return size
    }
    func append(id: UUID, offset: Int, data: Data) throws -> Int {
        guard let offer = state.partials.first(where: { $0.offer.id == id })?.offer else { throw SyncProtocolError.state }
        let file = try FileHandle(forWritingTo: partial(id)); defer { try? file.close() }
        let size = try file.seekToEnd()
        try SyncProtocol.require(size == UInt64(offset) && data.count <= offer.size - offset)
        try file.write(contentsOf: data); try file.synchronize(); return offset + data.count
    }
    func verified(_ offer: SyncOffer) throws -> URL {
        let url = partial(offer.id), file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var digest = SHA256(), count = 0
        while let data = try file.read(upToCount: SyncProtocol.chunkBytes), !data.isEmpty { digest.update(data: data); count += data.count }
        let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard count == offer.size && hash == offer.sha256 else {
            try discard(offer.id); throw SyncProtocolError.authentication
        }
        return url
    }
    func discard(_ id: UUID) throws {
        state.partials.removeAll { $0.offer.id == id }; try save()
        try? FileManager.default.removeItem(at: partial(id))
    }
    private func cleanup() throws {
        let keep = Set(state.pending.map { body($0.id).lastPathComponent } + state.partials.map { partial($0.offer.id).lastPathComponent } + ["state.json"])
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where !keep.contains(url.lastPathComponent) { try FileManager.default.removeItem(at: url) }
    }
}
