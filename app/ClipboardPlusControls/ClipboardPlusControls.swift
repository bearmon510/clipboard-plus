import AppIntents
import SwiftUI
import WidgetKit

/// Control Center buttons. They only open clipboard+ in a capture mode: a control cannot take a
/// screenshot, and the history stays inside the app.
@main
struct ClipboardPlusControls: WidgetBundle {
    var body: some Widget {
        TextCaptureControl()
        ImageCaptureControl()
    }
}

struct TextCaptureControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "clipboardplus.capture.text") {
            ControlWidgetButton(action: StartCaptureIntent(mode: .text)) {
                Label("文字を切り取る", systemImage: "text.viewfinder")
            }
        }
        .displayName("文字を切り取る")
        .description("clipboard+を開いて、画面の文字を切り取ります。")
    }
}

struct ImageCaptureControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "clipboardplus.capture.image") {
            ControlWidgetButton(action: StartCaptureIntent(mode: .image)) {
                Label("画像を切り取る", systemImage: "crop")
            }
        }
        .displayName("画像を切り取る")
        .description("clipboard+を開いて、画面の一部を画像として切り取ります。")
    }
}
