import Foundation
import SwiftUI
import UIKit

enum KeyboardMode: Equatable, Sendable {
    case list
    case alphanumeric
}

enum KeyboardAlphanumericPage: Equatable, Sendable {
    case letters
    case numbers
    case symbols
}

enum KeyboardShiftState: Equatable, Sendable {
    case off
    case once
    case locked

    var isUppercased: Bool { self != .off }
}

enum KeyboardLoadState: Equatable, Sendable {
    case loading
    case loaded
    case unavailable
}

struct KeyboardStatusBanner: Equatable, Sendable {
    let message: String
    let isError: Bool
}

struct KeyboardTemplateGroup: Identifiable, Equatable, Sendable {
    let tag: String?
    let entries: [KeyboardHistoryEntry]

    var id: String { tag ?? "" }
    var title: String { tag ?? "その他" }
}

enum KeyboardTemplateGrouping {
    static func make(_ entries: [KeyboardHistoryEntry]) -> [KeyboardTemplateGroup] {
        let templates = entries.filter(\.isTemplate)
        var grouped: [String?: [KeyboardHistoryEntry]] = [:]
        for entry in templates {
            grouped[normalizedTag(entry.tag), default: []].append(entry)
        }
        let namedTags = grouped.keys.compactMap { $0 }.sorted {
            let order = $0.localizedStandardCompare($1)
            return order == .orderedSame ? $0 < $1 : order == .orderedAscending
        }
        let orderedKeys: [String?] = namedTags.map { Optional($0) } + [nil]
        return orderedKeys.compactMap { key in
            guard let items = grouped[key], !items.isEmpty else { return nil }
            return KeyboardTemplateGroup(tag: key, entries: orderedTemplates(items))
        }
    }

    static func sortedHistory(_ entries: [KeyboardHistoryEntry]) -> [KeyboardHistoryEntry] {
        entries
            .filter { !$0.isTemplate }
            .sorted {
                $0.lastCollectedAt == $1.lastCollectedAt
                    ? $0.id > $1.id
                    : $0.lastCollectedAt > $1.lastCollectedAt
            }
    }

    private static func orderedTemplates(_ entries: [KeyboardHistoryEntry]) -> [KeyboardHistoryEntry] {
        entries.sorted { lhs, rhs in
            switch (lhs.templateOrder, rhs.templateOrder) {
            case let (a?, b?) where a != b: return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.id < rhs.id
            }
        }
    }

    private static func normalizedTag(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum KeyboardTimeFormatter {
    static func label(for date: Date, now: Date, calendar: Calendar = .current) -> String {
        let elapsed = max(0, now.timeIntervalSince(date))
        if elapsed < 10 { return "たった今" }
        if elapsed < 60 { return "\(Int(elapsed))秒前" }
        if elapsed < 3_600 { return "\(Int(elapsed / 60))分前" }
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let minute = parts.minute ?? 0
        let time = "\(parts.hour ?? 0):" + (minute < 10 ? "0\(minute)" : "\(minute)")
        if calendar.isDate(date, inSameDayAs: now) {
            return time
        }
        let day = "\(parts.month ?? 0)/\(parts.day ?? 0)"
        if parts.year != calendar.component(.year, from: now) {
            return "\(parts.year ?? 0)/\(day)"
        }
        return "\(day) \(time)"
    }
}

enum KeyboardLinkFormatting {
    struct Parts: Equatable {
        let host: String
        let remainder: String?
    }

    static func parts(_ text: String) -> Parts? {
        guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = components.host, !host.isEmpty else {
            return nil
        }
        var remainder = components.path
        if let query = components.query, !query.isEmpty { remainder += "?" + query }
        if let fragment = components.fragment, !fragment.isEmpty { remainder += "#" + fragment }
        return Parts(host: host, remainder: remainder.isEmpty || remainder == "/" ? nil : remainder)
    }
}

enum KeyboardEntryPreview {
    static func summary(_ text: String, maxCharacters: Int = 180) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "（空文字）" }
        if trimmed.count <= maxCharacters {
            return trimmed
        }
        return String(trimmed.prefix(maxCharacters)) + "…"
    }
}

