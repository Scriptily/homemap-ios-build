import ARKit
import CoreImage
import FoundationModels
import RoomPlan
import UIKit

/// What the on-device model said about the thing under the crosshair.
@Generable
struct Sighting {
    @Guide(description: "The object at the very center of the photo, in 1 to 4 plain English words, for example \"floor lamp\", \"split air conditioner\", \"shoe rack\", \"wall clock\". Answer \"none\" if the center shows only bare wall, floor, ceiling, a door or a window.")
    var name: String
    @Guide(description: "How sure you are that the name is right, from 0 to 1.", .range(0.0...1.0))
    var confidence: Double
    @Guide(description: "Only when the center is a bare wall, floor or ground: what that surface is made of (paving stones and cobblestones are stone). Otherwise none.",
           .anyOf(["none", "paint", "concrete", "wood", "wallpaper", "brick", "stone", "tile", "marble", "carpet", "grass"]))
    var surface: String
}

/// What a wall or floor is made of (asked by itself while you scan - materials are never picked by hand)
@Generable
struct SurfaceLook {
    @Guide(description: "What the wall, floor or ground at the center of the photo is made of. Plain painted plaster is paint; paving stones and cobblestones are stone; laminate and parquet are wood. Say unsure if it's hidden or too dark to tell.",
           .anyOf(["paint", "concrete", "wood", "wallpaper", "brick", "stone", "tile", "marble", "carpet", "grass", "unsure"]))
    var material: String
}

/// one thing the phone recognized while you scanned: where it is and what it's called
struct FoundThing: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var p: SIMD3<Float>
    var n: SIMD3<Float>
    var confidence: Double
    var seen = 1
    var thumb: Data?                    // small JPEG, so the dashboard (and a later review) can see what it was
    var fix = false                     // named again on purpose (held twice as long): this name wins on the map

    static func == (a: FoundThing, b: FoundThing) -> Bool { a.id == b.id && a.name == b.name && a.seen == b.seen }
}

/// While you scan, names what the crosshair is on with Apple's on-device model (iOS 27: image + text in, a structured
/// answer out - nothing leaves the phone). Asks only when the phone is held fairly still on something 0.3-4 m away,
/// one question at a time, and not again for a spot it already knows.
@MainActor
final class Recognizer: ObservableObject {
    @Published private(set) var items: [FoundThing] = []
    @Published private(set) var lastName = ""          // shown next to the crosshair for a moment
    @Published var enabled: Bool
    @Published private(set) var thinking = false
    /// 0...1: how long you've held the circle still on this spot (the ring fills; full = ask)
    @Published private(set) var dwell: Double = 0
    /// on something already named (or a bare spot): it takes twice as long, so moving around never renames by accident
    @Published private(set) var dwellAgain = false
    static let holdNew: TimeInterval = 1.2, holdAgain: TimeInterval = 2.6
    private var stillSince: Date?
    private var askedThisHold = false
    /// the model saw a mirror (shown as a tip: it can't be placed, but a Mirror tag cleans up its reflection)
    var onMirror: ((SIMD3<Float>) -> Void)?   // where it saw a mirror

    /// surfaces noticed on bare walls and floors ("finish:wood", "floor:marble"...): the map draws them that way
    private(set) var finishes: [(p: SIMD3<Float>, n: SIMD3<Float>, kind: String)] = []
    static let finishNames = ["concrete": "Concrete", "wood": "Wood", "wallpaper": "Wallpaper", "brick": "Brick", "stone": "Stone", "tile": "Tiled"]
    static let floorNames = ["wood": "Wood", "tile": "Tiled", "marble": "Marble", "carpet": "Carpet", "concrete": "Concrete", "stone": "Stone", "grass": "Lawn"]

    private var busy = false
    private var lastAsk = Date.distantPast
    /// walls / floors already looked at by itself (not again within 1.5 m)
    private var looked: [(p: SIMD3<Float>, floor: Bool)] = []
    private var lastLook = Date.distantPast
    private var lookPose: simd_float4x4?
    private var nothing: [(p: SIMD3<Float>, t: Date)] = []
    private var lastPose: simd_float4x4?
    private let ci = CIContext(options: [.useSoftwareRenderer: false])

