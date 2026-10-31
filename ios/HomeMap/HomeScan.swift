import ARKit
import AVFoundation
import Combine
import RealityKit
import RoomPlan
import SwiftUI

/// Floor outlines seen from above (x, z): inside, and how far outside
enum Floorplan {
    static func inside(_ p: SIMD2<Float>, _ poly: [SIMD2<Float>]) -> Bool {
        var c = false
        for i in 0..<poly.count {
            let a = poly[i], b = poly[(i + poly.count - 1) % poly.count]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { c.toggle() }
        }
        return c
    }

    /// distance to the outline (0 inside)
    static func outside(_ p: SIMD2<Float>, _ poly: [SIMD2<Float>]) -> Float {
        guard poly.count >= 3, !inside(p, poly) else { return 0 }
        var best = Float.greatestFiniteMagnitude
        for i in 0..<poly.count {
            let a = poly[i], b = poly[(i + 1) % poly.count], ab = b - a
            let t = max(0, min(1, simd_dot(p - a, ab) / max(simd_dot(ab, ab), 1e-6)))
            best = min(best, simd_distance(p, a + ab * t))
        }
        return best
    }
}

/// What a scan does to the map in Home Assistant.
enum ScanMode: String {
    case new          // the whole home from scratch (replaceAll: the old scans are kept as a backup, not shown)
    case add          // more rooms, a floor, the garden: lines up with the saved map
    case rescan       // one room again: replaces that room on the map
    case tags         // no room scanning, just tag / measure things
}

/// How far along the room you're in is: its outline (walls all the way round), and the floor and ceiling the LiDAR has
/// covered. Furniture doesn't count - this is the room's shell.
struct RoomProgress: Equatable {
    var percent = 0
    var walls: Float = 0
    var floor: Float?              // nil: the phone's mesh can't tell floor from ceiling here
    var ceiling: Float?
    var missing = ""               // "the wall on your left", "the ceiling"...
    var size = SIMD2<Float>.zero   // width × depth (m)
    var area: Float = 0
}

/// what happened to the room that was being scanned when it stopped
enum RoomResult { case saved(Int), empty, failed(Error) }

/// One continuous scan. Every room, every floor and the garden share one AR session, so everything lines up by itself.
/// With a saved world map the session first "locks on" to the home it already knows, so new rooms land in the right place.
final class HomeScanController: UIViewController, RoomCaptureSessionDelegate {
    private(set) var capture: RoomCaptureSession?
    /// our own AR session, handed to RoomPlan: we switch the LiDAR mesh on in it (RoomPlan's own session has none), so
    /// the live view can show the real mesh
    private let ownSession = ARSession()
    var arSession: ARSession { ownSession }
    var withObjects = true { didSet { overlay.showObjects = withObjects } }
    let worldMap: ARWorldMap?
    /// the saved map this scan locks on to, with its frame in the home and the home's surfaces (to check the lock-on)
    let pack: WorldPack?
    /// live AR world -> the home's frame everything is sent in: the saved map's place in the home (locked on), else
    /// this scan's own first section. Changes when a fresh map section starts (RoomPlan ran out of room).
    private(set) var toHome = matrix_identity_float4x4
    /// per room: the AR world it was scanned in -> the live one (identity unless a fresh section started after it)
    private var roomFix: [Int: simd_float4x4] = [:]
    /// the home's surfaces as you scan them (in the home's frame): saved with the map for the next lock-on, and for
    /// rebuilding walls and furniture on the PC
    let cloud = SurfaceCloud()
    /// map sections: RoomPlan stops every new room once one AR world holds too much (~10 rooms), so the scan carries on
    /// in a fresh one, chained to the last by the phone's pose across the restart (held still). Earlier sections' maps
    /// are kept: the one with the most rooms is saved for next time.
    private(set) var sections = 1
    private(set) var sectionMaps: [(map: ARWorldMap, toHome: simd_float4x4, rooms: Int)] = []
    private var sectionFirstRoom = 0
    var roomsInSection: Int { rooms.count - sectionFirstRoom }
    /// a room's walls, doors and furniture in the live world (its fix applied)
    func fix(_ i: Int) -> simd_float4x4 { roomFix[i] ?? matrix_identity_float4x4 }
    let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
    let overlay = LiveOverlay()
    let poses = PoseLogger()
    let lights = LightFinder()
    let colors = WallColors()
    private(set) var rooms: [CapturedRoom] = []
    var roomNames: [Int: String] = [:]
    private(set) var tags: [[String: Any]] = []
    /// what each room's floor is made of (the naming model's guess): exported as a floor tag at the room's middle
    var roomFloors: [Int: String] = [:]
    /// what each room's walls are made of (most of the phone's looks at them): a finish tag on every wall of the room
    var roomFinishes: [Int: String] = [:]
    /// photos of the scan for later (textures, a photo-real model), when kept
    var keyframes: Keyframes?
    /// the floor each room is on (0 = First floor), and the floor you're on now (from the start, the stairs, or set by hand)
    private(set) var roomLevel: [Int: Int] = [:]
    var floor = 0
    private var roomFloorAtStart = 0
    /// tags, measurements and each room's floor kind - in the home's frame
    var allTags: [[String: Any]] {
        let floors: [[String: Any]] = roomFloors.compactMap { i, kind in
            guard i < rooms.count, let f = rooms[i].floors.first else { return nil }
            let c = Frames.apply(toHome * fix(i), simd_make_float3(f.transform.columns.3))
            return ["type": "object", "kind": "floor:" + kind, "p": [c.x, c.y, c.z], "n": [0, 1, 0]]   // the room's majority: as good as a tag
        }
        // a room's walls all get the material most of its looks saw (a wall looked at on its own still has its own
        // look among the marks, which comes later and wins for that wall)
        let walls: [[String: Any]] = roomFinishes.flatMap { i, kind -> [[String: Any]] in
            guard i < rooms.count else { return [] }
            let m = toHome * fix(i)
            return rooms[i].walls.map { w in
                let c = Frames.apply(m, simd_make_float3(w.transform.columns.3)), n = Frames.turn(m, simd_make_float3(w.transform.columns.2))
                return ["type": "object", "kind": "finish:" + kind, "p": [c.x, c.y, c.z], "n": [n.x, n.y, n.z], "auto": true]
            }
        }
        return walls + floors + tags.map(homeTag)
    }

    /// each room's real floor color from the scan's surfaces: [{p: the floor's middle, c: "#rrggbb"}] (home frame)
    func floorColors() -> [[String: Any]] {
        let cells = cloud.finished()
        guard !cells.isEmpty else { return [] }
        let merged = Set(mergeInto.values)
        var out: [[String: Any]] = []
        for (i, r) in rooms.enumerated() where !merged.contains(i) {
            guard let f = r.floors.first else { continue }
            let m = toHome * fix(i) * f.transform
            let poly = f.polygonCorners.map { c -> SIMD2<Float> in let w = Frames.apply(m, c); return SIMD2(w.x, w.z) }
            let mid = Frames.apply(m, .zero)
            guard let hex = SurfaceCloud.floorColor(cells, poly: poly, floorY: mid.y) else { continue }
            out.append(["p": [mid.x, mid.y, mid.z], "c": hex])
        }
        return out
    }

    /// a tag / measurement (kept in the live world) in the home's frame
    private func homeTag(_ t: [String: Any]) -> [String: Any] {
        var o = t
        for k in ["p", "a", "b"] { if let v = t[k] as? [Float], v.count == 3 { let w = Frames.apply(toHome, SIMD3(v[0], v[1], v[2])); o[k] = [w.x, w.y, w.z] } }
        if let v = t["n"] as? [Float], v.count == 3 { let w = Frames.turn(toHome, SIMD3(v[0], v[1], v[2])); o["n"] = [w.x, w.y, w.z] }
        return o
    }

    /// a point / direction in the live world -> the home's frame (for what's exported)
    func home(_ p: SIMD3<Float>) -> SIMD3<Float> { Frames.apply(toHome, p) }
    func homeDir(_ n: SIMD3<Float>) -> SIMD3<Float> { Frames.turn(toHome, n) }
    var onAim: ((Float?) -> Void)?
    /// every look (~3x a second): the camera frame and what the crosshair hits (the recognizer uses it)
    var onFrame: ((ARFrame, (p: SIMD3<Float>, n: SIMD3<Float>)?) -> Void)?
    var onLocked: (() -> Void)?
    /// you went up / down about a floor (meters, + = up) while a room was being scanned
    var onFloorChange: ((Float) -> Void)?
    /// spots on a floor well below yours: you looked down over a railing, a mezzanine edge or into a stairwell
    private(set) var drops: [(p: SIMD3<Float>, eye: Float)] = []
    private var roomActive = false
    /// a RoomPlan room is being captured right now (stopping one that isn't would wait forever)
    private(set) var capturing = false
    /// stopped by Pause: nothing is scanned until Resume (tracking carries on, so it still lines up)
    private(set) var paused = false
    private var pausing = false
    private var pausedAt: (eye: SIMD3<Float>, shape: [SIMD2<Float>])?
    /// a sheet or card is open: nothing happens by itself (no new room, no new floor, no garden hint)
    var held = false
    /// shut down (finished or thrown away): RoomPlan's last answers are ignored
    private(set) var isShutDown = false
    /// rooms scanned before the first time outside: the house (rooms out in the garden sit lower)
    private var houseRooms: Int?
    private var roomEyes: [Float] = []
    private var roomEye: Float?
    private var offFloor = 0
    /// outside: how far the ground under you is below the floor you walked out from (nil = can't tell: the world moved)
    var onGarden: ((Float?) -> Void)?
    /// you seem to be outside (looked up and saw nothing within 6 m): offer the garden
    var onLooksOutside: (() -> Void)?
    var client: HAClient?

