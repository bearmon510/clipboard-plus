import SwiftUI

@main
struct ClipboardPlusApp: App {
    @StateObject private var monitor = ClipboardMonitor()

    var body: some Scene {
        WindowGroup {
            ContentView(monitor: monitor, log: monitor.log)
        }
    }
}