    /// Apple Intelligence on, model downloaded, this iPhone supported
    static var available: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// why it can't run (shown in the scan intro)
    static var unavailableReason: String {
        switch SystemLanguageModel.default.availability {
        case .available: return ""
        case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in Settings to let the phone name things as you scan."
        case .unavailable(.modelNotReady): return "Apple Intelligence is still getting ready (downloading). Naming things turns on when it's done."
        case .unavailable(.deviceNotEligible): return "This iPhone can't run Apple Intelligence."
        default: return "Apple Intelligence isn't available right now."
        }
    }

    init() { enabled = Recognizer.available }

    private func resetHold() {
        stillSince = nil
        askedThisHold = false
        if dwell != 0 { dwell = 0 }
    }

    /// called ~3x a second with the camera frame and what the crosshair hits: hold the circle still on something and the
    /// ring fills; full = the phone names it. On something it already named it takes twice as long, then names it again.
    func consider(_ frame: ARFrame, aim: (p: SIMD3<Float>, n: SIMD3<Float>)?, hint: ((SIMD3<Float>) -> String?)? = nil) {
        let pose = frame.camera.transform
        defer { lastPose = pose }
        guard enabled, let aim, let prev = lastPose, case .normal = frame.camera.trackingState else { resetHold(); return }
        // very hot: the model waits (naming took 10 s a go on a hot phone, and only made it hotter)
        if ProcessInfo.processInfo.thermalState == .critical { resetHold(); return }
        // too dark to see what it is (ARKit's estimate of the light in lumens; a lit room is ~1000)
        if let light = frame.lightEstimate?.ambientIntensity, light < 180 { resetHold(); return }
        // held still: < 3 cm and < ~4° since the last look
        let move = simd_distance(SIMD3(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z), SIMD3(prev.columns.3.x, prev.columns.3.y, prev.columns.3.z))
        let f0 = -SIMD3(pose.columns.2.x, pose.columns.2.y, pose.columns.2.z), f1 = -SIMD3(prev.columns.2.x, prev.columns.2.y, prev.columns.2.z)
        let cam = SIMD3(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z), d = simd_distance(cam, aim.p)
        guard move < 0.03, simd_dot(f0, f1) > 0.9975, d > 0.3, d < 4 else { resetHold(); return }
        nothing.removeAll { Date().timeIntervalSince($0.t) > 30 }
        let known = items.firstIndex(where: { simd_distance($0.p, aim.p) < 0.2 })
        let again = known != nil
        let empty = nothing.contains(where: { simd_distance($0.p, aim.p) < 0.25 })   // nothing to name here a moment ago
        if dwellAgain != again { dwellAgain = again }
        let since = stillSince ?? Date()
        stillSince = since
        let held = Date().timeIntervalSince(since), need = again || empty ? Self.holdAgain : Self.holdNew
        dwell = min(1, held / need)
        guard held >= need, !askedThisHold, !busy, let (image, thumb) = crop(frame) else { return }
        askedThisHold = true
        busy = true; thinking = true; lastAsk = Date()
        let spot = aim
        // what the depth scanner outlined there (it measures a TV's shape even when the glossy screen only shows reflections)
        let scanned = hint?(aim.p)
        Task {
            defer { busy = false; thinking = false }
            let t0 = Date()
            do {
                let session = LanguageModelSession(instructions: "You look at photos taken inside and around a home and name the household object the camera is pointed at. Use short, common English names. Glossy black screens (TVs, monitors) often show reflections of the room: name the screen, not what's reflected in it.")
                let ask = "What is the object inside the white ring at the center of this photo (where the phone is pointing)? The ring is only a marker drawn on the photo - never name the ring. If it is just a bare wall, floor, ceiling, door or window, say none. If it is a mirror or something seen in a mirror, say mirror."
                    + (scanned.map { " The phone's depth scanner outlined something here as: \($0). Use that only if the photo agrees." } ?? "")
                let answer = try await session.respond(generating: Sighting.self) {
                    ask
                    Attachment(image)
                }.content
                ScanLog.shared.add(String(format: "naming took %.1f s", Date().timeIntervalSince(t0)) + (scanned.map { " (depth scanner: \($0))" } ?? ""))
                self.take(answer, at: spot, thumb: thumb, replacing: known)
            } catch {
                ScanLog.shared.add("naming failed: \(error.localizedDescription)")
                nothing.append((spot.p, Date()))      // context too big, model busy, guardrail... try another spot
            }
        }
    }

