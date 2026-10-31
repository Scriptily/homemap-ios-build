import SwiftUI
import UIKit

/// "Live session with Claude" (a switch in the menu, off by default): for testing the app together while you walk.
/// - messages from the PC show in a blue banner at the top ("point at the ceiling", "walk into the hallway")
/// - the PC can press the scan's buttons (pause, new room, garden, flashlight, finish...) - never "throw away"
/// - the app tells the PC how the scan is going every 2 s (what's on screen, the room's progress, heat, the last log lines)
/// - a screenshot only when the PC asks, and the screen says so each time
/// Everything goes through the paired Home Assistant over your Wi-Fi, held in its memory only (nothing is stored).
@MainActor
final class LiveSession: ObservableObject {
    static let shared = LiveSession()

    @Published var on: Bool { didSet { UserDefaults.standard.set(on, forKey: "liveSession"); on ? start() : stop() } }
    @Published var message = ""
    private var client: HAClient?
    private weak var model: HomeScanModel?
    private var listening: Task<Void, Never>?
    private var reporting: Task<Void, Never>?
    private var since = 0
    private var messageClear: Task<Void, Never>?

    init() { on = UserDefaults.standard.bool(forKey: "liveSession") }

    /// the paired Home Assistant (nil = not paired / demo)
    func configure(_ c: HAClient?) {
        client = c
        if on, c != nil { start() } else if c == nil { stop() }
    }

    /// the scan on screen (nil = back on the start screen)
    func attach(_ m: HomeScanModel?) {
        model = m
        if on { post(["event": m == nil ? "scan closed" : "scan opened: \(m!.mode.rawValue)"]) }
    }

    private func start() {
        guard client != nil, listening == nil else { return }
        listening = Task { await listen() }
        reporting = Task { await report() }
        post(["event": "live session on"])
    }

    private func stop() {
        listening?.cancel(); reporting?.cancel()
        listening = nil; reporting = nil
        message = ""
    }

    private func post(_ o: [String: Any]) {
        guard let c = client else { return }
        Task { try? await c.livePost(o) }
    }

    private func listen() async {
        // only what's sent from now on (not old messages from an earlier session)
        if let c = client, let r = try? await c.live(since: 0, wait: 0) { since = r.seq }
        while !Task.isCancelled {
            guard let c = client else { return }
            do {
                let r = try await c.live(since: since, wait: 20)
                for m in r.messages {
                    since = max(since, (m["seq"] as? NSNumber)?.intValue ?? since)
                    await handle(m)
                }
            } catch {
                try? await Task.sleep(for: .seconds(3))       // Home Assistant down: try again in a moment
            }
        }
    }

    private func report() async {
        while !Task.isCancelled {
            post(["status": status()])
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func handle(_ m: [String: Any]) async {
        if let say = m["say"] as? String {
            withAnimation(Theme.spring) { message = say }
            if !say.isEmpty { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
            messageClear?.cancel()
            messageClear = Task { [weak self] in
                try? await Task.sleep(for: .seconds(90))
                guard !Task.isCancelled else { return }
                withAnimation(Theme.spring) { self?.message = "" }
            }
        }
        if let cmd = m["cmd"] as? String {
            let (ok, note) = await run(cmd, m["arg"])
            post(["done": cmd, "ok": ok, "note": note, "status": status()])
        }
    }

    /// the scan's buttons, by name. Throwing a scan away is never one of them.
    private func run(_ cmd: String, _ arg: Any?) async -> (Bool, String) {
        if cmd == "shot" { return await shot() }
        guard let m = model else { return (false, "no scan on screen (start screen)") }
        switch cmd {
        case "start": guard m.phase == .intro else { return (false, "not on the intro") }; m.start()
        case "lockskip": guard m.phase == .locking else { return (false, "not locking on") }; m.skipLock()
        case "pause": await m.pause()
        case "resume": m.resume()
        case "newroom": await m.nextRoom()
        case "garden": await m.goOutside()
        case "inside": guard m.phase == .outside else { return (false, "not in the garden") }; m.backInside()
        case "finish": await m.finish()
        case "send": guard m.phase == .review else { return (false, "not on the review") }; await m.send()
        case "torch": if (arg as? Bool) != m.torch { m.toggleTorch() }
        case "floor": guard let i = (arg as? NSNumber)?.intValue else { return (false, "floor needs a number (0 = First floor)") }; m.setFloor(i)
        case "measure": m.measureTap()
        case "tag":
            guard let kind = arg as? String, let k = TagCatalog.groups.flatMap(\.items).first(where: { $0.kind == kind }) else { return (false, "unknown tag kind") }
            m.beginTag(); m.finishTag(k, name: "")
        case "redo": await m.redoRoom()
        case "naming": m.recognizer.enabled = (arg as? Bool) ?? !m.recognizer.enabled
        default: return (false, "unknown command")
        }
        return (true, "")
    }

    /// what's on screen and how the scan is going
    private func status() -> [String: Any] {
        var s: [String: Any] = ["health": ScanLog.health(), "log": ScanLog.shared.tail(6)]
        guard let m = model else { s["screen"] = "start"; return s }
        let p = m.progress
        s["screen"] = "scan"
        s["phase"] = "\(m.phase)"; s["mode"] = m.mode.rawValue
        s["floor"] = m.floorName; s["rooms"] = m.roomsDone; s["area"] = Int(m.area)
        s["progress"] = ["percent": p.percent, "walls": p.walls, "floor": p.floor as Any, "ceiling": p.ceiling as Any, "missing": p.missing,
                         "size": [p.size.x, p.size.y]]
        s["tip"] = m.tip; s["flash"] = m.flash; s["aim"] = m.aimText; s["torch"] = m.torch; s["held"] = m.controller.held
        s["named"] = m.recognizer.items.count; s["lastNamed"] = m.recognizer.lastName; s["tags"] = m.tagCount
        s["garden"] = m.gardenText; s["gardenHint"] = m.gardenHint; s["saved"] = m.saved?.name as Any
        return s
    }

    /// a small screenshot of the app (and of the camera view, which a screenshot of the app may leave black) - only when
    /// asked, and the screen says so
    private func shot() async -> (Bool, String) {
        guard let win = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return (false, "no window") }
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        let ui = UIGraphicsImageRenderer(bounds: win.bounds, format: fmt).image { _ in win.drawHierarchy(in: win.bounds, afterScreenUpdates: false) }
        var out: [String: Any] = ["shot": Self.small(ui)]
        if let m = model, !m.demo {
            let cam: UIImage? = await withCheckedContinuation { k in m.controller.arView.snapshot(saveToHDR: false) { k.resume(returning: $0) } }
            if let cam { out["camera"] = Self.small(cam) }
        }
        post(out)
        if let m = model { m.show("Claude took a screenshot") } else { message = "Claude took a screenshot" }
        return (true, "")
    }

    private static func small(_ img: UIImage) -> String {
        let w: CGFloat = 390, h = img.size.height * w / max(1, img.size.width)
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        let s = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: fmt).image { _ in img.draw(in: CGRect(x: 0, y: 0, width: w, height: h)) }
        return s.jpegData(compressionQuality: 0.55)?.base64EncodedString() ?? ""
    }
}
