import Foundation

struct HistoryAdmission {
    enum Decision: Equatable {
        case add
        case skip(reason: String)
    }

    private(set) var previousText: String?
    private var pendingSelfCopy: String?

    mutating func receive(_ text: String) -> Decision {
        // Only the immediate readback is suppressed; later external copies count again.
        let isRepeated = pendingSelfCopy.map { $0.utf8.elementsEqual(text.utf8) } ?? false
        pendingSelfCopy = nil
        previousText = text
        return isRepeated ? .skip(reason: "直前の内容と同じ") : .add
    }

    mutating func recordSelfCopy(_ text: String) {
        previousText = text
        pendingSelfCopy = text
    }

    mutating func discardPendingSelfCopy() {
        pendingSelfCopy = nil
    }
}