    /// a bare surface named like a thing ("floor", "white wall", "tiles"): no thing
    nonisolated static func isSurface(_ name: String) -> Bool {
        let words = name.split(separator: " ").map(String.init)
        guard let head = words.last else { return true }
        return ["none", "floor", "floors", "flooring", "wall", "walls", "ceiling", "ground", "tile", "tiles", "doorway", "door",
                "doors", "window", "windows", "corner", "room", "paint", "plaster", "surface",
                // the ring drawn on the photo to show where the phone points (the model named the ring itself)
                "ring", "circle", "marker", "crosshair", "target"].contains(head)
    }

    private func take(_ s: Sighting, at spot: (p: SIMD3<Float>, n: SIMD3<Float>), thumb: Data?, replacing known: Int?) {
        let name = Self.clean(s.name)
        ScanLog.shared.add("named: \"\(s.name)\" -> \"\(name)\" (sure \(String(format: "%.2f", s.confidence)), surface \(s.surface)\(known != nil ? ", naming again" : ""))")
        // held twice as long on something already named: this is its name now
        if let i = known, i < items.count, !Self.isSurface(name), !name.split(separator: " ").contains("mirror") {
            items[i].name = name
            items[i].fix = true
            items[i].thumb = thumb ?? items[i].thumb
            lastName = "Now: " + name.prefix(1).uppercased() + name.dropFirst()
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            let shown = lastName
            Task { try? await Task.sleep(for: .seconds(2.4)); if self.lastName == shown { self.lastName = "" } }
            return
        }
        // a bare wall (faces sideways) or floor (faces up): note what it's made of
        if name == "none" || name.hasSuffix("wall") || name.hasSuffix("floor") || name == "ground" {
            if abs(spot.n.y) < 0.35, let f = Self.finishNames[s.surface] { noteFinish("finish:" + s.surface, "\(f) wall", at: spot) }
            else if spot.n.y > 0.8, let f = Self.floorNames[s.surface] { noteFinish("floor:" + s.surface, s.surface == "grass" ? f : "\(f) floor", at: spot) }
        }
        guard !name.isEmpty, !Self.isSurface(name) else {
            nothing.append((spot.p, Date()))
            lastName = "Nothing to name here"                 // the ring finished: say so, instead of no answer at all
            let shown = lastName
            Task { try? await Task.sleep(for: .seconds(1.6)); if self.lastName == shown { self.lastName = "" } }
            return
        }
        // a mirror: the depth sensor measured the reflection (behind the wall), so it can't be placed - ask for a Mirror tag instead
        if name.split(separator: " ").contains(where: { $0 == "mirror" || $0 == "reflection" }) {
            nothing.append((spot.p, Date()))
            onMirror?(spot.p)
            return
        }
        // the same thing seen again close by: keep the surer name, average the spot
        if let i = items.firstIndex(where: { $0.name == name && simd_distance($0.p, spot.p) < 0.6 }) {
            var it = items[i]
            it.p = (it.p * Float(it.seen) + spot.p) / Float(it.seen + 1)
            it.seen += 1
            if s.confidence > it.confidence { it.confidence = s.confidence; it.thumb = thumb ?? it.thumb }
            items[i] = it
            return
        }
        guard items.count < 400 else { return }
        items.append(FoundThing(name: name, p: spot.p, n: spot.n, confidence: s.confidence, thumb: thumb))
        lastName = name.prefix(1).uppercased() + name.dropFirst()
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        let shown = lastName
        Task { try? await Task.sleep(for: .seconds(2.2)); if self.lastName == shown { self.lastName = "" } }
    }

    private func noteFinish(_ kind: String, _ label: String, at spot: (p: SIMD3<Float>, n: SIMD3<Float>)) {
        if finishes.contains(where: { $0.kind == kind && simd_distance($0.p, spot.p) < 1.0 }) { return }
        guard finishes.count < 400 else { return }
        finishes.append((spot.p, spot.n, kind))
        guard !label.isEmpty else { return }                  // noticed by itself: quietly
        lastName = label
        let shown = lastName
        Task { try? await Task.sleep(for: .seconds(2.2)); if self.lastName == shown { self.lastName = "" } }
    }