enum KeyboardLayoutMetrics {
    static func preferredHeight(
        idiom: UIUserInterfaceIdiom,
        verticalSizeClass: UIUserInterfaceSizeClass,
        width: CGFloat
    ) -> CGFloat {
        switch idiom {
        case .pad:
            if width > 0 && width < 500 {
                return 284
            }
            return width >= 950 ? 340 : 316
        default:
            return verticalSizeClass == .compact ? 204 : 284
        }
    }

    static func columnCount(forWidth width: CGFloat) -> Int {
        width >= 600 ? 2 : 1
    }

    static func keyHeight(idiom: UIUserInterfaceIdiom, availableHeight: CGFloat) -> CGFloat {
        if availableHeight > 0 && availableHeight < 235 {
            return 36
        }
        return idiom == .pad ? 48 : 42
    }
}

@MainActor
final class KeyboardViewModel: ObservableObject {
    @Published var selectedTab: KeyboardTab
    @Published var mode: KeyboardMode
    @Published var alphanumericPage: KeyboardAlphanumericPage
    @Published var shiftState: KeyboardShiftState
    @Published private(set) var loadState: KeyboardLoadState
    @Published private(set) var historyEntries: [KeyboardHistoryEntry]
    @Published private(set) var templateGroups: [KeyboardTemplateGroup]
    @Published var hasFullAccess: Bool
    @Published var needsInputModeSwitchKey: Bool
    @Published private(set) var flashedEntryID: Int?
    @Published private(set) var statusMessage: KeyboardStatusBanner?

    var showsSaveClipboardButton: Bool { hasFullAccess }

    var referenceDateOverride: Date?
    var insertText: (String) -> Void
    var deleteBackward: () -> Void
    private let pasteboardProvider: () -> KeyboardPasteboardReadable?
    private let inboxDirectoryProvider: () -> URL?
    private let now: () -> Date

    private var loadGeneration = 0
    private var loadTask: Task<Void, Never>?
    private var flashTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var lastShiftTapDate: Date?

    init(
        entries: [KeyboardHistoryEntry] = [],
        initialTab: KeyboardTab = .history,
        loadState: KeyboardLoadState = .loaded,
        mode: KeyboardMode = .list,
        alphanumericPage: KeyboardAlphanumericPage = .letters,
        shiftState: KeyboardShiftState = .off,
        hasFullAccess: Bool = false,
        needsInputModeSwitchKey: Bool = true,
        referenceDateOverride: Date? = nil,
        insertText: @escaping (String) -> Void = { _ in },
        deleteBackward: @escaping () -> Void = {},
        pasteboardProvider: @escaping () -> KeyboardPasteboardReadable? = { nil },
        inboxDirectoryProvider: @escaping () -> URL? = { SharedAppGroup.inboxDirectoryURL() },
        now: @escaping () -> Date = Date.init
    ) {
        self.selectedTab = initialTab
        self.mode = mode
        self.alphanumericPage = alphanumericPage
        self.shiftState = shiftState
        self.loadState = loadState
        self.historyEntries = KeyboardTemplateGrouping.sortedHistory(entries)
        self.templateGroups = KeyboardTemplateGrouping.make(entries)
        self.hasFullAccess = hasFullAccess
        self.needsInputModeSwitchKey = needsInputModeSwitchKey
        self.referenceDateOverride = referenceDateOverride
        self.insertText = insertText
        self.deleteBackward = deleteBackward
        self.pasteboardProvider = pasteboardProvider
        self.inboxDirectoryProvider = inboxDirectoryProvider
        self.now = now
    }

    deinit {
        loadTask?.cancel()
        flashTask?.cancel()
        statusTask?.cancel()
    }