    var onProgress: ((RoomProgress) -> Void)?
    var onInstruction: ((String) -> Void)?
    var onRoomDone: ((RoomResult) -> Void)?
    /// walk anywhere: you walked out of the room through one of its doors / openings (the next room starts by itself)
    var onLeftRoom: ((String) -> Void)?
    var autoRooms = true
    private var nearDoorAt: Date?
    private var outSince: Date?
    /// the room being scanned seen from above: its outline (from its walls) and its walls as lines
    private var liveShape: (poly: [SIMD2<Float>], walls: [(SIMD2<Float>, SIMD2<Float>)])?

    /// near one of this room's doors or openings a moment ago, and now well outside its outline for 1.5 s: you've gone
    /// through. Or it grew past one room's size (an opening RoomPlan didn't see, and you walked on): it's saved too.
    private func watchDoorway(_ eye: SIMD3<Float>) {
        guard autoRooms, !held, roomActive, capturing, !outside, let r = liveRoom, let s = liveShape, r.walls.count >= 3,
              Date().timeIntervalSince(roomStarted) > 8 else { outSince = nil; return }
        let p = SIMD2<Float>(eye.x, eye.z)
        if RoomShape.tooBig(s.poly) {
            outSince = nil; nearDoorAt = nil
            let sz = RoomShape.size(s.poly)
            diag(String(format: "the room got big (%.1f x %.1f m): saved, next room", sz.x, sz.y), now: true)
            DispatchQueue.main.async { self.onLeftRoom?("big") }
            return
        }
        if (r.doors + r.openings).contains(where: { simd_distance(SIMD2($0.transform.columns.3.x, $0.transform.columns.3.z), p) < 1.1 }) {
            nearDoorAt = Date()
        }
        guard let d = nearDoorAt, Date().timeIntervalSince(d) < 8, Floorplan.outside(p, s.poly) > 0.8 else { outSince = nil; return }
        let since = outSince ?? Date()
        outSince = since
        guard Date().timeIntervalSince(since) > 1.5 else { return }
        outSince = nil; nearDoorAt = nil
        diag("walked out of the room through a doorway: next room", now: true)
        DispatchQueue.main.async { self.onLeftRoom?("door") }
    }

    /// RoomPlan stopped the room by itself (tracking lost, a popup over the app): kept = the part so far was kept
    var onRoomLost: ((Error, Bool) -> Void)?
    /// rooms that are the first part of a room (paused, or a popup stopped RoomPlan), and the room each one continues into
    private(set) var partials = Set<Int>()
    private(set) var mergeInto: [Int: Int] = [:]      // continuation room index -> its first part's index
    private var pendingPartial: Int?
    private var lastEye: SIMD3<Float>?
    /// how often ARKit re-aligned the world (a jump of over 1.2 m between two looks)
    private(set) var shifts = 0
    private var roomWaiter: CheckedContinuation<Void, Never>?
    /// the room being stopped is thrown away (Start this room over), not kept
    private var discardNext = false
    private var lastLive = Date.distantPast
    private var liveRoom: CapturedRoom?
    private var timer: Timer?
    private var ticks = 0
    private(set) var outside = false
    private(set) var locked = false
    private var sawRelocalizing = false
    private(set) var skippedLock = false
    /// true when we really locked on to the saved map (not skipped)
    var lockedForReal: Bool { locked && !skippedLock }
    /// not locking on: start tracking afresh without the saved map. With the map still loaded ARKit keeps trying to
    /// recognize it ("relocalizing") for good - no mesh comes, and RoomPlan refuses to start a room. Home Assistant lines
    /// the scan up with the map by matching walls instead.
    func forceUnlocked() {
        skippedLock = true; locked = true
        toHome = matrix_identity_float4x4             // its own frame: Home Assistant places it
        guard let cur = arSession.configuration as? ARWorldTrackingConfiguration, cur.initialWorldMap != nil,
              let cfg = cur.copy() as? ARWorldTrackingConfiguration else { return }
        cfg.initialWorldMap = nil
        arSession.run(cfg, options: [.resetTracking, .removeExistingAnchors])
        afterRun()
        diag("lock-on skipped: tracking restarted without the saved map", now: true)
    }