    /// "A Floor Lamp." -> "floor lamp"
    nonisolated static func clean(_ raw: String) -> String {
        var t = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        for a in ["a ", "an ", "the ", "some "] where t.hasPrefix(a) { t.removeFirst(a.count) }
        t = t.split(whereSeparator: { $0.isWhitespace }).prefix(5).joined(separator: " ")
        return t.count > 40 ? String(t.prefix(40)) : t
    }

    func rename(_ id: UUID, to name: String) {
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].name = Self.clean(name) }
    }
    func remove(_ id: UUID) { items.removeAll { $0.id == id } }

    /// the middle of the camera picture (upright), and a small thumbnail of it
    private func crop(_ frame: ARFrame) -> (UIImage, Data?)? {
        let img = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
        let e = img.extent, side = min(e.width, e.height) * 0.6
        let square = img.cropped(to: CGRect(x: e.midX - side / 2, y: e.midY - side / 2, width: side, height: side))
        let scaled = square.transformed(by: CGAffineTransform(scaleX: 512 / side, y: 512 / side))
        guard let cg = ci.createCGImage(scaled, from: scaled.extent) else { return nil }
        let ui = UIImage(cgImage: cg)
        let small = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 160)).image { _ in ui.draw(in: CGRect(x: 0, y: 0, width: 160, height: 160)) }
        let ringed = UIGraphicsImageRenderer(size: ui.size).image { ctx in
            ui.draw(at: .zero)
            let c = CGPoint(x: ui.size.width / 2, y: ui.size.height / 2), r = ui.size.width * 0.07
            ctx.cgContext.setLineWidth(4)
            ctx.cgContext.setStrokeColor(UIColor.black.withAlphaComponent(0.55).cgColor)
            ctx.cgContext.strokeEllipse(in: CGRect(x: c.x - r - 2, y: c.y - r - 2, width: 2 * r + 4, height: 2 * r + 4))
            ctx.cgContext.setStrokeColor(UIColor.white.cgColor)
            ctx.cgContext.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        }
        return (ringed, small.jpegData(compressionQuality: 0.6))
    }

    /// Materials, by itself: every few seconds, when the circle is on a bare wall or the floor a little way off and the
    /// phone is fairly steady, the model is asked what that surface is made of (quietly - nothing to hold, no tag to
    /// pick). Each room then gets the material most of its looks saw (HomeScanModel). Not while you're naming something.
    func lookAtSurface(_ frame: ARFrame, aim: (p: SIMD3<Float>, n: SIMD3<Float>)?) {
        let pose = frame.camera.transform
        defer { lookPose = pose }
        guard enabled, !busy, dwell == 0, let aim, let prev = lookPose, case .normal = frame.camera.trackingState,
              Date().timeIntervalSince(lastLook) > 5, ProcessInfo.processInfo.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue else { return }
        if let light = frame.lightEstimate?.ambientIntensity, light < 250 { return }
        let eye = simd_make_float3(pose.columns.3), d = simd_distance(eye, aim.p)
        let isFloor = aim.n.y > 0.8 && eye.y - aim.p.y > 0.8 && d < 3.2
        let isWall = abs(aim.n.y) < 0.3 && d > 0.7 && d < 3
        guard isFloor || isWall else { return }
        guard simd_distance(eye, simd_make_float3(prev.columns.3)) < 0.08 else { return }
        if looked.contains(where: { $0.floor == isFloor && simd_distance($0.p, aim.p) < 1.5 }) { return }
        if finishes.contains(where: { $0.kind.hasPrefix(isFloor ? "floor:" : "finish:") && simd_distance($0.p, aim.p) < 1.5 }) { return }
        guard let image = plainCrop(frame) else { return }
        lastLook = Date(); busy = true
        looked.append((aim.p, isFloor))
        let spot = aim
        Task {
            defer { busy = false }
            do {
                let session = LanguageModelSession(instructions: "You look at photos taken inside and around a home and say what a wall or floor is made of.")
                let ask = "What is the \(isFloor ? "floor or ground" : "wall") at the center of this photo made of?"
                let answer = try await session.respond(generating: SurfaceLook.self) { ask; Attachment(image) }.content
                let m = answer.material
                ScanLog.shared.add("material (by itself): \(isFloor ? "floor" : "wall") = \(m)")
                if isFloor, Self.floorNames[m] != nil { noteFinish("floor:" + m, "", at: spot) }
                else if !isFloor, Self.finishNames[m] != nil { noteFinish("finish:" + m, "", at: spot) }
            } catch {
                ScanLog.shared.add("material look failed: \(error.localizedDescription)")
            }
        }
    }

    /// the middle of the camera picture (upright), without the ring
    private func plainCrop(_ frame: ARFrame) -> UIImage? {
        let img = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
        let e = img.extent, side = min(e.width, e.height) * 0.45
        let square = img.cropped(to: CGRect(x: e.midX - side / 2, y: e.midY - side / 2, width: side, height: side))
        let scaled = square.transformed(by: CGAffineTransform(scaleX: 384 / side, y: 384 / side))
        guard let cg = ci.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// a fresh map section: everything named so far moves into the new AR world
    func rebase(_ m: simd_float4x4) {
        looked = looked.map { (p: Frames.apply(m, $0.p), floor: $0.floor) }
        for i in items.indices { items[i].p = Frames.apply(m, items[i].p); items[i].n = Frames.turn(m, items[i].n) }
        finishes = finishes.map { (p: Frames.apply(m, $0.p), n: Frames.turn(m, $0.n), kind: $0.kind) }
        nothing = nothing.map { (p: Frames.apply(m, $0.p), t: $0.t) }
    }

    /// marks for the scan: [{type: "found", name, p, n, conf, seen, thumb, rp}] (rp = the RoomPlan object it's part of),
    /// in the home's frame. `fixes`: each room's AR world -> the live one; `toHome`: the live world -> the home.
    func marks(rooms: [CapturedRoom], fixes: [simd_float4x4] = [], toHome: simd_float4x4 = matrix_identity_float4x4) -> [[String: Any]] {
        let P = { (p: SIMD3<Float>) -> [Float] in let w = Frames.apply(toHome, p); return [w.x, w.y, w.z] }
        let N = { (n: SIMD3<Float>) -> [Float] in let w = Frames.turn(toHome, n); return [w.x, w.y, w.z] }
        return finishes.map { f in
            ["type": "object", "kind": f.kind, "p": P(f.p), "n": N(f.n), "auto": true] as [String: Any]
        } + items.map { it in
            var m: [String: Any] = ["type": "found", "name": it.name, "p": P(it.p), "n": N(it.n),
                                    "conf": (it.confidence * 100).rounded() / 100, "seen": it.seen]
            if let t = it.thumb { m["thumb"] = t.base64EncodedString() }
            if let rp = Self.roomPlanObject(at: it.p, in: rooms, fixes: fixes) { m["rp"] = rp }
            if it.fix { m["fix"] = true }
            return m
        }
    }

    /// the RoomPlan furniture box this spot is on / in (with a little margin), if any
    nonisolated static func roomPlanObject(at p: SIMD3<Float>, in rooms: [CapturedRoom], fixes: [simd_float4x4] = []) -> String? {
        for (i, r) in rooms.enumerated() {
            let m = i < fixes.count ? fixes[i] : matrix_identity_float4x4
            for o in r.objects where o.category != .stairs && inside(p, transform: m * o.transform, size: o.dimensions, margin: 0.12) { return o.identifier.uuidString }
        }
        return nil
    }

    nonisolated static func inside(_ p: SIMD3<Float>, transform: simd_float4x4, size: SIMD3<Float>, margin: Float) -> Bool {
        let local = transform.inverse * SIMD4<Float>(p.x, p.y, p.z, 1)
        return abs(local.x) <= size.x / 2 + margin && abs(local.y) <= size.y / 2 + margin && abs(local.z) <= size.z / 2 + margin
    }

    /// demo / screenshots
    func preview(_ things: [FoundThing], last: String) { items = things; lastName = last }
}
