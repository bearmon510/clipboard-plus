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

        // Merged 150 + 150 = 300 x 64KiB distinct items (needs 100 pages > 80) throws limit
        let pc150 = (0..<150).map { i in
            TemplateSyncItem(id: UUID(), kind: .text, text: String(format: "pc-%03d-", Int32(i)) + String(repeating: "a", count: SyncProtocol.maxTemplateTextBytes - 7), order: i, updatedAt: now)
        }
        let remote150 = (0..<150).map { i in
            TemplateSyncItem(id: UUID(), kind: .text, text: String(format: "rm-%03d-", Int32(i)) + String(repeating: "b", count: SyncProtocol.maxTemplateTextBytes - 7), order: i, updatedAt: now)
        }
        error(.limit) {
            _ = try TemplateSyncMerge.merge(
                pc: TemplateSyncState(templates: pc150, tombstones: []),
                remote: TemplateSyncState(templates: remote150, tombstones: []),
                nowMillis: now
            )
        }

        // Order upper bound on wire (encode/validate) and bounded writer rejection on oversized pages
        let op = UUID()
        let maxOrderItem = TemplateSyncItem(id: UUID(), kind: .text, text: "max-order", order: TemplateSyncMessageCodec.maxOrder, updatedAt: 1)
        let encodedMaxOrder = try TemplateSyncMessageCodec.encode(.push(op: op, part: 0, total: 1, page: TemplateSyncPage(version: 1, sentAt: 0, templates: [maxOrderItem], tombstones: [])))
        _ = try TemplateSyncMessageCodec.decode(encodedMaxOrder)
        let overOrderItem = TemplateSyncItem(id: UUID(), kind: .text, text: "over-order", order: TemplateSyncMessageCodec.maxOrder + 1, updatedAt: 1)
        error(.format) {
            _ = try TemplateSyncMessageCodec.encode(.push(op: op, part: 0, total: 1, page: TemplateSyncPage(version: 1, sentAt: 0, templates: [overOrderItem], tombstones: [])))
        }

        let oversizedPage = TemplateSyncPage(version: 1, sentAt: 0, templates: [
            TemplateSyncItem(id: UUID(), kind: .text, text: String(repeating: "\u{0001}", count: SyncProtocol.maxTemplateTextBytes), order: 0, updatedAt: 1)
        ], tombstones: [])
        error(.limit) {
            _ = try TemplateSyncMessageCodec.encode(.push(op: op, part: 0, total: 1, page: oversizedPage))
        }
        let manyLargeItems = (0..<10).map { i in
            let ch = String(Unicode.Scalar(97 + i)!)
            return TemplateSyncItem(id: UUID(), kind: .text, text: String(repeating: ch, count: SyncProtocol.maxTemplateTextBytes), order: i, updatedAt: 1)
        }
        error(.limit) {
            _ = try TemplateSyncMessageCodec.encode(.push(op: op, part: 0, total: 1, page: TemplateSyncPage(version: 1, sentAt: 0, templates: manyLargeItems, tombstones: [])))
        }
        let assembler = TemplateSyncPageAssembler()
        error(.limit) { _ = try assembler.append(.push(op: op, part: 0, total: 1, page: oversizedPage)) }

        // Direct UTF-8 byte comparison check for NFC vs NFD and PrepareSyncState dirty input filtering
        let nfcId = UUID()
        let nfdId = UUID()
        let nfcVsNfd = try TemplateSyncMerge.merge(
            pc: TemplateSyncState(templates: [TemplateSyncItem(id: nfcId, kind: .text, text: "\u{00E9}", tag: "\u{00E9}", order: 0, updatedAt: now)], tombstones: []),
            remote: TemplateSyncState(templates: [TemplateSyncItem(id: nfdId, kind: .text, text: "e\u{0301}", tag: "e\u{0301}", order: 0, updatedAt: now)], tombstones: []),
            nowMillis: now
        )
        XCTAssertEqual(nfcVsNfd.subsumedDuplicateCount, 0)
        XCTAssertEqual(nfcVsNfd.templates.count, 2)
        XCTAssertEqual(Array(nfcVsNfd.templates[0].text.utf8), Array("e\u{0301}".utf8))
        XCTAssertEqual(Array(nfcVsNfd.templates[1].text.utf8), Array("\u{00E9}".utf8))

        let keepId = UUID()
        let ctrlId = UUID()
        let preparedDirty = try TemplateSyncMerge.prepareSyncState(
            templates: [
                TemplateSyncItem(id: keepId, kind: .text, text: "valid", title: "ok", tag: "tag", order: 0, updatedAt: now),
                TemplateSyncItem(id: keepId, kind: .text, text: "duplicate-id", order: 1, updatedAt: now),
                TemplateSyncItem(id: ctrlId, kind: .text, text: "bad-title", title: "a\u{0007}b", order: 2, updatedAt: now)
            ],
            tombstones: [
                TemplateSyncTombstone(id: keepId, deletedAt: now - 1000)
            ],
            nowMillis: now
        )
        XCTAssertEqual(preparedDirty.state.templates.count, 1)
        XCTAssertEqual(preparedDirty.state.templates[0].id, keepId)
        XCTAssertTrue(preparedDirty.state.tombstones.isEmpty)
        XCTAssertEqual(preparedDirty.excludedTemplateCount, 2)
    }

    func testThreeDeviceMergeAllDeleteDoesNotResurrectStaleUneditedVersionAndKeepsConcurrentEdit() throws {
        let now: Int64 = 1_794_873_600_000
        let sharedId = UUID()
        let hV1 = TemplateSyncMerge.contentHash(kind: .text, text: "v1", title: "題", tag: "仕事")
        let hV2 = TemplateSyncMerge.contentHash(kind: .text, text: "v2", title: "題", tag: "仕事")

        let pcState = TemplateSyncState(
            templates: [TemplateSyncItem(id: sharedId, kind: .text, text: "v2", title: "題", tag: "仕事", order: 0, updatedAt: now - 10_000)],
            tombstones: []
        )
        let iPadDelete = TemplateSyncRemoteState(
            state: TemplateSyncState(templates: [], tombstones: [TemplateSyncTombstone(id: sharedId, deletedAt: now - 5_000, baseHash: hV2)]),
            sentAtMillis: now
        )
        let iPhoneStale = TemplateSyncRemoteState(
            state: TemplateSyncState(
                templates: [TemplateSyncItem(id: sharedId, kind: .text, text: "v1", title: "題", tag: "仕事", order: 0, updatedAt: now - 20_000, baseHash: hV1)],
                tombstones: []
            ),
            sentAtMillis: now
        )

        for order in [[iPadDelete, iPhoneStale], [iPhoneStale, iPadDelete]] {
            let merged = try TemplateSyncMerge.mergeAll(pc: pcState, remotes: order, nowMillis: now)
            XCTAssertTrue(merged.templates.isEmpty)
            XCTAssertEqual(merged.tombstones.map(\.id), [sharedId])
            XCTAssertEqual(merged.pcChanges.deleted, 1)
        }

        let iPhoneEdited = TemplateSyncRemoteState(
            state: TemplateSyncState(
                templates: [TemplateSyncItem(id: sharedId, kind: .text, text: "v3-edited", title: "題", tag: "仕事", order: 0, updatedAt: now - 3_000, baseHash: hV1)],
                tombstones: []
            ),
            sentAtMillis: now
        )
        for order in [[iPadDelete, iPhoneEdited], [iPhoneEdited, iPadDelete]] {
            let merged = try TemplateSyncMerge.mergeAll(pc: pcState, remotes: order, nowMillis: now)
            XCTAssertEqual(merged.templates.count, 1)
            XCTAssertEqual(merged.templates.first?.id, sharedId)
            XCTAssertEqual(merged.templates.first?.text, "v3-edited")
            XCTAssertTrue(merged.tombstones.isEmpty)
        }
    }

    func testLineEndingsNormalizeCrlfAndCrToLfPreservingUnicodeForms() throws {
        let now: Int64 = 1_794_873_600_000
        XCTAssertEqual(TemplateSyncMerge.normalizeLineEndings("a\r\nb\rc\r\n"), "a\nb\nc\n")
        XCTAssertEqual(TemplateSyncMerge.normalizeLineEndings("plain"), "plain")
        // Preserve distinct NFC / NFD UTF-8 byte sequences while normalizing CRLF -> LF.
        let nfdCrlf = "cafe\u{0301}\r\nline2"
        let nfdLf = TemplateSyncMerge.normalizeLineEndings(nfdCrlf)
        XCTAssertEqual(Array(nfdLf.utf8), Array("cafe\u{0301}\nline2".utf8))
        XCTAssertEqual(
            TemplateSyncMerge.contentHash(kind: .text, text: "line1\nline2\nline3", title: "題", tag: "仕事"),
            TemplateSyncMerge.contentHash(kind: .text, text: "line1\r\nline2\rline3", title: "題", tag: "仕事")
        )

        let pcId = UUID()
        let iosId = UUID()
        let merged = try TemplateSyncMerge.merge(
            pc: TemplateSyncState(
                templates: [TemplateSyncItem(id: pcId, kind: .text, text: "line1\r\nline2", title: "PC題", tag: nil, order: 0, updatedAt: now - 1_000)],
                tombstones: []
            ),
            remote: TemplateSyncState(
                templates: [TemplateSyncItem(id: iosId, kind: .text, text: "line1\nline2", title: nil, tag: "仕事", order: 0, updatedAt: now)],
                tombstones: []
            ),
            nowMillis: now
        )
        XCTAssertEqual(merged.templates.count, 1)
        XCTAssertEqual(merged.templates.first?.id, iosId)
        XCTAssertEqual(merged.templates.first?.text, "line1\nline2")
        XCTAssertEqual(merged.templates.first?.title, "PC題")
        XCTAssertEqual(merged.templates.first?.tag, "仕事")
        XCTAssertEqual(merged.subsumedDuplicateCount, 1)
    }

    func testThreeDeviceMergePreservesIndependentRemoteWriteBackWithConcurrentEdit() throws {
        let now: Int64 = 1_794_873_600_000
        let sharedId = UUID()
        let hA = TemplateSyncMerge.contentHash(kind: .text, text: "A", title: "題", tag: "仕事")

        let pcState = TemplateSyncState(
            templates: [TemplateSyncItem(id: sharedId, kind: .text, text: "C", title: "題", tag: "仕事", order: 0, updatedAt: now - 2_000)],
            tombstones: []
        )
        let iPadWriteBack = TemplateSyncRemoteState(
            state: TemplateSyncState(
                templates: [TemplateSyncItem(id: sharedId, kind: .text, text: "A", title: "題", tag: "仕事", order: 0, updatedAt: now - 1_000, baseHash: nil)],
                tombstones: []
            ),
            sentAtMillis: now
        )
        let iPhoneEdit = TemplateSyncRemoteState(
            state: TemplateSyncState(
                templates: [TemplateSyncItem(id: sharedId, kind: .text, text: "B", title: "題", tag: "仕事", order: 0, updatedAt: now - 3_000, baseHash: hA)],
                tombstones: []
            ),
            sentAtMillis: now
        )

        for order in [[iPadWriteBack, iPhoneEdit], [iPhoneEdit, iPadWriteBack]] {
            let merged = try TemplateSyncMerge.mergeAll(pc: pcState, remotes: order, nowMillis: now)
            XCTAssertEqual(merged.conflictCopyCount, 2)
            XCTAssertEqual(merged.templates.count, 3)
            XCTAssertTrue(merged.templates.contains { $0.id == sharedId && $0.text == "A" })
            XCTAssertTrue(merged.templates.contains { $0.text == "C" && $0.tag == nil })
            XCTAssertTrue(merged.templates.contains { $0.text == "B" && $0.tag == nil })
        }
    }

    func testDeletedItemDoesNotResurrectAfter181DaysOr1000TombstoneCapForUneditedDeviceButKeepsEdit() throws {
        let now: Int64 = 1_794_873_600_000
        let day: Int64 = 86_400_000
        let uneditedId = UUID()
        let editedId = UUID()
        let hUnedited = TemplateSyncMerge.contentHash(kind: .text, text: "消した定型文", title: "旧", tag: "仕事")
        let hOrigEdited = TemplateSyncMerge.contentHash(kind: .text, text: "元の文", title: "題", tag: "仕事")

        // 1. After 181 days, PC's tombstone expired; unedited remote copy must not resurrect, offline edit survives.
        let expiredResult = try TemplateSyncMerge.merge(
            pc: TemplateSyncState(
                templates: [],
                tombstones: [
                    TemplateSyncTombstone(id: uneditedId, deletedAt: now - 181 * day, baseHash: hUnedited),
                    TemplateSyncTombstone(id: editedId, deletedAt: now - 181 * day, baseHash: hOrigEdited)
                ]
            ),
            remote: TemplateSyncState(
                templates: [
                    TemplateSyncItem(id: uneditedId, kind: .text, text: "消した定型文", title: "旧", tag: "仕事", order: 0, updatedAt: now - 200 * day, baseHash: hUnedited),
                    TemplateSyncItem(id: editedId, kind: .text, text: "オフラインで書き直した文", title: "題", tag: "仕事", order: 1, updatedAt: now - 10 * day, baseHash: hOrigEdited)
                ],
                tombstones: []
            ),
            nowMillis: now,
            remoteSentAtMillis: now
        )
        XCTAssertEqual(expiredResult.templates.map(\.id), [editedId])
        XCTAssertEqual(expiredResult.templates.map(\.text), ["オフラインで書き直した文"])
        XCTAssertEqual(expiredResult.remoteChanges.deleted, 1)

        // 2. After >1000 tombstones evicted the original tombstone from PC, unedited remote still does not resurrect.
        let pcTombs = (0..<SyncProtocol.maxTemplateTombstones).map { i in
            TemplateSyncTombstone(id: UUID(), deletedAt: now - 10_000 + Int64(i))
        }
        let evictedResult = try TemplateSyncMerge.merge(
            pc: TemplateSyncState(templates: [], tombstones: pcTombs),
            remote: TemplateSyncState(
                templates: [
                    TemplateSyncItem(id: uneditedId, kind: .text, text: "消した定型文", title: "旧", tag: "仕事", order: 0, updatedAt: now - 20_000, baseHash: hUnedited)
                ],
                tombstones: []
            ),
            nowMillis: now,
            remoteSentAtMillis: now
        )
        XCTAssertTrue(evictedResult.templates.isEmpty)
        XCTAssertEqual(evictedResult.remoteChanges.deleted, 1)
    }

    func testEditedConflictCopyIsNotDuplicatedWhenRemoteResendsLoser() throws {
        let now: Int64 = 1_794_873_600_000
        let sharedId = UUID()
        let hA = TemplateSyncMerge.contentHash(kind: .text, text: "A", title: "題", tag: "仕事")
        let pcItem = TemplateSyncItem(id: sharedId, kind: .text, text: "C", title: "題", tag: "仕事", order: 0, updatedAt: now - 1_000)
        let remoteLoser = TemplateSyncItem(id: sharedId, kind: .text, text: "B", title: "題", tag: "仕事", order: 0, updatedAt: now - 2_000, baseHash: hA)

        // First merge produces conflict copy for B, then simulate disconnect before remote receives tpl_state.
        let first = try TemplateSyncMerge.merge(
            pc: TemplateSyncState(templates: [pcItem], tombstones: []),
            remote: TemplateSyncState(templates: [remoteLoser], tombstones: []),
            nowMillis: now,
            remoteSentAtMillis: now
        )
        XCTAssertEqual(first.conflictCopyCount, 1)
        let copyB = try XCTUnwrap(first.templates.first { $0.text == "B" })

        // PC edits the conflict copy B -> B2 while remote still holds B with baseHash H(A) and resends it.
        let editedCopyB2 = TemplateSyncItem(
            id: copyB.id, kind: .text, text: "B2", title: copyB.title, tag: copyB.tag, order: copyB.order, updatedAt: now + 5_000
        )
        let second = try TemplateSyncMerge.merge(
            pc: TemplateSyncState(templates: [pcItem, editedCopyB2], tombstones: first.tombstones),
            remote: TemplateSyncState(templates: [remoteLoser], tombstones: []),
            nowMillis: now + 10_000,
            remoteSentAtMillis: now + 10_000
        )
        XCTAssertEqual(second.conflictCopyCount, 0)
        XCTAssertEqual(second.templates.count, 2)
        XCTAssertTrue(second.templates.contains { $0.id == sharedId && $0.text == "C" })
        XCTAssertTrue(second.templates.contains { $0.id == copyB.id && $0.text == "B2" })
        XCTAssertFalse(second.templates.contains { $0.text == "B" })
    }
}
