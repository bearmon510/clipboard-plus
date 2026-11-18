import Foundation
import XCTest
@testable import ClipboardPlus

final class TemplateSyncTests: XCTestCase {
    private func error(_ expected: SyncProtocolError, file: StaticString = #filePath, line: UInt = #line, _ action: () throws -> Void) {
        XCTAssertThrowsError(try action(), file: file, line: line) {
            XCTAssertEqual($0 as? SyncProtocolError, expected, file: file, line: line)
        }
    }

    private func plain(_ header: String, body: Data = Data()) -> Data {
        let h = Data(header.utf8)
        return Data([UInt8(h.count >> 8), UInt8(truncatingIfNeeded: h.count)]) + h + body
    }

    func testSplitPagesAndAssemblerRoundtripAcross256KiBPageBoundaries() throws {
        let op = UUID()
        let items = (0..<10).map { i -> TemplateSyncItem in
            let prefix = i % 2 == 0 ? "本文" : "https://example.com/"
            let scalar = Unicode.Scalar(97 + i)!
            return TemplateSyncItem(
                id: UUID(),
                kind: i % 2 == 0 ? .text : .url,
                text: prefix + String(repeating: String(scalar), count: 60_000),
                title: "題名\(i)",
                tag: i < 5 ? "仕事" : nil,
                order: i % 5,
                updatedAt: 1_794_873_600_000 + Int64(i),
                baseHash: String(repeating: "a", count: 64)
            )
        }
        let tombs = (0..<10).map { i in
            TemplateSyncTombstone(id: UUID(), deletedAt: 1_794_873_500_000 + Int64(i), baseHash: String(repeating: "b", count: 64))
        }

        let snapshot = TemplateSyncSnapshot(sentAt: 1_794_873_600_500, templates: items, tombstones: tombs)
        let pages = try TemplateSyncMessageCodec.splitPages(op: op, snapshot: snapshot, isState: false)
        XCTAssertGreaterThanOrEqual(pages.count, 3)

        let assembler = TemplateSyncPageAssembler(expectedOp: op, expectedIsState: false)
        var reassembled: TemplateSyncSnapshot?
        for (index, pageMsg) in pages.enumerated() {
            let encoded = try TemplateSyncMessageCodec.encode(pageMsg)
            let decoded = try TemplateSyncMessageCodec.decode(encoded)
            guard case let .push(_, part, total, _) = decoded else {
                return XCTFail("Expected tpl_push")
            }
            XCTAssertEqual(part, index)
            XCTAssertEqual(total, pages.count)
            reassembled = try assembler.append(decoded)
            if index < pages.count - 1 { XCTAssertNil(reassembled) }
        }
        let result = try XCTUnwrap(reassembled)
        XCTAssertEqual(result.sentAt, snapshot.sentAt)
        XCTAssertEqual(result.templates, items)
        XCTAssertEqual(result.tombstones, tombs)
        try assembler.finish()
        error(.state) { _ = try assembler.append(pages[0]) }
    }

