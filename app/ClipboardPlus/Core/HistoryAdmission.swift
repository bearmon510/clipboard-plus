import Foundation

struct HistoryAdmission {
    enum Decision: Equatable {
        case add
        case skip(reason: String)
    }

    private(set) var previousText: String?
    private var pendingSelfCopy: String?
    private var latestExport: String?
    private var backupExportDigests: Set<String> = []
    private var changedDuringRead: (text: String, after: Int)?

    mutating func receive(_ text: String, before: Int? = nil, after: Int? = nil) -> Decision {
        let repeatedRead = changedDuringRead.map {
            $0.after == before && before == after && $0.text.utf8.elementsEqual(text.utf8)
        } ?? false
        // Only the next stable read at the observed endpoint can be explained by the earlier race.
        changedDuringRead = nil
        if let before, let after, after > before {
            changedDuringRead = (text, after)
        }
        // Only the immediate readback is suppressed; later external copies count again.
        let isRepeated = pendingSelfCopy.map { $0.utf8.elementsEqual(text.utf8) } ?? false
        pendingSelfCopy = nil
        previousText = text
        if latestExport.map({ $0.utf8.elementsEqual(text.utf8) }) == true
            || (!backupExportDigests.isEmpty && backupExportDigests.contains(HistoryBackup.digest(Data(text.utf8))))
            || text.hasPrefix("CLIPPLUS\0\0\0\0\0\0\0\u{1}")
            || text.hasPrefix("CLIPPLUS\0\0\0\0\0\0\0\u{2}") {
            return .skip(reason: "このアプリが書き出した内容")
        }
        if isRepeated { return .skip(reason: "直前の内容と同じ") }
        return repeatedRead ? .skip(reason: "読み取り中の変更を再確認") : .add
    }

    mutating func recordExport(_ text: String) {
        latestExport = text
    }

    mutating func recordBackup(manifestDigest: String, url: URL) {
        // The share sheet receives a file URL, never individual original texts or image bytes.
        // Suppress the exact manifest and URL if a share extension puts either onto the pasteboard.
        backupExportDigests = [manifestDigest, HistoryBackup.digest(Data(url.absoluteString.utf8)),
                               HistoryBackup.digest(Data(url.path.utf8))]
    }

    mutating func recordSelfCopy(_ text: String) {
        changedDuringRead = nil
        previousText = text
        pendingSelfCopy = text
    }

    mutating func discardPendingSelfCopy() {
        pendingSelfCopy = nil
        changedDuringRead = nil
    }
}

