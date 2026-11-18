import CryptoKit
import Foundation

public struct TemplateSyncState: Equatable {
    public let templates: [TemplateSyncItem]
    public let tombstones: [TemplateSyncTombstone]

    public init(templates: [TemplateSyncItem], tombstones: [TemplateSyncTombstone]) {
        self.templates = templates
        self.tombstones = tombstones
    }
}

public struct TemplateSyncSideChanges: Equatable {
    public let added: Int
    public let updated: Int
    public let deleted: Int

    public var total: Int { added + updated + deleted }

    public init(added: Int, updated: Int, deleted: Int) {
        self.added = added
        self.updated = updated
        self.deleted = deleted
    }
}

public struct TemplateSyncMergeResult: Equatable {
    public let templates: [TemplateSyncItem]
    public let tombstones: [TemplateSyncTombstone]
    public let conflictCopyCount: Int
    public let subsumedDuplicateCount: Int
    public let pcChanges: TemplateSyncSideChanges
    public let remoteChanges: TemplateSyncSideChanges
    public let clockSkewSeconds: Int64?

    public init(templates: [TemplateSyncItem], tombstones: [TemplateSyncTombstone],
                conflictCopyCount: Int, subsumedDuplicateCount: Int,
                pcChanges: TemplateSyncSideChanges, remoteChanges: TemplateSyncSideChanges,
                clockSkewSeconds: Int64?) {
        self.templates = templates
        self.tombstones = tombstones
        self.conflictCopyCount = conflictCopyCount
        self.subsumedDuplicateCount = subsumedDuplicateCount
        self.pcChanges = pcChanges
        self.remoteChanges = remoteChanges
        self.clockSkewSeconds = clockSkewSeconds
    }
}

public enum TemplateSyncMerge {
    public static func normalizedTitle(_ title: String?) -> String? {
        normalizeLabel(title, maxChars: SyncProtocol.maxTemplateTitleCharacters, maxBytes: SyncProtocol.maxTemplateTitleBytes)
    }

    public static func normalizedTag(_ tag: String?) -> String? {
        normalizeLabel(tag, maxChars: SyncProtocol.maxTemplateTagCharacters, maxBytes: SyncProtocol.maxTemplateTagBytes)
    }

    private static func normalizeLabel(_ value: String?, maxChars: Int, maxBytes: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let capped = truncateByGraphemesAndBytes(trimmed, maxChars: maxChars, maxBytes: maxBytes)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return capped.isEmpty ? nil : capped
    }

    static func truncateByGraphemesAndBytes(_ value: String, maxChars: Int, maxBytes: Int) -> String {
        guard !value.isEmpty, maxChars > 0, maxBytes > 0 else { return "" }
        var result = ""
        var chars = 0
        var bytes = 0
        for ch in value {
            let elemBytes = String(ch).utf8.count
            if chars + 1 > maxChars || bytes + elemBytes > maxBytes { break }
            result.append(ch)
            chars += 1
            bytes += elemBytes
        }
        return result
    }

    public static func contentHash(_ item: TemplateSyncItem) -> String {
        contentHash(kind: item.kind, text: item.text, title: item.title, tag: item.tag)
    }

