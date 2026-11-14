import SwiftUI

@main
struct ClipboardPlusApp: App {
    @StateObject private var monitor = ClipboardPlusApp.makeMonitor()

    /// Recording is on unless the user has paused it. The registered default applies only
    /// until the user's own choice is stored, and only to the app's standard defaults.
    private static func makeMonitor() -> ClipboardMonitor {
        // Unit tests run inside this app as their host. A recording host app would poll the
        // simulator's pasteboard and write to the shared log while tests run, so skip it there.
        let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if !isTestHost {
            UserDefaults.standard.register(defaults: ["isRecording": true])
        }
        return ClipboardMonitor()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(monitor: monitor, log: monitor.log)
        }
    }
}

