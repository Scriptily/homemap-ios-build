import ARKit
import RoomPlan
import SwiftUI

/// Sends a finished scan to Home Assistant (it waits on the phone until every part is in), then the phone's map
/// of the place for next time. Used by a scan that just finished, by "Send" on the start screen and by the automatic
/// retry when Home Assistant comes back.
enum Uploader {
    static func send(_ pending: PendingScan, client: HAClient, progress: @escaping (String) -> Void) async throws {
        for i in 0..<pending.parts {
            progress(pending.parts > 1 ? "Sending to Home Assistant (\(i + 1) of \(pending.parts))…" : "Sending to Home Assistant…")
            try await client.upload(scan: pending.id, kind: pending.kind, level: "ground", name: pending.name, part: i, of: pending.parts, data: try pending.load(i))
        }
        if let world = pending.world() {
            progress("Saving the map of your home for next time…")
            try await WorldMapStore.upload(archive: world, id: "w" + pending.id.dropFirst(), client: client, name: pending.name)
        }
        pending.remove()
    }
}

/// one row of the tag list
struct TagRow: Identifiable { let id: Int; let title: String; let detail: String; let icon: String }

/// one room of this scan, for the review before sending (and the "saved" note while scanning)
struct RoomRow: Identifiable, Equatable {
    let id: Int                // index in the controller's rooms
    var name: String           // what you called it, else the phone's guess, else ""
    var guessed: Bool          // the name is the phone's guess (not typed or picked)
    let floor: Int             // 0 = First floor
    let area: Float
    let warn: String           // a door that came out an odd size
}

@MainActor
final class HomeScanModel: ObservableObject {
    enum Phase { case intro, locking, scanning, paused, processing, outside, tagging, review, uploading, done, failed }
    @Published var phase: Phase = .intro { didSet { if phase != oldValue { ScanLog.shared.add("phase: \(phase)") } } }
    /// when locking on started (after a while, starting without it is offered more strongly)
    @Published var lockStart = Date()
    /// what the lock-on is doing ("" = still looking): found it, checking it lines up, wrong spot...
    @Published var lockText = ""
    @Published var tip = ""
    @Published var flash = ""
    @Published var roomsDone = 0
    @Published var area: Float = 0
    @Published var objects = 0
    @Published var lights = 0
    /// how far along the room you're in is (its outline, floor and ceiling)
    @Published var progress = RoomProgress()
    @Published var aimText = ""
    @Published var tagging = false
    @Published var tagCount = 0
    @Published var showTags = false
    @Published var undoText = ""
    private var undoClear: Task<Void, Never>?
    @Published var gardenText = ""
    /// you seem to be outside: the garden is offered
    @Published var gardenHint = false
    @Published var measuring = false
    /// where you start (ground = First floor, first = Second floor, outdoor = the garden)
    @Published var startLevel: String
    /// the floor you're on now (0 = First floor)
    @Published var floor = 0
    @Published var torch = false
    /// "Bedroom saved" for a few seconds after a room saves, with Rename
    @Published var saved: RoomRow?
    private var savedClear: Task<Void, Never>?
    /// the room being renamed (sheet)
    @Published var renaming: Int?
    /// the X menu: finish, start this room over, discard
    @Published var showMenu = false
    @Published var confirmDiscard = false
    @Published var confirmRedo = false
    /// every room so far, for the review
    @Published var rooms: [RoomRow] = []
    /// furniture and things too (always on in the app now; kept for the export format)
    var withObjects = true
    /// Re-scan only to add the furniture: the room on the map keeps its walls and floor
    @Published var keepRoom = false
    @Published var result = ""
    private var tagSpot: (p: SIMD3<Float>, n: SIMD3<Float>)?
    private var measureA: SIMD3<Float>?
    /// thrown away: nothing may be saved after this (a room finishing a moment later brought a discarded scan back)
    private var discarded = false

    let controller: HomeScanController
    let recognizer = Recognizer()
    let scanID = "h" + String(Int(Date().timeIntervalSince1970))
    let name: String
    let mode: ScanMode
    let baseScan: String?
    let replaceAll: Bool
    let demo: Bool
    private let client: HAClient?
    private var finishedArea: Float = 0
    private var finishedObjects = 0
    /// everything but the found things, kept while you review
    private var package: (main: [String: Any], chunks: [[[String: Any]]], world: WorldPack?)?

