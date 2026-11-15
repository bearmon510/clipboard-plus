import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @ObservedObject var monitor: ClipboardMonitor
    /// Not observed as a whole: every log line would otherwise redraw this screen.
    let log: MeasurementLog
    @State private var logHasError = false
    @StateObject private var pictureInPicture: PictureInPictureController
    @AppStorage("pinnedSectionCollapsed") private var pinnedCollapsed = false
    @State private var showSettings = false
    @State private var confirmHistoryClear = false
    @State private var searchText: String
    @State private var filter = HistoryFilter.all
    @State private var detailEntry: HistoryEntry?
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?
    @State private var deletion: HistoryDeletion?
    @State private var undoTask: Task<Void, Never>?
    @State private var copiedID: Int?
    @State private var copiedTask: Task<Void, Never>?
    @State private var isDropTargeted = false
    @State private var captureSource: CaptureSource?
    @State private var showCaptureGuide = false

    /// `initialSearch` lets previews and screenshot tests open the screen mid-search.
    init(monitor: ClipboardMonitor, log: MeasurementLog, initialSearch: String = "") {
        self.monitor = monitor
        self.log = log
        _pictureInPicture = StateObject(wrappedValue: PictureInPictureController(monitor: monitor))
        _searchText = State(initialValue: initialSearch)
    }

    /// The search term without surrounding spaces, as used for filtering and highlighting.
    private var query: String { HistoryFilter.normalized(searchText) }

    /// Pinned items get their own section only in the plain, unfiltered list.
    private var separatesPinned: Bool { filter == .all && query.isEmpty }

    var body: some View {
        screen
            .sheet(isPresented: $showCaptureGuide) { CaptureGuideView() }
            .fullScreenCover(item: $captureSource) { source in
                CaptureView(
                    source: source,
                    onText: { monitor.saveCaptured(text: $0) },
                    onImage: { data in
                        monitor.saveCaptured(pngData: data)
                        showToast("切り取った画像を保存してコピーしました")
                    },
                    onClose: { captureSource = nil }
                )
            }
            // A shortcut delivers its screenshot here. Other sheets close so the picture can open.
            .onReceive(CaptureInbox.shared.$pending) { pending in
                guard let pending else { return }
                CaptureInbox.shared.pending = nil
                let wasPresenting = showSettings || showCaptureGuide || detailEntry != nil
                showSettings = false
                showCaptureGuide = false
                detailEntry = nil
                if wasPresenting {
                    // A new cover cannot open while another sheet is still closing.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { captureSource = pending }
                } else {
                    captureSource = pending
                }
            }
    }

    private var screen: some View {
        VStack(spacing: 0) {
            topBar
            statusStrip
            filterBar
            history
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.page.ignoresSafeArea())
        .overlay(alignment: .bottom) { bottomOverlay }
        .overlay { dropOverlay }
        .tint(Theme.accent)
        .contentShape(Rectangle())
        .onDrop(of: HistoryImageLoader.contentTypes, isTargeted: $isDropTargeted) { providers, _ in
            monitor.receiveDropped(providers, receivedAt: Date())
        }
        .onAppear {
            updateScene(scenePhase)
            monitor.pendingDeletion { showUndo($0) }
        }
        .onChange(of: scenePhase) { _, phase in
            updateScene(phase)
            if phase == .active { monitor.pendingDeletion { showUndo($0) } }
        }
        .onReceive(log.$errorMessage) { logHasError = $0 != nil }
        .sheet(isPresented: $showSettings) {
            SettingsView(monitor: monitor, log: log, pictureInPicture: pictureInPicture)
        }
        .sheet(item: $detailEntry) { entry in detail(entry) }
        .confirmationDialog("履歴を全消去しますか？", isPresented: $confirmHistoryClear, titleVisibility: .visible) {
            Button("ピン留めを残して消去", role: .destructive) {
                monitor.deleteAllHistory(includePinned: false) { showUndo($0) }
            }
            Button("ピン留めも含めてすべて消去", role: .destructive) {
                monitor.deleteAllHistory(includePinned: true) { showUndo($0) }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("5秒間は「元に戻す」で取り消せます。")
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 2) {
            // Priority lets the field take the width first; the spacer only fills a wide window.
            searchField.frame(maxWidth: 560).layoutPriority(1)
            Spacer(minLength: 4)
            recordingButton
            if pictureInPicture.isSupported { pictureInPictureButton }
            moreMenu
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("検索", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("検索をクリア")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, searchText.isEmpty ? 10 : 2)
        .frame(height: 40)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private var recordingButton: some View {
        Button {
            if monitor.isRecording { monitor.stop() } else { monitor.start() }
        } label: {
            Image(systemName: monitor.isRecording ? "pause.fill" : "play.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(monitor.isRecording ? Color.secondary : Color.orange)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(monitor.isRecording ? "記録を一時停止" : "記録を再開")
    }

    /// The button is a tiny screen. Once PiP is on, the live picture that feeds the
    /// PiP window sits inside it, which AVKit needs to stay visible in the window.
    private var pictureInPictureButton: some View {
        Button {
            pictureInPicture.togglePictureInPicture()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(pictureInPicture.isEnabled ? Color.black : Theme.field)
                if pictureInPicture.isEnabled {
                    PictureInPicturePreview(displayLayer: pictureInPicture.displayLayer,
                                            onReadinessChanged: pictureInPicture.sourceReadinessChanged)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                if pictureInPicture.isStarting && !pictureInPicture.isActive {
                    ProgressView().controlSize(.mini).tint(Color.white)
                } else {
                    Image(systemName: pictureInPicture.isActive ? "pip.exit" : "pip.enter")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(pictureInPicture.isEnabled ? Color.white : Theme.accent)
                }
            }
            .frame(width: 40, height: 22.5)
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(pictureInPicture.isActive ? Theme.accent : Color.primary.opacity(0.15),
                              lineWidth: pictureInPicture.isActive ? 2 : 1))
            .frame(width: 46, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(pictureInPicture.isStarting && !pictureInPicture.isActive)
        .accessibilityLabel(pictureInPicture.isActive ? "PiPを終了" : "PiPを開始")
        .accessibilityHint(pictureInPicture.isActive ? "小窓を閉じます。記録は続きます。" : "小窓を出して、ほかのアプリを使っている間も収集します。")
    }

    private var moreMenu: some View {
        Menu {
            Button("画面の切り取り…", systemImage: "crop") { showCaptureGuide = true }
            Button("設定", systemImage: "gearshape") { showSettings = true }
            Button("履歴を全消去…", systemImage: "trash", role: .destructive) {
                confirmHistoryClear = true
            }
            .disabled(monitor.entries.isEmpty)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("設定と履歴の全消去")
    }

    // MARK: Status

    private var statusStrip: some View {
        VStack(spacing: 6) {
            if !monitor.isRecording { pausedBanner }
            if pictureInPicture.isStarting && !pictureInPicture.isActive {
                statusRow("PiPを準備中です", symbol: "pip", tint: Color.secondary)
            }
            if let message = pictureInPicture.failureMessage {
                statusRow(message, symbol: "exclamationmark.triangle.fill", tint: Color.red)
            }
            if let error = monitor.storageError {
                statusRow(error, symbol: "exclamationmark.triangle.fill", tint: Color.red)
            }
            if let message = monitor.imageNotice {
                statusRow(message, symbol: "photo", tint: Color.red)
            }
            if monitor.pendingSaveCount > 0 {
                statusRow("保存待ち \(monitor.pendingSaveCount)件", symbol: "clock", tint: Color.secondary)
            }
            if logHasError {
                statusRow("計測ログにエラーがあります。設定の「開発者向け」で確認できます。",
                          symbol: "exclamationmark.triangle.fill", tint: Color.red)
            }
        }
        .padding(.horizontal, 12)
    }

    private var pausedBanner: some View {
        Button {
            monitor.start()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "pause.circle.fill")
                Text("一時停止中").fontWeight(.semibold)
                Text("コピーしても記録しません").foregroundStyle(Color.orange.opacity(0.8)).lineLimit(1)
                Spacer(minLength: 4)
                Text("再開").fontWeight(.semibold)
            }
            .font(.footnote)
            .foregroundStyle(Color.orange)
            .padding(.horizontal, 12)
            .frame(minHeight: 40)
            .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("一時停止中。タップで記録を再開")
    }

    private func statusRow(_ text: String, symbol: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.footnote)
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: Filters

    private var filterBar: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(HistoryFilter.allCases, id: \.self) { value in
                        filterChip(value)
                    }
                }
                .padding(.leading, 12)
                .padding(.trailing, 18)
            }
            // Fades the chips out at the edge instead of cutting them off.
            .mask(HStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [Color.black, Color.clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 18)
            })
            .accessibilityElement(children: .contain)
            .accessibilityLabel("表示する履歴")
            pasteButton.padding(.trailing, 12)
        }
        .padding(.top, 2)
        .padding(.bottom, 2)
    }

    private func filterChip(_ value: HistoryFilter) -> some View {
        let selected = filter == value
        return Button {
            filter = value
        } label: {
            HStack(spacing: 4) {
                if let symbol = value.symbolName {
                    Image(systemName: selected && value == .pinned ? "pin.fill" : symbol)
                        .font(.caption.weight(.semibold))
                }
                Text(value.title).font(.subheadline.weight(selected ? .semibold : .regular))
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(selected ? Theme.accent : Theme.field, in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var pasteButton: some View {
        PasteButton(supportedContentTypes: HistoryImageLoader.contentTypes) { providers in
            let receivedAt = Date()
            DispatchQueue.main.async { monitor.saveManually(providers, receivedAt: receivedAt) }
        }
        .labelStyle(.iconOnly)
        .buttonBorderShape(.capsule)
        .accessibilityLabel("今のクリップボードの内容を保存")
    }

    // MARK: History

    private var history: some View {
        GeometryReader { proxy in
            // The periodic refresh keeps labels such as "3分前" current.
            TimelineView(.periodic(from: .now, by: 20)) { context in
                historyScroll(HistoryFilter.entries(monitor.entries, filter: filter, search: query),
                              now: context.date, columnCount: EntryColumns.count(forWidth: proxy.size.width))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Takes the filtered entries as a parameter so that they are filtered once per redraw.
    private func historyScroll(_ entries: [HistoryEntry], now: Date, columnCount: Int) -> some View {
        ScrollView {
            if entries.isEmpty {
                emptyState
            } else {
                sectionList(entries, now: now, columnCount: columnCount)
            }
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private func sectionList(_ entries: [HistoryEntry], now: Date, columnCount: Int) -> some View {
        let sections = EntrySections.make(entries, separatesPinned: separatesPinned, now: now)
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(sections) { section in
                sectionHeader(section)
                if !(section.kind == .pinned && pinnedCollapsed) {
                    if columnCount == 1 {
                        // One column stays fully lazy, which matters with a long history.
                        ForEach(section.entries) { entry in
                            card(entry, section: section.kind, now: now).padding(.bottom, 10)
                        }
                    } else {
                        columns(section, count: columnCount, now: now).padding(.bottom, 10)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        // Keeps the last card clear of the undo bar.
        .padding(.bottom, 96)
    }

    /// Cards of different heights pack tightly when each column is its own stack.
    private func columns(_ section: EntrySection, count: Int, now: Date) -> some View {
        let groups = EntryColumns.split(section.entries, into: count)
        return HStack(alignment: .top, spacing: 10) {
            ForEach(groups.indices, id: \.self) { index in
                LazyVStack(spacing: 10) {
                    ForEach(groups[index]) { entry in
                        card(entry, section: section.kind, now: now)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    private func card(_ entry: HistoryEntry, section: EntrySectionKind, now: Date) -> some View {
        HistoryCard(
            entry: entry,
            thumbnailURL: entry.image.map { monitor.imageURL($0, thumbnail: true) },
            timeLabel: EntryTime.label(for: entry.lastCollectedAt, now: now,
                                       includesDay: section != .today && section != .yesterday),
            query: query,
            isCopied: copiedID == entry.id,
            onCopy: { copy(entry) },
            dragProvider: { monitor.rowProvider(entry) },
            actions: { rowActions(entry) }
        )
    }

    @ViewBuilder private func sectionHeader(_ section: EntrySection) -> some View {
        if section.kind == .pinned {
            Button {
                pinnedCollapsed.toggle()
            } label: {
                sectionTitle(section, chevron: pinnedCollapsed ? "chevron.right" : "chevron.down")
            }
            .buttonStyle(.plain)
            .accessibilityHint(pinnedCollapsed ? "ピン留めを表示します" : "ピン留めをたたみます")
        } else {
            sectionTitle(section, chevron: nil)
        }
    }

    private func sectionTitle(_ section: EntrySection, chevron: String?) -> some View {
        HStack(spacing: 6) {
            if section.kind == .pinned {
                Image(systemName: "pin.fill").font(.caption2).foregroundStyle(Color.orange)
            }
            Text(section.kind.title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            Text("\(section.entries.count)").font(.caption.weight(.medium)).foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            if let chevron {
                Image(systemName: chevron).font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 12)
        .frame(minHeight: 36, alignment: .bottom)
        .padding(.bottom, 8)
        .contentShape(Rectangle())
    }

    @ViewBuilder private func rowActions(_ entry: HistoryEntry) -> some View {
        Button("コピー", systemImage: "doc.on.doc") { copy(entry) }
        Button(entry.kind == .image ? "拡大表示" : "全文を表示", systemImage: "arrow.up.left.and.arrow.down.right") {
            detailEntry = entry
        }
        if entry.kind == .image {
            Button("文字を読み取る", systemImage: "text.viewfinder") { readText(of: entry) }
            Button("切り取る…", systemImage: "crop") { openCapture(entry) }
        }
        if entry.kind == .url, let url = URL(string: entry.text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            Button("リンクを開く", systemImage: "safari") { openURL(url) }
        }
        Button(entry.isPinned ? "ピン留めを解除" : "ピン留め", systemImage: entry.isPinned ? "pin.slash" : "pin") {
            monitor.togglePin(entry)
        }
        Divider()
        Button("削除", systemImage: "trash", role: .destructive) {
            monitor.delete(entry) { showUndo($0) }
        }
    }

    @ViewBuilder private func detail(_ entry: HistoryEntry) -> some View {
        if let image = entry.image {
            HistoryImagePreview(image: image, url: monitor.imageURL(image, thumbnail: false))
        } else {
            EntryDetailView(entry: entry) { copy(entry) }
        }
    }

    // MARK: Empty states

    @ViewBuilder private var emptyState: some View {
        if monitor.entries.isEmpty {
            VStack(spacing: 14) {
                emptySymbol("doc.on.clipboard")
                Text("コピーすると、ここに並びます").font(.title3.weight(.semibold))
                Text("ほかのアプリで文章や画像をコピーしてみてください。ここへドラッグしても保存できます。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if pictureInPicture.isSupported && !pictureInPicture.isActive {
                    pictureInPictureTip
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 48)
            .frame(maxWidth: 440)
            .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 14) {
                emptySymbol("magnifyingglass")
                Text("見つかりませんでした").font(.title3.weight(.semibold))
                Button("条件をクリア") {
                    searchText = ""
                    filter = .all
                }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
            }
            .padding(.horizontal, 28)
            .padding(.top, 48)
            .frame(maxWidth: .infinity)
        }
    }

    private func emptySymbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 38, weight: .medium))
            .foregroundStyle(Theme.accent)
            .frame(width: 92, height: 92)
            .background(Theme.accent.opacity(0.12), in: Circle())
            .accessibilityHidden(true)
    }

    private var pictureInPictureTip: some View {
        VStack(spacing: 10) {
            Text("全画面のアプリを使うときは、PiPの小窓を出しておくと、その間のコピーも収集できます。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                pictureInPicture.togglePictureInPicture()
            } label: {
                Label("PiPの小窓を出す", systemImage: "pip.enter").frame(minHeight: 28)
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .padding(.top, 8)
    }

    // MARK: Overlays

    private var bottomOverlay: some View {
        VStack(spacing: 8) {
            if let toast {
                Text(toast)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: Color.black.opacity(0.12), radius: 10, y: 3)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
            if let deletion {
                undoBar(deletion)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: toast)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: deletion)
    }

    private func undoBar(_ deletion: HistoryDeletion) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "trash").foregroundStyle(.secondary).accessibilityHidden(true)
            Text("\(deletion.count)件を削除しました").font(.subheadline)
            Spacer(minLength: 8)
            Button("元に戻す") {
                showUndo(nil)
                monitor.undo(deletion) { restored in
                    if !restored { showToast("元に戻せませんでした") }
                }
            }
            .font(.subheadline.weight(.semibold))
            .frame(minHeight: 44)
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .shadow(color: Color.black.opacity(0.12), radius: 10, y: 3)
    }

    @ViewBuilder private var dropOverlay: some View {
        if isDropTargeted {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.accent, lineWidth: 3)
                .background(Theme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(6)
                .overlay(alignment: .top) {
                    Label("ドロップして保存", systemImage: "arrow.down.doc")
                        .font(.headline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 18)
                }
                .allowsHitTesting(false)
        }
    }

    // MARK: Actions

    private func copy(_ entry: HistoryEntry) {
        monitor.copy(entry) { success in
            if success {
                showCopied(entry.id)
            } else {
                showToast("コピーできませんでした")
            }
        }
    }

    /// Opens a saved picture so that a part of it can be cut out or read.
    private func openCapture(_ entry: HistoryEntry) {
        guard let image = entry.image else { return }
        monitor.imageData(image) { data in
            guard let data, let picture = UIImage(data: data) else {
                showToast("画像を読み込めませんでした")
                return
            }
            captureSource = CaptureSource(image: picture)
        }
    }

    /// Reads all the text in a saved picture, saves it as a new item and copies it.
    private func readText(of entry: HistoryEntry) {
        guard let image = entry.image else { return }
        showToast("文字を読み取っています…")
        monitor.imageData(image) { data in
            guard let data, let picture = UIImage(data: data),
                  let pixels = CaptureSource(image: picture).image.cgImage else {
                showToast("画像を読み込めませんでした")
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try TextRecognizer.text(in: pixels) }
                DispatchQueue.main.async {
                    switch result {
                    case .success(let text) where !text.isEmpty:
                        monitor.saveCaptured(text: text)
                        showToast("文字を読み取ってコピーしました")
                    case .success:
                        showToast("文字が見つかりませんでした")
                    case .failure:
                        showToast("文字を読み取れませんでした")
                    }
                }
            }
        }
    }

    private func showCopied(_ id: Int) {
        copiedTask?.cancel()
        copiedID = id
        copiedTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            guard !Task.isCancelled else { return }
            copiedID = nil
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

    private func showToast(_ text: String) {
        toastTask?.cancel()
        toast = text
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            toast = nil
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
