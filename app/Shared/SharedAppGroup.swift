import Foundation

/// Resolves the App Group identifier and shared container paths across the app and extensions.
enum SharedAppGroup {
    static let infoPlistKey = "ClipboardPlusAppGroup"
    static let keyboardHistoryFilename = "keyboard-history.json"
    static let keyboardSettingsFilename = "keyboard-settings.json"
    static let inboxDirectoryName = "inbox"

    static func identifier(in bundle: Bundle = .main) -> String? {
        guard let raw = bundle.object(forInfoDictionaryKey: infoPlistKey) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else { return nil }
        return trimmed
    }

    static func containerURL(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        // Unit test hosts must never read or write the simulator's shared App Group container unless injected.
        guard environment["XCTestConfigurationFilePath"] == nil,
              let identifier = identifier(in: bundle) else { return nil }
        return fileManager.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    static func keyboardHistoryURL(in containerURL: URL) -> URL {
        containerURL.appendingPathComponent(keyboardHistoryFilename)
    }

    static func keyboardSettingsURL(in containerURL: URL) -> URL {
        containerURL.appendingPathComponent(keyboardSettingsFilename)
    }

    static func inboxDirectoryURL(in containerURL: URL) -> URL {
        containerURL.appendingPathComponent(inboxDirectoryName, isDirectory: true)
    }

    static func keyboardHistoryURL() -> URL? {
        containerURL().map(keyboardHistoryURL(in:))
    }

    static func keyboardSettingsURL() -> URL? {
        containerURL().map(keyboardSettingsURL(in:))
    }

    static func inboxDirectoryURL() -> URL? {
        containerURL().map(inboxDirectoryURL(in:))
    }
}