    func testEmptySnapshotSerializesToSinglePageAndAssemblerRejectsBadSequence() throws {
        let op = UUID()
        let empty = TemplateSyncSnapshot(sentAt: 12345, templates: [], tombstones: [])
        let pages = try TemplateSyncMessageCodec.splitPages(op: op, snapshot: empty, isState: true)
        XCTAssertEqual(pages.count, 1)
        guard case let .state(_, part, total, _) = pages[0] else {
            return XCTFail("Expected tpl_state")
        }
        XCTAssertEqual(part, 0)
        XCTAssertEqual(total, 1)

        let decoded = try TemplateSyncMessageCodec.decode(TemplateSyncMessageCodec.encode(pages[0]))
        guard case let .state(_, _, _, roundtripPage) = decoded else {
            return XCTFail("Expected tpl_state")
        }
        XCTAssertEqual(roundtripPage.sentAt, 12345)
        XCTAssertTrue(roundtripPage.templates.isEmpty)
        XCTAssertTrue(roundtripPage.tombstones.isEmpty)

        let badStart = TemplateSyncPageAssembler()
        let p1of2 = TemplateSyncMessage.push(op: op, part: 1, total: 2, page: TemplateSyncPage(templates: [], tombstones: []))
        error(.state) { _ = try badStart.append(p1of2) }
        error(.state) { _ = try badStart.append(.push(op: op, part: 0, total: 1, page: TemplateSyncPage(version: 1, sentAt: 0, templates: [], tombstones: []))) }

        let wrongOp = TemplateSyncPageAssembler(expectedOp: UUID())
        error(.state) { _ = try wrongOp.append(.push(op: op, part: 0, total: 1, page: TemplateSyncPage(version: 1, sentAt: 0, templates: [], tombstones: []))) }

        let incomplete = TemplateSyncPageAssembler()
        XCTAssertNil(try incomplete.append(.push(op: op, part: 0, total: 2, page: TemplateSyncPage(version: 1, sentAt: 0, templates: [], tombstones: []))))
        XCTAssertTrue(incomplete.hasPartialSnapshot)
        error(.state) { try incomplete.finish() }

        let dupAcrossPages = TemplateSyncPageAssembler()
        let dupId = UUID()
        let item = TemplateSyncItem(id: dupId, kind: .text, text: "x", order: 0, updatedAt: 1)
        XCTAssertNil(try dupAcrossPages.append(.push(op: op, part: 0, total: 2, page: TemplateSyncPage(version: 1, sentAt: 0, templates: [item], tombstones: []))))
        let item2 = TemplateSyncItem(id: dupId, kind: .text, text: "y", order: 1, updatedAt: 2)
        error(.format) { _ = try dupAcrossPages.append(.push(op: op, part: 1, total: 2, page: TemplateSyncPage(templates: [item2], tombstones: []))) }

        let pullRejected = TemplateSyncPageAssembler()
        error(.state) { _ = try pullRejected.append(.pull(op: op)) }
    }