    init(name: String, client: HAClient?, mode: ScanMode = .new, pack: WorldPack? = nil, baseScan: String? = nil,
         replaceAll: Bool = false, startLevel: String = "ground", demo: Bool = false) {
        self.name = name
        self.client = client
        self.mode = mode
        self.baseScan = baseScan
        self.replaceAll = replaceAll
        self.startLevel = startLevel
        self.demo = demo
        controller = HomeScanController(pack: pack, demo: demo)
        if !demo, mode != .tags, Keyframes.on { controller.keyframes = Keyframes(scan: scanID) }
        controller.client = client
        controller.mode = mode
        controller.onProgress = { [weak self] p in
            MainActor.assumeIsolated {   // sent on the main thread
                guard let self, self.phase == .scanning else { return }
                self.progress = p
                self.area = self.finishedArea + p.area
            }
        }
        controller.onInstruction = { [weak self] t in Task { @MainActor in
            if !t.isEmpty { ScanLog.shared.add("RoomPlan says: \(t)") }
            withAnimation(Theme.spring) { self?.tip = t } } }
        controller.onTracking = { [weak self] t in Task { @MainActor in
            guard let self else { return }
            ScanLog.shared.add("tracking: \(t ?? "ok again")")
            if let t { withAnimation(Theme.spring) { self.tip = t } }
            else if self.tip.hasPrefix("Keep the camera") || self.tip.hasPrefix("Slow down") { withAnimation(Theme.spring) { self.tip = "" } }
        } }
        controller.onRoomLost = { [weak self] err, kept in Task { @MainActor in
            guard let self else { return }
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            withAnimation(Theme.spring) {
                let big: Bool = { if let e = err as? RoomCaptureSession.CaptureError, case .exceedSceneSizeLimit = e { return true }; return false }()
                self.tip = kept && big ? "That room got too big to scan in one go - it's saved. Carrying on with the next."
                    : kept ? "Scanning stopped for a moment (a popup or the camera was covered) - what you scanned is kept. Carry on."
                           : "Lost track of the room - scanning this room again from here."
                if !kept { self.area = self.finishedArea; self.progress = RoomProgress() }
            }
        } }
        controller.onAim = { [weak self] d in
            // the depth sensor reads up to ~5 m: past that, walls and furniture need you closer
            Task { @MainActor in self?.aimText = d.map { $0 < 1 ? String(format: "%.0f cm", $0 * 100) : $0 > 5 ? String(format: "%.1f m · walk closer", $0) : String(format: "%.1f m", $0) } ?? "" }
        }
        controller.onFrame = { [weak self] frame, aim in
            MainActor.assumeIsolated {   // the controller's look timer runs on the main thread
                guard let self, !self.controller.held else { return }
                self.recognizer.consider(frame, aim: aim, hint: { [weak self] p in self?.controller.roomPlanGuess(at: p) })
                self.recognizer.lookAtSurface(frame, aim: aim)
                let n = self.controller.lights.lights.count
                if self.lights != n { withAnimation(Theme.spring) { self.lights = n } }
            }
        }
        controller.onLocked = { [weak self] in Task { @MainActor in self?.locked() } }
        controller.onLockStage = { [weak self] t in Task { @MainActor in withAnimation(Theme.spring) { self?.lockText = t } } }
        controller.onSection = { [weak self] t in Task { @MainActor in
            guard let self else { return }
            UINotificationFeedbackGenerator().notificationOccurred(t.isEmpty ? .success : .warning)
            withAnimation(Theme.spring) { self.tip = t.isEmpty ? "Fresh map section started - carry on scanning" : t }
        } }
        controller.onRebase = { [weak self] m in MainActor.assumeIsolated { self?.recognizer.rebase(m) } }
        controller.onFloorChange = { [weak self] dy in Task { @MainActor in await self?.floorChanged(dy) } }
        controller.onLeftRoom = { [weak self] why in Task { @MainActor in await self?.walkedOut(why) } }
        controller.onLooksOutside = { [weak self] in Task { @MainActor in self?.offerGarden() } }
        controller.overlay.nameNear = { [weak self] p, r in
            MainActor.assumeIsolated { self?.recognizer.items.first { simd_distance($0.p, p) < r }?.name }
        }
        recognizer.onMirror = { [weak self] p in
            Task { @MainActor in
                guard let self, Date().timeIntervalSince(self.lastMirrorTip) > 30 else { return }
                // already tagged there (tagged first, then the ring finished on it): nothing to suggest
                if self.controller.hasTag(prefix: "mirror", near: p, within: 1.0) { ScanLog.shared.add("mirror seen - already tagged"); return }
                self.lastMirrorTip = Date()
                self.show("That looks like a mirror: tag it as Mirror so its reflection is cleaned up")
            }
        }
        controller.onGarden = { [weak self] d in
            Task { @MainActor in
                guard let self else { return }
                guard let d else { self.gardenText = ""; return }
                self.gardenText = abs(d) < 0.08 ? "The garden is level with the house floor"
                    : String(format: "The ground here is %.0f cm %@ the house floor", abs(d) * 100, d > 0 ? "below" : "above")
            }
        }
        controller.onRoomDone = { [weak self] res in Task { @MainActor in self?.roomDone(res) } }
    }

