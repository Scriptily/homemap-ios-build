import XCTest

/// Opens every screen of the app with made-up data (`-demo <screen>`), saves a screenshot of each (SHOT_DIR) and
/// checks that every visible button is on screen and doesn't overlap another one.
final class ScreensUITests: XCTestCase {
    static let screens = ["home-unpaired", "home-new", "home", "home-offline",
                          "scan-intro-new", "scan-intro-add", "scan-intro-tags", "scan-locking",
                          "scan-scanning", "scan-done-room", "scan-saved", "scan-rename", "scan-paused", "scan-garden-hint", "scan-live",
                          "scan-outside", "scan-tags", "scan-tagpicker", "scan-menu",
                          "scan-review", "scan-uploading", "scan-done", "scan-failed"]

    override func setUp() {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait   // the app is portrait-only; a landscape simulator letterboxes it
    }

    func testEveryScreen() throws {
        let env = ProcessInfo.processInfo.environment
        let dir = URL(fileURLWithPath: env["SHOT_DIR"] ?? NSTemporaryDirectory(), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dev = env["DEV"] ?? "iphone"
        for s in Self.screens {
            let app = XCUIApplication()
            app.launchArguments = ["-demo", s]
            app.launch()
            _ = app.wait(for: .runningForeground, timeout: 10)
            Thread.sleep(forTimeInterval: 2.2)            // let the springs and sheets settle
            let png = XCUIScreen.main.screenshot().pngRepresentation
            try png.write(to: dir.appendingPathComponent("\(dev)-\(s).png"))
            checkLayout(app, screen: s)
            // (the next launch replaces it; terminate() itself is flaky on the simulator)
        }
    }

    /// buttons inside the screen and not on top of each other. Buttons in scrolling content (lists, the room-name chips)
    /// may run past the edge and pass under fixed bars - those are only checked against each other.
    private func checkLayout(_ app: XCUIApplication, screen: String) {
        let win = app.windows.firstMatch.frame
        let containers = app.scrollViews.allElementsBoundByIndex + app.collectionViews.allElementsBoundByIndex + app.tables.allElementsBoundByIndex
        let scrolled = Set(containers.flatMap { $0.descendants(matching: .button).allElementsBoundByIndex.map { "\($0.frame)" } })
        let buttons = app.buttons.allElementsBoundByIndex.filter { $0.exists && $0.isHittable && $0.frame.width > 1 && $0.frame.height > 1 }
        var frames: [(String, CGRect, Bool)] = []
        for b in buttons {
            let f = b.frame, inScroll = scrolled.contains("\(f)")
            let label = b.label.isEmpty ? b.identifier : b.label
            if !inScroll && !win.insetBy(dx: -1, dy: -1).contains(f) { XCTFail("\(screen): '\(label)' sticks out of the screen \(f)") }
            frames.append((label, f, inScroll))
        }
        for i in 0..<frames.count {
            for j in (i + 1)..<frames.count where frames[i].2 == frames[j].2 {
                let a = frames[i].1, b = frames[j].1
                let x = a.intersection(b)
                // nested (a chip inside a row) is fine; a real overlap of 4+ pt both ways is not
                if x.width > 4 && x.height > 4 && !a.contains(b) && !b.contains(a) {
                    XCTFail("\(screen): '\(frames[i].0)' overlaps '\(frames[j].0)' (\(Int(x.width))×\(Int(x.height)) pt)")
                }
            }
        }
    }
}
