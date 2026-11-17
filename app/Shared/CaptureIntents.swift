import AppIntents

/// Text or picture, as offered to Shortcuts and Siri.
enum CaptureModeOption: String, AppEnum {
    case text
    case image

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "切り取りの方式"
    static let caseDisplayRepresentations: [CaptureModeOption: DisplayRepresentation] = [
        .text: DisplayRepresentation(title: "文字", image: .init(systemName: "text.viewfinder")),
        .image: DisplayRepresentation(title: "画像", image: .init(systemName: "crop")),
    ]
}
