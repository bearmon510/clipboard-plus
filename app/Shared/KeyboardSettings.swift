import Foundation

/// Initial tab shown when switching to the clipboard+ keyboard extension.
enum KeyboardTab: String, Codable, CaseIterable, Identifiable {
    case history
    case templates

    static let defaultsKey = "keyboardInitialTab"
    static let defaultValue: KeyboardTab = .history

    var id: String { rawValue }
    var title: String { self == .history ? "履歴" : "テンプレート" }

    static func load(from defaults: UserDefaults) -> KeyboardTab {
        guard let raw = defaults.string(forKey: defaultsKey),
              let value = KeyboardTab(rawValue: raw) else { return defaultValue }
        return value
    }

    func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

struct KeyboardSettings: Codable, Equatable {
    static let currentVersion = 1

    let formatVersion: Int
    let initialTab: KeyboardTab
    let updatedAt: Date

    init(initialTab: KeyboardTab, updatedAt: Date = Date()) {
        self.formatVersion = Self.currentVersion
        self.initialTab = initialTab
        self.updatedAt = updatedAt
    }
}

enum KeyboardSettingsFile {
    static let filename = SharedAppGroup.keyboardSettingsFilename

    static func write(_ settings: KeyboardSettings, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(settings)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func read(from url: URL?) -> KeyboardSettings? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let settings = try? decoder.decode(KeyboardSettings.self, from: data),
              settings.formatVersion == KeyboardSettings.currentVersion else { return nil }
        return settings
    }

    static func initialTab(from url: URL?) -> KeyboardTab {
        read(from: url)?.initialTab ?? .defaultValue
    }
}
