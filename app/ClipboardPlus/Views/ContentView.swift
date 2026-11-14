import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var monitor: ClipboardMonitor
    @ObservedObject var log: MeasurementLog
    @State private var showSettings = false
    @State private var confirmHistoryClear = false
    @State private var searchText = ""
    @State private var pinnedOnly = false
    @State private var notice: String?
    @State private var noticeTask: Task<Void, Never>?
    @State private var deletion: HistoryDeletion?
    @State private var undoTask: Task<Void, Never>?
    @State private var didShowResume = false
    @State private var isDropTargeted = false

    private var visibleEntries: [HistoryEntry] {
        monitor.entries.filter {
            (!pinnedOnly || $0.isPinned) &&
                (searchText.isEmpty || $0.text.range(of: searchText, options: .caseInsensitive) != nil)
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            header
            controls
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("履歴を検索", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !searchText.isEmpty {
                    Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .accessibilityLabel("検索をクリア")
                        .frame(minWidth: 44, minHeight: 44)
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal)
            Picker("表示する履歴", selection: $pinnedOnly) {
                Text("すべて").tag(false)
                Text("ピン留め").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            HStack {
                Text(notice ?? "履歴 \(visibleEntries.count)件")
                Spacer()
                Text("新しい順")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            if monitor.pendingSaveCount > 0 {
                Text("保存待ち \(monitor.pendingSaveCount)件")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            }
            if let error = monitor.storageError {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal)
            }
            history
            if let deletion {
                HStack {
                    Text("\(deletion.count)件を削除しました")
                    Spacer()
                    Button("元に戻す") {
                        showUndo(nil)
                        monitor.undo(deletion) { restored in
                            if !restored { showNotice("元に戻せませんでした") }
                        }
                    }
                    .frame(minHeight: 44)
                }
                .font(.subheadline)
                .padding(.horizontal)
                .background(.regularMaterial)
            }
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .contentShape(Rectangle())
        .onDrop(of: DroppedTextLoader.contentTypes, isTargeted: $isDropTargeted) { providers, _ in
            monitor.receiveDropped(providers, receivedAt: Date())
        }
        .onAppear {
            updateScene(scenePhase)
            monitor.pendingDeletion { showUndo($0) }
            if monitor.resumedAtLaunch && !didShowResume {
                didShowResume = true
                showNotice("記録を再開しました（起動時）")
            }
        }
        .onChange(of: scenePhase) { _, phase in
            updateScene(phase)
            if phase == .active { monitor.pendingDeletion { showUndo($0) } }
        }
        .sheet(isPresented: $showSettings) { SettingsView(monitor: monitor, log: log) }
        .confirmationDialog("履歴を全消去しますか？", isPresented: $confirmHistoryClear, titleVisibility: .visible) {
            Button("ピン留めを残して消去", role: .destructive) {
                monitor.deleteAllHistory(includePinned: false) { showUndo($0) }
            }
            Button("ピン留めも含めてすべて消去", role: .destructive) {
                monitor.deleteAllHistory(includePinned: true) { showUndo($0) }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("5秒間は「元に戻す」で取り消せます。計測ログとクリップボードの内容は残ります。")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("clipboard+").font(.headline)
                Text(monitor.isRecording ? "記録中" : "記録停止中").font(.subheadline)
            }
            Spacer(minLength: 4)
            if log.errorMessage != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityLabel("計測ログにエラーがあります。設定から確認できます")
            }
            Menu {
                Button("設定", systemImage: "slider.horizontal.3") { showSettings = true }
                Button("履歴を全消去…", systemImage: "trash", role: .destructive) {
                    confirmHistoryClear = true
                }
                .disabled(monitor.entries.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle").font(.title2)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("設定と履歴の全消去")
        }
        .padding(.horizontal)
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { recordingButton; pasteButton }
            VStack(spacing: 4) { recordingButton; pasteButton }
        }
        .padding(.horizontal)
    }

    private var recordingButton: some View {
        Button(monitor.isRecording ? "記録を停止" : "記録を開始") {
            if monitor.isRecording { monitor.stop() } else { monitor.start() }
        }
        .buttonStyle(.borderedProminent)
        .frame(minHeight: 44)
    }

    private var pasteButton: some View {
        PasteButton(payloadType: String.self) { strings in
            let receivedAt = Date()
            DispatchQueue.main.async { monitor.saveManually(strings, receivedAt: receivedAt) }
        }
        .labelStyle(.titleAndIcon)
        .frame(minWidth: 100, minHeight: 44)
        .accessibilityLabel("文章を手動保存")
    }

    private var history: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if visibleEntries.isEmpty {
                    Text(monitor.entries.isEmpty
                         ? "記録の開始後にコピーした文章を収集します。開始前の文章は「ペースト」で保存できます。ここへ文章をドロップしても保存できます。"
                         : "条件に一致する履歴がありません。")
                        .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 12)
                        .frame(maxWidth: .infinity, minHeight: 100)
                }
                ForEach(visibleEntries, id: \.id) { entry in
                    VStack(spacing: 0) {
                        HStack(spacing: 8) {
                            Button {
                                monitor.copy(entry)
                                showNotice("コピーしました")
                            } label: { HistoryRow(entry: entry) }
                            .buttonStyle(.plain)
                            .onDrag { DroppedTextLoader.rowProvider(text: entry.text) }
                            Menu {
                                rowActions(entry)
                            } label: {
                                Image(systemName: "ellipsis")
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel("履歴の操作")
                        }
                        .padding(.vertical, 6)
                        .contextMenu { rowActions(entry) }
                        Divider()
                    }
                }
                Text("タップでコピー、ドラッグで持ち出し。「⋯」または長押しでピン留め・削除。文章をドロップすると保存します。自動収集では他のアプリからのペースト許可を求められる場合があります。")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            }
            .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .overlay(alignment: .top) {
                        Text("ドロップして保存")
                            .font(.headline)
                            .padding(12)
                            .background(.regularMaterial, in: Capsule())
                            .padding(.top, 12)
                    }
                    .allowsHitTesting(false)
            }
        }
        // Stable row IDs and no scroll-to or insertion animation limit unsolicited movement.
        .transaction { $0.animation = nil }
    }

    @ViewBuilder
    private func rowActions(_ entry: HistoryEntry) -> some View {
        Button(entry.isPinned ? "ピン留めを解除" : "ピン留め", systemImage: entry.isPinned ? "pin.slash" : "pin") {
            monitor.togglePin(entry)
        }
        Button("削除", systemImage: "trash", role: .destructive) {
            monitor.delete(entry) { showUndo($0) }
        }
    }

    private func showUndo(_ value: HistoryDeletion?) {
        undoTask?.cancel()
        deletion = value
        guard let value else { return }
        let remaining = value.expiresAt.timeIntervalSinceNow
        guard remaining > 0 else { deletion = nil; return }
        undoTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            guard !Task.isCancelled else { return }
            deletion = nil
        }
    }

    private func showNotice(_ text: String) {
        noticeTask?.cancel()
        notice = text
        noticeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            notice = nil
        }
    }

    private func updateScene(_ phase: ScenePhase) {
        switch phase {
        case .active: monitor.updateScene("active")
        case .inactive: monitor.updateScene("inactive")
        case .background: monitor.updateScene("background")
        @unknown default: monitor.updateScene("inactive")
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if entry.isPinned {
                    Image(systemName: "pin.fill").accessibilityLabel("ピン留め")
                }
                Text(entry.lastCollectedAt, format: .dateTime.month().day().hour().minute().second())
                Spacer()
                Text("\(entry.collectionCount)回")
            }
            .font(.caption).foregroundStyle(.secondary)
            if let domain = entry.domain {
                Text(domain).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(entry.text.isEmpty ? "（空文字）" : String(entry.text.prefix(160)))
                .font(.body).lineLimit(3).multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityHint("タップでコピー。ドラッグで他のアプリへ持ち出せます。")
    }
}
