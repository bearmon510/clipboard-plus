import Foundation

struct MeasurementEvent {
    var timestamp = Date()
    let kind: String
    let changeCount: Int
    let scene: String
    var characterCount: Int?
    var historyNumber: Int?
    var details = ""
    var text: String?
}

struct LogLineFormatter {
    var includeTextPreview = false
    var timeZone: TimeZone = .current

    func format(_ event: MeasurementEvent, sessionID: String, eventNumber: Int) -> String {
        var fields = [
            timestamp(event.timestamp),
            escape(sessionID),
            String(eventNumber),
            escape(event.kind),
            String(event.changeCount),
            escape(event.scene),
            event.characterCount.map { String($0) } ?? "-",
            event.historyNumber.map { String($0) } ?? "-",
            escape(event.details)
        ]
        if includeTextPreview, let text = event.text {
            fields.append("冒頭20文字=" + escape(String(text.prefix(20))))
        }
        return fields.joined(separator: "\t")
    }

    func timestamp(_ date: Date) -> String {
        dateFormatter("yyyy-MM-dd'T'HH:mm:ss.SSSxxx").string(from: date)
    }

    private func dateFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\u{0085}", with: "\\u{0085}")
            .replacingOccurrences(of: "\u{2028}", with: "\\u{2028}")
            .replacingOccurrences(of: "\u{2029}", with: "\\u{2029}")
    }
}

