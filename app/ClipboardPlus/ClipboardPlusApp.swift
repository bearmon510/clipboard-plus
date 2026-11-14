import SwiftUI

@main
struct ClipboardPlusApp: App {
    @StateObject private var monitor = ClipboardPlusApp.makeMonitor()

    /// Recording is on unless the user has paused it. The registered default applies only
    /// until the user's own choice is stored, and only to the app's standard defaults.
    private static func makeMonitor() -> ClipboardMonitor {
        UserDefaults.standard.register(defaults: ["isRecording": true])
        return ClipboardMonitor()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(monitor: monitor, log: monitor.log)
        }
    }
}