    var needsLock: Bool { controller.worldMap != nil }
    var scanningPhases: Bool { [.scanning, .paused, .outside, .tagging].contains(phase) }
    var floorName: String { Levels.name(floor) }

    /// a sheet or menu is open (or a pause): nothing happens by itself meanwhile - no new room, no floor change, no naming
    func hold(_ on: Bool) {
        let h = on || tagging || showTags || renaming != nil || showMenu || confirmDiscard || confirmRedo
        if controller.held != h { controller.held = h; ScanLog.shared.add(h ? "on hold (a sheet is open)" : "carrying on") }
    }

    // MARK: rooms

    nonisolated static func guess(_ r: CapturedRoom) -> String {
        switch r.sections.first?.label {
        case .bedroom?: return "Bedroom"
        case .bathroom?: return "Bathroom"
        case .diningRoom?: return "Dining room"
        case .kitchen?: return "Kitchen"
        case .livingRoom?: return "Living room"
        default: return ""
        }
    }

    /// "Doors 90×205, 88×204 · Windows 140×120 cm (W×H)" - RoomPlan measures the doorway (frame to frame), not the slab
    static func openings(_ r: CapturedRoom) -> (String, String) {
        openingsText(doors: r.doors.map(\.dimensions), windows: r.windows.map(\.dimensions))
    }

    /// sizes are RoomPlan's dimensions: x = width, y = height (meters)
    nonisolated static func openingsText(doors: [SIMD3<Float>], windows: [SIMD3<Float>]) -> (String, String) {
        let cm = { (v: Float) in Int((v * 100).rounded()) }
        let size = { (d: SIMD3<Float>) in "\(cm(d.x))×\(cm(d.y))" }
        var parts: [String] = []
        if !doors.isEmpty { parts.append((doors.count == 1 ? "Door " : "Doors ") + doors.map(size).joined(separator: ", ")) }
        if !windows.isEmpty { parts.append((windows.count == 1 ? "Window " : "Windows ") + windows.map(size).joined(separator: ", ")) }
        let odd = doors.filter { $0.y < 1.85 || $0.y > 2.4 || $0.x < 0.6 || $0.x > 1.9 }.count
        let warn = odd == 0 ? "" : (odd == 1 ? "A door" : "\(odd) doors") + " came out an unusual size - use Measure on it, or fix it on the map (Edit → tap the door)."
        return (parts.isEmpty ? "" : parts.joined(separator: " · ") + " cm (W×H)", warn)
    }

    static func area(_ r: CapturedRoom) -> Float {
        let f = r.floors.reduce(Float(0)) { $0 + abs(Triangulate.signedArea($1.polygonCorners.map { SIMD2($0.x, $0.y) })) }
        if f > 0 { return f }
        // no floor worked out (a part of a room): the outline of its walls
        let ends = r.walls.flatMap { w -> [SIMD2<Float>] in
            let c = w.transform.columns.3, d = w.transform.columns.0
            let e = RoomShape.ends(center: SIMD2(c.x, c.z), along: SIMD2(d.x, d.z), length: w.dimensions.x)
            return [e.0, e.1]
        }
        return RoomShape.area(RoomShape.hull(ends))
    }

