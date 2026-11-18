import SwiftUI
import UIKit
import XCTest
@testable import ClipboardPlus

/// Renders the main screens with fictional sample data and saves them as PNG files,
/// so the design can be reviewed from CI without a Mac or a device at hand.
/// The directory comes from SNAPSHOT_DIR (set by the workflow) or the temporary directory.
final class ScreenSnapshotTests: XCTestCase {
    @MainActor
    private final class IdlePasteboard: ClipboardPasteboard {
        let changeCount = 0
        let hasImages = false
        let hasStrings = false
        let types: [String] = []
        var string: String?
        let image: UIImage? = nil
        func data(forPasteboardType pasteboardType: String) -> Data? { nil }
        func setData(_ data: Data, forPasteboardType pasteboardType: String) {}
    }

    private static let narrow = CGSize(width: 360, height: 780)
    private static let wide = CGSize(width: 1_024, height: 768)
    private static let phone = CGSize(width: 393, height: 852)
    private static let keyboardPhone = CGSize(
        width: 393,
        height: KeyboardLayoutMetrics.preferredHeight(idiom: .phone, verticalSizeClass: .regular, width: 393)
    )
    private static let keyboardPad = CGSize(
        width: 1_024,
        height: KeyboardLayoutMetrics.preferredHeight(idiom: .pad, verticalSizeClass: .regular, width: 1_024)
    )
    private static let keyboardPadLandscape = CGSize(
        width: 1_366,
        height: KeyboardLayoutMetrics.preferredHeight(idiom: .pad, verticalSizeClass: .regular, width: 1_366)
    )