    /// pack: lock on to a home scanned before (add / re-scan / tag walk). demo: screenshots in the simulator
    /// (no camera, no LiDAR) - nothing is started
    init(pack: WorldPack?, demo: Bool = false) {
        self.pack = pack
        self.worldMap = demo ? nil : pack?.map
        super.init(nibName: nil, bundle: nil)
        locked = worldMap == nil
        if worldMap != nil, let p = pack {
            toHome = p.toHome
            // the saved surfaces to check the lock-on against (a few seconds for a big home: off the main thread)
            if let c = p.cloud {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let index = SurfaceCloud.index(c)
                    DispatchQueue.main.async { self?.lockIndex = index; self?.indexReady = true }
                }
            } else { indexReady = true }
        }
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        arView.frame = view.bounds
        arView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        arView.session = arSession
        // only the camera and our lines: no soft "grounding" shadows under the wireframe (the dark patches on the floor),
        // no film effects - less work for a phone that's also running RoomPlan and the LiDAR mesh
        arView.renderOptions.formUnion([.disableMotionBlur, .disableGroundingShadows, .disableDepthOfField, .disableHDR,
                                        .disableCameraGrain, .disableAREnvironmentLighting, .disablePersonOcclusion])
        arView.scene.addAnchor(overlay.root)
        view.addSubview(arView)
        // how smoothly the live view draws (for the debug log): frames, and frames slower than 1/40 s
        renderSub = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] e in
            guard let self else { return }
            self.renderFrames += 1
            if e.deltaTime > 1.0 / 40 { self.renderSlow += 1 }
        }
        capture?.delegate = self
    }

    /// own session: world tracking (+ the saved map to lock on to). The camera runs at its normal size - 4K made the
    /// phone hot and slow within minutes, and naming things needs only the middle of the picture.
    private func trackingConfig(map: ARWorldMap?) -> ARWorldTrackingConfiguration? {
        let cfg = ARWorldTrackingConfiguration()
        cfg.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) { cfg.frameSemantics.insert(.sceneDepth) }
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) { cfg.sceneReconstruction = .meshWithClassification }
        else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) { cfg.sceneReconstruction = .mesh }
        if let map { cfg.initialWorldMap = map }
        return cfg
    }

    func startTracking() {
        guard let cfg = trackingConfig(map: worldMap) else { return }
        ownSession.run(cfg, options: [.resetTracking, .removeExistingAnchors])
        afterRun()
        overlay.planesAfter = Date().addingTimeInterval(ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) ? 5 : 0)
        poses.start(session: ownSession, client: client)
        startTimer()
    }

    func startRoom() {
        guard !isShutDown, !restarting else { return }
        if capture == nil {
            let c = RoomCaptureSession(arSession: ownSession)
            c.delegate = self
            capture = c
        }
        capture?.run(configuration: RoomCaptureSession.Configuration())
        roomActive = true; capturing = true; paused = false; roomEyes = []; roomEye = nil; offFloor = 0
        roomStarted = Date(); roomFloorAtStart = floor; liveShape = nil; skyTicks = 0; lookedOutsideHint = false
        poses.start(session: arSession, client: client)
        startTimer()
        // RoomPlan has just re-run our session with its own settings - put the mesh back on top of them
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.boostRoomSession() }
        afterRun()
    }

    // MARK: the live mesh while RoomPlan scans

    /// RoomPlan runs the AR session with its own settings, and those leave out the LiDAR mesh: no wireframe, and nothing
    /// for the live view to hide behind. So once a room is under way, the mesh goes back on top of RoomPlan's own
    /// settings - same world, no reset. If RoomPlan can't scan like that (it stops within seconds, twice), it's
    /// remembered and rooms are scanned without it from then on (the live view falls back to outlines + floor planes).
    static var meshStops: Int {
        get { UserDefaults.standard.integer(forKey: "meshStopsRoomPlan") }
        set { UserDefaults.standard.set(newValue, forKey: "meshStopsRoomPlan") }
    }
    static var meshBreaksRoomPlan: Bool { meshStops >= 2 }
    private var trackingWasNormal = false
    private var boostedAt: Date?
    private var roomStarted = Date.distantPast
    private func boostRoomSession(again: Bool = false) {
        guard capturing, !outside, !isShutDown, let cur = arSession.configuration as? ARWorldTrackingConfiguration else { return }
        if !again {
            diag("room started; RoomPlan's settings: mesh=\(cur.sceneReconstruction.rawValue) semantics=\(cur.frameSemantics.rawValue) saved map \(cur.initialWorldMap != nil) "
                 + "planes=\(cur.planeDetection.rawValue) video=\(Int(cur.videoFormat.imageResolution.width))x\(Int(cur.videoFormat.imageResolution.height))"
                 + (Self.meshBreaksRoomPlan ? " (mesh off: it stopped RoomPlan before)" : ""))
        }
        let depthOK = !ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) || cur.frameSemantics.contains(.sceneDepth)
        guard !Self.meshBreaksRoomPlan, cur.sceneReconstruction.isEmpty || !depthOK, let cfg = cur.copy() as? ARWorldTrackingConfiguration else { return }
        // with classification: the room progress can tell floor from ceiling; depth: the surfaces' colors are checked
        // against it (nothing behind a chair gets the chair's color)
        if cur.sceneReconstruction.isEmpty {
            if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) { cfg.sceneReconstruction = .meshWithClassification }
            else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) { cfg.sceneReconstruction = .mesh }
            else { return }
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) { cfg.frameSemantics.insert(.sceneDepth) }
        boostedAt = Date()
        meshBoosts += 1
        if again { diag("RoomPlan switched the LiDAR mesh off mid-room: back on (\(meshBoosts) times this scan)", now: meshBoosts <= 3) }
        rerun(cfg)
        guard !again else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.capturing else { return }
            self.diag("mesh on top of RoomPlan: \(self.meshAnchors.count) mesh pieces after 4 s")
        }
    }

    /// RoomPlan can re-run the session with its own settings mid-room (after tracking trouble, for one) and the mesh is
    /// gone again: checked every ~0.7 s, and put back. Never during the first 1.5 s of a room (the first boost is due).
    private var meshBoosts = 0
    private func keepMeshOn() {
        guard !Self.meshBreaksRoomPlan, Date().timeIntervalSince(roomStarted) > 1.5,
              Date().timeIntervalSince(boostedAt ?? .distantPast) > 1.0,
              let cur = arSession.configuration as? ARWorldTrackingConfiguration, cur.sceneReconstruction.isEmpty else { return }
        boostRoomSession(again: true)
    }

    private var renderSub: Cancellable?
    private var renderFrames = 0, renderSlow = 0, statusAt = Date()

    /// the phone got hot: walls and furniture stop hiding the lines behind them (that depth test costs every frame)
    private var occlusionOff = false
    private func coolDown() {
        guard !occlusionOff, [.serious, .critical].contains(ProcessInfo.processInfo.thermalState) else { return }
        occlusionOff = true
        arView.environment.sceneUnderstanding.options.remove(.occlusion)
        diag("phone hot: the live view stops hiding lines behind walls, to save power", now: true)
    }

    /// what RoomPlan has outlined where the circle is (the room being scanned and the finished ones):
    /// "television, about 1.4 x 0.8 m" - a hint for the naming model
    func roomPlanGuess(at p: SIMD3<Float>) -> String? {
        let all = [liveRoom].compactMap { $0 }.map { ($0, matrix_identity_float4x4) } + rooms.indices.map { (rooms[$0], fix($0)) }
        for (r, m) in all {
            for o in r.objects where Recognizer.inside(p, transform: m * o.transform, size: o.dimensions, margin: 0.1) {
                return "\(o.category), about " + String(format: "%.1f x %.1f m", o.dimensions.x, o.dimensions.y)
            }
        }
        return nil
    }

    /// the camera's line of sight through the circle
    func sightLine() -> (o: SIMD3<Float>, d: SIMD3<Float>)? {
        guard let f = arSession.currentFrame else { return nil }
        let t = f.camera.transform
        return (SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z), -simd_normalize(SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z)))
    }

    /// where that line meets a surface ARKit knows (only upright ones: for a mirror - the glass hangs on a wall or a
    /// cabinet front, while the depth sensor only measures the reflection behind it). nil = none within 6 m
    func spotOnPlanes(_ ray: (o: SIMD3<Float>, d: SIMD3<Float>), vertical: Bool) -> (p: SIMD3<Float>, n: SIMD3<Float>)? {
        guard let f = arSession.currentFrame else { return nil }
        var best: (t: Float, p: SIMD3<Float>, n: SIMD3<Float>)?
        for case let a as ARPlaneAnchor in f.anchors where !vertical || a.alignment == .vertical {
            let n4 = a.transform.columns.1, n = simd_normalize(SIMD3<Float>(n4.x, n4.y, n4.z))
            let c4 = a.transform.columns.3, c = SIMD3<Float>(c4.x, c4.y, c4.z)
            let den = simd_dot(n, ray.d)
            guard abs(den) > 0.15 else { continue }
            let t = simd_dot(c - ray.o, n) / den
            guard t > 0.2, t < 6 else { continue }
            let p = ray.o + ray.d * t
            let local = a.transform.inverse * SIMD4<Float>(p.x, p.y, p.z, 1)
            guard abs(local.x) < a.planeExtent.width / 2 + 0.4, abs(local.z) < a.planeExtent.height / 2 + 0.4 else { continue }
            if best == nil || t < best!.t { best = (t, p, den < 0 ? n : -n) }
        }
        return best.map { ($0.p, $0.n) }
    }

    /// re-run the session with changed settings (no reset: the world carries on) - but never with the saved map again:
    /// that's only for the first lock-on. Re-running with it made ARKit snap the world back onto the saved map: jumps of
    /// 3-12 m, after which RoomPlan stopped every room ("Capture scene exceeded limit") and the wireframe was lost.
    private func rerun(_ cfg: ARConfiguration) {
        guard let c = cfg.copy() as? ARConfiguration else { return }
        (c as? ARWorldTrackingConfiguration)?.initialWorldMap = nil
        arSession.run(c)
        afterRun()
    }

    // MARK: flashlight

    /// the flashlight, for dark corners and the garden at night. Re-running the AR session (a new room, the garden)
    /// switches the camera's light off, so it's switched back on after every run.
    private(set) var torchOn = false
    func setTorch(_ on: Bool) {
        torchOn = on
        applyTorch()
        diag("flashlight \(on ? "on" : "off")")
    }

    private func afterRun() {
        guard torchOn else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.applyTorch() }
    }

    private func applyTorch() {
        guard let dev = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera, dev.hasTorch else { return }
        do {
            try dev.lockForConfiguration()
            if torchOn, dev.isTorchModeSupported(.on) { try dev.setTorchModeOn(level: 0.8) } else { dev.torchMode = .off }
            dev.unlockForConfiguration()
        } catch { diag("flashlight: \(error.localizedDescription)") }
    }

    static var hasTorch: Bool { ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera?.hasTorch ?? false }

    /// a line in the scan's debug log (ScanLog: Home Assistant's log + sent with the scan)
    func diag(_ s: String, now: Bool = false) { ScanLog.shared.add(s, now: now) }

    /// every ~10 s: tracking, the live view's mesh / planes, what the AR session runs with, how the phone is doing
    private func status(_ frame: ARFrame) {
        let tr: String
        switch frame.camera.trackingState {
        case .normal: tr = "normal"
        case .notAvailable: tr = "not available"
        case .limited(let r): tr = "limited (\(r))"
        }
        let cfg = arSession.configuration as? ARWorldTrackingConfiguration
        let planes = frame.anchors.filter { $0 is ARPlaneAnchor }.count
        let dt = max(0.1, Date().timeIntervalSince(statusAt))
        let fps = String(format: "%.0f fps, %d slow", Double(renderFrames) / dt, renderSlow)
        let build = LiveOverlay.built > 0 ? String(format: "%d rebuilt, %.0f ms avg", LiveOverlay.built, LiveOverlay.buildMs / Double(LiveOverlay.built)) : "none rebuilt"
        renderFrames = 0; renderSlow = 0; statusAt = Date(); LiveOverlay.built = 0; LiveOverlay.buildMs = 0
        let video = cfg.map { "\(Int($0.videoFormat.imageResolution.width))x\(Int($0.videoFormat.imageResolution.height))" } ?? "?"
        diag("status: \(fps) | tracking \(tr) | mesh pieces \(meshAnchors.count) (\(build)), drawn \(overlay.hasMesh) | planes \(planes) | "
             + "session mesh=\(cfg.map { String($0.sceneReconstruction.rawValue) } ?? "?") video \(video) | rooms \(rooms.count), capturing \(capturing), "
             + "paused \(paused), outside \(outside), floor \(floor + 1), held \(held) | \(lastProgress.percent)% | \(ScanLog.health())")
    }

    private var meshTimer: Timer?
    private func startTimer() {
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.33, repeats: true) { [weak self] _ in self?.tick() }
        }
        // the wireframe of what's been seen, refreshed often so it fills in smoothly as you look around
        // (also while locking on: you see what it's looking at, and it shows it's working)
        if meshTimer == nil {
            meshTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self, let f = self.arSession.currentFrame else { return }
                let had = self.overlay.hasMesh
                self.overlay.updateMesh(f)
                // with the mesh, real surfaces (walls, furniture) hide what's behind them in the live view
                if self.overlay.hasMesh && !had && !self.occlusionOff { self.arView.environment.sceneUnderstanding.options.insert(.occlusion) }
            }
        }
    }

    /// what tracking is struggling with right now (nil = fine): shown before RoomPlan gives up on the room
    var onTracking: ((String?) -> Void)?
    private var lastTracking: String?
    private func watchTracking(_ frame: ARFrame) {
        var text: String?
        if case .limited(let why) = frame.camera.trackingState {
            switch why {
            case .insufficientFeatures: text = "Keep the camera clear and point it at the room"
            case .excessiveMotion: text = "Slow down a little"
            default: text = nil
            }
        }
        guard text != lastTracking else { return }
        lastTracking = text
        DispatchQueue.main.async { self.onTracking?(text) }
    }

    /// tracking has been normal for 1.5 s with no jump of the world: only then is anything placed on the map (lights,
    /// wall colors, look-down spots, named things, tags, the walk for the Wi-Fi map, floor changes, surfaces). Right
    /// after tracking comes back ARKit is still settling, and what's placed then can land in the wrong spot.
    private var normalSince: Date?
    var steady: Bool { normalSince.map { Date().timeIntervalSince($0) >= 1.5 } ?? false }
    /// in a fresh-section restart: nothing runs until it's done
    private(set) var restarting = false

    private func tick() {
        guard !isShutDown, !restarting, let frame = arSession.currentFrame else { return }
        ticks += 1
        // locking on to the saved map: ARKit says "relocalizing" until it recognizes the place, then "normal" - and
        // then the LiDAR has to confirm it
        if !locked { lockTick(frame); return }
        if capturing { watchTracking(frame) }
        if case .normal = frame.camera.trackingState { trackingWasNormal = true } else { trackingWasNormal = false }
        let cam = frame.camera.transform.columns.3, eye = SIMD3<Float>(cam.x, cam.y, cam.z)
        if case .normal = frame.camera.trackingState {
            if normalSince == nil { normalSince = Date() }
            if let l = lastEye, simd_distance(l, eye) > 1.2 {
                shifts += 1
                normalSince = Date()                       // settle again after a jump
                diag(String(format: "world shifted %.1f m between two looks (ARKit re-aligned)", simd_distance(l, eye)), now: true)
            }
            lastEye = eye
        } else {
            normalSince = nil
        }
        if ticks % 30 == 0 { status(frame) }
        if ticks % 9 == 0 { coolDown() }
        if capturing, !outside, ticks % 2 == 0 { keepMeshOn() }
        overlay.updatePlanes(frame, cameraY: eye.y)
        let settled = steady
        poses.recording = settled
        if settled {
            if !torchOn { lights.look(frame, session: arSession) }   // the flashlight's own glare isn't a ceiling light
            if let r = liveRoom, ticks % 2 == 0 { colors.sample(frame, walls: r.walls) }
            if ticks % 6 == 0 { feedCloud(frame) }
            if capturing || outside { keyframes?.consider(frame, room: rooms.count, section: sections) }
        }
        let spot = aim()
        onAim?(spot.map { simd_distance($0.p, eye) })
        if settled { onFrame?(frame, spot) }
        if !outside, settled {
            watchFloor(eye: eye.y)
            watchDoorway(eye)
            watchSky(frame, spot: spot, eye: eye)
            if let s = spot { lookDown(s, eye: eye) }
        }
        if !outside, capturing, ticks % 3 == 0, case .normal = frame.camera.trackingState { progress(frame, eye: eye) }
        if outside, settled, ticks % 6 == 0 { garden(frame, eye: eye); captureGarden() }
    }

    /// the mesh near you into the home's surfaces, with the camera's colors (not when the phone is hot)
    private func feedCloud(_ frame: ARFrame) {
        let hot = [.serious, .critical].contains(ProcessInfo.processInfo.thermalState)
        let pic = hot ? nil : SurfaceCloud.picture(frame)
        cloud.feed(meshAnchors, camera: frame.camera.transform, to: toHome, picture: pic)
    }

    // MARK: locking on

    /// what the lock-on is doing, for the screen
    var onLockStage: ((String) -> Void)?
    private var lockIndex: SurfaceIndex?
    private var indexReady = false
    private var recognizedSince: Date?
    private var checkingSince: Date?
    private var goodSince: Date?, lastGoodAt = Date.distantPast, mismatchSince: Date?
    private var goodMedians: [Float] = []
    private var checkBusy = false
    private let checkQueue = DispatchQueue(label: "lockcheck", qos: .userInitiated)
    private var lastStage = ""
    /// how the lock-on was confirmed: the LiDAR's median distance to the saved surfaces, and a note
    private(set) var lockResidual: Float?
    private(set) var lockNote = ""
    private(set) var lockRetries = 0

    private func stage(_ s: String) {
        guard s != lastStage else { return }
        lastStage = s
        DispatchQueue.main.async { self.onLockStage?(s) }
    }

    private func lockTick(_ frame: ARFrame) {
        if ticks % 30 == 0 { status(frame) }
        switch frame.camera.trackingState {
        case .limited(.relocalizing):
            sawRelocalizing = true
            recognizedSince = nil; goodSince = nil
            stage("")
        case .normal where sawRelocalizing:
            if recognizedSince == nil { recognizedSince = Date(); diag("ARKit recognized the place: checking it lines up", now: true) }
        default:
            recognizedSince = nil; goodSince = nil
        }
        guard let since = recognizedSince else { return }
        let now = Date()
        guard indexReady else { stage("Found it - checking it lines up…"); return }
        guard let index = lockIndex, !index.isEmpty else {
            // a map saved by app 1.7 or older: nothing to measure against - trust ARKit once tracking held a moment
            if now.timeIntervalSince(since) >= 1.5 { acceptLock(residual: nil, note: "not checked: the saved map has no surfaces (saved by app 1.7 or older)") }
            return
        }
        if checkingSince == nil { checkingSince = now }
        if now.timeIntervalSince(checkingSince!) > 45 {
            acceptLock(residual: nil, note: "not checked: never saw enough of a scanned corner in 45 s (ARKit's word taken)")
            return
        }
        guard !checkBusy, now.timeIntervalSince(since) >= 0.5 else { return }
        let anchors = meshAnchors, camera = frame.camera.transform, m = toHome
        checkBusy = true
        checkQueue.async { [weak self] in
            let c = index.check(LiveMeshSampler.sample(anchors, camera: camera, to: m))
            DispatchQueue.main.async { self?.checked(c) }
        }
    }

    private func checked(_ c: LockCheck) {
        checkBusy = false
        guard !locked, !isShutDown, recognizedSince != nil else { return }
        let now = Date()
        if c.isGood, let med = c.median {
            mismatchSince = nil
            if goodSince == nil { goodSince = now; goodMedians = [] }
            goodMedians.append(med)
            lastGoodAt = now
            stage("Lining up - hold steady…")
            if now.timeIntervalSince(goodSince!) >= 1.5, goodMedians.count >= 4 {
                acceptLock(residual: goodMedians.sorted()[goodMedians.count / 2], note: c.summary)
            }
        } else if c.isMismatch {
            goodSince = nil
            if mismatchSince == nil { mismatchSince = now; diag("lock-on doesn't line up: \(c.summary)", now: true) }
            stage("That doesn't line up with your map yet - keep looking around")
            if now.timeIntervalSince(mismatchSince!) >= 3 { lockAgain(c) }
        } else {
            if goodSince != nil, now.timeIntervalSince(lastGoodAt) > 1 { goodSince = nil }
            if goodSince == nil {
                stage(c.needsCorner ? "Found it - now point at a corner where two walls meet"
                                    : "Found it - look at the walls of a room you scanned before")
            }
        }
    }

    /// ARKit recognized the wrong spot (the LiDAR sees walls where the map has none): start the lock-on over
    private func lockAgain(_ c: LockCheck) {
        lockRetries += 1
        diag("wrong lock-on (\(c.summary)): looking again (\(lockRetries))", now: true)
        sawRelocalizing = false; recognizedSince = nil; mismatchSince = nil; checkingSince = nil; goodSince = nil
        if let cfg = trackingConfig(map: worldMap) { arSession.run(cfg, options: [.resetTracking, .removeExistingAnchors]); afterRun() }
        stage("That wasn't the right spot - looking again")
    }

    private func acceptLock(residual: Float?, note: String) {
        lockResidual = residual
        lockNote = note
        locked = true
        normalSince = Date().addingTimeInterval(-1.5)   // it's held steady already
        diag("locked on: " + (residual.map { String(format: "lines up within %.1f cm", $0 * 100) } ?? "not measured") + " | \(note)", now: true)
        stage("")
        DispatchQueue.main.async { self.onLocked?() }
    }

    /// the phone's height while this room is scanned; ~a floor higher or lower for 2 s = you took the stairs
    private func watchFloor(eye: Float) {
        guard roomActive, !held else { return }
        guard let e = roomEye else {
            roomEyes.append(eye)
            if roomEyes.count >= 9 { roomEye = roomEyes.sorted()[roomEyes.count / 2] }
            return
        }
        if abs(eye - e) > 1.8 { offFloor += 1 } else { offFloor = 0 }
        if offFloor == 6 {
            roomActive = false
            let dy = eye - e
            DispatchQueue.main.async { self.onFloorChange?(dy) }
        }
    }

    /// looking up (> 30°) at nothing within 6 m for ~2 s: the sky, so you're probably outside. Offered once per room.
    private var skyTicks = 0
    private var lookedOutsideHint = false
    private func watchSky(_ frame: ARFrame, spot: (p: SIMD3<Float>, n: SIMD3<Float>)?, eye: SIMD3<Float>) {
        guard !held, !lookedOutsideHint, mode != .tags else { return }
        let t = frame.camera.transform, up = -t.columns.2.y
        let far = spot.map { simd_distance($0.p, eye) > 6 } ?? true
        skyTicks = up > 0.5 && far ? skyTicks + 1 : 0
        guard skyTicks >= 6 else { return }
        lookedOutsideHint = true
        diag("looked up at nothing for 2 s: outside?", now: true)
        DispatchQueue.main.async { self.onLooksOutside?() }
    }
    var mode: ScanMode = .new

    /// the circle on a floor more than ~1.2 m below the one you stand on (eye ~1.4 m above it), a little way off
    private func lookDown(_ s: (p: SIMD3<Float>, n: SIMD3<Float>), eye: SIMD3<Float>) {
        guard s.n.y > 0.85, eye.y - s.p.y > 2.6, simd_distance(SIMD2(s.p.x, s.p.z), SIMD2(eye.x, eye.z)) > 0.6, drops.count < 600 else { return }
        if drops.contains(where: { simd_distance(SIMD2($0.p.x, $0.p.z), SIMD2(s.p.x, s.p.z)) < 0.4 && abs($0.p.y - s.p.y) < 0.3 }) { return }
        drops.append((s.p, eye.y))
    }

    // MARK: how far along this room is

    private var lastProgress = RoomProgress()
    private var progressBusy = false
    private let progressQueue = DispatchQueue(label: "progress", qos: .utility)

    /// once a second: the room's outline from its walls, and the floor / ceiling the mesh covers inside it
    private func progress(_ frame: ARFrame, eye: SIMD3<Float>) {
        guard let s = liveShape, let r = liveRoom, !progressBusy else { return }
        let fwd3 = -frame.camera.transform.columns.2
        let fwd = SIMD2<Float>(fwd3.x, fwd3.z), me = SIMD2<Float>(eye.x, eye.z)
        let bottoms = r.walls.map { $0.transform.columns.3.y - $0.dimensions.y / 2 }.sorted()
        let heights = r.walls.map(\.dimensions.y).sorted()
        let floorY = bottoms.isEmpty ? eye.y - 1.4 : bottoms[bottoms.count / 2]
        let ceilY = floorY + (heights.isEmpty ? 2.6 : heights[heights.count / 2])
        let anchors = meshAnchors
        progressBusy = true
        progressQueue.async { [weak self] in
            let (closed, gap) = RoomShape.closure(s.poly, walls: s.walls)
            let cover = Self.cover(s.poly, anchors: anchors, floorY: floorY, ceilY: ceilY)
            var p = RoomProgress()
            p.walls = closed; p.floor = cover?.floor; p.ceiling = cover?.ceiling
            p.size = RoomShape.size(s.poly); p.area = RoomShape.area(s.poly)
            let shell = cover.map { closed * 0.6 + $0.floor * 0.2 + $0.ceiling * 0.2 } ?? closed
            p.percent = min(Int((shell * 100).rounded()), closed >= 1 && (cover.map { $0.floor >= 1 && $0.ceiling >= 1 } ?? true) ? 100 : 99)
            if closed < 0.97, let g = gap { p.missing = "a wall " + RoomShape.direction(of: g, from: me, facing: fwd) }
            else if let c = cover, c.floor < 0.7 { p.missing = "the floor (point down)" }
            else if let c = cover, c.ceiling < 0.7 { p.missing = "the ceiling (look up)" }
            DispatchQueue.main.async {
                guard let self else { return }
                self.progressBusy = false
                guard self.capturing else { return }
                self.lastProgress = p
                self.onProgress?(p)
            }
        }
    }

    /// share of the room's inside (0.5 m squares) where the mesh has seen floor / ceiling; nil = no floor / ceiling
    /// labels in the mesh. 85% of the squares counts as all of it (furniture covers the floor, the outline is a hull).
    static func cover(_ poly: [SIMD2<Float>], anchors: [ARMeshAnchor], floorY: Float, ceilY: Float) -> (floor: Float, ceiling: Float)? {
        let lo = poly.reduce(SIMD2<Float>(repeating: .greatestFiniteMagnitude)) { simd_min($0, $1) }
        let hi = poly.reduce(SIMD2<Float>(repeating: -.greatestFiniteMagnitude)) { simd_max($0, $1) }
        let cell: Float = 0.5, nx = Int(((hi.x - lo.x) / cell).rounded(.up)), nz = Int(((hi.y - lo.y) / cell).rounded(.up))
        guard nx > 0, nz > 0, nx * nz < 4000 else { return nil }
        var inside = [Bool](repeating: false, count: nx * nz), need = 0
        for i in 0..<nx { for j in 0..<nz {
            if Floorplan.inside(lo + SIMD2(Float(i) + 0.5, Float(j) + 0.5) * cell, poly) { inside[i * nz + j] = true; need += 1 }
        } }
        guard need > 0 else { return nil }
        var fl = Set<Int>(), ce = Set<Int>(), labeled = false
        for a in anchors {
            let c = a.transform.columns.3
            guard c.x > lo.x - 3, c.x < hi.x + 3, c.z > lo.y - 3, c.z < hi.y + 3, let cls = a.geometry.classification else { continue }
            labeled = true
            let g = a.geometry, fs = g.faces, vs = g.vertices
            let ip = fs.buffer.contents(), vp = vs.buffer.contents(), cp = cls.buffer.contents()
            for f in stride(from: 0, to: fs.count, by: 2) {
                let kind = cp.advanced(by: cls.offset + cls.stride * f).assumingMemoryBound(to: UInt8.self).pointee
                guard kind == UInt8(ARMeshClassification.floor.rawValue) || kind == UInt8(ARMeshClassification.ceiling.rawValue) else { continue }
                let n = f * 3
                let vi = fs.bytesPerIndex == 4 ? Int(ip.advanced(by: n * 4).assumingMemoryBound(to: UInt32.self).pointee)
                                               : Int(ip.advanced(by: n * 2).assumingMemoryBound(to: UInt16.self).pointee)
                let q = vp.advanced(by: vs.offset + vs.stride * vi).assumingMemoryBound(to: Float.self)
                let w = a.transform * SIMD4<Float>(q[0], q[1], q[2], 1)
                let i = Int((w.x - lo.x) / cell), j = Int((w.z - lo.y) / cell)
                guard i >= 0, i < nx, j >= 0, j < nz, inside[i * nz + j] else { continue }
                if kind == UInt8(ARMeshClassification.floor.rawValue), abs(w.y - floorY) < 0.35 { fl.insert(i * nz + j) }
                else if kind == UInt8(ARMeshClassification.ceiling.rawValue), w.y > floorY + 1.8 { ce.insert(i * nz + j) }
            }
        }
        guard labeled else { return nil }
        let full = Float(need) * 0.85
        return (min(1, Float(fl.count) / full), min(1, Float(ce.count) / full))
    }

    // MARK: the garden

    /// the floor of the room you walked out from, and how often the world had shifted by then
    private var exitFloor: (y: Float, shifts: Int)?
    private var groundYs: [Float] = []

    /// how far the ground under you is below the floor you walked out from: straight down from the phone to the ground
    /// it sees. After ARKit re-aligned the world the two can't be compared any more (the 1.6 walk said "60 cm above").
    private func garden(_ frame: ARFrame, eye: SIMD3<Float>) {
        guard let ex = exitFloor else { return }
        guard ex.shifts == shifts else { DispatchQueue.main.async { self.onGarden?(nil) }; return }
        let q = ARRaycastQuery(origin: eye, direction: [0, -1, 0], allowing: .estimatedPlane, alignment: .horizontal)
        guard let hit = arSession.raycast(q).first else { return }
        let y = hit.worldTransform.columns.3.y
        guard eye.y - y > 0.6, eye.y - y < 2.4 else { return }       // the ground under you, not a table or a step
        groundYs.append(y); if groundYs.count > 7 { groundYs.removeFirst() }
        let g = groundYs.sorted()[groundYs.count / 2]
        DispatchQueue.main.async { self.onGarden?(ex.y - g) }
    }

    /// floor height of a room: the middle of its walls' bottoms
    static func floorY(_ r: CapturedRoom) -> Float? {
        let b = r.walls.map { $0.transform.columns.3.y - $0.dimensions.y / 2 }.sorted()
        return b.isEmpty ? nil : b[b.count / 2]
    }

    /// what the crosshair (screen center) is pointing at: the spot and the way its surface faces
    func aim() -> (p: SIMD3<Float>, n: SIMD3<Float>)? {
        let c = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        guard let hit = arView.raycast(from: c, allowing: .estimatedPlane, alignment: .any).first else { return nil }
        let t = hit.worldTransform
        return (SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z), simd_normalize(SIMD3(t.columns.1.x, t.columns.1.y, t.columns.1.z)))
    }

    // MARK: tags

    /// the pins drawn for each tag (a measurement has two), so a tag can be taken back
    private var tagPins: [[Entity]] = []

    func addTag(kind: String, name: String, at spot: (p: SIMD3<Float>, n: SIMD3<Float>)) {
        var m: [String: Any] = ["type": "object", "kind": kind, "p": [spot.p.x, spot.p.y, spot.p.z], "n": [spot.n.x, spot.n.y, spot.n.z]]
        if !name.isEmpty { m["name"] = name }
        tags.append(m)
        tagPins.append([overlay.addTag(at: spot.p, normal: spot.n)])
    }

    /// take a tag (or a measurement) back: it's off the map and its pin goes
    func removeTag(at i: Int) {
        guard i >= 0, i < tags.count else { return }
        let t = tags.remove(at: i)
        if i < tagPins.count { tagPins.remove(at: i).forEach { $0.removeFromParent() } }
        diag("tag removed: \(t["kind"] as? String ?? t["type"] as? String ?? "?")", now: true)
    }

    /// a tag of this kind (or kinds starting with it) within reach of a spot, along the floor
    func hasTag(prefix: String, near p: SIMD3<Float>, within r: Float) -> Bool {
        tags.contains { t in
            guard (t["kind"] as? String)?.hasPrefix(prefix) == true, let q = t["p"] as? [Float], q.count == 3 else { return false }
            return simd_distance(SIMD2(q[0], q[2]), SIMD2(p.x, p.z)) < r
        }
    }

    func addMeasure(_ a: SIMD3<Float>, _ b: SIMD3<Float>) {
        tags.append(["type": "measure", "a": [a.x, a.y, a.z], "b": [b.x, b.y, b.z]])
        tagPins.append([overlay.addTag(at: a, normal: [0, 1, 0]), overlay.addTag(at: b, normal: [0, 1, 0])])
    }

    // MARK: rooms: stop, pause, start over

    /// stop the current room and wait until RoomPlan has processed it
    func finishRoom() async {
        roomActive = false
        guard !outside, capturing, let c = capture else { return }
        capturing = false
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            roomWaiter = k
            c.stop(pauseARSession: false)
        }
    }

    /// Pause: RoomPlan stops (nothing is scanned while you walk around or figure something out); tracking carries on, so
    /// Resume picks up the same room - its two parts are joined on the map.
    func pauseRoom() async {
        guard !outside, capturing, let c = capture else { return }
        pausing = true
        capturing = false
        roomActive = false
        if let e = lastEye { pausedAt = (eye: e, shape: liveShape?.poly ?? []) } else { pausedAt = nil }
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            roomWaiter = k
            c.stop(pauseARSession: false)
        }
        paused = true
        diag("paused", now: true)
    }

    /// Resume: carry on with the paused room - unless you walked to another floor or far from it (then the paused part
    /// is a room of its own and this is a new one). Returns true when it's the same room.
    @discardableResult
    func resumeRoom() -> Bool {
        var same = pendingPartial != nil
        if let at = pausedAt, let e = lastEye {
            let otherFloor = abs(e.y - at.eye.y) > 1.8
            let far = at.shape.count >= 3 ? Floorplan.outside(SIMD2(e.x, e.z), at.shape) > 1.5 : simd_distance(SIMD2(e.x, e.z), SIMD2(at.eye.x, at.eye.z)) > 6
            if otherFloor || far, let p = pendingPartial {
                partials.remove(p); pendingPartial = nil; same = false
                if otherFloor { floor = max(0, floor + (e.y > at.eye.y ? 1 : -1)) }
            }
        }
        pausedAt = nil
        diag("resumed: " + (same ? "same room" : "a new room"), now: true)
        startRoom()
        return same
    }

    /// done while paused (Finish, the garden): the paused part is a room of its own - nothing is restarted
    func endPause() {
        if let p = pendingPartial, paused { partials.remove(p); pendingPartial = nil }
        paused = false
        pausedAt = nil
    }

    /// throw away what's scanned of the room you're in and scan it again (finished rooms stay)
    func redoRoom() async {
        guard !outside, capturing, let c = capture else { return }
        capturing = false
        roomActive = false
        discardNext = true
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            roomWaiter = k
            c.stop(pauseARSession: false)
        }
        startRoom()
    }

    /// garden / alleys: keep the same AR session (so it lines up) but build a raw LiDAR mesh instead of rooms
    func goOutside() {
        if houseRooms == nil { houseRooms = rooms.count }
        let fy = liveRoom.flatMap(Self.floorY) ?? rooms.last.flatMap(Self.floorY) ?? lastEye.map { $0.y - 1.4 }
        if let fy { exitFloor = (y: fy, shifts: shifts) } else { exitFloor = nil }
        groundYs = []
        outside = true; paused = false
        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) { config.sceneReconstruction = .meshWithClassification }
        else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) { config.sceneReconstruction = .mesh }
        config.planeDetection = [.horizontal, .vertical]
        arSession.run(config)   // no reset options: the world coordinates carry on from inside
        afterRun()
        // what's meshed so far is the house: only what's scanned out here is the garden
        for a in meshAnchors where gardenMesh[a.identifier] == nil { insideMesh.insert(a.identifier) }
    }

    var meshAnchors: [ARMeshAnchor] { arSession.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? [] }

    /// everything scanned outside (kept as you go: ARKit drops it when room scanning restarts, and the house's own
    /// mesh scanned after coming back in isn't the garden)
    var allMeshAnchors: [ARMeshAnchor] {
        guard houseRooms != nil else { return [] }   // never went outside
        if outside, !isShutDown { captureGarden() }
        return Array(gardenMesh.values)
    }
    private var insideMesh = Set<UUID>()

    /// the garden mesh in view now goes into the kept garden
    private func captureGarden() {
        for a in meshAnchors where !insideMesh.contains(a.identifier) { gardenMesh[a.identifier] = a; gardenFix[a.identifier] = nil }
    }

    /// a garden mesh piece -> the home's frame
    func meshToHome(_ a: ARMeshAnchor) -> simd_float4x4 { toHome * (gardenFix[a.identifier] ?? matrix_identity_float4x4) }

    /// back to room scanning from the garden (into the house, or a room out there): same AR session
    func backInside() {
        captureGarden()
        outside = false
        exitFloor = nil
    }

    // MARK: a fresh map section

    /// "Hold still…" while a fresh section starts ("" when done)
    var onSection: ((String) -> Void)?
    /// a fresh section started: positions kept elsewhere (the named things) move by this (old live world -> new one)
    var onRebase: ((simd_float4x4) -> Void)?
    /// rooms RoomPlan stopped right at their start for being too big, in a row
    private var earlyLimits = 0
    /// which section each room was scanned in (rooms of different sections can't go into one RoomPlan structure)
    private var roomSection: [Int: Int] = [:]
    /// garden mesh pieces (seen while outside), and what moves each into the live world
    private var gardenMesh: [UUID: ARMeshAnchor] = [:]
    private var gardenFix: [UUID: simd_float4x4] = [:]

    /// a room into the list: its floor and section
    @discardableResult
    private func addRoom(_ r: CapturedRoom) -> Int {
        rooms.append(r)
        let i = rooms.count - 1
        roomLevel[i] = roomFloorAtStart
        roomSection[i] = sections
        return i
    }

    /// RoomPlan stops every new room once one AR world holds too much ("Capture scene exceeded limit" right at the
    /// start, twice in a row). The scan carries on in a fresh AR world: the phone is held still across the restart, so
    /// its pose in the old world and in the new one ties them together (ARKit keeps "up" in both). Everything scanned
    /// so far is moved into the new world, and what's sent goes back to the home's frame by `toHome`.
    func newSection() async {
        guard !isShutDown, !restarting else { return }
        restarting = true
        capturing = false; roomActive = false
        capture = nil
        liveRoom = nil; liveShape = nil
        if let p = pendingPartial { partials.remove(p); pendingPartial = nil }    // a part that was stopped: a room of its own
        DispatchQueue.main.async { self.onSection?("Hold the phone still - starting a fresh map section…") }
        diag("RoomPlan keeps stopping new rooms (this AR world holds too much): fresh map section \(sections + 1) "
             + "after \(roomsInSection) rooms in this one", now: true)
        if let m = await worldMapNow() { sectionMaps.append((map: m, toHome: toHome, rooms: roomsInSection)) }
        // the old world's pose, held still for 0.6 s (up to 5 s)
        var recent: [simd_float4x4] = []
        var oldPose: simd_float4x4?
        for _ in 0..<50 {
            try? await Task.sleep(for: .milliseconds(100))
            guard let f = arSession.currentFrame, case .normal = f.camera.trackingState else { recent = []; continue }
            recent.append(f.camera.transform)
            if recent.count > 6 { recent.removeFirst() }
            if recent.count == 6, Self.still(recent) { oldPose = recent.last; break }
        }
        let heldOld = oldPose != nil
        guard let old = oldPose ?? arSession.currentFrame?.camera.transform, let cfg = trackingConfig(map: nil), !isShutDown else {
            restarting = false
            DispatchQueue.main.async { self.onSection?("") }
            return
        }
        let stamp = arSession.currentFrame?.timestamp ?? 0
        arSession.run(cfg, options: [.resetTracking, .removeExistingAnchors])
        afterRun()
        // the new world's first steady poses (up to 8 s)
        var fresh: [simd_float4x4] = []
        for _ in 0..<80 {
            try? await Task.sleep(for: .milliseconds(100))
            guard let f = arSession.currentFrame, f.timestamp > stamp, case .normal = f.camera.trackingState else { continue }
            fresh.append(f.camera.transform)
            if fresh.count >= 4 { break }
        }
        guard !isShutDown else { restarting = false; return }
        let new = fresh.first ?? arSession.currentFrame?.camera.transform ?? matrix_identity_float4x4
        let heldNew = fresh.count >= 4 && Self.still(fresh)
        let k = Frames.chain(old: old, new: new)          // new world -> old world
        let m = k.inverse                                  // old world -> new world
        toHome = toHome * k
        for i in rooms.indices { roomFix[i] = m * fix(i) }
        for id in gardenMesh.keys { gardenFix[id] = m * (gardenFix[id] ?? matrix_identity_float4x4) }
        rebase(m)
        sections += 1
        sectionFirstRoom = rooms.count
        earlyLimits = 0
        lastEye = nil; normalSince = nil
        insideMesh = []
        diag("fresh map section \(sections) started" + (heldOld && heldNew ? " (phone held still: lines up)" : " - the phone moved during the restart: Home Assistant may need to line it up"), now: true)
        restarting = false
        DispatchQueue.main.async { self.onSection?("") }
        startRoom()
    }

    /// a few poses within 1.5 cm and ~1.5° of each other
    private static func still(_ poses: [simd_float4x4]) -> Bool {
        guard let a = poses.first else { return false }
        let fa = simd_make_float3(a.columns.2)
        return poses.allSatisfy { p in
            simd_distance(simd_make_float3(p.columns.3), simd_make_float3(a.columns.3)) < 0.015 && simd_dot(simd_make_float3(p.columns.2), fa) > 0.9997
        }
    }

    /// everything kept in the live world moves into the new one
    private func rebase(_ m: simd_float4x4) {
        tags = tags.map { t in
            var o = t
            for k in ["p", "a", "b"] { if let v = t[k] as? [Float], v.count == 3 { let w = Frames.apply(m, SIMD3(v[0], v[1], v[2])); o[k] = [w.x, w.y, w.z] } }
            if let v = t["n"] as? [Float], v.count == 3 { let w = Frames.turn(m, SIMD3(v[0], v[1], v[2])); o["n"] = [w.x, w.y, w.z] }
            return o
        }
        drops = drops.map { (p: Frames.apply(m, $0.p), eye: $0.eye + m.columns.3.y) }
        lights.rebase(m)
        colors.rebase(m)
        poses.rebase(m)
        overlay.rebase(m)
        keyframes?.rebase(m)
        onRebase?(m)
    }

    /// the phone's memory of this place, so a later scan can lock on to it
    func worldMapNow() async -> ARWorldMap? {
        await withCheckedContinuation { k in
            arSession.getCurrentWorldMap { map, _ in k.resume(returning: map) }
        }
    }

    func shutdown() {
        guard !isShutDown else { return }
        if torchOn { torchOn = false; applyTorch() }
        isShutDown = true
        timer?.invalidate()
        timer = nil
        meshTimer?.invalidate()
        meshTimer = nil
        poses.stop()
        if capturing { capture?.stop() }
        capturing = false
        arSession.pause()
        roomWaiter?.resume(); roomWaiter = nil
    }

    // MARK: RoomCaptureSessionDelegate

    func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        liveRoom = room
        let walls = room.walls.map { w -> (SIMD2<Float>, SIMD2<Float>) in
            let c = w.transform.columns.3, d = w.transform.columns.0
            return RoomShape.ends(center: SIMD2(c.x, c.z), along: SIMD2(d.x, d.z), length: w.dimensions.x)
        }
        let poly = RoomShape.hull(walls.flatMap { [$0.0, $0.1] })
        DispatchQueue.main.async { if self.capturing { self.liveShape = (poly: poly, walls: walls) } }
        let now = Date()
        guard now.timeIntervalSince(lastLive) > 0.3 else { return }
        lastLive = now
        DispatchQueue.main.async { if !self.isShutDown { self.overlay.showLive(room) } }
    }

    func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
        let text: String
        switch instruction {
        case .moveCloseToWall: text = "Move a little closer to the walls"
        case .moveAwayFromWall: text = "Step back from the wall"
        case .slowDown: text = "Slow down a little"
        case .turnOnLight: text = Self.hasTorch ? "Too dark - turn on a light or the flashlight" : "Too dark - turn on a light"
        case .lowTexture: text = "Point at something with more detail"
        case .normal: text = ""
        @unknown default: text = ""
        }
        DispatchQueue.main.async { self.onInstruction?(text) }
    }

    /// nothing in it: a room stopped before RoomPlan saw a wall or a piece of furniture (it made empty floors on the map)
    private static func isEmpty(_ r: CapturedRoom) -> Bool { r.walls.isEmpty && r.objects.isEmpty }

    private func done() {
        roomWaiter?.resume()
        roomWaiter = nil
    }

    func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        // thrown away (Stop and discard / finished): nothing more is kept or saved
        if isShutDown { DispatchQueue.main.async { self.done() }; return }
        if discardNext {
            discardNext = false
            DispatchQueue.main.async { self.liveRoom = nil; self.done() }
            return
        }
        // paused: keep what's scanned as the first part of this room; Resume carries on with it
        if pausing {
            pausing = false
            Task {
                let part = try? await RoomBuilder(options: [.beautifyObjects]).capturedRoom(from: data)
                await MainActor.run {
                    if let part, !Self.isEmpty(part), !self.isShutDown {
                        let i = self.addRoom(part)
                        self.partials.insert(i)
                        self.pendingPartial = i
                        self.overlay.commit(part)
                    }
                    self.liveRoom = nil
                    self.done()
                }
            }
            return
        }
        // RoomPlan gave up on the room by itself (tracking lost - the camera was covered, it was moved too fast...):
        // it has stopped the camera too. Get the camera going again and start the room over, instead of a frozen picture.
        if let error, roomWaiter == nil {
            let boosted = boostedAt.map { Date().timeIntervalSince($0) < 15 } ?? false
            let early = Date().timeIntervalSince(roomStarted) < 20
            // only a stop while tracking was fine counts against the mesh (relocalizing, a covered camera... are other causes)
            if boosted && early && trackingWasNormal && !Self.meshBreaksRoomPlan {
                Self.meshStops += 1
                diag("RoomPlan stopped right after the mesh was added (\(error.localizedDescription)) - "
                     + (Self.meshBreaksRoomPlan ? "rooms scan without it from now on" : "once; it's tried again"), now: true)
            } else {
                diag("RoomPlan stopped the room: \(error.localizedDescription)", now: true)
            }
            boostedAt = nil
            let before = lastEye
            let age = Date().timeIntervalSince(roomStarted)
            DispatchQueue.main.async {
                self.liveRoom = nil
                self.capturing = false
                self.capture = nil                             // a fresh RoomPlan session to carry on with
                if let cfg = self.arSession.configuration { self.rerun(cfg) }   // camera back, same world, no saved map
            }
            Task {
                // keep what's scanned so far (a popup - AirPods, a call - pauses the camera and RoomPlan gives up on the room)
                let part = try? await RoomBuilder(options: [.beautifyObjects]).capturedRoom(from: data)
                // carry on only once tracking is back (straight away it failed again within seconds)
                for _ in 0..<24 {
                    if case .normal? = self.arSession.currentFrame?.camera.trackingState { break }
                    try? await Task.sleep(for: .milliseconds(500))
                }
                await MainActor.run {
                    guard !self.isShutDown else { return }
                    // the world mustn't have jumped while the camera was paused, or the two parts won't line up
                    var jump: Float = 0
                    if let b = before, let c = self.arSession.currentFrame?.camera.transform.columns.3 { jump = simd_distance(b, SIMD3(c.x, c.y, c.z)) }
                    var kept = false
                    var tooBig = false
                    if let e = error as? RoomCaptureSession.CaptureError, case .exceedSceneSizeLimit = e { tooBig = true }
                    // "too big" right as a room starts, with next to nothing scanned: it's the AR world that's full, not
                    // this room. The second time in a row, the scan carries on in a fresh map section.
                    if tooBig, age < 25, (part?.walls.count ?? 0) < 3 { self.earlyLimits += 1 } else { self.earlyLimits = 0 }
                    if self.earlyLimits >= 2, self.rooms.count > self.sectionFirstRoom {
                        if let part, part.walls.count >= 2 || !part.objects.isEmpty, jump < 1.5 {
                            let i = self.addRoom(part)
                            self.overlay.commit(part)
                            self.onRoomDone?(.saved(i))
                        }
                        self.onRoomLost?(error, false)
                        Task { await self.newSection() }
                        return
                    }
                    if tooBig, let part, part.walls.count >= 2, jump < 1.5 {
                        // the room got too big for RoomPlan (walked on through a door it didn't see): what's scanned is a
                        // room of its own, and the next one starts
                        self.addRoom(part)
                        self.overlay.commit(part)
                        self.diag("the room got too big for RoomPlan: saved as its own room (\(part.walls.count) walls, \(part.objects.count) objects)", now: true)
                        self.onRoomDone?(.saved(self.rooms.count - 1))
                        self.onRoomLost?(error, true)
                        self.startRoom()
                        return
                    }
                    if let part, (part.walls.count >= 2 || !part.objects.isEmpty), jump < 1.5 {
                        let i = self.addRoom(part)
                        self.partials.insert(i)
                        self.pendingPartial = i
                        self.overlay.commit(part)
                        kept = true
                    }
                    self.diag(kept ? "kept the part scanned so far (\(part?.walls.count ?? 0) walls, \(part?.objects.count ?? 0) objects); carrying on"
                                   : "nothing kept (\(part == nil ? "no room data" : jump >= 1.5 ? String(format: "the world moved %.1f m", jump) : "too little scanned")); starting the room over", now: true)
                    self.onRoomLost?(error, kept)
                    self.startRoom()
                }
            }
            return
        }
        Task {
            var result: RoomResult = .empty
            if let error { result = .failed(error) } else {
                do {
                    let room = try await RoomBuilder(options: [.beautifyObjects]).capturedRoom(from: data)
                    result = await MainActor.run { () -> RoomResult in
                        guard !self.isShutDown else { return .empty }
                        if Self.isEmpty(room) {
                            // nothing scanned: the paused part (if any) is the whole room
                            if let p = self.pendingPartial { self.partials.remove(p); self.pendingPartial = nil }
                            self.diag("room had nothing in it - not saved")
                            return .empty
                        }
                        let i = self.addRoom(room)
                        self.earlyLimits = 0
                        if let p = self.pendingPartial { self.mergeInto[i] = p; self.pendingPartial = nil }
                        self.overlay.commit(room)
                        return .saved(i)
                    }
                } catch { result = .failed(error) }
            }
            let final = result
            await MainActor.run {
                self.liveRoom = nil
                if !self.isShutDown { self.onRoomDone?(final) }
                self.done()
            }
        }
    }

    // MARK: export

    /// rooms grouped into floors by height (stairs take you > 1.2 m up), each floor merged into one structure, and the
    /// floor each story is (what you started on, plus the stairs you took)
    func exportStories() async -> [[String: Any]] {
        let merged = Set(mergeInto.values)                     // first parts that went into their room
        // floor heights in the home's frame (a fresh section's world starts at another height; turns are about the vertical)
        let sorted = rooms.enumerated().filter { !merged.contains($0.offset) && !Self.isEmpty($0.element) }
            .map { ($0.element, (Self.floorY($0.element) ?? 0) + (toHome * fix($0.offset)).columns.3.y, $0.offset) }.sorted { $0.1 < $1.1 }
        var groups: [[(CapturedRoom, Float, Int)]] = []
        for r in sorted {
            if let last = groups.last?.last, r.1 - last.1 < 1.2 { groups[groups.count - 1].append(r) } else { groups.append([r]) }
        }
        var out: [[String: Any]] = []
        for g in groups {
            let ys = g.map(\.1).sorted()
            let heights = g.flatMap { $0.0.walls.map(\.dimensions.y) }.sorted()
            // a room's name: what you called it, else the phone's guess (bedroom, kitchen...), else none
            func name(_ i: Int, _ r: CapturedRoom) -> String? {
                if let n = roomNames[i] { return n }
                let g = [r] + (mergeInto[i].flatMap { $0 < rooms.count ? [rooms[$0]] : nil } ?? [])
                return g.map(HomeScanModel.guess).first { !$0.isEmpty }
            }
            var story: [String: Any] = ["floorY": ys[ys.count / 2], "rooms": g.map { r -> [String: Any] in
                let to = toHome * fix(r.2)
                if let p = mergeInto[r.2], p < rooms.count { return Export.merged(rooms[p], r.0, name: name(r.2, r.0), objects: withObjects, to: to) }
                return Export.room(r.0, name: name(r.2, r.0), objects: withObjects, to: to)
            }]
            // the floor this story is on: what most of its rooms were scanned on
            let votes = Dictionary(grouping: g.map { roomLevel[$0.2] ?? 0 }, by: { $0 }).mapValues(\.count)
            if let lv = votes.max(by: { $0.value < $1.value })?.key { story["level"] = Levels.id(lv) }
            if !heights.isEmpty { story["ceiling"] = heights[heights.count / 2] }
            // both parts of a paused room go into the floor's structure (the room list keeps one of each)
            let idx = g.map(\.2) + g.compactMap { mergeInto[$0.2] }.filter { $0 < rooms.count }
            let parts = idx.map { rooms[$0] }
            // only rooms of one map section can be merged by RoomPlan (each section is its own AR world)
            let oneSection = Set(idx.map { roomSection[$0] ?? 1 }).count == 1
            if parts.count > 1, oneSection, let first = idx.first,
               let s = try? await StructureBuilder(options: [.beautifyObjects]).capturedStructure(from: parts) {
                story["structure"] = Export.structure(s, objects: withObjects, to: toHome * fix(first))
            }
            out.append(story)
        }
        return out
    }
}

