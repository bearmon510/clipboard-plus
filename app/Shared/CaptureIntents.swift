import AppIntents

// The Control Center extension that shared these intents was removed in 0.11.0, together with
// the direct capture it started. The file stays here so that the intents keep their identity.

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
/// Hidden from Shortcuts since 0.11.0, together with the direct capture itself; it only works
/// while "画面を直接取り込む" is on in the developer settings.
struct StartCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "画面の切り取りを始める"
    static let description: IntentDescription? = IntentDescription("clipboard+を開き、画面を直接取り込んで、文字か画像の切り取りを始めます。")
    static let openAppWhenRun: Bool = true
    static let isDiscoverable: Bool = false

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
        CaptureInbox.shared.startDirect(CaptureMode(mode))
        return .result()
    }
}