    func testStrictJsonRejectsMalformedHeadersAndBodiesAndAllowsGraphemeAndZwjLimits() throws {
        let op = "22222222-3333-4444-8555-666666666666"
        let id = "44444444-5555-4666-8777-888888888881"

        error(.format) { _ = try TemplateSyncMessageCodec.decode(plain("{\"t\":\"tpl_pull\",\"op\":\"\(op)\",}")) }
        error(.format) { _ = try TemplateSyncMessageCodec.decode(plain("{\"t\":\"tpl_pull\",\"op\":\"\(op)\",\"\\u0074\":\"tpl_pull\"}")) }
        error(.format) { _ = try TemplateSyncMessageCodec.decode(plain("{\"t\":\"tpl_ack\",\"op\":\"\(op)\",\"extra\":1}")) }
        error(.format) { _ = try TemplateSyncMessageCodec.decode(plain("{\"t\":\"tpl_push\",\"op\":\"\(op)\",\"part\":0,\"total\":1.0}", body: Data("{}".utf8))) }

        let validHeader = "{\"t\":\"tpl_push\",\"op\":\"\(op)\",\"part\":0,\"total\":1}"
        for badBody in [
            "{\"v\":1,\"sentAt\":1,\"templates\":[],\"tombstones\":[],}",
            "{\"v\":1,\"sentAt\":1,\"templates\":[],\"tombstones\":[]} trailing",
            "{\"v\":1,\"sentAt\":1.0,\"templates\":[],\"tombstones\":[]}",
            "{\"v\":1,\"sentAt\":1e3,\"templates\":[],\"tombstones\":[]}",
            "{\"v\":true,\"sentAt\":1,\"templates\":[],\"tombstones\":[]}",
            "{\"v\":1,\"sentAt\":1,\"templates\":[],\"templates\":[],\"tombstones\":[]}",
            "{\"v\":1,\"sentAt\":1,\"templates\":[{\"id\":\"\(id)\",\"kind\":\"text\",\"text\":\"a\",\"title\":null,\"order\":0,\"updatedAt\":1}],\"tombstones\":[]}",
            "{\"v\":1,\"sentAt\":1,\"templates\":[{\"id\":\"\(id)\",\"kind\":\"text\",\"text\":\"a\",\"title\":\"x\\u2028y\",\"order\":0,\"updatedAt\":1}],\"tombstones\":[]}",
            "{\"v\":1,\"sentAt\":1,\"templates\":[{\"id\":\"\(id)\",\"kind\":\"text\",\"text\":\"\\uD800\",\"order\":0,\"updatedAt\":1}],\"tombstones\":[]}"
        ] {
            error(.format) { _ = try TemplateSyncMessageCodec.decode(plain(validHeader, body: Data(badBody.utf8))) }
        }

        error(.format) { _ = try TemplateSyncMessageCodec.decode(plain(validHeader, body: Data([0xC0, 0xAF]))) }

        let title400 = String(repeating: "👨‍👩‍👧‍👦", count: 16)
        XCTAssertEqual(title400.count, 16)
        XCTAssertEqual(title400.utf8.count, 400)
        let title100 = String(repeating: "あ", count: 100)
        let tag30 = String(repeating: "あ", count: 30)
        let tag120 = String(repeating: "😀", count: 30)
        let opUUID = try XCTUnwrap(UUID(uuidString: op))
        let itemUUID = try XCTUnwrap(UUID(uuidString: id))
        for (title, tag) in [(title400, tag120), (title100, tag30)] {
            let msg = TemplateSyncMessage.push(op: opUUID, part: 0, total: 1, page: TemplateSyncPage(
                version: 1,
                sentAt: 0,
                templates: [TemplateSyncItem(id: itemUUID, kind: .text, text: "ok", title: title, tag: tag, order: 0, updatedAt: 1)],
                tombstones: []
            ))
            let roundtrip = try TemplateSyncMessageCodec.decode(TemplateSyncMessageCodec.encode(msg))
            guard case let .push(_, _, _, roundtripPage) = roundtrip else {
                return XCTFail("Expected tpl_push")
            }
            XCTAssertEqual(roundtripPage.templates[0].title, title)
            XCTAssertEqual(roundtripPage.templates[0].tag, tag)
        }

        let heavyControlItem = TemplateSyncItem(
            id: itemUUID,
            kind: .text,
            text: String(repeating: "\u{0001}", count: SyncProtocol.maxTemplateTextBytes),
            order: 0,
            updatedAt: 1
        )
        error(.limit) {
            _ = try TemplateSyncMessageCodec.splitPages(
                op: opUUID,
                snapshot: TemplateSyncSnapshot(sentAt: 0, templates: [heavyControlItem], tombstones: []),
                isState: false
            )
        }
    }

