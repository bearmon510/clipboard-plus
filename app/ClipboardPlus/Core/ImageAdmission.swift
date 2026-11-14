import Foundation

// Confined to HistoryStore's queue, including resets and self-copy registration.
struct ImageAdmission {
    private var selfCopy: (hash: String, changeCount: Int)?
    private var changedDuringRead: (hash: String, after: Int)?

    mutating func recordSelfCopy(hash: String, changeCount: Int) {
        changedDuringRead = nil
        selfCopy = (hash, changeCount)
    }

    mutating func reset() {
        selfCopy = nil
        changedDuringRead = nil
    }

    mutating func receive(hash: String, before: Int, after: Int) -> HistoryAdmission.Decision {
        let repeatedRead = changedDuringRead.map {
            $0.hash == hash && $0.after == before && before == after
        } ?? false
        changedDuringRead = after > before ? (hash, after) : nil
        let ownRead = selfCopy.map {
            $0.hash == hash && $0.changeCount == before && before == after
        } ?? false
        selfCopy = nil
        if ownRead { return .skip(reason: "直前の内容と同じ") }
        return repeatedRead ? .skip(reason: "読み取り中の変更を再確認") : .add
    }
}
