import AppIntents

// Compiled into both the app and the Control Center extension. A control that opens the app
// must name an intent that both binaries know; the system then runs `perform()` in the app.

/// Text or picture, as offered to Shortcuts, Siri and Control Center.
enum CaptureModeOption: String, AppEnum {
    case text
    case image

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "切り取りの方式"
    static let caseDisplayRepresentations: [CaptureModeOption: DisplayRepresentation] = [
        .text: DisplayRepresentation(title: "文字", image: .init(systemName: "text.viewfinder")),
        .image: DisplayRepresentation(title: "画像", image: .init(systemName: "crop")),
    ]
}

/// Opens clipboard+ and starts cutting out the screen directly, without a screenshot.
struct StartCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "画面の切り取りを始める"
    static let description: IntentDescription? = IntentDescription("clipboard+を開き、画面を直接取り込んで、文字か画像の切り取りを始めます。")
    static let openAppWhenRun: Bool = true

    @Parameter(title: "方式", default: .text)
    var mode: CaptureModeOption

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$mode)で画面の切り取りを始める")
    }

    init() {}

    init(mode: CaptureModeOption) {
        self.mode = mode
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !CLIPBOARD_PLUS_CONTROLS
        CaptureInbox.shared.startDirect(CaptureMode(mode))
        #endif
        return .result()
    }
}
