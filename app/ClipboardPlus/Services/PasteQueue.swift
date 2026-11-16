import Foundation

struct PasteQueueState: Equatable {
    var entryIDs: [Int] = []
    var currentIndex: Int? = nil
    var isRunning = false
    var isPaused = false
    var lastAdvance: Date? = nil
}

/// A provider load is a heuristic for a destination paste, not an OS paste notification.
/// All state changes happen on the main actor, including callbacks from provider workers.
@MainActor
final class PasteQueue {
    private(set) var state = PasteQueueState() {
        didSet { changed(state) }
    }
    private let entry: (Int) -> HistoryEntry?
    private let write: (NSItemProvider) -> Int?
    private let changeCount: () -> Int
    private let scene: () -> String
    private let changed: (PasteQueueState) -> Void
    private let log: (String, Int?, String) -> Void
    private var currentWrite: Write?
    private var timer: Timer?

    private final class Write {
        let index: Int
        var changeCount: Int?
        init(index: Int) { self.index = index }
    }

    init(entry: @escaping (Int) -> HistoryEntry?, write: @escaping (NSItemProvider) -> Int?,
         changeCount: @escaping () -> Int, scene: @escaping () -> String,
         changed: @escaping (PasteQueueState) -> Void,
         log: @escaping (String, Int?, String) -> Void) {
        self.entry = entry
        self.write = write
        self.changeCount = changeCount
        self.scene = scene
        self.changed = changed
        self.log = log
    }

    deinit { timer?.invalidate() }

    func enqueue(_ value: HistoryEntry) {
        guard value.kind == .text || value.kind == .url,
              !state.entryIDs.contains(value.id) else { return }
        state.entryIDs.append(value.id)
    }

    func remove(id: Int) {
        guard let removed = state.entryIDs.firstIndex(of: id) else { return }
        let current = state.currentIndex
        state.entryIDs.remove(at: removed)
        guard !state.entryIDs.isEmpty else { stop(); return }
        guard let current else { return }
        if removed < current {
            state.currentIndex = current - 1
            // Invalidate pending callbacks whose index refers to the old list.
            if state.isRunning && !state.isPaused { writeCurrent() }
        } else if removed == current {
            currentWrite = nil
            if current >= state.entryIDs.count {
                state.currentIndex = state.entryIDs.count - 1
                finish()
            } else if state.isRunning && !state.isPaused {
                writeCurrent()
            }
        }
    }

    func reconcile(with entries: [HistoryEntry]) {
        guard !state.entryIDs.isEmpty else { return }
        let valid = Set(entries.filter { $0.kind == .text || $0.kind == .url }.map(\.id))
        for id in state.entryIDs where !valid.contains(id) { remove(id: id) }
    }

    func start() {
        guard !state.entryIDs.isEmpty else { return }
        let resuming = state.isRunning
        if !resuming { state.currentIndex = 0; state.lastAdvance = nil }
        state.isRunning = true
        state.isPaused = false
        log(resuming ? "連続貼り付けの再開" : "連続貼り付けの開始", nil, "件数=\(state.entryIDs.count)")
        installTimer()
        writeCurrent()
    }

    func advance() {
        guard state.isRunning else { start(); return }
        observePasteboard()
        if state.isPaused { start(); return }
        advance(automatic: false)
    }

    func rewind() {
        guard !state.entryIDs.isEmpty else { return }
        state.currentIndex = max(0, (state.currentIndex ?? 0) - 1)
        state.isRunning = true
        state.isPaused = false
        state.lastAdvance = Date()
        log("連続貼り付けの戻る", nil, "index=\(state.currentIndex ?? 0)")
        installTimer()
        writeCurrent()
    }

    func stop() {
        currentWrite = nil
        timer?.invalidate()
        timer = nil
        state = PasteQueueState()
        log("連続貼り付けの停止", nil, "")
    }

    func sceneDidChange(_ value: String) {
        guard state.isRunning else { return }
        if value == "background" { pause(reason: "バックグラウンド") }
        if value == "active" { start() }
    }

    func observePasteboard() {
        guard state.isRunning, !state.isPaused, let count = currentWrite?.changeCount else { return }
        if count != changeCount() { pause(reason: "クリップボードの変更") }
    }

    private func pause(reason: String) {
        guard state.isRunning, !state.isPaused else { return }
        state.isPaused = true
        currentWrite = nil
        log("連続貼り付けの一時停止", nil, "理由=\(reason); index=\(state.currentIndex ?? 0)")
    }

    private func installTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.observePasteboard() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func writeCurrent() {
        guard state.isRunning, let index = state.currentIndex, state.entryIDs.indices.contains(index) else { return }
        guard scene() != "background" else { pause(reason: "バックグラウンド"); return }
        let id = state.entryIDs[index]
        guard let value = entry(id), value.kind == .text || value.kind == .url else { remove(id: id); return }
        let ticket = Write(index: index)
        currentWrite = ticket
        let provider = NSItemProvider()
        // Leave suggestedName nil: a named text provider would be classified as a file.
        let data = Data(value.text.utf8)
        let types = value.kind == .url ? ["public.utf8-plain-text", "public.url"] : ["public.utf8-plain-text"]
        for type in types {
            provider.registerDataRepresentation(forTypeIdentifier: type, visibility: .all) { [weak self] completion in
                let requestedAt = Date()
                completion(data, nil)
                // Yield until the destination's completion has returned before replacing the clipboard.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.didLoad(ticket, type: type, requestedAt: requestedAt)
                }
                return nil
            }
        }
        guard let count = write(provider) else { pause(reason: "書き込み失敗"); return }
        ticket.changeCount = count
    }

    private func didLoad(_ ticket: Write, type: String, requestedAt: Date) {
        log("連続貼り付けの読み込み要求", ticket.changeCount,
            "型=\(type); scene=\(scene()); index=\(ticket.index); 要求時刻=\(requestedAt.timeIntervalSince1970)")
        observePasteboard()
        guard state.isRunning, !state.isPaused, currentWrite === ticket,
              ticket.changeCount == changeCount(), scene() != "background" else { return }
        // Invalidate before advancing: multiple types or repeated loads consume one write only.
        currentWrite = nil
        advance(automatic: true)
    }

    private func advance(automatic: Bool) {
        guard let index = state.currentIndex else { return }
        currentWrite = nil
        state.lastAdvance = Date()
        log("連続貼り付けの次へ", nil, "自動=\(automatic); index=\(index)")
        guard index + 1 < state.entryIDs.count else { finish(); return }
        state.currentIndex = index + 1
        writeCurrent()
    }

    private func finish() {
        currentWrite = nil
        timer?.invalidate()
        timer = nil
        state.isRunning = false
        state.isPaused = false
        log("連続貼り付けの停止", nil, "理由=最後まで完了")
    }
}