    /// a room saved: counted, named by the phone's guess, shown for a few seconds with Rename (never a question that
    /// waits - names can be fixed at the end, before sending)
    private func roomDone(_ res: RoomResult) {
        guard !discarded else { return }
        switch res {
        case .failed(let err):
            ScanLog.shared.add("room didn't save: \(err.localizedDescription)", now: true)
            tip = "That room didn't save (\(err.localizedDescription)). Scan it again."
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .empty:
            break
        case .saved(let i):
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            let r = controller.rooms[i]
            ScanLog.shared.add("room \(i + 1) saved: \(r.walls.count) walls, \(r.doors.count) doors, \(r.windows.count) windows, \(r.openings.count) openings, "
                + "\(r.objects.count) objects, \(String(format: "%.1f", Self.area(r))) m², floor \(controller.roomLevel[i].map { $0 + 1 } ?? 0) | \(ScanLog.health())", now: true)
            let fg = floorGuess(i)
            if !fg.isEmpty { controller.roomFloors[i] = fg }
            let wg = wallGuess(i)
            if !wg.isEmpty { controller.roomFinishes[i] = wg }
            refreshRooms()
            Task { await checkpoint() }
            if let row = rooms.first(where: { $0.id == i }) {
                withAnimation(Theme.spring) { saved = row }
                savedClear?.cancel()
                savedClear = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(6))
                    guard !Task.isCancelled else { return }
                    withAnimation(Theme.spring) { self?.saved = nil }
                }
            }
        }
    }

    /// the room list from the controller: one row per room (a paused room's two parts are one)
    func refreshRooms() {
        let c = controller
        let merged = Set(c.mergeInto.values)
        rooms = c.rooms.indices.filter { !merged.contains($0) && !c.partials.contains($0) || c.mergeInto[$0] != nil }.map { i in
            let r = c.rooms[i]
            let typed = c.roomNames[i]
            var g = Self.guess(r)
            if g.isEmpty, let p = c.mergeInto[i] { g = Self.guess(c.rooms[p]) }
            return RoomRow(id: i, name: typed ?? g, guessed: typed == nil, floor: c.roomLevel[i] ?? 0,
                           area: Self.area(r) + (c.mergeInto[i].map { Self.area(c.rooms[$0]) } ?? 0), warn: Self.openings(r).1)
        }
        roomsDone = rooms.count
        finishedArea = rooms.reduce(0) { $0 + $1.area }
        finishedObjects = c.rooms.reduce(0) { $0 + $1.objects.count }
        area = finishedArea
        objects = finishedObjects
    }

    private var namesChanged = false
    func renameRoom(_ i: Int, _ name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        controller.roomNames[i] = n.isEmpty ? nil : n
        if package != nil { namesChanged = true }
        ScanLog.shared.add("room \(i + 1) named \"\(n)\"")
        refreshRooms()
        if saved?.id == i { saved = rooms.first { $0.id == i } }
    }

    /// what the phone's naming saw on this room's floor most often
    private func floorGuess(_ i: Int) -> String {
        guard i < controller.rooms.count, let f = controller.rooms[i].floors.first else { return "" }
        let tf = controller.fix(i) * f.transform
        let poly = f.polygonCorners.map { c -> SIMD2<Float> in let w = tf * SIMD4(c.x, c.y, c.z, 1); return SIMD2(w.x, w.z) }
        var votes: [String: Int] = [:]
        for v in recognizer.finishes where v.kind.hasPrefix("floor:") && Floorplan.inside(SIMD2(v.p.x, v.p.z), poly) { votes[String(v.kind.dropFirst(6)), default: 0] += 1 }
        return votes.max { $0.value < $1.value }?.key ?? ""
    }

    /// what the phone's looks at this room's walls saw most (looks within 40 cm of its outline); "" = nothing / plain paint
    private func wallGuess(_ i: Int) -> String {
        guard i < controller.rooms.count else { return "" }
        let r = controller.rooms[i], m = controller.fix(i)
        let ends = r.walls.flatMap { w -> [SIMD2<Float>] in
            let tf = m * w.transform, c = tf.columns.3, d = tf.columns.0
            let e = RoomShape.ends(center: SIMD2(c.x, c.z), along: SIMD2(d.x, d.z), length: w.dimensions.x)
            return [e.0, e.1]
        }
        let poly = RoomShape.hull(ends)
        guard poly.count >= 3 else { return "" }
        var votes: [String: Int] = [:]
        for v in recognizer.finishes where v.kind.hasPrefix("finish:") && Floorplan.outside(SIMD2(v.p.x, v.p.z), poly) < 0.4 {
            votes[String(v.kind.dropFirst(7)), default: 0] += 1
        }
        return votes.max { $0.value < $1.value }?.key ?? ""
    }

    // MARK: tags

    /// Tag: grab what's under the circle right away (the spot, and the line of sight in case the depth sensor can't hit
    /// it - a mirror, glass, something far), then ask what it is
    private var tagRay: (o: SIMD3<Float>, d: SIMD3<Float>)?
    func beginTag() {
        // tracking just came back (or the world jumped): a tag placed now can land in the wrong spot
        guard controller.steady else { show("Hold on a second - the phone is finding its place again"); return }
        tagSpot = controller.aim()
        tagRay = controller.sightLine()
        ScanLog.shared.add("tag: started, " + (tagSpot.map { s in String(format: "the circle hit something %.2f m away", tagRay.map { simd_distance($0.o, s.p) } ?? 0) }
                                                   ?? "no depth hit under the circle"))
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        tagging = true
    }

    func finishTag(_ k: TagKind?, name: String) {
        tagging = false
        defer { tagSpot = nil; tagRay = nil }
        guard let k else { ScanLog.shared.add("tag: cancelled"); return }
        var spot = tagSpot, how = "where the circle hit"
        // a mirror: the depth sensor measures the reflection behind the glass - it goes on the upright surface the glass
        // is on (a wall, a dresser front). Nothing hit at all: the nearest surface along the circle, else 1.2 m ahead
        let mirror = k.kind.hasPrefix("mirror")
        if let r = tagRay, mirror || spot == nil {
            if let s = controller.spotOnPlanes(r, vertical: true) ?? (spot == nil ? controller.spotOnPlanes(r, vertical: false) : nil) {
                spot = s; how = "on the nearest surface along the circle"
            } else if spot == nil {
                spot = (r.o + r.d * 1.2, -r.d); how = "1.2 m ahead (no surface found)"
            }
        }
        guard let spot else { ScanLog.shared.add("tag: \(k.kind) not placed (no camera)"); show("Couldn't place it - try again"); return }
        controller.addTag(kind: k.kind, name: name, at: spot)
        tagCount = controller.tags.count
        ScanLog.shared.add("tag: \(k.kind)\(name.isEmpty ? "" : " \"\(name)\"") placed \(how)", now: true)
        offerUndo("\(name.isEmpty ? k.name : name) tagged")
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// "<thing> tagged - Undo" for a few seconds
    private func offerUndo(_ text: String) {
        withAnimation(Theme.spring) { undoText = text }
        undoClear?.cancel()
        undoClear = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation(Theme.spring) { self?.undoText = "" }
        }
    }

    func undoLastTag() {
        undoClear?.cancel()
        removeTag(at: controller.tags.count - 1)
        withAnimation(Theme.spring) { undoText = "" }
    }

    func removeTag(at i: Int) {
        controller.removeTag(at: i)
        tagCount = controller.tags.count
        if tagCount == 0 { showTags = false }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// the tags so far, for the list: what each is
    var tagList: [TagRow] {
        controller.tags.enumerated().map { i, t in
            if (t["type"] as? String) == "measure", let a = t["a"] as? [Float], let b = t["b"] as? [Float], a.count == 3, b.count == 3 {
                let d = simd_distance(SIMD3(a[0], a[1], a[2]), SIMD3(b[0], b[1], b[2]))
                return TagRow(id: i, title: "Measurement", detail: d < 1 ? String(format: "%.0f cm", d * 100) : String(format: "%.2f m", d), icon: "ruler")
            }
            let kind = t["kind"] as? String ?? ""
            let k = TagCatalog.groups.flatMap(\.items).first { $0.kind == kind }
            let name = t["name"] as? String ?? ""
            return TagRow(id: i, title: name.isEmpty ? (k?.name ?? kind) : name, detail: name.isEmpty ? "" : (k?.name ?? kind), icon: k?.icon ?? "mappin")
        }
    }

    /// Measure: aim + tap for the start, aim + tap for the end; the line is kept on the map
    func measureTap() {
        guard controller.steady else { show("Hold on a second - the phone is finding its place again"); return }
        guard let spot = controller.aim() else { show("Point the circle at a surface first."); return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if let a = measureA {
            let d = simd_distance(a, spot.p)
            controller.addMeasure(a, spot.p)
            measureA = nil
            measuring = false
            offerUndo(d < 1 ? String(format: "%.0f cm measured", d * 100) : String(format: "%.2f m measured", d))
            tagCount = controller.tags.count
        } else {
            measureA = spot.p
            measuring = true
            show("Start set. Aim at the end and tap Measure again.")
        }
    }

    /// a short message; it always goes away after ~3 s
    private var flashClear: Task<Void, Never>?
    func show(_ text: String) {
        withAnimation(Theme.spring) { flash = text }
        flashClear?.cancel()
        flashClear = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(Theme.spring) { self?.flash = "" }
        }
    }

    // MARK: the walk

    func start() {
        floor = Levels.index(of: startLevel)
        controller.floor = floor
        if !demo {
            ScanLog.shared.begin(scan: scanID, client: client, what: "mode \(mode.rawValue), keep room \(keepRoom), naming \(recognizer.enabled), "
                + "saved map \(controller.worldMap != nil), start \(startLevel)")
        }
        lockStart = Date()
        controller.withObjects = withObjects
        withAnimation(Theme.spring) {
            controller.startTracking()   // our own AR session (with the LiDAR mesh for the live view)
            if needsLock { phase = .locking; tip = "" } else { begin() }
        }
        if let c = client { let id = scanID; Task { try? await c.survey("start", scan: id, ip: wifiIPAddress()) } }
    }

    /// after locking on (or without it): rooms, the tag walk, or the garden if that's where you start
    private func begin() {
        if mode == .tags { phase = .tagging }
        else if startLevel == Levels.garden { controller.goOutside(); phase = .outside; floor = 0; controller.floor = 0 }
        else { controller.startRoom(); phase = .scanning }
    }

    private func locked() {
        ScanLog.shared.add(controller.lockedForReal ? String(format: "locked on after %.0f s", Date().timeIntervalSince(lockStart))
                                                   : String(format: "started without locking on after %.0f s", Date().timeIntervalSince(lockStart)), now: true)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(Theme.spring) { tip = ""; lockText = ""; begin() }
        if controller.lockedForReal {
            show(controller.lockResidual.map { String(format: "Found your place on the map - lines up within %.0f cm", max(1, ($0 * 100).rounded())) }
                 ?? "Found your place on the map")
        }
    }

    /// start without locking on: Home Assistant lines the scan up with the map by matching walls instead
    func skipLock() {
        controller.forceUnlocked()
        locked()
        show("Started without locking on - Home Assistant lines it up afterwards")
    }

    /// you went through a door (or the room grew past one room's size): the room is saved and the next one starts
    func walkedOut(_ why: String) async {
        guard phase == .scanning, mode != .rescan, mode != .tags, !controller.held else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        await nextRoom(auto: true)
    }

    /// New room: save this one, start the next (also what going through a door does by itself)
    func nextRoom(auto: Bool = false) async {
        guard phase == .scanning else { return }
        withAnimation(Theme.spring) { phase = .processing }
        await controller.finishRoom()
        guard !discarded else { return }
        controller.startRoom()
        withAnimation(Theme.spring) { phase = .scanning; progress = RoomProgress() }
    }

    /// took the stairs: the room you were in is saved and a new one starts on this floor
    private var lastMirrorTip = Date.distantPast
    func floorChanged(_ dy: Float) async {
        guard phase == .scanning else { return }
        if mode == .rescan {
            withAnimation(Theme.spring) { tip = "You're on another floor now. A re-scan covers one room: go back, or tap Finish." }
            return
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(Theme.spring) { phase = .processing }
        await controller.finishRoom()
        guard !discarded else { return }
        setFloor(max(0, floor + (dy > 0 ? 1 : -1)), quiet: true)
        controller.startRoom()
        withAnimation(Theme.spring) { phase = .scanning; progress = RoomProgress() }
        show("\(dy > 0 ? "Upstairs" : "Downstairs"): you're on the \(floorName) now")
    }

    /// the floor you're on (from the menu on the floor label, when the stairs weren't noticed or you started wrong)
    func setFloor(_ i: Int, quiet: Bool = false) {
        floor = max(0, min(Levels.ids.count - 1, i))
        controller.floor = floor
        ScanLog.shared.add("now on floor \(floor + 1)" + (quiet ? "" : " (set by hand)"), now: true)
        if !quiet { show("You're on the \(floorName)") }
    }

    func togglePause() async {
        if phase == .paused { resume() } else { await pause() }
    }

    /// Pause: nothing is scanned until Resume - walk around, read, sort something out
    func pause() async {
        guard phase == .scanning else { return }
        withAnimation(Theme.spring) { phase = .processing }
        await controller.pauseRoom()
        guard !discarded else { return }
        withAnimation(Theme.spring) { phase = .paused; tip = "" }
    }

    func resume() {
        guard phase == .paused else { return }
        let same = controller.resumeRoom()
        floor = controller.floor
        withAnimation(Theme.spring) { phase = .scanning; progress = RoomProgress() }
        show(same ? "Carrying on with this room" : "New room - you moved away from the paused one")
    }

    /// looked up at the sky: offer the garden for a while
    private func offerGarden() {
        guard phase == .scanning, mode != .rescan else { return }
        withAnimation(Theme.spring) { gardenHint = true }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            withAnimation(Theme.spring) { self?.gardenHint = false }
        }
    }

    func goOutside() async {
        gardenHint = false
        if phase == .scanning {
            withAnimation(Theme.spring) { phase = .processing }
            await controller.finishRoom()
        } else if phase == .paused {
            controller.endPause()            // the paused part is a room of its own
            refreshRooms()
        }
        guard !discarded else { return }
        controller.goOutside()
        withAnimation(Theme.spring) {
            phase = .outside
            progress = RoomProgress()
            tip = "Walk the garden and side paths slowly. Sweep across walls, steps and the ground."
        }
    }

    /// from the garden back to scanning rooms (the house, or a room out there)
    func backInside() {
        controller.backInside()
        controller.startRoom()
        withAnimation(Theme.spring) { phase = .scanning; tip = ""; gardenText = "" }
        show("Scanning rooms again")
    }

    /// stop scanning, put everything together, then the review (room names, things the phone named)
    func finish() async {
        if phase == .scanning {
            withAnimation(Theme.spring) { phase = .processing }
            await controller.finishRoom()
        } else if phase == .paused {
            controller.endPause()
        }
        guard !discarded else { return }
        if controller.torchOn { toggleTorch() }
        withAnimation(Theme.spring) { phase = .uploading; tip = ""; saved = nil }
        result = "Putting your home together…"
        refreshRooms()
        let anchors = controller.allMeshAnchors
        controller.poses.stop()
        let stories = await controller.exportStories()
        let poses = controller.poses.json(to: controller.toHome)
        let lights = controller.lights.lights
        let world = await controller.worldMapNow()
        let relocalized = controller.worldMap != nil && controller.lockedForReal
        let pack = makePack(current: world)
        let floorColors = controller.floorColors()
        let gardenColors = anchors.isEmpty ? [:] : controller.cloud.colorTable()
        controller.shutdown()
        let names = Dictionary(uniqueKeysWithValues: rooms.map { ($0.id, $0.name) })
        controller.keyframes?.finish(toHome: controller.toHome, rooms: names)
        // mesh (garden) goes in extra parts of ~6 MB so no single upload is too big
        var chunks: [[[String: Any]]] = []
        var size = 0
        for a in anchors {
            let m = Export.mesh(a, to: controller.meshToHome(a), colors: gardenColors)
            let s = ((m["p"] as? String)?.count ?? 0) + ((m["i"] as? String)?.count ?? 0)
            if chunks.isEmpty || size + s > 6_000_000 { chunks.append([]); size = 0 }
            chunks[chunks.count - 1].append(m)
            size += s
        }
        var main = mainPart(stories: stories, lights: lights, poses: poses, relocalized: relocalized)
        if !floorColors.isEmpty { main["floorColors"] = floorColors }
        if let k = controller.keyframes, !k.shots.isEmpty { main["photos"] = ["count": k.shots.count, "mb": k.bytes / 1_000_000] }
        package = (main, chunks, pack)
        if recognizer.items.isEmpty && rooms.isEmpty { await send() } else { withAnimation(Theme.spring) { phase = .review } }
    }

    /// The map saved for next time: of the scan's map sections, the one with the most rooms (its place in the home
    /// comes along), with the home's surfaces for checking the next lock-on.
    private func makePack(current: ARWorldMap?) -> WorldPack? {
        let c = controller
        var options = c.sectionMaps
        if let w = current { options.append((map: w, toHome: c.toHome, rooms: c.roomsInSection)) }
        guard let best = options.enumerated().max(by: { ($0.element.rooms, $0.offset) < ($1.element.rooms, $1.offset) })?.element,
              let archive = try? NSKeyedArchiver.archivedData(withRootObject: best.map, requiringSecureCoding: true) else { return nil }
        let cloud = c.cloud.packed()
        ScanLog.shared.add("saving the map: section with \(best.rooms) rooms of \(c.sections), \(archive.count / 1_000_000) MB; surfaces \(c.cloud.count) cells, \(cloud.count / 1000) kB")
        return WorldPack(archive: archive, toHome: best.toHome, cloud: cloud.count > 20 ? cloud : nil, rooms: best.rooms, sections: c.sections)
    }

    /// the scan's main part: rooms, the marks (lights, tags, look-down spots), wall colors, the walk
    private func mainPart(stories: [[String: Any]], lights: [SIMD3<Float>], poses: [[String: Any]], relocalized: Bool) -> [String: Any] {
        // everything in the home's frame (the live AR world can differ: a map from a later section, a fresh section)
        let c = controller
        let lightMarks: [[String: Any]] = (withObjects ? lights : []).map { l in
            let p = c.home(l)
            return ["type": "light", "p": [p.x, p.y, p.z], "auto": true]
        }
        let dropMarks: [[String: Any]] = c.drops.map { d in
            let p = c.home(d.p)
            return ["type": "drop", "p": [p.x, p.y, p.z], "eye": d.eye + c.toHome.columns.3.y]
        }
        var main: [String: Any] = [
            "version": 2, "created": Date().timeIntervalSince1970,
            "app": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            "mode": mode.rawValue, "relocalized": relocalized, "replaceAll": replaceAll, "startLevel": startLevel,
            "stories": stories,
            "objects": withObjects, "keepRoom": keepRoom && mode == .rescan,
            "marks": lightMarks + c.allTags + dropMarks,
            "colors": controller.colors.json(to: controller.toHome),
            "poses": poses,
            // how the lock-on was confirmed, and how many map sections the scan needed (for the log / debugging)
            "lock": ["checked": controller.lockResidual != nil, "residual": controller.lockResidual ?? -1, "retries": controller.lockRetries,
                     "note": controller.lockNote] as [String: Any],
            "sections": controller.sections,
        ]
        if let b = baseScan { main["base"] = b }
        if ScanLog.shared.enabled { main["debugLog"] = ScanLog.shared.text }   // Settings: Send debug logs
        return main
    }

    /// after each room: what's scanned so far is kept on the phone, so a scan cut short (the app closed, a call, the
    /// battery) still shows on the start screen under "Not sent yet". Finishing replaces it with the whole scan.
    private func checkpoint() async {
        guard !demo, !discarded, mode != .tags, phase != .uploading, phase != .done else { return }
        let stories = await controller.exportStories()
        guard !discarded else { return }
        var main = mainPart(stories: stories, lights: controller.lights.lights, poses: controller.poses.json(to: controller.toHome),
                            relocalized: controller.worldMap != nil && controller.lockedForReal)
        main["marks"] = ((main["marks"] as? [[String: Any]]) ?? []) + foundMarks()
        guard let d = try? JSONSerialization.data(withJSONObject: main) else { return }
        try? PendingScan(id: scanID, name: "\(name) (unfinished)", kind: "rooms", parts: 1, rooms: roomsDone).save([d])
    }

    /// what the phone named, in the home's frame
    private func foundMarks() -> [[String: Any]] {
        let c = controller
        return recognizer.marks(rooms: c.rooms, fixes: c.rooms.indices.map(c.fix), toHome: c.toHome)
    }

    /// throw away what's scanned of the room you're in and scan it again
    func redoRoom() async {
        guard phase == .scanning else { return }
        withAnimation(Theme.spring) { phase = .processing }
        await controller.redoRoom()
        withAnimation(Theme.spring) { phase = .scanning; progress = RoomProgress(); area = finishedArea; tip = "" }
        show("This room is cleared - scan it again")
    }

    // MARK: flashlight

    func toggleTorch() {
        torch.toggle()
        controller.setTorch(torch)
    }

    // MARK: sending

    /// package (with the names and found things as you left them in the review) and send
    func send() async {
        guard var p = package else { return }
        // names changed in the review: the stories carry the new ones (the phone's guesses go along for unnamed rooms)
        if namesChanged {
            result = "Putting your home together…"
            p.main["stories"] = await controller.exportStories()
            namesChanged = false
        }
        p.main["marks"] = ((p.main["marks"] as? [[String: Any]]) ?? []) + foundMarks()
        var parts: [Data] = []
        do {
            parts.append(try JSONSerialization.data(withJSONObject: p.main))
            for chunk in p.chunks { parts.append(try JSONSerialization.data(withJSONObject: ["version": 2, "meshes": chunk])) }
        } catch { withAnimation(Theme.spring) { phase = .failed }; result = "Couldn't package the scan: \(error.localizedDescription)"; return }
        // kept on the phone until Home Assistant has every part (with the phone's map of the place for next time)
        let pending = PendingScan(id: scanID, name: name, kind: "rooms", parts: parts.count, rooms: roomsDone)
        try? pending.save(parts)
        if let w = p.world {
            let data = w.data
            try? pending.saveWorld(data)
            WorldMapStore.keepLocal(data)
        }
        await upload(pending)
    }

    private func upload(_ pending: PendingScan) async {
        guard let c = client else { withAnimation(Theme.spring) { phase = .failed }; result = "Not paired with Home Assistant."; return }
        withAnimation(Theme.spring) { phase = .uploading }
        do {
            try await Uploader.send(pending, client: c) { [weak self] t in Task { @MainActor in self?.result = t } }
            try? await c.survey("stop", scan: scanID, ip: nil)
            let tagged = controller.tags.count, found = withObjects ? recognizer.items.count : 0
            result = mode == .tags
                ? "\(tagged) tagged and measured\(found > 0 ? ", \(found) things named" : "")."
                : "\(roomsDone) room\(roomsDone == 1 ? "" : "s"), \(objects) pieces of furniture, \(controller.lights.lights.count) lights\(tagged > 0 ? ", \(tagged) tags" : "")\(found > 0 ? ", \(found) things named" : "")\(controller.allMeshAnchors.isEmpty ? "" : " and the garden")."
            ScanLog.shared.end("sent: \(result)")
            withAnimation(Theme.spring) { phase = .done }
            PhotoSender.shared.send(client: c)              // the photos follow, to the PC
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            result = HAClient.unreachable(error)
                ? "Home Assistant can't be reached right now. Your scan is saved on this phone and sends by itself when it's back - or tap Try again."
                : "Sending failed: \(error.localizedDescription). Your scan is saved on this phone - try again now or later from the start screen."
            ScanLog.shared.end("upload failed: \(error.localizedDescription)")
            withAnimation(Theme.spring) { phase = .failed }
        }
    }

    func retry() async {
        guard let p = PendingScan.all().first(where: { $0.id == scanID }) else { await send(); return }
        await upload(p)
    }

    /// Discard: everything of this scan goes - nothing is kept on the phone or sent
    func discard() {
        discarded = true
        controller.keyframes?.discard()
        ScanLog.shared.end("scan discarded (\(roomsDone) rooms done)")
        controller.shutdown()
        PendingScan.all().first { $0.id == scanID }?.remove()
        if let c = client { let id = scanID; Task { try? await c.survey("stop", scan: id, ip: nil) } }
    }
}
