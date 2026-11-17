import Foundation
import XCTest
@testable import ClipboardPlus

final class SyncStorageTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testPendingSurvivesRestartPrunesDeletedHistoryAndExpires() throws {
        let root = try directory(), pair = UUID(), now = Date()
        var disk = SyncDiskStore(root: root); try disk.load(pairId: pair, now: now)
        for index in 0..<102 {
            let item = SyncPending(id: UUID(), historyID: index, at: Int64(now.timeIntervalSince1970 * 1000), offer: nil)
            try disk.enqueue(item, bytes: Data("text".utf8), now: now)
        }
        disk = SyncDiskStore(root: root); try disk.load(pairId: pair, now: now)
        XCTAssertEqual(disk.state.pending.count, 100)
        XCTAssertEqual(disk.state.pending.first?.historyID, 2)
        try disk.prune(now: now, historyIDs: [100, 101]); XCTAssertEqual(disk.state.pending.count, 2)
        try disk.prune(now: now.addingTimeInterval(SyncProtocol.pendingLifetime + 1))
        XCTAssertTrue(disk.state.pending.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["state.json"])
    }

    func testPartialResumesAcrossRestartAndVerifiesBytesLargerThanFrame() throws {
        let root = try directory(), pair = UUID(), now = Date()
        let data = Data(repeating: 37, count: SyncProtocol.maxFrameBytes + 17)
        let offer = SyncOffer(id: UUID(), at: 1234, from: "pc", kind: "file", size: data.count,
            sha256: SyncEchoGuard.hash(data), name64: Data("試験.txt".utf8).base64EncodedString(), type: "public.data")
        var disk = SyncDiskStore(root: root); try disk.load(pairId: pair, now: now)
        XCTAssertEqual(try disk.begin(offer, now: now), 0)
        var offset = 0
        while offset < data.count {
            let end = min(data.count, offset + SyncProtocol.chunkBytes)
            offset = try disk.append(id: offer.id, offset: offset, data: data.subdata(in: offset..<end))
            if offset == SyncProtocol.chunkBytes * 2 {
                disk = SyncDiskStore(root: root); try disk.load(pairId: pair, now: now)
                XCTAssertEqual(try disk.begin(offer, now: now), offset)
            }
        }
        XCTAssertEqual(try Data(contentsOf: disk.verified(offer)), data)
        try disk.markSeen(offer.id); try disk.discard(offer.id)
        disk = SyncDiskStore(root: root); try disk.load(pairId: pair, now: now)
        XCTAssertTrue(disk.state.seen.contains(offer.id))
        try disk.load(pairId: UUID(), now: now)
        XCTAssertTrue(disk.state.seen.isEmpty)
    }

    func testHashMismatchAndOffsetGapCannotComplete() throws {
        let disk = SyncDiskStore(root: try directory()), now = Date()
        try disk.load(pairId: UUID(), now: now)
        let offer = SyncOffer(id: UUID(), at: 0, from: "pc", kind: "file", size: 2,
            sha256: String(repeating: "0", count: 64), name64: "YS50eHQ=", type: "public.data")
        _ = try disk.begin(offer, now: now)
        XCTAssertThrowsError(try disk.append(id: offer.id, offset: 1, data: Data([1])))
        _ = try disk.append(id: offer.id, offset: 0, data: Data([1, 2]))
        XCTAssertThrowsError(try disk.verified(offer))
        XCTAssertTrue(disk.state.partials.isEmpty)
    }

    func testUniversalClipboardFingerprintsHaveNoTimeExpiryAndClearOnDifferentContent() throws {
        let suite = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for kind in ["text", "image", "file"] {
            let hash = SyncEchoGuard.hash(Data(kind.utf8))
            SyncEchoGuard(defaults: defaults).remember(kind: kind, hash: hash)
            let afterRelaunch = SyncEchoGuard(defaults: defaults)
            XCTAssertTrue(afterRelaunch.observe(kind: kind, hash: hash))
            XCTAssertTrue(afterRelaunch.observe(kind: kind, hash: hash))
            XCTAssertFalse(afterRelaunch.observe(kind: "text", hash: "different"))
            XCTAssertFalse(afterRelaunch.observe(kind: kind, hash: hash))
        }
    }

    func testDeviceIdentityIsBoundToAuthenticationAndVersionHasDistinctError() throws {
        let pair = try SyncPairing.create(name: "test"), device = UUID()
        let pad = try SyncPadHandshake(pairing: pair, padId: device)
        var hello = try pad.createHello(); hello[2] ^= 1
        let pc = try SyncPcHandshake(pairing: pair)
        let welcome = try pc.acceptHello(hello)
        XCTAssertThrowsError(try pad.acceptWelcome(welcome)) { XCTAssertEqual($0 as? SyncProtocolError, .authentication) }
        hello = try SyncPadHandshake(pairing: pair, padId: device).createHello(); hello[1] = 1
        XCTAssertThrowsError(try SyncPcHandshake(pairing: pair).acceptHello(hello)) { XCTAssertEqual($0 as? SyncProtocolError, .version) }
    }

    func testBeginEvictsOldestPartialAtLimit() throws {
        let root = try directory(), pair = UUID(), now = Date()
        let disk = SyncDiskStore(root: root); try disk.load(pairId: pair, now: now)
        let sha = SyncEchoGuard.hash(Data([1]))
        var created: [SyncOffer] = []
        for index in 0..<SyncProtocol.maxPending {
            let offer = SyncOffer(id: UUID(), at: Int64(index), from: "pc", kind: "file", size: 1,
                sha256: sha, name64: Data("f\(index).txt".utf8).base64EncodedString(), type: "public.data")
            created.append(offer)
            let createdAt = index <= 1 ? now : now.addingTimeInterval(Double(index))
            XCTAssertEqual(try disk.begin(offer, now: createdAt), 0)
        }
        let extra = SyncOffer(id: UUID(), at: 999, from: "pc", kind: "file", size: 1,
            sha256: sha, name64: Data("extra.txt".utf8).base64EncodedString(), type: "public.data")
        XCTAssertEqual(try disk.begin(extra, now: now.addingTimeInterval(500)), 0)
        XCTAssertEqual(disk.state.partials.count, SyncProtocol.maxPending)
        XCTAssertFalse(disk.state.partials.contains { $0.offer.id == created[0].id })
        XCTAssertFalse(FileManager.default.fileExists(atPath: disk.partial(created[0].id).path))
        XCTAssertTrue(disk.state.partials.contains { $0.offer.id == created[1].id })
        XCTAssertTrue(disk.state.partials.contains { $0.offer.id == extra.id })

        let extra2 = SyncOffer(id: UUID(), at: 1000, from: "pc", kind: "file", size: 1,
            sha256: sha, name64: Data("extra2.txt".utf8).base64EncodedString(), type: "public.data")
        XCTAssertEqual(try disk.begin(extra2, now: now.addingTimeInterval(501)), 0)
        XCTAssertFalse(disk.state.partials.contains { $0.offer.id == created[1].id })
        XCTAssertFalse(FileManager.default.fileExists(atPath: disk.partial(created[1].id).path))
    }

    func testPruneAndLoadRemoveMissingOrMismatchedBodyAndPartialFiles() throws {
        let root = try directory(), pair = UUID(), now = Date()
        let disk = SyncDiskStore(root: root); try disk.load(pairId: pair, now: now)
        func offer(bytes: Data, name: String) -> SyncOffer {
            SyncOffer(id: UUID(), at: Int64(now.timeIntervalSince1970 * 1000), from: "pad", kind: "file",
                size: bytes.count, sha256: SyncEchoGuard.hash(bytes),
                name64: Data(name.utf8).base64EncodedString(), type: "public.data")
        }
        let goodBytes = Data([1, 2, 3]), missingBytes = Data([4, 5, 6]), wrongBytes = Data([7, 8, 9])
        let goodOffer = offer(bytes: goodBytes, name: "good.bin")
        let missingOffer = offer(bytes: missingBytes, name: "missing.bin")
        let wrongOffer = offer(bytes: wrongBytes, name: "wrong.bin")
        try disk.enqueue(SyncPending(id: goodOffer.id, historyID: 1, at: goodOffer.at, offer: goodOffer), bytes: goodBytes, now: now)
        try disk.enqueue(SyncPending(id: missingOffer.id, historyID: 2, at: missingOffer.at, offer: missingOffer), bytes: missingBytes, now: now)
        try disk.enqueue(SyncPending(id: wrongOffer.id, historyID: 3, at: wrongOffer.at, offer: wrongOffer), bytes: wrongBytes, now: now)
        let textGood = SyncPending(id: UUID(), historyID: 4, at: goodOffer.at, offer: nil)
        let textMissing = SyncPending(id: UUID(), historyID: 5, at: goodOffer.at, offer: nil)
        try disk.enqueue(textGood, bytes: Data("ok".utf8), now: now)
        try disk.enqueue(textMissing, bytes: Data("gone".utf8), now: now)

        let pGood = offer(bytes: Data([1, 2]), name: "pgood.bin")
        let pMissing = offer(bytes: Data([3, 4]), name: "pmiss.bin")
        let pOver = offer(bytes: Data([5, 6]), name: "pover.bin")
        _ = try disk.begin(pGood, now: now)
        _ = try disk.begin(pMissing, now: now)
        _ = try disk.begin(pOver, now: now)

        try FileManager.default.removeItem(at: disk.body(missingOffer.id))
        try Data([7]).write(to: disk.body(wrongOffer.id))
        try FileManager.default.removeItem(at: disk.body(textMissing.id))
        try FileManager.default.removeItem(at: disk.partial(pMissing.id))
        try Data([1, 2, 3]).write(to: disk.partial(pOver.id))

        try disk.prune(now: now)
        XCTAssertEqual(disk.state.pending.map(\.id), [goodOffer.id, textGood.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: disk.body(wrongOffer.id).path))
        XCTAssertEqual(disk.state.partials.map(\.offer.id), [pGood.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: disk.partial(pOver.id).path))

        try FileManager.default.removeItem(at: disk.body(goodOffer.id))
        try FileManager.default.removeItem(at: disk.partial(pGood.id))
        let reloaded = SyncDiskStore(root: root); try reloaded.load(pairId: pair, now: now)
        XCTAssertEqual(reloaded.state.pending.map(\.id), [textGood.id])
        XCTAssertTrue(reloaded.state.partials.isEmpty)
    }

    func testSyncEchoGuardCapsAtFiveHundredRecentFingerprints() throws {
        let suite = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let echo = SyncEchoGuard(defaults: defaults)
        let hashes = (0...500).map { SyncEchoGuard.hash(Data("item-\($0)".utf8)) }
        for hash in hashes { echo.remember(kind: "text", hash: hash) }
        XCTAssertTrue(echo.observe(kind: "text", hash: hashes[1]))
        XCTAssertTrue(echo.observe(kind: "text", hash: hashes[500]))
        XCTAssertFalse(echo.observe(kind: "text", hash: hashes[0]))

        for index in 0..<500 { echo.remember(kind: "text", hash: hashes[index]) }
        echo.remember(kind: "text", hash: hashes[0])
        echo.remember(kind: "text", hash: hashes[500])
        XCTAssertTrue(echo.observe(kind: "text", hash: hashes[0]))
        XCTAssertTrue(echo.observe(kind: "text", hash: hashes[500]))
        XCTAssertFalse(echo.observe(kind: "text", hash: hashes[1]))
    }

    func testBeginFailureBeforeWritingPartPreservesExistingPartials() throws {
        let root = try directory(), pair = UUID(), now = Date()
        let disk = SyncDiskStore(root: root); try disk.load(pairId: pair, now: now)
        let sha = SyncEchoGuard.hash(Data([1]))
        var created: [SyncOffer] = []
        for index in 0..<SyncProtocol.maxPending {
            let offer = SyncOffer(id: UUID(), at: Int64(index), from: "pc", kind: "file", size: 1,
                sha256: sha, name64: Data("f\(index).txt".utf8).base64EncodedString(), type: "public.data")
            created.append(offer)
            XCTAssertEqual(try disk.begin(offer, now: now.addingTimeInterval(Double(index))), 0)
        }
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)

        let extra = SyncOffer(id: UUID(), at: 999, from: "pc", kind: "file", size: 1,
            sha256: sha, name64: Data("extra.txt".utf8).base64EncodedString(), type: "public.data")
        XCTAssertThrowsError(try disk.begin(extra, now: now.addingTimeInterval(500)))
        XCTAssertEqual(disk.state.partials.count, SyncProtocol.maxPending)
        XCTAssertTrue(disk.state.partials.contains { $0.offer.id == created[0].id })
        XCTAssertFalse(disk.state.partials.contains { $0.offer.id == extra.id })

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        XCTAssertEqual(try disk.begin(extra, now: now.addingTimeInterval(500)), 0)
        XCTAssertEqual(disk.state.partials.count, SyncProtocol.maxPending)
        XCTAssertFalse(disk.state.partials.contains { $0.offer.id == created[0].id })
        XCTAssertTrue(disk.state.partials.contains { $0.offer.id == extra.id })
    }
}
