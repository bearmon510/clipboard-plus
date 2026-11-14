import Foundation

struct HistoryEntry: Identifiable {
    let id: Int
    let savedAt: Date
    let text: String

    var characterCount: Int { text.count }
}

