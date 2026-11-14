import Foundation

enum HistoryRetention: Int, CaseIterable {
    case never = 0
    case oneDay = 1
    case sevenDays = 7
    case thirtyDays = 30
    case ninetyDays = 90

    static let defaultsKey = "historyRetentionDays"
    static let defaultValue: HistoryRetention = .thirtyDays

    var displayName: String { self == .never ? "しない" : "\(rawValue)日" }
    var seconds: TimeInterval? { self == .never ? nil : TimeInterval(rawValue) * 24 * 60 * 60 }

    func cutoff(relativeTo date: Date) -> Date? {
        seconds.map { date.addingTimeInterval(-$0) }
    }

    static func load(from defaults: UserDefaults) -> HistoryRetention {
        guard let days = defaults.object(forKey: defaultsKey) as? Int,
              let value = HistoryRetention(rawValue: days) else { return defaultValue }
        return value
    }

    func save(to defaults: UserDefaults) { defaults.set(rawValue, forKey: Self.defaultsKey) }
}
