import SwiftUI

@main
struct HomeMapApp: App {
    @StateObject private var settings = Settings()

    init() {
        // crash reports, and a scan that ended without finishing last time, for Home Assistant's log
        if Demo.screen == nil { Diagnostics.shared.start() }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(demo: Demo.screen)
                .environmentObject(settings)
                .preferredColorScheme(.dark)
        }
    }
}