    func testMergeHelpersEnforceNextUpdatedAtClockSkewConflictTitleAndLimits() throws {
        let now: Int64 = 1_794_873_600_000

        XCTAssertEqual(TemplateSyncMerge.nextUpdatedAt(nowMillis: now, existingUpdatedAt: nil), now)
        XCTAssertEqual(TemplateSyncMerge.nextUpdatedAt(nowMillis: now, existingUpdatedAt: now - 10_000), now)
        XCTAssertEqual(TemplateSyncMerge.nextUpdatedAt(nowMillis: now - 3_600_000, existingUpdatedAt: now), now + 1)
        XCTAssertEqual(TemplateSyncMerge.nextUpdatedAt(nowMillis: now, existingUpdatedAt: now + SyncProtocol.templateFutureTimestampCapMillis + 1), now)
        XCTAssertEqual(
            TemplateSyncMerge.nextUpdatedAt(nowMillis: now, existingUpdatedAt: now + SyncProtocol.templateFutureTimestampCapMillis),
            now + SyncProtocol.templateFutureTimestampCapMillis + 1
        )

        XCTAssertNil(try TemplateSyncMerge.clockSkewSeconds(remoteSentAtMillis: now + 299_999, nowMillis: now))
        XCTAssertEqual(try TemplateSyncMerge.clockSkewSeconds(remoteSentAtMillis: now + 300_000, nowMillis: now), 300)
        XCTAssertEqual(try TemplateSyncMerge.clockSkewSeconds(remoteSentAtMillis: now - 3_600_000, nowMillis: now), 3600)

        XCTAssertEqual(TemplateSyncMerge.makeConflictTitle(nil), "別の端末の編集")
        XCTAssertEqual(TemplateSyncMerge.makeConflictTitle("   \n "), "別の端末の編集")
        let longTitle = String(repeating: "あ", count: 100)
        let conflictLong = TemplateSyncMerge.makeConflictTitle(longTitle)
        XCTAssertTrue(conflictLong.hasSuffix("（別の端末の編集）"))
        XCTAssertLessThanOrEqual(conflictLong.count, 100)
        XCTAssertLessThanOrEqual(conflictLong.utf8.count, 400)

        let emojiTitle = String(repeating: "👨‍👩‍👧‍👦", count: 20)
        let conflictEmoji = TemplateSyncMerge.makeConflictTitle(emojiTitle)
        XCTAssertTrue(conflictEmoji.hasSuffix("（別の端末の編集）"))
        XCTAssertLessThanOrEqual(conflictEmoji.count, 100)
        XCTAssertLessThanOrEqual(conflictEmoji.utf8.count, 400)

        let pcTombs = (0..<600).map { i in TemplateSyncTombstone(id: UUID(), deletedAt: now - 10_000 + Int64(i)) }
        let remoteTombs = (600..<1200).map { i in TemplateSyncTombstone(id: UUID(), deletedAt: now - 10_000 + Int64(i)) }
        let capped = try TemplateSyncMerge.merge(
            pc: TemplateSyncState(templates: [], tombstones: pcTombs),
            remote: TemplateSyncState(templates: [], tombstones: remoteTombs),
            nowMillis: now
        )
        XCTAssertEqual(capped.tombstones.count, 1000)
        XCTAssertEqual(capped.tombstones.first?.deletedAt, now - 10_000 + 200)
        XCTAssertEqual(capped.tombstones.last?.deletedAt, now - 10_000 + 1199)

        let pc200 = (0..<200).map { i in TemplateSyncItem(id: UUID(), kind: .text, text: "pc-\(i)", order: i, updatedAt: now) }
        let remote200 = (0..<200).map { i in TemplateSyncItem(id: UUID(), kind: .text, text: "rem-\(i)", order: i, updatedAt: now) }
        error(.limit) {
            _ = try TemplateSyncMerge.merge(
                pc: TemplateSyncState(templates: pc200, tombstones: []),
                remote: TemplateSyncState(templates: remote200, tombstones: []),
                nowMillis: now
            )
        }

        let sharedId = UUID()
        let otherId = UUID()
        let hOrig = TemplateSyncMerge.contentHash(kind: .text, text: "orig", title: nil, tag: nil)
        let conflictWithExistingText = try TemplateSyncMerge.merge(
            pc: TemplateSyncState(templates: [
                TemplateSyncItem(id: sharedId, kind: .text, text: "winner", order: 0, updatedAt: now),
                TemplateSyncItem(id: otherId, kind: .text, text: "existing", order: 1, updatedAt: now)
            ], tombstones: []),
            remote: TemplateSyncState(templates: [
                TemplateSyncItem(id: sharedId, kind: .text, text: "existing", order: 0, updatedAt: now - 1000, baseHash: hOrig)
            ], tombstones: []),
            nowMillis: now
        )
        XCTAssertEqual(conflictWithExistingText.conflictCopyCount, 0)
        XCTAssertEqual(conflictWithExistingText.templates.count, 2)
    }
}