/// Real wall colors: while you scan, each wall in view gets its color sampled from the camera (only the color is kept).
final class WallColors {
    private var acc: [UUID: (p: SIMD3<Float>, r: Float, g: Float, b: Float, n: Float)] = [:]

    func sample(_ frame: ARFrame, walls: [CapturedRoom.Surface]) {
        let pb = frame.capturedImage
        guard CVPixelBufferGetPlaneCount(pb) >= 2 else { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0), let cBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let yRow = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), cRow = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        let Y = yBase.assumingMemoryBound(to: UInt8.self), CbCr = cBase.assumingMemoryBound(to: UInt8.self)
        let cam = frame.camera.transform.columns.3, camP = SIMD3<Float>(cam.x, cam.y, cam.z)
        let fwd = -SIMD3<Float>(frame.camera.transform.columns.2.x, frame.camera.transform.columns.2.y, frame.camera.transform.columns.2.z)
        for wall in walls {
            let c4 = wall.transform.columns.3, c = SIMD3<Float>(c4.x, c4.y, c4.z)
            let toWall = c - camP, dist = simd_length(toWall)
            guard dist > 0.6, dist < 4.5, simd_dot(simd_normalize(toWall), fwd) > 0.55 else { continue }
            let n4 = wall.transform.columns.2, n = simd_normalize(SIMD3<Float>(n4.x, n4.y, n4.z))
            guard abs(simd_dot(n, simd_normalize(toWall))) > 0.45 else { continue }   // facing the camera, not edge-on
            // a spot a little below the wall's middle (pictures and furniture tend to sit lower; ceilings are above)
            let spot = c + SIMD3<Float>(0, -wall.dimensions.y * 0.12, 0)
            let ip = frame.camera.projectPoint(spot, orientation: .landscapeRight, viewportSize: CGSize(width: w, height: h))
            let px = Int(ip.x), py = Int(ip.y)
            guard px > 8, py > 8, px < w - 8, py < h - 8 else { continue }
            var ys: Float = 0, cbs: Float = 0, crs: Float = 0, k: Float = 0
            for dy in stride(from: -6, through: 6, by: 3) {
                for dx in stride(from: -6, through: 6, by: 3) {
                    let x = px + dx, y = py + dy
                    ys += Float(Y[y * yRow + x])
                    let ci = (y / 2) * cRow + (x / 2) * 2
                    cbs += Float(CbCr[ci]); crs += Float(CbCr[ci + 1]); k += 1
                }
            }
            let yy = ys / k, cb = cbs / k - 128, cr = crs / k - 128
            let r = yy + 1.402 * cr, g = yy - 0.344136 * cb - 0.714136 * cr, b = yy + 1.772 * cb
            var e = acc[wall.identifier] ?? (p: c, r: 0, g: 0, b: 0, n: 0)
            e.p = c; e.r += r; e.g += g; e.b += b; e.n += 1
            acc[wall.identifier] = e
        }
    }

    /// a fresh map section: the walls' spots move into the new AR world
    func rebase(_ m: simd_float4x4) { acc = acc.mapValues { e in var e = e; e.p = Frames.apply(m, e.p); return e } }

    /// [{p: [x,y,z], c: "#rrggbb"}] with brightness evened out (rooms are lit differently), in the home's frame
    func json(to m: simd_float4x4 = matrix_identity_float4x4) -> [[String: Any]] {
        acc.values.filter { $0.n >= 2 }.map { e in
            var r = e.r / e.n, g = e.g / e.n, b = e.b / e.n
            let l = max(1, 0.299 * r + 0.587 * g + 0.114 * b)
            let target = min(235, max(120, l * 1.25))
            r *= target / l; g *= target / l; b *= target / l
            let hex = String(format: "#%02x%02x%02x", Int(min(255, max(0, r))), Int(min(255, max(0, g))), Int(min(255, max(0, b))))
            let p = Frames.apply(m, e.p)
            return ["p": [p.x, p.y, p.z], "c": hex]
        }
    }
}

struct HomeScanContainer: UIViewControllerRepresentable {
    let controller: HomeScanController
    func makeUIViewController(context: Context) -> HomeScanController { controller }
    func updateUIViewController(_ vc: HomeScanController, context: Context) {}
}
