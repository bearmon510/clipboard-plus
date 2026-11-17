import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @ObservedObject var monitor: ClipboardMonitor
    /// Not observed as a whole: every log line would otherwise redraw this screen.
    let log: MeasurementLog
    @State private var logHasError = false
    @State private var showSettings = false
    @State private var confirmHistoryClear = false
    @State private var searchText: String
    @State private var pane: Pane
    /// Template groups the user opened, by group id.
    @State private var openTags: Set<String> = []
    /// Groups the user closed while they would otherwise show open: a lone group, or any group
    /// during a search.
    @State private var closedTags: Set<String> = []
    @State private var reorderGroup: TemplateGroup?
    @State private var renamingGroup: TemplateGroup?
    @State private var tagDraft = ""
    @State private var detailEntry: HistoryEntry?
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?
    @State private var deletion: HistoryDeletion?
    @State private var undoTask: Task<Void, Never>?
    @State private var copiedID: Int?
    @State private var copiedTask: Task<Void, Never>?
    @State private var isDropTargeted = false
    @StateObject private var screenshots: ScreenshotWatcher
    @State private var capture: CaptureRequest?
    @State private var showCaptureGuide = false
    /// The first-run guide. It opens by itself until it has been closed once.
    @State private var showWelcome = false
    @AppStorage(WelcomeView.shownKey) private var welcomeShown = false
    /// A capture waiting for an open sheet to finish closing. Opened from the sheet's onDismiss.
    @State private var queuedCapture: CaptureRequest?
    /// The writing sheet: a new template, or a change to a template.
    @State private var editor: EntryEditorView.Mode?

    /// A still picture to choose from, and what to do with the chosen part.
    struct CaptureRequest: Identifiable {
        let id = UUID()
        let source: CaptureSource
        let mode: CaptureMode
        /// The Photos asset when the picture came from an iPad screenshot.
        var screenshotID: String? = nil
    }

    /// `initialSearch`, `initialPane` and `initialOpenTags` let previews and screenshot tests
    /// open the screen mid-search, on the templates, or with a group open.
    init(monitor: ClipboardMonitor, log: MeasurementLog, initialSearch: String = "", initialPane: Pane = .history,
         initialOpenTags: Set<String> = []) {
        self.monitor = monitor
        self.log = log
        _screenshots = StateObject(wrappedValue: ScreenshotWatcher(log: log))
        _searchText = State(initialValue: initialSearch)
        _pane = State(initialValue: initialPane)
        _openTags = State(initialValue: initialOpenTags)
    }

    /// The search term without surrounding spaces, as used for filtering and highlighting.
    private var query: String { HistoryFilter.normalized(searchText) }

    /// Any sheet over the history. A capture from outside waits for it to close.
    private var isPresentingSheet: Bool {
        showSettings || showCaptureGuide || showWelcome || detailEntry != nil || editor != nil
            || reorderGroup != nil || renamingGroup != nil
    }

    private var hasHistory: Bool { monitor.entries.contains { !$0.isTemplate } }

    private func closeSheets() {
        showSettings = false
        showCaptureGuide = false
        showWelcome = false
        detailEntry = nil
        editor = nil
        reorderGroup = nil
        renamingGroup = nil
    }

    var body: some View {
        screen
            .sheet(isPresented: $showCaptureGuide, onDismiss: presentQueuedCapture) { CaptureGuideView() }
            .sheet(isPresented: $showWelcome, onDismiss: {
                welcomeShown = true
                presentQueuedCapture()
            }) { WelcomeView() }
            .fullScreenCover(item: $capture) { request in
                CaptureView(
                    source: request.source,
                    mode: request.mode,
                    // Each callback checks that its request is still the one on screen, so that
                    // a slow text reading never saves into, or closes, a newer capture.
                    onText: { text in
                        guard capture?.id == request.id else { return }
                        monitor.saveCaptured(text: text)
                        if let id = request.screenshotID { screenshots.markUsed(id) }
                        showToast("文字をコピーしました：" + Self.toastPreview(text))
                    },
                    onImage: { data in
                        guard capture?.id == request.id else { return }
                        monitor.saveCaptured(pngData: data)
                        if let id = request.screenshotID { screenshots.markUsed(id) }
                        showToast("画像をコピーしました")
                    },
                    onClose: { if capture?.id == request.id { capture = nil } }
                )
            }
            // Shortcuts and Siri deliver a screenshot or image to cut out here.
            .onReceive(CaptureInbox.shared.$request) { request in
                guard let request else { return }
                // As below, clear it on the next turn, because @Published stores it after announcing.
                DispatchQueue.main.async {
                    if CaptureInbox.shared.request?.id == request.id { CaptureInbox.shared.request = nil }
                }
                openFromOutside(CaptureRequest(source: request.source,
                                               mode: request.mode ?? CaptureSettings.screenshotMode()))
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
            paneBar
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
            if !welcomeShown { showWelcome = true }
        }
        .onChange(of: scenePhase) { _, phase in
            updateScene(phase)
            // A capture queued behind a sheet is dropped when the app leaves the screen.
            if phase == .background {
                queuedCapture = nil
            }
            if phase == .active {
                monitor.pendingDeletion { showUndo($0) }
            }
            // Only leaving the screen stops it: a side window turns inactive whenever
            // another app is touched, and the system picker does the same.
            screenshots.sceneDidChange(isActive: phase != .background)
        }
        // The badge belongs to the list the user tapped in, so it goes with that list.
        .onChange(of: pane) { _, _ in clearCopied() }
        .onReceive(log.$errorMessage) { logHasError = $0 != nil }
        .sheet(isPresented: $showSettings, onDismiss: presentQueuedCapture) {
            SettingsView(monitor: monitor, log: log, screenshots: screenshots)
        }
        .sheet(item: $detailEntry, onDismiss: presentQueuedCapture) { entry in detail(entry) }
        .sheet(item: $editor, onDismiss: presentQueuedCapture) { mode in
            EntryEditorView(monitor: monitor, mode: mode, tags: TemplateGroups.tags(monitor.entries)) {
                showToast($0)
            }
        }
        .sheet(item: $reorderGroup, onDismiss: presentQueuedCapture) { group in
            TemplateOrderView(title: group.title, items: group.entries) { monitor.reorderTemplates($0) }
        }
        .alert(renamingGroup?.tag == nil ? "タグを付ける" : "タグ名を変更",
               isPresented: Binding(get: { renamingGroup != nil }, set: { if !$0 { renamingGroup = nil } })) {
            TextField("タグ名", text: $tagDraft)
            Button("キャンセル", role: .cancel) { renamingGroup = nil }
            Button("決定") {
                if let group = renamingGroup { renameTag(group) }
            }
        } message: {
            Text(renamingGroup?.tag == nil
                 ? "「その他」のテンプレートすべてに、このタグを付けます。"
                 : "このタグのテンプレートすべてのタグが変わります。空にすると「その他」に移ります。")
        }
        .confirmationDialog("履歴を全消去しますか？", isPresented: $confirmHistoryClear, titleVisibility: .visible) {
            Button("履歴を全消去", role: .destructive) {
                monitor.deleteAllHistory { showUndo($0) }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("テンプレートは消えません。5秒間は「元に戻す」で取り消せます。")
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 2) {
            // Priority lets the field take the width first; the spacer only fills a wide window.
            searchField.frame(maxWidth: 560).layoutPriority(1)
            Spacer(minLength: 4)
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
            TextField(pane == .history ? "履歴を検索" : "テンプレートを検索", text: $searchText)
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

    private var moreMenu: some View {
        Menu {
            if monitor.isRecording {
                Button("記録を一時停止", systemImage: "pause") { monitor.stop() }
            } else {
                Button("記録を再開", systemImage: "play") { monitor.start() }
            }
            Button("テンプレートを書く", systemImage: "square.and.pencil") { editor = .create(tag: nil) }
            Button("使い方", systemImage: "questionmark.circle") { showWelcome = true }
            Button("設定", systemImage: "gearshape") { showSettings = true }
            Button("履歴を全消去…", systemImage: "trash", role: .destructive) {
                confirmHistoryClear = true
            }
            .disabled(!hasHistory)
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

    // MARK: Pane switch

    /// 履歴 and テンプレート. The kind filters went away in 0.13.0; search narrows instead.
    enum Pane: String, CaseIterable, Identifiable {
        case history, templates
        var id: String { rawValue }
        var title: String { self == .history ? "履歴" : "テンプレート" }
    }

    private var paneBar: some View {
        HStack(spacing: 8) {
            Picker("表示", selection: $pane) {
                ForEach(Pane.allCases) { value in
                    Text(value.title).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 340)
            Spacer(minLength: 0)
            if pane == .history {
                pasteButton
            } else {
                Button {
                    editor = .create(tag: nil)
                } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 28)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .accessibilityLabel("テンプレートを書く")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 6)
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

    // MARK: Lists

    private var history: some View {
        GeometryReader { proxy in
            // The periodic refresh keeps labels such as "3分前" current.
            TimelineView(.periodic(from: .now, by: 20)) { context in
                let columnCount = EntryColumns.count(forWidth: proxy.size.width)
                ScrollView {
                    if pane == .history {
                        historyList(HistoryFilter.history(monitor.entries, search: query),
                                    now: context.date, columnCount: columnCount)
                    } else {
                        templateList(TemplateGroups.make(monitor.entries, search: query), columnCount: columnCount)
                    }
                }
                .scrollDismissesKeyboard(.immediately)
                // A fresh list for each pane. In 0.12.0, a card that moved to another list while
                // its コピーしました badge was showing left the list unresponsive on device.
                .id(pane)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Keeps the last card clear of the undo bar.
    private var bottomClearance: CGFloat { 96 }

    @ViewBuilder
    private func historyList(_ entries: [HistoryEntry], now: Date, columnCount: Int) -> some View {
        if entries.isEmpty {
            historyEmptyState
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(EntrySections.make(entries, now: now)) { section in
                    sectionTitle(section.kind.title, count: section.entries.count)
                    cards(section.entries, columnCount: columnCount) { entry in
                        card(entry, timeLabel: EntryTime.label(
                            for: entry.lastCollectedAt, now: now,
                            includesDay: section.kind != .today && section.kind != .yesterday))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, bottomClearance)
        }
    }

    @ViewBuilder
    private func templateList(_ groups: [TemplateGroup], columnCount: Int) -> some View {
        if groups.isEmpty {
            templateEmptyState
        } else {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(groups) { group in
                    let open = isOpen(group, groupCount: groups.count)
                    templateHeader(group, isOpen: open, groupCount: groups.count)
                    if open {
                        cards(group.entries, columnCount: columnCount) { entry in
                            card(entry, timeLabel: "")
                        }
                        .padding(.leading, 8)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, bottomClearance)
        }
    }

    /// One column stays fully lazy, which matters with a long history. Wider windows use columns,
    /// each its own stack, so that cards of different heights pack tightly.
    @ViewBuilder
    private func cards<Card: View>(_ entries: [HistoryEntry], columnCount: Int,
                                   @ViewBuilder card: @escaping (HistoryEntry) -> Card) -> some View {
        if columnCount == 1 {
            ForEach(entries) { entry in
                card(entry).padding(.bottom, 10)
            }
        } else {
            let groups = EntryColumns.split(entries, into: columnCount)
            HStack(alignment: .top, spacing: 10) {
                ForEach(groups.indices, id: \.self) { index in
                    LazyVStack(spacing: 10) {
                        ForEach(groups[index]) { entry in
                            card(entry)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
            .padding(.bottom, 10)
        }
    }

    private func card(_ entry: HistoryEntry, timeLabel: String) -> some View {
        HistoryCard(
            entry: entry,
            thumbnailURL: entry.image.map { monitor.imageURL($0, thumbnail: true) },
            timeLabel: timeLabel,
            query: query,
            isCopied: copiedID == entry.id,
            onCopy: { copy(entry) },
            dragProvider: { monitor.rowProvider(entry) },
            actions: { rowActions(entry) }
        )
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            Text("\(count)").font(.caption.weight(.medium)).foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.top, 12)
        .frame(minHeight: 36, alignment: .bottom)
        .padding(.bottom, 8)
    }

    // MARK: Template groups

    /// Groups start closed. A lone group, and every group while searching, starts open.
    /// Either way, tapping the header opens or closes it.
    private func startsOpen(groupCount: Int) -> Bool { groupCount == 1 || !query.isEmpty }

    private func isOpen(_ group: TemplateGroup, groupCount: Int) -> Bool {
        startsOpen(groupCount: groupCount) ? !closedTags.contains(group.id) : openTags.contains(group.id)
    }

    private func toggle(_ group: TemplateGroup, groupCount: Int) {
        if startsOpen(groupCount: groupCount) {
            if closedTags.contains(group.id) { closedTags.remove(group.id) } else { closedTags.insert(group.id) }
        } else {
            if openTags.contains(group.id) { openTags.remove(group.id) } else { openTags.insert(group.id) }
        }
    }

    private func templateHeader(_ group: TemplateGroup, isOpen: Bool, groupCount: Int) -> some View {
        HStack(spacing: 2) {
            Button {
                toggle(group, groupCount: groupCount)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: 12)
                    Image(systemName: group.tag == nil ? "tray" : "tag")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 22)
                    Text(group.title)
                        .font(.headline)
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Text("\(group.entries.count)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 4)
                }
                .padding(.leading, 12)
                .padding(.trailing, 6)
                .frame(minHeight: 54)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isOpen ? "たたみます" : "開いて中身を表示します")
            Menu {
                Button("このタグで書く", systemImage: "square.and.pencil") { editor = .create(tag: group.tag) }
                // The whole group, even while a search hides part of it.
                let whole = query.isEmpty ? group
                    : TemplateGroups.make(monitor.entries, search: "").first(where: { $0.id == group.id }) ?? group
                if whole.entries.count > 1 {
                    Button("並べ替え", systemImage: "arrow.up.arrow.down") { reorderGroup = whole }
                }
                Button(group.tag == nil ? "タグを付ける…" : "タグ名を変更…", systemImage: "tag") {
                    tagDraft = group.tag ?? ""
                    renamingGroup = group
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("「\(group.title)」の操作")
        }
        .padding(.trailing, 2)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            .allowsHitTesting(false))
    }

    private func renameTag(_ group: TemplateGroup) {
        let newTag = HistoryEntry.normalizedTag(tagDraft)
        monitor.renameTag(group.tag, to: newTag)
        // Keeps the renamed group open or closed as it was. The id matches TemplateGroup.id.
        let newID = newTag ?? ""
        if openTags.remove(group.id) != nil { openTags.insert(newID) }
        if closedTags.remove(group.id) != nil { closedTags.insert(newID) }
        renamingGroup = nil
    }

    // MARK: Item actions

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
        if entry.isTemplate {
            Button("編集…", systemImage: "pencil") { editor = .edit(entry) }
        } else {
            Button("テンプレートに移動", systemImage: "square.stack") { moveToTemplates(entry) }
        }
        Divider()
        Button("削除", systemImage: "trash", role: .destructive) {
            monitor.delete(entry) { showUndo($0) }
        }
    }

    private func moveToTemplates(_ entry: HistoryEntry) {
        monitor.moveToTemplates(entry) { result in
            switch result {
            case .success: showToast("テンプレートの「その他」に移動しました")
            case .failure(let error): showToast(error.message)
            }
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

    @ViewBuilder private var historyEmptyState: some View {
        if query.isEmpty {
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
        } else {
            notFound
        }
    }

    @ViewBuilder private var templateEmptyState: some View {
        if query.isEmpty {
            VStack(spacing: 14) {
                emptySymbol("square.stack")
                Text("テンプレートはまだありません").font(.title3.weight(.semibold))
                Text("よく使う文を書いておくと、押すだけでコピーできます。タグを付けると、同じタグのものがまとまります。履歴のカードのメニューから「テンプレートに移動」することもできます。テンプレートは自動では消えません。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("テンプレートを書く", systemImage: "square.and.pencil") { editor = .create(tag: nil) }
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
            }
            .padding(.horizontal, 28)
            .padding(.top, 48)
            .frame(maxWidth: 440)
            .frame(maxWidth: .infinity)
        } else {
            notFound
        }
    }

    private var notFound: some View {
        VStack(spacing: 14) {
            emptySymbol("magnifyingglass")
            Text("見つかりませんでした").font(.title3.weight(.semibold))
            Button("検索をクリア") { searchText = "" }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
        }
        .padding(.horizontal, 28)
        .padding(.top, 48)
        .frame(maxWidth: .infinity)
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

    /// Opens a picture that arrived from outside the screen: a shortcut or a screenshot.
    /// Nothing replaces a capture already on screen. When a sheet is
    /// open, the picture waits until that sheet has finished closing.
    private func openFromOutside(_ request: CaptureRequest) {
        guard capture == nil else { return }
        guard isPresentingSheet else {
            queuedCapture = nil
            capture = request
            return
        }
        // Only the newest arrival waits; an older one is simply replaced.
        queuedCapture = request
        closeSheets()
    }

    /// Called when a sheet has finished closing.
    private func presentQueuedCapture() {
        guard let request = queuedCapture else { return }
        queuedCapture = nil
        guard capture == nil else { return }
        capture = request
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

    /// Removes the コピーしました badge at once, without its fade, so that no animation is
    /// left running in a list that is being replaced.
    private func clearCopied() {
        copiedTask?.cancel()
        copiedTask = nil
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { copiedID = nil }
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