    func loadFromSharedContainer(
        historyURL: URL? = SharedAppGroup.keyboardHistoryURL(),
        settingsURL: URL? = SharedAppGroup.keyboardSettingsURL()
    ) {
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        loadTask = Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) {
                Self.readSnapshot(historyURL: historyURL, settingsURL: settingsURL)
            }.value
            guard !Task.isCancelled, let self, self.loadGeneration == generation else { return }
            self.applySnapshot(loaded)
        }
    }

    func loadSynchronously(
        historyURL: URL?,
        settingsURL: URL?
    ) {
        loadTask?.cancel()
        loadGeneration += 1
        applySnapshot(Self.readSnapshot(historyURL: historyURL, settingsURL: settingsURL))
    }

    private struct DiskSnapshot: Sendable {
        let initialTab: KeyboardTab
        let entries: [KeyboardHistoryEntry]
        let loadState: KeyboardLoadState
    }

    private nonisolated static func readSnapshot(historyURL: URL?, settingsURL: URL?) -> DiskSnapshot {
        autoreleasepool {
            let initialTab = KeyboardSettingsFile.initialTab(from: settingsURL)
            guard let historyURL,
                  FileManager.default.fileExists(atPath: historyURL.path),
                  let history = KeyboardHistoryFile.read(from: historyURL) else {
                return DiskSnapshot(initialTab: initialTab, entries: [], loadState: .unavailable)
            }
            return DiskSnapshot(initialTab: initialTab, entries: history.entries, loadState: .loaded)
        }
    }

    private func applySnapshot(_ snapshot: DiskSnapshot) {
        selectedTab = snapshot.initialTab
        historyEntries = KeyboardTemplateGrouping.sortedHistory(snapshot.entries)
        templateGroups = KeyboardTemplateGrouping.make(snapshot.entries)
        loadState = snapshot.loadState
    }

    // MARK: - Text Insertion

    func tapEntry(_ entry: KeyboardHistoryEntry) {
        insertText(entry.text)
        flashEntry(entry.id)
    }

    func tapCharacter(_ key: String) {
        let output: String
        if alphanumericPage == .letters && shiftState.isUppercased {
            output = key.uppercased()
            if shiftState == .once {
                shiftState = .off
            }
        } else {
            output = key
        }
        insertText(output)
    }

    func tapSpace() {
        insertText(" ")
    }

    func tapReturn() {
        insertText("\n")
    }

    func tapDelete() {
        deleteBackward()
    }

    func toggleShift() {
        let current = now()
        if let previous = lastShiftTapDate,
           current.timeIntervalSince(previous) < 0.35,
           shiftState == .once {
            shiftState = .locked
            lastShiftTapDate = nil
            return
        }
        lastShiftTapDate = current
        switch shiftState {
        case .off:
            shiftState = .once
        case .once, .locked:
            shiftState = .off
        }
    }

    func switchToAlphanumeric() {
        mode = .alphanumeric
    }

    func switchToList() {
        mode = .list
    }

    // MARK: - Full Access Save

    func saveFromPasteboard() {
        guard hasFullAccess else { return }
        guard let pasteboard = pasteboardProvider() else {
            showStatus("クリップボードを読めませんでした", isError: true)
            return
        }
        switch SharedTextExtractor.extractFromPasteboard(pasteboard) {
        case .text(let text):
            saveToInbox(text: text)
        case .concealed:
            showStatus("秘密の印があるため保存しませんでした", isError: false)
        case .emptyOrUnsupported:
            showStatus("保存できる文章やリンクがありません", isError: false)
        }
    }

    func saveToInbox(text: String) {
        guard hasFullAccess else { return }
        guard let candidate = SharedTextExtractor.normalizedCandidate(text) else {
            showStatus("保存できる文章やリンクがありません", isError: false)
            return
        }
        guard let directory = inboxDirectoryProvider() else {
            showStatus("共有コンテナを開けませんでした", isError: true)
            return
        }
        do {
            _ = try SharedInbox.write(text: candidate, origin: .keyboard, createdAt: now(), to: directory)
            showStatus("保存しました", isError: false)
        } catch {
            showStatus("保存できませんでした", isError: true)
        }
    }

    func handleMemoryWarning() {
        flashTask?.cancel()
        flashTask = nil
        flashedEntryID = nil
        statusTask?.cancel()
        statusTask = nil
        statusMessage = nil
    }

    private func flashEntry(_ id: Int) {
        flashTask?.cancel()
        flashedEntryID = id
        flashTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            self?.flashedEntryID = nil
        }
    }

    func showStatus(_ message: String, isError: Bool) {
        statusTask?.cancel()
        statusMessage = KeyboardStatusBanner(message: message, isError: isError)
        statusTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.statusMessage = nil
        }
    }
}
