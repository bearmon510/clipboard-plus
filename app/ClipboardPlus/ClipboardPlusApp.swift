import SwiftUI

@main
@MainActor
struct ClipboardPlusApp: App {
    @StateObject private var monitor = ClipboardMonitor.shared

    init() {
        // Eagerly restore Bluetooth even when launched in the background without a window.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            _ = PCSyncController.shared
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(monitor: monitor, log: monitor.log)
        }
    }
}

