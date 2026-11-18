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

public struct TemplateSyncRemoteState: Equatable {
    public let state: TemplateSyncState
    public let sentAtMillis: Int64?

    public init(state: TemplateSyncState, sentAtMillis: Int64? = nil) {
        self.state = state
        self.sentAtMillis = sentAtMillis
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

public struct TemplateSyncMultiMergeResult: Equatable {
    public let templates: [TemplateSyncItem]
    public let tombstones: [TemplateSyncTombstone]
    public let conflictCopyCount: Int
    public let subsumedDuplicateCount: Int
    public let pcChanges: TemplateSyncSideChanges
    public let remoteChanges: [TemplateSyncSideChanges]
    public let remoteClockSkewSeconds: [Int64?]

    public init(templates: [TemplateSyncItem], tombstones: [TemplateSyncTombstone],
                conflictCopyCount: Int, subsumedDuplicateCount: Int,
                pcChanges: TemplateSyncSideChanges, remoteChanges: [TemplateSyncSideChanges],
                remoteClockSkewSeconds: [Int64?]) {
        self.templates = templates
        self.tombstones = tombstones
        self.conflictCopyCount = conflictCopyCount
        self.subsumedDuplicateCount = subsumedDuplicateCount
        self.pcChanges = pcChanges
        self.remoteChanges = remoteChanges
        self.remoteClockSkewSeconds = remoteClockSkewSeconds
    }
}

public struct TemplateSyncPreparedState: Equatable {
    public let state: TemplateSyncState
    public let excludedTemplateCount: Int

    public init(state: TemplateSyncState, excludedTemplateCount: Int) {
        self.state = state
        self.excludedTemplateCount = excludedTemplateCount
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
        let data = (try? TemplateCanonicalJson.serializeContentHashInput(kind: kind, text: text, normTitle: normTitle, normTag: normTag)) ?? Data()
        let digest = SHA256.hash(data: data)
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

    private static let placeholderBaseHash = String(repeating: "0", count: 64)

    private static func utf8Equals(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }

    private static func utf8EqualsOptional(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (a?, b?): return a.utf8.elementsEqual(b.utf8)
        default: return false
        }
    }

    public static func deterministicConflictId(originalId: UUID, loserContentHash: String, usedIds: inout Set<UUID>) -> UUID {
        var counter = 0
        while true {
            let candidate = conflictUuid(originalId: originalId, loserContentHash: loserContentHash, counter: counter)
            if usedIds.insert(candidate).inserted {
                return candidate
            }
            counter += 1
        }
    }

    private static func resolveConflictId(
        originalId: UUID,
        loserContentHash: String,
        activeIds: inout Set<UUID>,
        tombstoneIds: Set<UUID>
    ) -> UUID? {
        var counter = 0
        while true {
            let candidate = conflictUuid(originalId: originalId, loserContentHash: loserContentHash, counter: counter)
            // Suppress recreation if this conflict copy was already deleted (tombstone present).
            if tombstoneIds.contains(candidate) {
                return nil
            }
            if activeIds.insert(candidate).inserted {
                return candidate
            }
            counter += 1
        }
    }

    private static func conflictUuid(originalId: UUID, loserContentHash: String, counter: Int) -> UUID {
        let input: String
        if counter == 0 {
            input = "clipboardplus-tpl-conflict-v1:\(originalId.uuidString):\(loserContentHash)"
        } else {
            input = "clipboardplus-tpl-conflict-v1:\(originalId.uuidString):\(loserContentHash):\(counter)"
        }
        var bytes = Array(SHA256.hash(data: Data(input.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
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

    private struct PagePackerState {
        let flushedPages: Int
        let flushedTotalBytes: Int
        let currentPageBytes: Int
        let currentHasItems: Bool

        static func initial(firstPageEmptyBytes: Int) -> PagePackerState {
            PagePackerState(flushedPages: 0, flushedTotalBytes: 0, currentPageBytes: firstPageEmptyBytes, currentHasItems: false)
        }

        func addingItem(_ itemBytes: Int, continuationEmptyBytes: Int) -> PagePackerState? {
            let commaBytes = currentHasItems ? 1 : 0
            if currentPageBytes + commaBytes + itemBytes <= SyncProtocol.maxTemplatePageBodyBytes {
                return PagePackerState(
                    flushedPages: flushedPages,
                    flushedTotalBytes: flushedTotalBytes,
                    currentPageBytes: currentPageBytes + commaBytes + itemBytes,
                    currentHasItems: true
                )
            }
            guard currentHasItems, flushedPages + 1 < SyncProtocol.maxTemplatePages else {
                return nil
            }
            let newTotal = flushedTotalBytes + currentPageBytes
            guard newTotal <= SyncProtocol.maxTemplateTotalBytes,
                  continuationEmptyBytes + itemBytes <= SyncProtocol.maxTemplatePageBodyBytes else {
                return nil
            }
            return PagePackerState(
                flushedPages: flushedPages + 1,
                flushedTotalBytes: newTotal,
                currentPageBytes: continuationEmptyBytes + itemBytes,
                currentHasItems: true
            )
        }

        func canFinishWithTombstones(_ tombstoneByteSizes: [Int], continuationEmptyBytes: Int) -> Bool {
            var pages = flushedPages
            var totalBytes = flushedTotalBytes
            var currentBytes = currentPageBytes
            var hasItems = currentHasItems
            var hasTombstones = false

            for tombBytes in tombstoneByteSizes {
                var commaBytes = hasTombstones ? 1 : 0
                if currentBytes + commaBytes + tombBytes > SyncProtocol.maxTemplatePageBodyBytes {
                    guard hasItems || hasTombstones else { return false }
                    guard pages + 1 < SyncProtocol.maxTemplatePages else { return false }
                    totalBytes += currentBytes
                    guard totalBytes <= SyncProtocol.maxTemplateTotalBytes else { return false }
                    pages += 1
                    currentBytes = continuationEmptyBytes
                    hasItems = false
                    hasTombstones = false
                    commaBytes = 0
                    guard currentBytes + tombBytes <= SyncProtocol.maxTemplatePageBodyBytes else { return false }
                }
                hasTombstones = true
                currentBytes += commaBytes + tombBytes
            }

            return pages + 1 <= SyncProtocol.maxTemplatePages &&
                totalBytes + currentBytes <= SyncProtocol.maxTemplateTotalBytes
        }
    }

    public static func prepareSyncState(
        templates: [TemplateSyncItem],
        tombstones: [TemplateSyncTombstone],
        nowMillis: Int64,
        sentAtMillis: Int64? = nil
    ) throws -> TemplateSyncPreparedState {
        try SyncProtocol.require(nowMillis >= -SyncProtocol.maxTimestamp && nowMillis <= SyncProtocol.maxTimestamp)
        let effectiveSentAt = sentAtMillis ?? nowMillis
        try SyncProtocol.require(effectiveSentAt >= -SyncProtocol.maxTimestamp && effectiveSentAt <= SyncProtocol.maxTimestamp)

        let firstPageEmptyBytes = try TemplateCanonicalJson.measurePageUtf8Bytes(
            TemplateSyncPage(version: 1, sentAt: effectiveSentAt, templates: [], tombstones: []),
            isFirstPage: true,
            includeItemBaseHash: true,
            maxBytes: SyncProtocol.maxTemplatePageBodyBytes
        )
        let continuationEmptyBytes = try TemplateCanonicalJson.measurePageUtf8Bytes(
            TemplateSyncPage(templates: [], tombstones: []),
            isFirstPage: false,
            includeItemBaseHash: true,
            maxBytes: SyncProtocol.maxTemplatePageBodyBytes
        )

        let inputTemplateIds = Set(templates.map(\.id))
        var validTombs: [UUID: TemplateSyncTombstone] = [:]
        for tomb in tombstones {
            if inputTemplateIds.contains(tomb.id) { continue }
            if tomb.deletedAt < -SyncProtocol.maxTimestamp || tomb.deletedAt > SyncProtocol.maxTimestamp { continue }
            if let baseHash = tomb.baseHash, !SyncProtocol.isLowerHex64(baseHash) { continue }
            if isExpiredTombstone(deletedAt: tomb.deletedAt, nowMillis: nowMillis) { continue }
            if let existing = validTombs[tomb.id] {
                validTombs[tomb.id] = mergeTombstones(existing, tomb)
            } else {
                validTombs[tomb.id] = tomb
            }
        }

        let cappedTombstones = pruneAndSortTombstones(Array(validTombs.values), nowMillis: nowMillis)
        let tombByteSizes = try cappedTombstones.map {
            try TemplateCanonicalJson.measureTombstoneUtf8Bytes(
                $0,
                maxBytes: SyncProtocol.maxTemplatePageBodyBytes - continuationEmptyBytes
            )
        }

        var accepted: [TemplateSyncItem] = []
        var seenItemIds = Set<UUID>()
        var excluded = 0
        var packer = PagePackerState.initial(firstPageEmptyBytes: firstPageEmptyBytes)

        for raw in templates {
            guard seenItemIds.insert(raw.id).inserted else {
                excluded += 1
                continue
            }
            let normalized = normalizeInputItem(raw)
            guard let itemBytes = measureSyncableItemBytes(normalized, firstPageEmptyBytes: firstPageEmptyBytes) else {
                excluded += 1
                continue
            }
            guard accepted.count < SyncProtocol.maxTemplates,
                  let nextPacker = packer.addingItem(itemBytes, continuationEmptyBytes: continuationEmptyBytes),
                  nextPacker.canFinishWithTombstones(tombByteSizes, continuationEmptyBytes: continuationEmptyBytes) else {
                excluded += 1
                continue
            }
            accepted.append(normalized)
            packer = nextPacker
        }

        return TemplateSyncPreparedState(
            state: TemplateSyncState(templates: accepted, tombstones: cappedTombstones),
            excludedTemplateCount: excluded
        )
    }

    private static func measureSyncableItemBytes(_ item: TemplateSyncItem, firstPageEmptyBytes: Int) -> Int? {
        guard item.order >= 0 && item.order <= TemplateSyncMessageCodec.maxOrder,
              item.updatedAt >= -SyncProtocol.maxTimestamp && item.updatedAt <= SyncProtocol.maxTimestamp else {
            return nil
        }
        if let baseHash = item.baseHash, !SyncProtocol.isLowerHex64(baseHash) {
            return nil
        }
        do {
            try TemplateSyncMessageCodec.validateItem(item, allowBaseHash: true)
            // Reserve space for a 64-hex baseHash so items selected by PC remain syncable after iOS computes baseHash.
            let sizingItem = item.baseHash != nil ? item : TemplateSyncItem(
                id: item.id,
                kind: item.kind,
                text: item.text,
                title: item.title,
                tag: item.tag,
                order: item.order,
                updatedAt: item.updatedAt,
                baseHash: placeholderBaseHash
            )
            return try TemplateCanonicalJson.measureItemUtf8Bytes(
                sizingItem,
                includeBaseHash: true,
                maxBytes: SyncProtocol.maxTemplatePageBodyBytes - firstPageEmptyBytes
            )
        } catch {
            return nil
        }
    }

    private static func fitsWithinSyncBudget(templates: [TemplateSyncItem], tombstones: [TemplateSyncTombstone]) throws -> Bool {
        let firstPageEmptyBytes = try TemplateCanonicalJson.measurePageUtf8Bytes(
            TemplateSyncPage(version: 1, sentAt: -SyncProtocol.maxTimestamp, templates: [], tombstones: []),
            isFirstPage: true,
            includeItemBaseHash: true,
            maxBytes: SyncProtocol.maxTemplatePageBodyBytes
        )
        let continuationEmptyBytes = try TemplateCanonicalJson.measurePageUtf8Bytes(
            TemplateSyncPage(templates: [], tombstones: []),
            isFirstPage: false,
            includeItemBaseHash: true,
            maxBytes: SyncProtocol.maxTemplatePageBodyBytes
        )

        var packer = PagePackerState.initial(firstPageEmptyBytes: firstPageEmptyBytes)
        for item in templates {
            let sizingItem = item.baseHash != nil ? item : TemplateSyncItem(
                id: item.id,
                kind: item.kind,
                text: item.text,
                title: item.title,
                tag: item.tag,
                order: item.order,
                updatedAt: item.updatedAt,
                baseHash: placeholderBaseHash
            )
            let itemBytes = try TemplateCanonicalJson.measureItemUtf8Bytes(
                sizingItem,
                includeBaseHash: true,
                maxBytes: SyncProtocol.maxTemplatePageBodyBytes - continuationEmptyBytes
            )
            guard let nextPacker = packer.addingItem(itemBytes, continuationEmptyBytes: continuationEmptyBytes) else {
                return false
            }
            packer = nextPacker
        }

        let tombByteSizes = try tombstones.map {
            try TemplateCanonicalJson.measureTombstoneUtf8Bytes(
                $0,
                maxBytes: SyncProtocol.maxTemplatePageBodyBytes - continuationEmptyBytes
            )
        }
        return packer.canFinishWithTombstones(tombByteSizes, continuationEmptyBytes: continuationEmptyBytes)
    }

    public static func merge(
        pc: TemplateSyncState,
        remote: TemplateSyncState,
        nowMillis: Int64,
        remoteSentAtMillis: Int64? = nil
    ) throws -> TemplateSyncMergeResult {
        let multi = try mergeAll(
            pc: pc,
            remotes: [TemplateSyncRemoteState(state: remote, sentAtMillis: remoteSentAtMillis)],
            nowMillis: nowMillis
        )
        return TemplateSyncMergeResult(
            templates: multi.templates,
            tombstones: multi.tombstones,
            conflictCopyCount: multi.conflictCopyCount,
            subsumedDuplicateCount: multi.subsumedDuplicateCount,
            pcChanges: multi.pcChanges,
            remoteChanges: multi.remoteChanges[0],
            clockSkewSeconds: multi.remoteClockSkewSeconds[0]
        )
    }

    public static func mergeAll(
        pc: TemplateSyncState,
        remotes: [TemplateSyncRemoteState],
        nowMillis: Int64
    ) throws -> TemplateSyncMultiMergeResult {
        try SyncProtocol.require(nowMillis >= -SyncProtocol.maxTimestamp && nowMillis <= SyncProtocol.maxTimestamp)

        let (pcItems, pcTombs) = try indexSide(pc, nowMillis: nowMillis, sentAtMillis: nil, knownPcTombs: nil)

        var remoteItemsList: [[UUID: NormalizedEntry]] = []
        remoteItemsList.reserveCapacity(remotes.count)
        var remoteTombsList: [[UUID: TemplateSyncTombstone]] = []
        remoteTombsList.reserveCapacity(remotes.count)
        var remoteClockSkews: [Int64?] = []
        remoteClockSkews.reserveCapacity(remotes.count)

        var allIds = Set<UUID>(pcItems.keys)
        allIds.formUnion(pcTombs.keys)

        for remote in remotes {
            let skew: Int64?
            if let sentAt = remote.sentAtMillis {
                skew = try clockSkewSeconds(remoteSentAtMillis: sentAt, nowMillis: nowMillis)
            } else {
                skew = nil
            }
            remoteClockSkews.append(skew)
            let (rItems, rTombs) = try indexSide(
                remote.state,
                nowMillis: nowMillis,
                sentAtMillis: remote.sentAtMillis,
                knownPcTombs: pcTombs
            )
            remoteItemsList.append(rItems)
            remoteTombsList.append(rTombs)
            allIds.formUnion(rItems.keys)
            allIds.formUnion(rTombs.keys)
        }

        var survivingItems: [NormalizedEntry] = []
        var survivingTombs: [UUID: TemplateSyncTombstone] = [:]
        var conflictCandidates: [ConflictCandidate] = []

        for id in allIds {
            var activeEntries: [NormalizedEntry] = []
            if let pcEntry = pcItems[id] {
                activeEntries.append(pcEntry)
            }
            for rItems in remoteItemsList {
                if let rEntry = rItems[id] {
                    activeEntries.append(rEntry)
                }
            }

            let pcTomb = pcTombs[id]
            var tombs: [TemplateSyncTombstone] = []
            if let pcTomb {
                tombs.append(pcTomb)
            }
            for rTombs in remoteTombsList {
                if let rTomb = rTombs[id] {
                    tombs.append(rTomb)
                }
            }

            if !tombs.isEmpty {
                let remainingActive = activeEntries.filter { !isKilledByTombstones($0, pcTomb: pcTomb, allTombs: tombs) }
                if remainingActive.isEmpty {
                    var mergedTomb = tombs[0]
                    for tomb in tombs.dropFirst() {
                        mergedTomb = mergeTombstones(mergedTomb, tomb)
                    }
                    survivingTombs[id] = mergedTomb
                } else {
                    resolveActiveEntries(remainingActive, survivingItems: &survivingItems, conflictCandidates: &conflictCandidates)
                }
            } else if !activeEntries.isEmpty {
                resolveActiveEntries(activeEntries, survivingItems: &survivingItems, conflictCandidates: &conflictCandidates)
            }
        }

        let (dedupedItems, subsumedCount) = deduplicateSameText(items: survivingItems, tombs: &survivingTombs, nowMillis: nowMillis)

        var activeIds = Set(dedupedItems.map(\.item.id))
        let tombstoneIds = Set(survivingTombs.keys)
        var activeTexts = Set(dedupedItems.map { Data($0.item.text.utf8) })
        var conflictCopies: [TemplateSyncItem] = []
        let sortedConflicts = conflictCandidates.sorted { lhs, rhs in
            if lhs.loser.updatedAt != rhs.loser.updatedAt { return lhs.loser.updatedAt < rhs.loser.updatedAt }
            if lhs.loserHash != rhs.loserHash { return lhs.loserHash < rhs.loserHash }
            return lhs.originalId.uuidString < rhs.originalId.uuidString
        }
        for candidate in sortedConflicts {
            let textKey = Data(candidate.loser.text.utf8)
            if activeTexts.contains(textKey) { continue }
            guard let newId = resolveConflictId(
                originalId: candidate.originalId,
                loserContentHash: candidate.loserHash,
                activeIds: &activeIds,
                tombstoneIds: tombstoneIds
            ) else { continue }
            activeTexts.insert(textKey)
            conflictCopies.append(TemplateSyncItem(
                id: newId,
                kind: candidate.loser.kind,
                text: candidate.loser.text,
                title: makeConflictTitle(candidate.loser.title),
                tag: nil,
                order: TemplateSyncMessageCodec.maxOrder,
                updatedAt: candidate.loser.updatedAt,
                baseHash: nil
            ))
        }

        try SyncProtocol.require(dedupedItems.count + conflictCopies.count <= SyncProtocol.maxTemplates, .limit)

        let finalTemplates = orderAndRenumber(normalItems: dedupedItems.map(\.item), conflictCopies: conflictCopies)
        let finalTombstones = pruneAndSortTombstones(Array(survivingTombs.values), nowMillis: nowMillis)
        try SyncProtocol.require(try fitsWithinSyncBudget(templates: finalTemplates, tombstones: finalTombstones), .limit)

        let pcChanges = computeChanges(before: pcItems.values.map(\.item), after: finalTemplates)
        let remoteChanges = remoteItemsList.map { rItems in
            computeChanges(before: rItems.values.map(\.item), after: finalTemplates)
        }

        return TemplateSyncMultiMergeResult(
            templates: finalTemplates,
            tombstones: finalTombstones,
            conflictCopyCount: conflictCopies.count,
            subsumedDuplicateCount: subsumedCount,
            pcChanges: pcChanges,
            remoteChanges: remoteChanges,
            remoteClockSkewSeconds: remoteClockSkews
        )
    }

    private static func indexSide(
        _ side: TemplateSyncState,
        nowMillis: Int64,
        sentAtMillis: Int64?,
        knownPcTombs: [UUID: TemplateSyncTombstone]?
    ) throws -> ([UUID: NormalizedEntry], [UUID: TemplateSyncTombstone]) {
        try SyncProtocol.require(side.templates.count <= SyncProtocol.maxTemplates, .limit)
        var sideIds = Set<UUID>()
        var items: [UUID: NormalizedEntry] = [:]
        items.reserveCapacity(side.templates.count)
        for raw in side.templates {
            let normalized = normalizeInputItem(raw)
            try TemplateSyncMessageCodec.validateItem(normalized, allowBaseHash: true)
            try SyncProtocol.require(sideIds.insert(normalized.id).inserted)
            items[normalized.id] = NormalizedEntry(item: normalized, hash: contentHash(normalized))
        }

        var tombs: [UUID: TemplateSyncTombstone] = [:]
        for tomb in side.tombstones {
            try TemplateSyncMessageCodec.validateTombstone(tomb)
            try SyncProtocol.require(sideIds.insert(tomb.id).inserted)
            if let sentAt = sentAtMillis {
                if let existingPcTomb = knownPcTombs?[tomb.id] {
                    // Already recorded on PC: preserve PC's deletedAt so resends never extend retention.
                    tombs[tomb.id] = TemplateSyncTombstone(id: tomb.id, deletedAt: existingPcTomb.deletedAt, baseHash: tomb.baseHash)
                    continue
                }
                let adjustedRaw = tomb.deletedAt + (nowMillis - sentAt)
                let clamped = min(SyncProtocol.maxTimestamp, max(-SyncProtocol.maxTimestamp, adjustedRaw))
                let adjusted = min(nowMillis, clamped)
                if !isExpiredTombstone(deletedAt: adjusted, nowMillis: nowMillis) {
                    tombs[tomb.id] = TemplateSyncTombstone(id: tomb.id, deletedAt: adjusted, baseHash: tomb.baseHash)
                }
            } else if !isExpiredTombstone(deletedAt: tomb.deletedAt, nowMillis: nowMillis) {
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

    private static func isExpiredTombstone(deletedAt: Int64, nowMillis: Int64) -> Bool {
        nowMillis - deletedAt > SyncProtocol.templateTombstoneLifetimeMillis
    }

    private static func isKilledByTombstones(
        _ entry: NormalizedEntry,
        pcTomb: TemplateSyncTombstone?,
        allTombs: [TemplateSyncTombstone]
    ) -> Bool {
        for tomb in allTombs {
            if let tombBaseHash = tomb.baseHash, tombBaseHash == entry.hash {
                return true
            }
        }
        if let itemBaseHash = entry.item.baseHash, itemBaseHash == entry.hash {
            if pcTomb != nil { return true }
            if allTombs.contains(where: { $0.baseHash == nil }) {
                return true
            }
        }
        return false
    }

    private static func resolveActiveEntries(
        _ entries: [NormalizedEntry],
        survivingItems: inout [NormalizedEntry],
        conflictCandidates: inout [ConflictCandidate]
    ) {
        if entries.count == 1 {
            survivingItems.append(NormalizedEntry(item: withoutBaseHash(entries[0].item), hash: entries[0].hash))
            return
        }

        let firstHash = entries[0].hash
        if entries.allSatisfy({ $0.hash == firstHash }) {
            survivingItems.append(combineMatchingEntries(entries))
            return
        }

        let editedBaseHashes = Set(entries.compactMap { e -> String? in
            guard let baseHash = e.item.baseHash, baseHash != e.hash else { return nil }
            return baseHash
        })
        let edited = entries.filter { e in
            if let baseHash = e.item.baseHash {
                return baseHash != e.hash
            }
            return !editedBaseHashes.contains(e.hash)
        }
        let pool = edited.isEmpty ? entries : edited

        let groupedByHash = Dictionary(grouping: pool, by: \.hash)
        var byHash = groupedByHash.values.map { combineMatchingEntries($0) }
        if byHash.count == 1 {
            let winnerHash = byHash[0].hash
            survivingItems.append(combineMatchingEntries(entries.filter { $0.hash == winnerHash }))
            return
        }

        byHash.sort { a, b in
            if a.item.updatedAt != b.item.updatedAt { return a.item.updatedAt > b.item.updatedAt }
            return a.hash < b.hash
        }

        let winnerHash = byHash[0].hash
        let winner = combineMatchingEntries(entries.filter { $0.hash == winnerHash })
        survivingItems.append(winner)
        for loser in byHash.dropFirst() {
            if !utf8Equals(winner.item.text, loser.item.text) {
                conflictCandidates.append(ConflictCandidate(originalId: winner.item.id, loser: loser.item, loserHash: loser.hash))
            }
        }
    }

    private static func combineMatchingEntries(_ entries: [NormalizedEntry]) -> NormalizedEntry {
        var best = entries[0]
        for e in entries.dropFirst() {
            if e.item.updatedAt > best.item.updatedAt ||
                (e.item.updatedAt == best.item.updatedAt && e.item.order < best.item.order) {
                best = e
            }
        }
        return NormalizedEntry(item: withoutBaseHash(best.item), hash: best.hash)
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
        let grouped = Dictionary(grouping: items, by: { Data($0.item.text.utf8) })
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
        var byTag: [Data: (tag: String, entries: [(item: TemplateSyncItem, isConflict: Bool)])] = [:]
        var untagged: [(item: TemplateSyncItem, isConflict: Bool)] = []

        for item in normalItems {
            if let tag = item.tag {
                let tagKey = Data(tag.utf8)
                if var group = byTag[tagKey] {
                    group.entries.append((item, false))
                    byTag[tagKey] = group
                } else {
                    byTag[tagKey] = (tag, [(item, false)])
                }
            } else {
                untagged.append((item, false))
            }
        }
        for copy in conflictCopies {
            untagged.append((copy, true))
        }

        var output: [TemplateSyncItem] = []
        let sortedGroups = byTag.values.sorted { precedesByUnicodeScalars($0.tag, $1.tag) }
        for group in sortedGroups {
            appendTagGroup(group.entries, to: &output)
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
            .filter { !isExpiredTombstone(deletedAt: $0.deletedAt, nowMillis: nowMillis) }
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
                !utf8Equals(beforeItem.text, afterItem.text) ||
                !utf8EqualsOptional(beforeItem.title, afterItem.title) ||
                !utf8EqualsOptional(beforeItem.tag, afterItem.tag) ||
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