    public static func contentHash(kind: TemplateSyncKind, text: String, title: String?, tag: String?) -> String {
        let normTitle = normalizedTitle(title)
        let normTag = normalizedTag(tag)
        var json = "["
        json += TemplateCanonicalJson.serializeString(kind.rawValue)
        json += ","
        json += TemplateCanonicalJson.serializeString(text)
        json += ","
        if let normTitle {
            json += TemplateCanonicalJson.serializeString(normTitle)
        } else {
            json += "null"
        }
        json += ","
        if let normTag {
            json += TemplateCanonicalJson.serializeString(normTag)
        } else {
            json += "null"
        }
        json += "]"
        let digest = SHA256.hash(data: Data(json.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func nextUpdatedAt(nowMillis: Int64, existingUpdatedAt: Int64?) -> Int64 {
        let clampedNow = min(SyncProtocol.maxTimestamp, max(-SyncProtocol.maxTimestamp, nowMillis))
        guard let prev = existingUpdatedAt else { return clampedNow }
        if prev > clampedNow && prev - clampedNow > SyncProtocol.templateFutureTimestampCapMillis {
            return clampedNow
        }
        let bumped: Int64 = prev >= SyncProtocol.maxTimestamp ? SyncProtocol.maxTimestamp : prev + 1
        return min(SyncProtocol.maxTimestamp, max(-SyncProtocol.maxTimestamp, max(clampedNow, bumped)))
    }

    public static func clockSkewSeconds(remoteSentAtMillis: Int64, nowMillis: Int64) throws -> Int64? {
        try SyncProtocol.require(remoteSentAtMillis >= -SyncProtocol.maxTimestamp && remoteSentAtMillis <= SyncProtocol.maxTimestamp)
        try SyncProtocol.require(nowMillis >= -SyncProtocol.maxTimestamp && nowMillis <= SyncProtocol.maxTimestamp)
        let diff = abs(remoteSentAtMillis - nowMillis)
        return diff >= SyncProtocol.templateClockSkewWarningMillis ? diff / 1000 : nil
    }

    public static func makeConflictTitle(_ originalTitle: String?) -> String {
        guard let norm = normalizedTitle(originalTitle) else { return "別の端末の編集" }
        let suffix = "（別の端末の編集）"
        let suffixChars = suffix.count
        let suffixBytes = suffix.utf8.count
        let rawPrefix = truncateByGraphemesAndBytes(
            norm,
            maxChars: SyncProtocol.maxTemplateTitleCharacters - suffixChars,
            maxBytes: SyncProtocol.maxTemplateTitleBytes - suffixBytes
        )
        return rawPrefix.trimmingCharacters(in: .whitespacesAndNewlines) + suffix
    }

    public static func deterministicConflictId(originalId: UUID, loserContentHash: String, usedIds: inout Set<UUID>) -> UUID {
        var counter = 0
        while true {
            let input: String
            if counter == 0 {
                input = "clipboardplus-tpl-conflict-v1:\(originalId.uuidString):\(loserContentHash)"
            } else {
                input = "clipboardplus-tpl-conflict-v1:\(originalId.uuidString):\(loserContentHash):\(counter)"
            }
            var bytes = Array(SHA256.hash(data: Data(input.utf8)).prefix(16))
            bytes[6] = (bytes[6] & 0x0F) | 0x40
            bytes[8] = (bytes[8] & 0x3F) | 0x80
            let candidate = UUID(uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            ))
            if usedIds.insert(candidate).inserted {
                return candidate
            }
            counter += 1
        }
    }

    private struct NormalizedEntry {
        let item: TemplateSyncItem
        let hash: String
    }

    private struct ConflictCandidate {
        let originalId: UUID
        let loser: TemplateSyncItem
        let loserHash: String
    }

    public static func merge(
        pc: TemplateSyncState,
        remote: TemplateSyncState,
        nowMillis: Int64,
        remoteSentAtMillis: Int64? = nil
    ) throws -> TemplateSyncMergeResult {
        try SyncProtocol.require(nowMillis >= -SyncProtocol.maxTimestamp && nowMillis <= SyncProtocol.maxTimestamp)
        let clockSkew: Int64?
        if let remoteSentAtMillis {
            clockSkew = try clockSkewSeconds(remoteSentAtMillis: remoteSentAtMillis, nowMillis: nowMillis)
        } else {
            clockSkew = nil
        }

        var usedIds = Set<UUID>()
        let (pcItems, pcTombs) = try indexSide(pc, nowMillis: nowMillis, usedIds: &usedIds)
        let (remoteItems, remoteTombs) = try indexSide(remote, nowMillis: nowMillis, usedIds: &usedIds)

        var allIds = Set<UUID>(pcItems.keys)
        allIds.formUnion(pcTombs.keys)
        allIds.formUnion(remoteItems.keys)
        allIds.formUnion(remoteTombs.keys)

        var survivingItems: [NormalizedEntry] = []
        var survivingTombs: [UUID: TemplateSyncTombstone] = [:]
        var conflictCandidates: [ConflictCandidate] = []

        for id in allIds {
            let pcEntry = pcItems[id]
            let remoteEntry = remoteItems[id]
            let pcTomb = pcTombs[id]
            let remoteTomb = remoteTombs[id]

            if let pcEntry, let remoteEntry {
                resolveBothActive(pc: pcEntry, remote: remoteEntry, survivingItems: &survivingItems, conflictCandidates: &conflictCandidates)
            } else if let pcEntry, let remoteTomb {
                resolveActiveVsTombstone(survivor: pcEntry, tomb: remoteTomb, survivingItems: &survivingItems, survivingTombs: &survivingTombs)
            } else if let remoteEntry, let pcTomb {
                resolveActiveVsTombstone(survivor: remoteEntry, tomb: pcTomb, survivingItems: &survivingItems, survivingTombs: &survivingTombs)
            } else if let pcEntry {
                survivingItems.append(pcEntry)
            } else if let remoteEntry {
                survivingItems.append(remoteEntry)
            } else if let pcTomb, let remoteTomb {
                survivingTombs[id] = mergeTombstones(pcTomb, remoteTomb)
            } else if let pcTomb {
                survivingTombs[id] = pcTomb
            } else if let remoteTomb {
                survivingTombs[id] = remoteTomb
            }
        }

        let (dedupedItems, subsumedCount) = deduplicateSameText(items: survivingItems, tombs: &survivingTombs, nowMillis: nowMillis)

        var activeTexts = Set(dedupedItems.map(\.item.text))
        var conflictCopies: [TemplateSyncItem] = []
        let sortedConflicts = conflictCandidates.sorted { lhs, rhs in
            if lhs.loser.updatedAt != rhs.loser.updatedAt { return lhs.loser.updatedAt < rhs.loser.updatedAt }
            if lhs.loserHash != rhs.loserHash { return lhs.loserHash < rhs.loserHash }
            return lhs.originalId.uuidString < rhs.originalId.uuidString
        }
        for candidate in sortedConflicts {
            if !activeTexts.insert(candidate.loser.text).inserted { continue }
            let newId = deterministicConflictId(originalId: candidate.originalId, loserContentHash: candidate.loserHash, usedIds: &usedIds)
            conflictCopies.append(TemplateSyncItem(
                id: newId,
                kind: candidate.loser.kind,
                text: candidate.loser.text,
                title: makeConflictTitle(candidate.loser.title),
                tag: nil,
                order: Int.max,
                updatedAt: candidate.loser.updatedAt,
                baseHash: nil
            ))
        }

        try SyncProtocol.require(dedupedItems.count + conflictCopies.count <= SyncProtocol.maxTemplates, .limit)

        let finalTemplates = orderAndRenumber(normalItems: dedupedItems.map(\.item), conflictCopies: conflictCopies)
        let finalTombstones = pruneAndSortTombstones(Array(survivingTombs.values), nowMillis: nowMillis)

        let pcChanges = computeChanges(before: pcItems.values.map(\.item), after: finalTemplates)
        let remoteChanges = computeChanges(before: remoteItems.values.map(\.item), after: finalTemplates)

        return TemplateSyncMergeResult(
            templates: finalTemplates,
            tombstones: finalTombstones,
            conflictCopyCount: conflictCopies.count,
            subsumedDuplicateCount: subsumedCount,
            pcChanges: pcChanges,
            remoteChanges: remoteChanges,
            clockSkewSeconds: clockSkew
        )
    }

    private static func indexSide(
        _ side: TemplateSyncState,
        nowMillis: Int64,
        usedIds: inout Set<UUID>
    ) throws -> ([UUID: NormalizedEntry], [UUID: TemplateSyncTombstone]) {
        try SyncProtocol.require(side.templates.count <= SyncProtocol.maxTemplates, .limit)
        var sideIds = Set<UUID>()
        var items: [UUID: NormalizedEntry] = [:]
        items.reserveCapacity(side.templates.count)
        for raw in side.templates {
            let normalized = normalizeInputItem(raw)
            try TemplateSyncMessageCodec.validateItem(normalized, allowBaseHash: true)
            try SyncProtocol.require(sideIds.insert(normalized.id).inserted)
            usedIds.insert(normalized.id)
            items[normalized.id] = NormalizedEntry(item: normalized, hash: contentHash(normalized))
        }

        var tombs: [UUID: TemplateSyncTombstone] = [:]
        for tomb in side.tombstones {
            try TemplateSyncMessageCodec.validateTombstone(tomb)
            try SyncProtocol.require(sideIds.insert(tomb.id).inserted)
            usedIds.insert(tomb.id)
            if !isExpiredTombstone(tomb, nowMillis: nowMillis) {
                tombs[tomb.id] = tomb
            }
        }
        return (items, tombs)
    }

    private static func normalizeInputItem(_ raw: TemplateSyncItem) -> TemplateSyncItem {
        TemplateSyncItem(
            id: raw.id,
            kind: raw.kind,
            text: raw.text,
            title: normalizedTitle(raw.title),
            tag: normalizedTag(raw.tag),
            order: raw.order,
            updatedAt: raw.updatedAt,
            baseHash: raw.baseHash
        )
    }

    private static func withoutBaseHash(_ item: TemplateSyncItem, order: Int? = nil, updatedAt: Int64? = nil) -> TemplateSyncItem {
        TemplateSyncItem(
            id: item.id,
            kind: item.kind,
            text: item.text,
            title: item.title,
            tag: item.tag,
            order: order ?? item.order,
            updatedAt: updatedAt ?? item.updatedAt,
            baseHash: nil
        )
    }

    private static func isExpiredTombstone(_ tomb: TemplateSyncTombstone, nowMillis: Int64) -> Bool {
        nowMillis - tomb.deletedAt > SyncProtocol.templateTombstoneLifetimeMillis
    }

    private static func resolveBothActive(
        pc: NormalizedEntry,
        remote: NormalizedEntry,
        survivingItems: inout [NormalizedEntry],
        conflictCandidates: inout [ConflictCandidate]
    ) {
        if pc.hash == remote.hash {
            let order: Int
            if remote.item.updatedAt > pc.item.updatedAt {
                order = remote.item.order
            } else if pc.item.updatedAt > remote.item.updatedAt {
                order = pc.item.order
            } else {
                order = min(pc.item.order, remote.item.order)
            }
            let updatedAt = max(pc.item.updatedAt, remote.item.updatedAt)
            let chosen = withoutBaseHash(pc.item, order: order, updatedAt: updatedAt)
            survivingItems.append(NormalizedEntry(item: chosen, hash: pc.hash))
            return
        }

        let remoteUnedited = remote.item.baseHash != nil && remote.item.baseHash == remote.hash
        let pcUnedited = remote.item.baseHash != nil && remote.item.baseHash == pc.hash

        if remoteUnedited && !pcUnedited {
            survivingItems.append(NormalizedEntry(item: withoutBaseHash(pc.item), hash: pc.hash))
            return
        }
        if pcUnedited && !remoteUnedited {
            survivingItems.append(NormalizedEntry(item: withoutBaseHash(remote.item), hash: remote.hash))
            return
        }

        let winner: NormalizedEntry
        let loser: NormalizedEntry
        if pc.item.updatedAt > remote.item.updatedAt {
            winner = pc; loser = remote
        } else if remote.item.updatedAt > pc.item.updatedAt {
            winner = remote; loser = pc
        } else if pc.hash <= remote.hash {
            winner = pc; loser = remote
        } else {
            winner = remote; loser = pc
        }

        survivingItems.append(NormalizedEntry(item: withoutBaseHash(winner.item), hash: winner.hash))
        if winner.item.text != loser.item.text {
            conflictCandidates.append(ConflictCandidate(originalId: winner.item.id, loser: withoutBaseHash(loser.item), loserHash: loser.hash))
        }
    }

    private static func resolveActiveVsTombstone(
        survivor: NormalizedEntry,
        tomb: TemplateSyncTombstone,
        survivingItems: inout [NormalizedEntry],
        survivingTombs: inout [UUID: TemplateSyncTombstone]
    ) {
        let survivorUnedited =
            (survivor.item.baseHash != nil && survivor.item.baseHash == survivor.hash) ||
            (tomb.baseHash != nil && tomb.baseHash == survivor.hash)
        if survivorUnedited {
            survivingTombs[tomb.id] = TemplateSyncTombstone(
                id: tomb.id,
                deletedAt: tomb.deletedAt,
                baseHash: tomb.baseHash ?? survivor.hash
            )
        } else {
            survivingItems.append(NormalizedEntry(item: withoutBaseHash(survivor.item), hash: survivor.hash))
        }
    }

    private static func mergeTombstones(_ a: TemplateSyncTombstone, _ b: TemplateSyncTombstone) -> TemplateSyncTombstone {
        if a.deletedAt > b.deletedAt {
            return TemplateSyncTombstone(id: a.id, deletedAt: a.deletedAt, baseHash: a.baseHash ?? b.baseHash)
        }
        if b.deletedAt > a.deletedAt {
            return TemplateSyncTombstone(id: b.id, deletedAt: b.deletedAt, baseHash: b.baseHash ?? a.baseHash)
        }
        let hash: String?
        if let ha = a.baseHash, let hb = b.baseHash {
            hash = ha <= hb ? ha : hb
        } else {
            hash = a.baseHash ?? b.baseHash
        }
        return TemplateSyncTombstone(id: a.id, deletedAt: a.deletedAt, baseHash: hash)
    }

    private static func deduplicateSameText(
        items: [NormalizedEntry],
        tombs: inout [UUID: TemplateSyncTombstone],
        nowMillis: Int64
    ) -> ([NormalizedEntry], Int) {
        let grouped = Dictionary(grouping: items, by: { $0.item.text })
        var result: [NormalizedEntry] = []
        var subsumed = 0
        for group in grouped.values {
            let ordered = group.sorted { lhs, rhs in
                if lhs.item.updatedAt != rhs.item.updatedAt { return lhs.item.updatedAt > rhs.item.updatedAt }
                return lhs.item.id.uuidString < rhs.item.id.uuidString
            }
            let primary = ordered[0].item
            var title = primary.title
            var tag = primary.tag
            for other in ordered.dropFirst() {
                if title == nil, let otherTitle = other.item.title { title = otherTitle }
                if tag == nil, let otherTag = other.item.tag { tag = otherTag }
                let tomb = TemplateSyncTombstone(id: other.item.id, deletedAt: nowMillis, baseHash: other.hash)
                if let existing = tombs[tomb.id] {
                    tombs[tomb.id] = mergeTombstones(existing, tomb)
                } else {
                    tombs[tomb.id] = tomb
                }
                subsumed += 1
            }
            let merged = TemplateSyncItem(
                id: primary.id,
                kind: primary.kind,
                text: primary.text,
                title: title,
                tag: tag,
                order: primary.order,
                updatedAt: primary.updatedAt,
                baseHash: nil
            )
            result.append(NormalizedEntry(item: merged, hash: contentHash(merged)))
        }
        return (result, subsumed)
    }

    private static func orderAndRenumber(
        normalItems: [TemplateSyncItem],
        conflictCopies: [TemplateSyncItem]
    ) -> [TemplateSyncItem] {
        var byTag: [String: [(item: TemplateSyncItem, isConflict: Bool)]] = [:]
        var untagged: [(item: TemplateSyncItem, isConflict: Bool)] = []

        for item in normalItems {
            if let tag = item.tag {
                byTag[tag, default: []].append((item, false))
            } else {
                untagged.append((item, false))
            }
        }
        for copy in conflictCopies {
            untagged.append((copy, true))
        }

        var output: [TemplateSyncItem] = []
        let sortedTags = byTag.keys.sorted(by: precedesByUnicodeScalars)
        for tag in sortedTags {
            appendTagGroup(byTag[tag]!, to: &output)
        }
        appendTagGroup(untagged, to: &output)
        return output
    }

    private static func appendTagGroup(_ group: [(item: TemplateSyncItem, isConflict: Bool)], to output: inout [TemplateSyncItem]) {
        let sorted = group.sorted { lhs, rhs in
            if lhs.isConflict != rhs.isConflict { return !lhs.isConflict }
            if lhs.item.order != rhs.item.order { return lhs.item.order < rhs.item.order }
            if lhs.item.updatedAt != rhs.item.updatedAt { return lhs.item.updatedAt < rhs.item.updatedAt }
            return lhs.item.id.uuidString < rhs.item.id.uuidString
        }
        for (order, entry) in sorted.enumerated() {
            output.append(withoutBaseHash(entry.item, order: order))
        }
    }

    private static func pruneAndSortTombstones(_ tombs: [TemplateSyncTombstone], nowMillis: Int64) -> [TemplateSyncTombstone] {
        var sorted = tombs
            .filter { !isExpiredTombstone($0, nowMillis: nowMillis) }
            .sorted { lhs, rhs in
                if lhs.deletedAt != rhs.deletedAt { return lhs.deletedAt < rhs.deletedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        if sorted.count > SyncProtocol.maxTemplateTombstones {
            sorted.removeFirst(sorted.count - SyncProtocol.maxTemplateTombstones)
        }
        return sorted
    }

    private static func computeChanges(before: [TemplateSyncItem], after: [TemplateSyncItem]) -> TemplateSyncSideChanges {
        let beforeById = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })
        let afterById = Dictionary(uniqueKeysWithValues: after.map { ($0.id, $0) })
        var added = 0
        var updated = 0
        var deleted = 0

        for (id, afterItem) in afterById {
            guard let beforeItem = beforeById[id] else {
                added += 1
                continue
            }
            if beforeItem.kind != afterItem.kind ||
                beforeItem.text != afterItem.text ||
                beforeItem.title != afterItem.title ||
                beforeItem.tag != afterItem.tag ||
                beforeItem.order != afterItem.order {
                updated += 1
            }
        }
        for id in beforeById.keys where afterById[id] == nil {
            deleted += 1
        }
        return TemplateSyncSideChanges(added: added, updated: updated, deleted: deleted)
    }

    private static func precedesByUnicodeScalars(_ lhs: String, _ rhs: String) -> Bool {
        var ix = lhs.unicodeScalars.makeIterator()
        var iy = rhs.unicodeScalars.makeIterator()
        while true {
            switch (ix.next(), iy.next()) {
            case let (a?, b?):
                if a.value != b.value { return a.value < b.value }
            case (nil, _?):
                return true
            case (_, nil):
                return false
            }
        }
    }
}