    /// The first-run guide would otherwise open over every main screen.
    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(true, forKey: WelcomeView.shownKey)
    }

    @MainActor
    func testRenderWelcome() async throws {
        try save(render(WelcomeView(), size: Self.narrow, style: .light), "welcome-narrow-light")
        try save(render(WelcomeView(), size: Self.wide, style: .dark), "welcome-wide-dark")
        // The tests run on an iPad, so the iPhone wording is drawn by asking for it.
        try save(render(WelcomeView(deviceOverride: .phone), size: Self.phone, style: .light), "welcome-phone-light")
        try save(render(CaptureGuideView(deviceOverride: .phone), size: Self.phone, style: .dark), "capture-guide-phone-dark")
    }

    /// The settings, with the Windows sync section unpaired as on a fresh install.
    @MainActor
    func testRenderSettings() async throws {
        let monitor = try await makeMonitor(populated: false)
        let settings = SettingsView(monitor: monitor, log: monitor.log, screenshots: ScreenshotWatcher(log: monitor.log))
        try save(render(settings, size: Self.narrow, style: .light), "settings-narrow-light")
    }

    /// The Windows sync section in the states that matter: a transfer in progress, and the two
    /// stops that need the user, which used to read "cannot be used on this iPad".
    @MainActor
    func testRenderSyncSettingsStates() async throws {
        let now = Date()
        let transferring = SyncDisplay(
            pcName: "DESK-PC", status: .connected, lastSentAt: now, lastReceivedAt: now.addingTimeInterval(-90),
            pendingCount: 3,
            transfer: PCSyncController.TransferProgress(direction: "send", itemID: UUID(), bytes: 1_400_000, totalBytes: 3_600_000))
        let repair = SyncDisplay(pcName: "DESK-PC", status: .unsupported, requiresRepair: true, lastSentAt: now.addingTimeInterval(-86_400))
        let update = SyncDisplay(pcName: "DESK-PC", status: .unsupported, requiresPeerUpdate: true, pendingCount: 12)
        try save(render(syncForm(transferring), size: Self.narrow, style: .light), "sync-transferring-narrow-light")
        try save(render(syncForm(repair), size: Self.narrow, style: .dark), "sync-repair-narrow-dark")
        try save(render(syncForm(update, device: .phone), size: Self.phone, style: .light), "sync-update-phone-light")
        try save(render(syncForm(SyncDisplay(), device: .phone), size: Self.phone, style: .dark), "sync-unpaired-phone-dark")

        XCTAssertEqual(repair.statusLabel(device: .pad).text, "組み直しが必要です")
        XCTAssertEqual(update.statusLabel(device: .pad).text, "アプリの更新が必要です")
        XCTAssertEqual(SyncDisplay(pcName: "PC", status: .unsupported).statusLabel(device: .phone).text, "このiPhoneでは使えません")
    }

    @MainActor
    private func syncForm(_ display: SyncDisplay, device: DeviceKind? = nil) -> some View {
        let actions = SyncSettingsActions(pair: { _ in }, unpair: {}, retryAfterPeerUpdate: {}, retryAfterRepair: {})
        return Form {
            SyncSettingsContent(display: display, copiesReceivedToPasteboard: .constant(true), actions: actions, deviceOverride: device)
        }
    }

    @MainActor
    func testRenderMainScreens() async throws {
        let monitor = try await makeMonitor(populated: true)
        monitor.start()
        defer { monitor.stop() }
        try save(render(ContentView(monitor: monitor, log: monitor.log), size: Self.narrow, style: .light), "main-narrow-light")
        try save(render(ContentView(monitor: monitor, log: monitor.log), size: Self.narrow, style: .dark), "main-narrow-dark")
        try save(render(ContentView(monitor: monitor, log: monitor.log), size: Self.wide, style: .light), "main-wide-light")
        try save(render(ContentView(monitor: monitor, log: monitor.log, initialSearch: "apple"), size: Self.narrow, style: .light),
                 "search-narrow-light")
        // The template groups: all closed, then one open, then a search that opens every match.
        try save(render(ContentView(monitor: monitor, log: monitor.log, initialPane: .templates),
                        size: Self.narrow, style: .light), "templates-narrow-light")
        try save(render(ContentView(monitor: monitor, log: monitor.log, initialPane: .templates, initialOpenTags: ["メール"]),
                        size: Self.narrow, style: .dark), "templates-open-narrow-dark")
        try save(render(ContentView(monitor: monitor, log: monitor.log, initialPane: .templates, initialOpenTags: ["メール", ""]),
                        size: Self.wide, style: .light), "templates-open-wide-light")
        try save(render(ContentView(monitor: monitor, log: monitor.log, initialSearch: "住所", initialPane: .templates),
                        size: Self.narrow, style: .light), "templates-search-narrow-light")
    }

    @MainActor
    func testRenderPausedAndEmptyScreens() async throws {
        let paused = try await makeMonitor(populated: true)
        try save(render(ContentView(monitor: paused, log: paused.log), size: Self.narrow, style: .light), "paused-narrow-light")
        let empty = try await makeMonitor(populated: false)
        empty.start()
        defer { empty.stop() }
        try save(render(ContentView(monitor: empty, log: empty.log), size: Self.narrow, style: .light), "empty-narrow-light")
        try save(render(ContentView(monitor: empty, log: empty.log, initialSearch: "ない"), size: Self.narrow, style: .dark),
                 "empty-search-narrow-dark")
    }

    @MainActor
    func testRenderTemplateEditorAndOrder() async throws {
        let monitor = try await makeMonitor(populated: true)
        monitor.start()
        defer { monitor.stop() }
        let groups = TemplateGroups.make(monitor.entries, search: "")
        let mail = try XCTUnwrap(groups.first { $0.tag == "メール" })
        let tags = TemplateGroups.tags(monitor.entries)
        let editing = try XCTUnwrap(mail.entries.first)
        try save(render(EntryEditorView(monitor: monitor, mode: .edit(editing), tags: tags) { _ in },
                        size: Self.narrow, style: .light), "editor-narrow-light")
        try save(render(EntryEditorView(monitor: monitor, mode: .create(tag: "メール"), tags: tags) { _ in },
                        size: Self.narrow, style: .dark), "editor-create-narrow-dark")
        let picture = try XCTUnwrap(monitor.entries.first { $0.isTemplate && $0.kind == .image })
        try save(render(EntryEditorView(monitor: monitor, mode: .edit(picture), tags: tags) { _ in },
                        size: Self.narrow, style: .light), "editor-image-narrow-light")
        try save(render(TemplateOrderView(title: mail.title, items: mail.entries) { _ in }, size: Self.narrow, style: .light),
                 "template-order-narrow-light")
    }

    @MainActor
    func testRenderDetailScreen() async throws {
        let now = Date()
        let entry = HistoryEntry(
            id: 1, kind: .url, text: "https://developer.apple.com/documentation/swiftui/lazyvgrid",
            savedAt: now.addingTimeInterval(-86_400 * 3), lastCollectedAt: now.addingTimeInterval(-600),
            collectionCount: 4, isTemplate: false, source: .automatic
        )
        try save(render(EntryDetailView(entry: entry) {}, size: Self.narrow, style: .light), "detail-narrow-light")
    }

    @MainActor
    func testRenderCaptureScreens() async throws {
        let source = CaptureSource(image: Self.sampleScreenshot())
        // Mid-drag in a wide window: the selection and the magnifier at the finger.
        let dragging = CaptureView(source: source, mode: .text,
                                   previewSelection: CGRect(x: 0.08, y: 0.2, width: 0.6, height: 0.28),
                                   // The finger over the third line of text, so the lens shows enlarged letters.
                                   previewTouch: CGPoint(x: 420, y: 288),
                                   onText: { _ in }, onImage: { _ in }, onClose: {})
        try save(render(dragging, size: Self.wide, style: .light), "capture-wide-dragging")
        // A narrow side window, where the magnifier matters most.
        let narrow = CaptureView(source: source, mode: .text,
                                 previewSelection: CGRect(x: 0.08, y: 0.2, width: 0.45, height: 0.1),
                                 // Over the second line of text in the shrunk picture.
                                 previewTouch: CGPoint(x: 110, y: 334),
                                 onText: { _ in }, onImage: { _ in }, onClose: {})
        try save(render(narrow, size: Self.narrow, style: .light), "capture-narrow-dragging")
        let untouched = CaptureView(source: source, mode: .image, onText: { _ in }, onImage: { _ in }, onClose: {})
        try save(render(untouched, size: Self.narrow, style: .dark), "capture-narrow-image")
        let reading = CaptureView(source: source, mode: .text,
                                  previewSelection: CGRect(x: 0.08, y: 0.2, width: 0.6, height: 0.28),
                                  previewPhase: .reading,
                                  onText: { _ in }, onImage: { _ in }, onClose: {})
        try save(render(reading, size: Self.wide, style: .light), "capture-wide-reading")
        let noText = CaptureView(source: source, mode: .text, previewPhase: .noText,
                                 onText: { _ in }, onImage: { _ in }, onClose: {})
        try save(render(noText, size: Self.narrow, style: .light), "capture-narrow-notext")
        try save(render(CaptureGuideView(), size: Self.narrow, style: .light), "capture-guide-narrow-light")
    }

    @MainActor
    func testRenderKeyboardScreens() throws {
        let now = Date()
        let entries = sampleKeyboardEntries(now: now)

        let historyPhone = KeyboardViewModel(
            entries: entries,
            initialTab: .history,
            loadState: .loaded,
            hasFullAccess: false,
            needsInputModeSwitchKey: true,
            referenceDateOverride: now
        )
        try save(renderKeyboard(historyPhone, size: Self.keyboardPhone, style: .light), "keyboard-history-phone-light")

        let templatesPad = KeyboardViewModel(
            entries: entries,
            initialTab: .templates,
            loadState: .loaded,
            hasFullAccess: false,
            needsInputModeSwitchKey: true,
            referenceDateOverride: now
        )
        try save(renderKeyboard(templatesPad, size: Self.keyboardPad, style: .dark), "keyboard-templates-pad-dark")

        let alphanumericPhone = KeyboardViewModel(
            entries: entries,
            initialTab: .history,
            loadState: .loaded,
            mode: .alphanumeric,
            alphanumericPage: .letters,
            shiftState: .once,
            hasFullAccess: false,
            needsInputModeSwitchKey: true,
            referenceDateOverride: now
        )
        try save(renderKeyboard(alphanumericPhone, size: Self.keyboardPhone, style: .dark), "keyboard-alphanumeric-phone-dark")

        let emptyPhone = KeyboardViewModel(
            entries: [],
            initialTab: .history,
            loadState: .loaded,
            hasFullAccess: false,
            needsInputModeSwitchKey: true,
            referenceDateOverride: now
        )
        try save(renderKeyboard(emptyPhone, size: Self.keyboardPhone, style: .light), "keyboard-empty-phone-light")

        let fullAccessPhone = KeyboardViewModel(
            entries: entries,
            initialTab: .history,
            loadState: .loaded,
            hasFullAccess: true,
            needsInputModeSwitchKey: true,
            referenceDateOverride: now
        )
        try save(renderKeyboard(fullAccessPhone, size: Self.keyboardPhone, style: .light), "keyboard-fullaccess-phone-light")

        let historyPadLandscape = KeyboardViewModel(
            entries: entries,
            initialTab: .history,
            loadState: .loaded,
            hasFullAccess: false,
            needsInputModeSwitchKey: true,
            referenceDateOverride: now
        )
        try save(
            renderKeyboard(historyPadLandscape, size: Self.keyboardPadLandscape, style: .light),
            "keyboard-history-pad-landscape-light"
        )
    }

    @MainActor
    private func renderKeyboard(_ model: KeyboardViewModel, size: CGSize, style: UIUserInterfaceStyle) -> UIImage {
        let view = KeyboardView(model: model)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(KeyboardTheme.page)
        return render(view, size: size, style: style, ignoresWindowSafeArea: true)
    }

    private func sampleKeyboardEntries(now: Date) -> [KeyboardHistoryEntry] {
        [
            KeyboardHistoryEntry(
                id: 1, kind: .text,
                text: "打ち合わせの議事録を共有します。\n明日の10時からレビューを行います。",
                lastCollectedAt: now.addingTimeInterval(-4), isTemplate: false, isFromPC: true
            ),
            KeyboardHistoryEntry(
                id: 2, kind: .url,
                text: "https://developer.apple.com/documentation/uikit/uipastecontrol",
                lastCollectedAt: now.addingTimeInterval(-240), isTemplate: false, isFromPC: false
            ),
            KeyboardHistoryEntry(
                id: 3, kind: .text,
                text: "〒100-0001 東京都千代田区千代田1-1 試験ビル 3階",
                lastCollectedAt: now.addingTimeInterval(-1_800), isTemplate: false, isFromPC: false
            ),
            KeyboardHistoryEntry(
                id: 4, kind: .text,
                text: "いつもお世話になっております。試験 太郎です。",
                lastCollectedAt: now, isTemplate: true, title: "あいさつ", tag: "メール", templateOrder: 0
            ),
            KeyboardHistoryEntry(
                id: 5, kind: .text,
                text: "引き続きよろしくお願いいたします。",
                lastCollectedAt: now, isTemplate: true, title: "結び", tag: "メール", templateOrder: 1
            ),
            KeyboardHistoryEntry(
                id: 6, kind: .text,
                text: "電話：03-0000-0000\nメール：hello@example.com",
                lastCollectedAt: now, isTemplate: true, title: "連絡先", tag: "住所セット", templateOrder: 0
            ),
            KeyboardHistoryEntry(
                id: 7, kind: .url,
                text: "https://example.com/forms/contact",
                lastCollectedAt: now, isTemplate: true, title: "問い合わせフォーム", tag: nil, templateOrder: 0
            ),
        ]
    }

    /// A made-up page standing in for a screenshot of another app.
    private static func sampleScreenshot() -> UIImage {
        let size = CGSize(width: 1_024, height: 768)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(white: 0.93, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: size.width, height: 64))
            ("試験用のページ" as NSString).draw(at: CGPoint(x: 32, y: 18), withAttributes: [
                .font: UIFont.systemFont(ofSize: 24, weight: .semibold), .foregroundColor: UIColor.black,
            ])
            let lines = ["クリップボードの使い方", "コピーした文章や画像は、自動で履歴に残ります。",
                         "必要な部分だけを切り取って、文字として読み取れます。", "問い合わせ先：hello@example.com"]
            for (index, line) in lines.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 96, y: 170 + CGFloat(index) * 52), withAttributes: [
                    .font: UIFont.systemFont(ofSize: index == 0 ? 34 : 24, weight: index == 0 ? .bold : .regular),
                    .foregroundColor: UIColor.darkGray,
                ])
            }
            UIColor(red: 0.18, green: 0.42, blue: 0.94, alpha: 1).setFill()
            context.fill(CGRect(x: 96, y: 460, width: 360, height: 200))
        }
    }

    // MARK: Sample data

    @MainActor
    private func makeMonitor(populated: Bool) async throws -> ClipboardMonitor {
        let root = try ImageTestSupport.directory(self)
        let url = root.appendingPathComponent("history.sqlite")
        let files = HistoryImageFiles(directory: root.appendingPathComponent("images"))
        if populated {
            let database = try HistoryDatabase(url: url)
            try fill(database, files: files)
        }
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        HistoryRetention.never.save(to: defaults)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let log = MeasurementLog(writer: MeasurementLogWriter(fileURL: root.appendingPathComponent("log.tsv")))
        let monitor = ClipboardMonitor(defaults: defaults, log: log, makeDatabase: { try HistoryDatabase(url: url) },
                                       schedulesMaintenance: false, imageDirectory: files.directory,
                                       pasteboard: IdlePasteboard())
        let loaded = expectation(description: "history loaded")
        monitor.pendingDeletion { _ in loaded.fulfill() }
        await fulfillment(of: [loaded], timeout: 10)
        return monitor
    }

    private func fill(_ database: HistoryDatabase, files: HistoryImageFiles) throws {
        let now = Date()
        func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
        let day: TimeInterval = 86_400

        try database.collect("来週の打ち合わせの候補日です。\n・11月18日（水）14時〜\n・11月19日（木）10時〜\nご都合のよい日を教えてください。",
                             source: .automatic, at: ago(9 * day))
        try database.collect("https://example.com/blog/2026/11/reading-list", source: .automatic, at: ago(3 * day))
        try database.collect("プロジェクトの進め方メモ：まず小さく試して、結果を見てから広げる。", source: .drag, at: ago(2 * day))
        try database.collect("03-1234-5678", source: .automatic, at: ago(day + 3_600))
        try database.collect("https://www.apple.com/jp/ipad-air/", source: .automatic, at: ago(day + 1_800))

        // Templates: two tags, and a group without one (その他) that holds a picture.
        let greeting = try database.collect("いつもお世話になっております。試験 太郎です。", source: .manual, at: ago(5 * day))
        let closing = try database.collect("引き続きよろしくお願いいたします。", source: .manual, at: ago(5 * day))
        let address = try database.collect("〒100-0001 東京都千代田区千代田1-1 試験ビル 3階", source: .manual, at: ago(4 * day))
        for (entry, title, tag) in [(greeting, "あいさつ", "メール"), (closing, "結び", "メール"), (address, "住所", "住所セット")] {
            let moved = try database.moveToTemplates(id: entry.id)
            _ = try database.updateTemplate(id: moved.id, text: nil, title: title, tag: tag)
        }
        _ = try database.createTemplate(text: "電話：03-0000-0000\nメール：hello@example.com", title: "連絡先", tag: "住所セット")
        _ = try database.createTemplate(text: "https://example.com/forms/contact", title: "問い合わせフォーム", tag: nil)
        let logo = try files.prepare(Self.samplePicture(width: 360), typeIdentifier: "public.png",
                                     hash: HistoryImageFiles.hash(Self.samplePicture(width: 360)))
        let logoEntry = try database.collectImage(logo, source: .manual, at: ago(6 * day))
        let movedLogo = try database.moveToTemplates(id: logoEntry.id)
        _ = try database.updateTemplate(id: movedLogo.id, text: nil, title: "ロゴ", tag: nil)

        try database.collect(String(repeating: "長い文章の例です。同じ文が続きます。", count: 30), source: .automatic, at: ago(3 * 3_600))
        try database.collect("#2E6BF0", source: .automatic, at: ago(2 * 3_600))
        try database.collect("hello@example.com", source: .automatic, at: ago(50 * 60))
        let image = try files.prepare(Self.samplePicture(), typeIdentifier: "public.png", hash: HistoryImageFiles.hash(Self.samplePicture()))
        try database.collectImage(image, source: .automatic, at: ago(25 * 60))
        // Only the card is drawn, so the file itself need not exist.
        try database.collectFile(HistoryFile(hash: String(repeating: "a", count: 64),
                                             filename: "sample-report.pdf", originalFilename: "11月の打ち合わせ資料.pdf",
                                             byteCount: 2_480_000, typeIdentifier: "com.adobe.pdf"),
                                 source: .automatic, at: ago(18 * 60))
        try database.collectFile(HistoryFile(hash: String(repeating: "b", count: 64),
                                             filename: "sample-archive.zip", originalFilename: "写真のまとめ.zip",
                                             byteCount: 31_200_000, typeIdentifier: "public.zip-archive"),
                                 source: .automatic, at: ago(2 * day + 600))
        try database.collect("https://developer.apple.com/documentation/swiftui/lazyvgrid", source: .automatic, at: ago(12 * 60))
        try database.collect("何度もコピーした文章", source: .automatic, at: ago(8 * 60))
        try database.collect("何度もコピーした文章", source: .automatic, at: ago(4 * 60))
        try database.collect("何度もコピーした文章", source: .automatic, at: ago(3 * 60))
        try database.collect("さっきコピーした一文。Apple の資料を読みながらメモしています。", source: .automatic, at: ago(20))
    }

    private static func samplePicture(width: CGFloat = 480) -> Data {
        let size = CGSize(width: width, height: 300)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            let colors = [UIColor(red: 0.18, green: 0.42, blue: 0.94, alpha: 1).cgColor,
                          UIColor(red: 0.98, green: 0.62, blue: 0.22, alpha: 1).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
            UIColor.white.withAlphaComponent(0.85).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 60, y: 70, width: 160, height: 160))
            UIColor.white.withAlphaComponent(0.5).setFill()
            context.cgContext.fill(CGRect(x: 270, y: 110, width: 150, height: 90))
        }
    }

    // MARK: Rendering

    @MainActor
    private func render<Content: View>(
        _ view: Content,
        size: CGSize,
        style: UIUserInterfaceStyle,
        ignoresWindowSafeArea: Bool = false
    ) -> UIImage {
        let controller = UIHostingController(rootView: view)
        if ignoresWindowSafeArea {
            controller.safeAreaRegions = []
        }
        controller.overrideUserInterfaceStyle = style
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(origin: .zero, size: size))
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = style
        window.rootViewController = controller
        window.isHidden = false
        window.layoutIfNeeded()
        // Lets lazy rows appear and thumbnails load before the picture is taken.
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            window.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
        window.isHidden = true
        window.rootViewController = nil
        return image
    }

    private func save(_ image: UIImage, _ name: String) throws {
        let directory = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("clipboardplus-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(name).png")
        try XCTUnwrap(image.pngData()).write(to: file, options: .atomic)
        print("SNAPSHOT_SAVED \(file.path)")
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
