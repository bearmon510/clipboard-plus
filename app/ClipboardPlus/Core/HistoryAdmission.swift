import Foundation

struct HistoryAdmission {
    enum Decision: Equatable {
        case add
        case skip(reason: String)
    }

    private(set) var previousText: String?

    mutating func receive(_ text: String) -> Decision {
        let isRepeated = previousText == text
        previousText = text
        return isRepeated ? .skip(reason: "直前の内容と同じ") : .add
    }

    mutating func recordSelfCopy(_ text: String) {
        previousText = text
    }
}

