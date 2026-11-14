import Foundation

struct LogRecord: Identifiable {
    let id: Int
    let fileLine: String
    let primaryText: String
    let secondaryText: String
}

struct LogEventSequence {
    let sessionID: String
    private(set) var nextEventNumber = 1

    init(sessionID: String = UUID().uuidString) {
        self.sessionID = sessionID
    }

    mutating func makeRecord(_ event: MeasurementEvent, formatter: LogLineFormatter) -> LogRecord {
        let number = nextEventNumber
        nextEventNumber += 1
        let line = formatter.format(event, sessionID: sessionID, eventNumber: number)
        let fields = line.components(separatedBy: "\t")
        let localTime = String(fields[0].dropFirst(11).prefix(12))
        return LogRecord(
            id: number,
            fileLine: line,
            primaryText: "\(localTime)・\(event.kind)・履歴\(event.historyNumber.map { "#\($0)" } ?? "-")",
            secondaryText: "イベント#\(number) · changeCount=\(event.changeCount) · scene=\(event.scene) · 文字数=\(event.characterCount.map { String($0) } ?? "-") · "
                + fields.dropFirst(8).joined(separator: " · ")
        )
    }
}

struct PendingLogLines {
    private(set) var records: [LogRecord] = []

    mutating func append(_ record: LogRecord) {
        records.append(record)
    }

    mutating func persist(using write: (Data) throws -> Void) rethrows {
        try write(data)
        records.removeAll()
    }

    func exportData(savedData: Data) -> Data {
        guard !records.isEmpty else { return savedData }
        var result = savedData
        if !result.isEmpty, result.last != 0x0A { result.append(0x0A) }
        result.append(Data("# ファイルへ保存できなかった行（再送による重複は起動IDとイベント番号で照合）\n".utf8))
        result.append(data)
        return result
    }

    private var data: Data {
        Data(records.map { $0.fileLine + "\n" }.joined().utf8)
    }
}
