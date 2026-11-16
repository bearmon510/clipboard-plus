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
    /// Hidden behind the developer settings since 0.11.0; see `CaptureSettings.directCaptureKey`.
    @AppStorage(CaptureSettings.directCaptureKey) private var directCaptureEnabled = false
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
    @StateObject private var screenCapture: ScreenCaptureController
    @StateObject private var screenshots: ScreenshotWatcher
    @State private var capture: CaptureRequest?
    /// The mode whose button is waiting for a picture of the screen.
    @State private var capturePending: CaptureMode?
    @State private var showCaptureGuide = false
    /// A capture waiting for an open sheet to finish closing. Opened from the sheet's onDismiss.
    @State private var queuedCapture: CaptureRequest?
    /// A direct capture asked for from outside, waiting for the app to be active and uncovered.
    @State private var queuedDirectMode: CaptureMode?
    /// The writing sheet: a new pinned text, or a change to an item's name and text.
    @State private var editor: EntryEditorView.Mode?
    @State private var showPinOrder = false

    /// A still picture to choose from, and what to do with the chosen part.
    struct CaptureRequest: Identifiable {
        let id = UUID()
        let source: CaptureSource
        let mode: CaptureMode
        /// The Photos asset when the picture came from an iPad screenshot.
        var screenshotID: String? = nil
    }

    /// `initialSearch` lets previews and screenshot tests open the screen mid-search.
    init(monitor: ClipboardMonitor, log: MeasurementLog, initialSearch: String = "") {
        self.monitor = monitor
        self.log = log
        _pictureInPicture = StateObject(wrappedValue: PictureInPictureController(monitor: monitor))
        _screenCapture = StateObject(wrappedValue: ScreenCaptureController(log: log))
        _screenshots = StateObject(wrappedValue: ScreenshotWatcher(log: log))
        _searchText = State(initialValue: initialSearch)
    }

    /// The search term without surrounding spaces, as used for filtering and highlighting.
    private var query: String { HistoryFilter.normalized(searchText) }

    /// Pinned items get their own section, in the user's order, in the plain list and under the
    /// ピン留め filter. While searching, everything follows the history order.
    private var separatesPinned: Bool { (filter == .all || filter == .pinned) && query.isEmpty }

    private var pinnedEntries: [HistoryEntry] {
        HistoryFilter.entries(monitor.entries, filter: .pinned, search: "")
    }

    /// Any sheet over the history. A capture from outside waits for it to close.
    private var isPresentingSheet: Bool {
        showSettings || showCaptureGuide || detailEntry != nil || editor != nil || showPinOrder
    }

    private func closeSheets() {
        showSettings = false
        showCaptureGuide = false
        detailEntry = nil
        editor = nil
        showPinOrder = false
    }

    var body: some View {
        screen
            .sheet(isPresented: $showCaptureGuide, onDismiss: presentQueuedCapture) { CaptureGuideView() }
            .fullScreenCover(item: $capture) { request in
                CaptureView(
                    source: request.source,
                    mode: request.mode,
                    // Each callback checks that its request is still the one on screen, so that
                    // a slow text reading never saves into, or closes, a newer capture.
                    onText: { text in
                        guard capture?.id == request.id else { return }
                        monitor.saveCaptured(text: text)
                        screenCapture.noteCaptureUsed()
                        if let id = request.screenshotID { screenshots.markUsed(id) }
                        showToast("文字をコピーしました：" + Self.toastPreview(text))
                    },
                    onImage: { data in
                        guard capture?.id == request.id else { return }
                        monitor.saveCaptured(pngData: data)
                        screenCapture.noteCaptureUsed()
                        if let id = request.screenshotID { screenshots.markUsed(id) }
                        showToast("画像をコピーしました")
                    },
                    onClose: { if capture?.id == request.id { capture = nil } }
                )
            }
            // Shortcuts, Siri and Control Center deliver here: a screenshot to cut out, or a
            // request to take the screen directly.
            .onReceive(CaptureInbox.shared.$request) { request in
                guard let request else { return }
                // As below, clear it on the next turn, because @Published stores it after announcing.
                DispatchQueue.main.async {
                    if CaptureInbox.shared.request?.id == request.id { CaptureInbox.shared.request = nil }
                }
                if let source = request.source {
                    openFromOutside(CaptureRequest(source: source,
                                                   mode: request.mode ?? CaptureSettings.screenshotMode()))
                } else if let mode = request.mode {
                    startFromOutside(mode)
                }
            }
            // An iPad screenshot, picked up from Photos when that experiment is on.
            .onReceive(screenshots.$delivered) { delivered in
                guard let delivered else { return }
                // @Published announces a value before storing it, so clearing it right here
                // would be overwritten. Clear it on the next turn, and only if it is unchanged.
                DispatchQueue.main.async {
                    if screenshots.delivered?.id == delivered.id { screenshots.delivered = nil }
                }
                openFromOutside(CaptureRequest(source: CaptureSource(image: delivered.image),
                                               mode: CaptureSettings.screenshotMode(),
                                               screenshotID: delivered.id))
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
            // The instant (burst) capture asked for permission every time on device, so
            // anyone who chose it in 0.9.0 goes back to continuous capture.
            screenCapture.setStrategy(.continuous)
            updateScene(scenePhase)
            monitor.pendingDeletion { showUndo($0) }
        }
        .onChange(of: scenePhase) { _, phase in
            updateScene(phase)
            // A capture queued behind a sheet is dropped when the app leaves the screen.
            if phase == .background {
                queuedCapture = nil
                queuedDirectMode = nil
            }
            if phase == .active {
                monitor.pendingDeletion { showUndo($0) }
                // Marks the system permission screen going away, so that the first capture
                // after approval shows the screen rather than the permission dialog.
                screenCapture.sceneDidActivate()
            }
            // Only leaving the screen stops it: a side window turns inactive whenever
            // another app is touched, and the system picker does the same.
            screenCapture.sceneDidChange(isActive: phase != .background)
            screenshots.sceneDidChange(isActive: phase != .background)
            // After the capture side has heard that the scene is active, or it would refuse.
            if phase == .active { startQueuedDirectCapture() }
        }
        .onChange(of: directCaptureEnabled) { _, enabled in
            guard !enabled else { return }
            queuedDirectMode = nil
            screenCapture.stop(reason: "開発者向けの設定でオフ")
        }
        .onReceive(log.$errorMessage) { logHasError = $0 != nil }
        .sheet(isPresented: $showSettings, onDismiss: presentQueuedCapture) {
            SettingsView(monitor: monitor, log: log, pictureInPicture: pictureInPicture,
                         screenCapture: screenCapture, screenshots: screenshots)
        }
        .sheet(item: $detailEntry, onDismiss: presentQueuedCapture) { entry in detail(entry) }
        .sheet(item: $editor, onDismiss: presentQueuedCapture) { mode in
            EntryEditorView(monitor: monitor, mode: mode) { showToast($0) }
        }
        .sheet(isPresented: $showPinOrder, onDismiss: presentQueuedCapture) {
            PinOrderView(pinned: pinnedEntries) { monitor.reorderPins($0) }
        }
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
            if directCaptureEnabled {
                captureButton(.text)
                captureButton(.image)
            }
            // PiP is set aside. Its button appears only when turned on under 開発者向け.
            if pictureInPicture.isSupported && pictureInPicture.isEnabled { pictureInPictureButton }
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

    /// Icon over a short word, so that the two capture buttons read clearly in a narrow window.
    private func captureButton(_ mode: CaptureMode) -> some View {
        let waiting = capturePending == mode
        return Button {
            startCapture(mode)
        } label: {
            VStack(spacing: 1) {
                ZStack {
                    if waiting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: mode.symbolName).font(.body.weight(.semibold))
                    }
                }
                .frame(height: 22)
                Text(mode.title).font(.caption2.weight(.semibold))
            }
            .foregroundStyle(Theme.accent)
            .frame(width: 46, height: 44)
            .overlay(alignment: .topTrailing) {
                // Shows that the screen is being taken in, so that it is never a secret.
                if screenCapture.state == .running {
                    Circle().fill(Color.green).frame(width: 7, height: 7).offset(x: -6, y: 3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(capturePending != nil)
        .accessibilityLabel(mode == .text ? "文字で切り取る" : "画像で切り取る")
        .accessibilityHint("画面を止めて範囲を選ぶと、クリップボードにコピーします")
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
            if monitor.isRecording {
                Button("記録を一時停止", systemImage: "pause") { monitor.stop() }
            } else {
                Button("記録を再開", systemImage: "play") { monitor.start() }
            }
            if screenCapture.state != .idle && screenCapture.state != .unsupported {
                Button("画面の取り込みを止める", systemImage: "stop.circle") {
                    screenCapture.stop(reason: "メニューから停止")
                }
            }
            Button("文章を書いてピン留め", systemImage: "square.and.pencil") { editor = .create }
            if pinnedEntries.count > 1 {
                Button("ピン留めを並べ替え", systemImage: "arrow.up.arrow.down") { showPinOrder = true }
            }
            Button("切り取りの使い方", systemImage: "questionmark.circle") { showCaptureGuide = true }
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
        .accessibilityLabel("その他の操作")
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
            if let message = monitor.fileNotice {
                statusRow(message, symbol: "doc", tint: Color.red)
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
        // Keeps the last card clear of the undo bar and the sequential paste bar.
        .padding(.bottom, monitor.pasteQueue.entryIDs.isEmpty ? 96 : 220)
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
        let queue = monitor.pasteQueue
        let place = queue.entryIDs.firstIndex(of: entry.id)
        return HistoryCard(
            entry: entry,
            thumbnailURL: entry.image.map { monitor.imageURL($0, thumbnail: true) },
            timeLabel: EntryTime.label(for: entry.lastCollectedAt, now: now,
                                       includesDay: section != .today && section != .yesterday),
            query: query,
            isCopied: copiedID == entry.id,
            onCopy: { copy(entry) },
            dragProvider: { monitor.rowProvider(entry) },
            queueNumber: place.map { $0 + 1 },
            isQueueCurrent: place != nil && queue.isRunning && queue.currentIndex == place,
            actions: { rowActions(entry) }
        )
    }

    @ViewBuilder private func sectionHeader(_ section: EntrySection) -> some View {
        if section.kind == .pinned {
            HStack(alignment: .bottom, spacing: 0) {
                Button {
                    pinnedCollapsed.toggle()
                } label: {
                    sectionTitle(section, chevron: pinnedCollapsed ? "chevron.right" : "chevron.down")
                }
                .buttonStyle(.plain)
                .accessibilityHint(pinnedCollapsed ? "ピン留めを表示します" : "ピン留めをたたみます")
                if section.entries.count > 1 {
                    pinnedAction("arrow.up.arrow.down", label: "ピン留めを並べ替え") { showPinOrder = true }
                }
                pinnedAction("plus", label: "文章を書いてピン留めに追加") { editor = .create }
            }
        } else {
            sectionTitle(section, chevron: nil)
        }
    }

    private func pinnedAction(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 44, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.bottom, -2)
        .accessibilityLabel(label)
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
        switch entry.kind {
        case .image:
            Button("拡大表示", systemImage: "arrow.up.left.and.arrow.down.right") { detailEntry = entry }
        case .file:
            Button("プレビュー", systemImage: "eye") { detailEntry = entry }
        case .text, .url:
            Button("全文を表示", systemImage: "arrow.up.left.and.arrow.down.right") { detailEntry = entry }
        }
        if entry.kind == .image {
            Button("全体の文字を読み取る", systemImage: "doc.text.viewfinder") { readText(of: entry) }
            Button("文字で切り取る…", systemImage: CaptureMode.text.symbolName) { openCapture(entry, mode: .text) }
            Button("画像で切り取る…", systemImage: CaptureMode.image.symbolName) { openCapture(entry, mode: .image) }
        }
        if entry.kind == .url, let url = URL(string: entry.text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            Button("リンクを開く", systemImage: "safari") { openURL(url) }
        }
        Button(entry.isPinned ? "ピン留めを解除" : "ピン留め", systemImage: entry.isPinned ? "pin.slash" : "pin") {
            monitor.togglePin(entry)
        }
        if entry.kind == .text || entry.kind == .url {
            Button("編集…", systemImage: "pencil") { editor = .edit(entry) }
            if monitor.pasteQueue.entryIDs.contains(entry.id) {
                Button("連続貼り付けから外す", systemImage: "minus.circle") {
                    monitor.removeFromPasteQueue(id: entry.id)
                }
            } else {
                Button("連続貼り付けに追加", systemImage: "text.badge.plus") { monitor.enqueueForPaste(entry) }
            }
        } else {
            Button(entry.displayTitle == nil ? "名前を付ける…" : "名前を変更…", systemImage: "tag") {
                editor = .edit(entry)
            }
        }
        Divider()
        Button("削除", systemImage: "trash", role: .destructive) {
            monitor.delete(entry) { showUndo($0) }
        }
    }

    @ViewBuilder private func detail(_ entry: HistoryEntry) -> some View {
        if let image = entry.image {
            HistoryImagePreview(image: image, url: monitor.imageURL(image, thumbnail: false))
        } else if let file = entry.file {
            FilePreview(file: file, url: monitor.fileURL(file)) { copy(entry) }
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
                Text("ほかのアプリで文章や画像、ファイルをコピーしてみてください。ここへドラッグしても保存できます。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                captureTip
            }
            .padding(.horizontal, 28)
            .padding(.top, 48)
            .frame(maxWidth: 440)
            .frame(maxWidth: .infinity)
        } else if filter == .pinned && query.isEmpty {
            VStack(spacing: 14) {
                emptySymbol("pin")
                Text("ピン留めはまだありません").font(.title3.weight(.semibold))
                Text("よく使う文を書いておくと、押すだけでコピーできます。履歴のメニューからピン留めすることもできます。ピン留めは自動では消えません。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("文章を書いて追加", systemImage: "square.and.pencil") { editor = .create }
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
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

    private var captureTip: some View {
        VStack(spacing: 10) {
            Label("スクリーンショットから切り取る", systemImage: "camera.viewfinder")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
            Text("「ショートカット」でスクリーンショットを撮り、clipboard+の「画面を切り取る」に渡すと、範囲を選んで文字か画像をコピーできます。AssistiveTouchに割り当てると、1回押すだけで始められます。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("使い方") { showCaptureGuide = true }
                .font(.footnote.weight(.semibold))
                .frame(minHeight: 44)
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
            if !monitor.pasteQueue.entryIDs.isEmpty {
                let queue = monitor.pasteQueue
                PasteQueueBar(
                    state: queue,
                    entries: queue.entryIDs.compactMap { id in monitor.entries.first { $0.id == id } },
                    onStart: { monitor.startPasteQueue() },
                    onNext: { monitor.advancePasteQueue() },
                    onBack: { monitor.rewindPasteQueue() },
                    onStop: { monitor.stopPasteQueue() }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
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
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: monitor.pasteQueue.entryIDs.isEmpty)
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

    /// Freezes the screen and opens the capture mode. Without ScreenCaptureKit, explains the
    /// screenshot route instead.
    private func startCapture(_ mode: CaptureMode) {
        guard capturePending == nil else { return }
        guard screenCapture.isSupported else {
            showCaptureGuide = true
            return
        }
        capturePending = mode
        screenCapture.requestFrame { result in
            capturePending = nil
            switch result {
            case .success(let image):
                // Something else may have opened while the screen was being taken in.
                guard capture == nil, queuedCapture == nil else { return }
                capture = CaptureRequest(source: CaptureSource(image: image), mode: mode)
            case .failure(.unsupported):
                showCaptureGuide = true
            case .failure(.declined):
                showToast("画面の取り込みが許可されませんでした")
            case .failure(.timeout):
                showToast("画面を取り込めませんでした。もう一度お試しください")
            case .failure(.failed):
                showToast("画面を取り込めませんでした")
            }
        }
    }

    /// Opens a picture that arrived from outside the screen: a shortcut or a screenshot.
    /// Nothing replaces a capture already on screen or one being taken in. When a sheet is
    /// open, the picture waits until that sheet has finished closing.
    private func openFromOutside(_ request: CaptureRequest) {
        guard capture == nil, capturePending == nil else { return }
        guard isPresentingSheet else {
            queuedCapture = nil
            capture = request
            return
        }
        // Only the newest arrival waits; an older one is simply replaced.
        queuedCapture = request
        queuedDirectMode = nil
        closeSheets()
    }

    /// Called when a sheet has finished closing.
    private func presentQueuedCapture() {
        if let request = queuedCapture {
            queuedCapture = nil
            guard capture == nil else { return }
            capture = request
            return
        }
        startQueuedDirectCapture()
    }

    /// Starts taking the screen for Shortcuts, Siri or Control Center. The app has usually just
    /// come to the front, so this waits until it is active and no sheet covers it.
    private func startFromOutside(_ mode: CaptureMode) {
        guard capture == nil, capturePending == nil else { return }
        // A shortcut or control made in 0.10.0 may still ask for the hidden direct capture.
        guard directCaptureEnabled else {
            openFromOutsideGuide()
            return
        }
        queuedCapture = nil
        queuedDirectMode = mode
        if isPresentingSheet {
            closeSheets()
            return
        }
        startQueuedDirectCapture()
    }

    /// Explains the screenshot shortcut instead, unless something else already covers the screen.
    private func openFromOutsideGuide() {
        guard !isPresentingSheet else { return }
        showCaptureGuide = true
    }

    private func startQueuedDirectCapture() {
        guard directCaptureEnabled else {
            queuedDirectMode = nil
            return
        }
        guard let mode = queuedDirectMode, scenePhase == .active else { return }
        guard !isPresentingSheet else { return }
        queuedDirectMode = nil
        guard capture == nil else { return }
        startCapture(mode)
    }

    /// Opens a saved picture so that a part of it can be cut out or read.
    private func openCapture(_ entry: HistoryEntry, mode: CaptureMode) {
        guard let image = entry.image else { return }
        monitor.imageData(image) { data in
            guard let data, let picture = UIImage(data: data) else {
                showToast("画像を読み込めませんでした")
                return
            }
            capture = CaptureRequest(source: CaptureSource(image: picture), mode: mode)
        }
    }

    /// The start of a text, on one line, for a short confirmation.
    static func toastPreview(_ text: String, limit: Int = 24) -> String {
        let line = text.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
        return line.count > limit ? String(line.prefix(limit)) + "…" : line
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
