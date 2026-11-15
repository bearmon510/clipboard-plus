import SwiftUI

@main
struct ClipboardPlusApp: App {
    @StateObject private var monitor = ClipboardMonitor.shared

    var body: some Scene {
        WindowGroup {
            ContentView(monitor: monitor, log: monitor.log)
        }
    }
}

