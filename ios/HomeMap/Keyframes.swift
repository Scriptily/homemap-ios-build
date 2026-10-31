import ARKit
import CoreImage
import Foundation
import simd

/// Photos of the scan, kept for later: textures on the map, a photo-real model of the home, rebuilding rooms with
/// better tools. Every sharp new view (moved 40 cm or turned 20° since the last one, the phone steady) is saved as the
/// camera picture (1920 x 1440 JPEG) + the LiDAR depth of that moment + exactly where the phone was and its lens.
/// About 0.6 MB a photo; a whole home is ~1-2 GB. They go to the PC (photo_sink.py, onto the NAS) after the scan is
/// sent - through Home Assistant's memory only - and leave the phone once the PC has them.
final class Keyframes {
    struct Shot {
        let name: String
        let t: Double
        var pose: simd_float4x4          // camera -> live AR world (the camera looks down -z)
        let fx: Float, fy: Float, cx: Float, cy: Float
        let w: Int, h: Int
        let depth: Bool
        let room: Int, section: Int
    }

    let scan: String
    let dir: URL
    private(set) var shots: [Shot] = []
    private(set) var bytes = 0
    private let queue = DispatchQueue(label: "keyframes", qos: .utility)
    private let ci = CIContext(options: [.useSoftwareRenderer: false])
    private var busy = false
    private var last: simd_float4x4?
    private var lastAt = Date.distantPast
    private var prev: simd_float4x4?
    /// off: no photos (Settings, a full phone)
    var enabled = Keyframes.on

    /// Settings: keep photos of the scan (on unless turned off)
    static var on: Bool {
        get { UserDefaults.standard.object(forKey: "keepPhotos") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "keepPhotos") }
    }

    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("photos", isDirectory: true)
    }

    init(scan: String) {
        self.scan = scan
        dir = Self.root.appendingPathComponent(scan, isDirectory: true)
    }

    /// every look (~3x a second) while scanning, with tracking steady: a photo when it's a new view and sharp
    func consider(_ frame: ARFrame, room: Int, section: Int) {
        let pose = frame.camera.transform
        defer { prev = pose }
        guard enabled, !busy, let p = prev else { return }
        let thermal = ProcessInfo.processInfo.thermalState
        guard thermal != .critical else { return }
        // sharp: hardly moved since the last look (a third of a second)
        let move = simd_distance(simd_make_float3(pose.columns.3), simd_make_float3(p.columns.3))
        let turn = simd_dot(simd_make_float3(pose.columns.2), simd_make_float3(p.columns.2))
        guard move < 0.05, turn > 0.9985 else { return }
        let gap: TimeInterval = thermal == .serious ? 1.5 : 0.6
        guard Date().timeIntervalSince(lastAt) >= gap else { return }
        if let l = last {
            let moved = simd_distance(simd_make_float3(pose.columns.3), simd_make_float3(l.columns.3))
            let turned = simd_dot(simd_make_float3(pose.columns.2), simd_make_float3(l.columns.2))
            guard moved >= 0.4 || turned < 0.94 else { return }
        }
        // the phone must keep room for itself (and the rest of the scan)
        if shots.count % 50 == 0, let free = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, free < 3_000_000_000 {
            enabled = false
            ScanLog.shared.add("photos stopped: less than 3 GB free on the phone", now: true)
            return
        }
        last = pose; lastAt = Date(); busy = true
        let name = String(format: "%05d", shots.count + 1)
        let k = frame.camera.intrinsics
        let pb = frame.capturedImage
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let depth = Self.depthData(frame)
        shots.append(Shot(name: name, t: Date().timeIntervalSince1970, pose: pose, fx: k[0][0], fy: k[1][1], cx: k[2][0], cy: k[2][1],
                          w: w, h: h, depth: depth != nil, room: room, section: section))
        let image = CIImage(cvPixelBuffer: pb)
        let dir = self.dir
        queue.async { [weak self] in
            guard let self else { return }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var n = 0
            // the raw sensor picture (landscape, as the lens numbers describe it): no rotation
            if let cs = CGColorSpace(name: CGColorSpace.sRGB),
               let jpg = self.ci.jpegRepresentation(of: image, colorSpace: cs, options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.8]) {
                try? jpg.write(to: dir.appendingPathComponent(name + ".jpg")); n += jpg.count
            }
            if let d = depth { try? d.write(to: dir.appendingPathComponent(name + ".depth")); n += d.count }
            DispatchQueue.main.async { self.bytes += n; self.busy = false }
        }
    }

    /// "HMD1" | width UInt16 | height UInt16 | raw deflate of (depth Float16 x w*h, meters; then confidence UInt8 x w*h, 0-2)
    static func depthData(_ frame: ARFrame) -> Data? {
        guard let dd = frame.sceneDepth ?? frame.smoothedSceneDepth else { return nil }
        let dm = dd.depthMap
        CVPixelBufferLockBaseAddress(dm, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(dm, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(dm) == kCVPixelFormatType_DepthFloat32, let base = CVPixelBufferGetBaseAddress(dm) else { return nil }
        let w = CVPixelBufferGetWidth(dm), h = CVPixelBufferGetHeight(dm), row = CVPixelBufferGetBytesPerRow(dm)
        var raw = Data(capacity: w * h * 3)
        for y in 0..<h {
            let line = base.advanced(by: y * row).assumingMemoryBound(to: Float32.self)
            for x in 0..<w { withUnsafeBytes(of: Float16(line[x]).bitPattern.littleEndian) { raw.append(contentsOf: $0) } }
        }
        if let cm = dd.confidenceMap {
            CVPixelBufferLockBaseAddress(cm, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(cm, .readOnly) }
            if let cb = CVPixelBufferGetBaseAddress(cm) {
                let crow = CVPixelBufferGetBytesPerRow(cm)
                for y in 0..<h { raw.append(cb.advanced(by: y * crow).assumingMemoryBound(to: UInt8.self), count: w) }
            }
        } else {
            raw.append(Data(repeating: 2, count: w * h))
        }
        guard let z = try? (raw as NSData).compressed(using: .zlib) as Data else { return nil }
        var d = Data("HMD1".utf8)
        withUnsafeBytes(of: UInt16(w).littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(h).littleEndian) { d.append(contentsOf: $0) }
        d.append(z)
        return d
    }

    /// a fresh map section: the photos' poses move into the new AR world
    func rebase(_ m: simd_float4x4) { for i in shots.indices { shots[i].pose = m * shots[i].pose } }

    /// after the scan: index.json (every photo's pose in the home's frame, its lens, its room) next to the photos.
    /// Waits for the last photo to be written. Returns the number of photos.
    @discardableResult
    func finish(toHome: simd_float4x4, rooms: [Int: String]) -> Int {
        queue.sync {}
        guard !shots.isEmpty else { try? FileManager.default.removeItem(at: dir); return 0 }
        let list: [[String: Any]] = shots.map { s in
            var o: [String: Any] = ["name": s.name, "t": s.t, "pose": Export.mat(toHome * s.pose), "intrinsics": [s.fx, s.fy, s.cx, s.cy],
                                    "w": s.w, "h": s.h, "depth": s.depth, "room": s.room, "section": s.section]
            if let n = rooms[s.room] { o["roomName"] = n }
            return o
        }
        let index: [String: Any] = [
            "version": 1, "scan": scan, "created": Date().timeIntervalSince1970,
            "about": "camera -> home frame (meters, +y up), column-major; the camera looks down -z, +y up in the raw landscape picture; "
                + "intrinsics fx fy cx cy in pixels of the jpg. depth: HMD1 | w | h (UInt16 LE) | raw deflate(Float16 meters x w*h, UInt8 confidence 0-2 x w*h)",
            "shots": list,
        ]
        if let d = try? JSONSerialization.data(withJSONObject: index) { try? d.write(to: dir.appendingPathComponent("index.json")) }
        ScanLog.shared.add("photos: \(shots.count) kept for later, \(bytes / 1_000_000) MB", now: true)
        return shots.count
    }

    /// thrown away with the scan
    func discard() {
        enabled = false
        queue.async { [dir] in try? FileManager.default.removeItem(at: dir) }
    }
}

/// Sends the kept photos to the PC (through Home Assistant's memory) and deletes each from the phone once the PC has
/// saved it. Runs after a scan is sent, and when the app opens with photos still waiting.
@MainActor
final class PhotoSender: ObservableObject {
    static let shared = PhotoSender()
    /// files still on the phone (all scans), and what's going on
    @Published private(set) var left = 0
    @Published private(set) var status = ""
    private var running = false

    /// photo sets waiting on the phone (only complete ones: index.json is written at the end of the scan)
    nonisolated static func waiting() -> [URL] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: Keyframes.root, includingPropertiesForKeys: nil) else { return [] }
        return dirs.filter { fm.fileExists(atPath: $0.appendingPathComponent("index.json").path) }
    }

    nonisolated static func count() -> Int {
        waiting().reduce(0) { $0 + ((try? FileManager.default.contentsOfDirectory(atPath: $1.path).count) ?? 0) }
    }

    func refresh() { left = Self.count(); if left == 0 { status = "" } }

    /// photos of a scan that never finished (the app was closed mid-scan): their poses were only in memory, so they're
    /// of no use - removed when the start screen opens (no scan is running then)
    nonisolated static func cleanOrphans() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: Keyframes.root, includingPropertiesForKeys: nil) else { return }
        for d in dirs where !fm.fileExists(atPath: d.appendingPathComponent("index.json").path) { try? fm.removeItem(at: d) }
    }

    func send(client: HAClient?) {
        guard let client, !running else { return }
        running = true
        Task {
            defer { running = false; refresh() }
            for dir in Self.waiting() {
                let scan = dir.lastPathComponent
                guard await sendSet(dir, scan: scan, client: client) else { return }
            }
            status = ""
        }
    }

    /// one scan's photos: everything but index.json first, index.json last; true when the set is all on the PC
    private func sendSet(_ dir: URL, scan: String, client: HAClient) async -> Bool {
        let fm = FileManager.default
        var names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0 != "index.json" }.sorted() + ["index.json"]
        var sentSince = 0
        while !names.isEmpty {
            left = Self.count()
            // the PC isn't listening (off, or photo_sink.py not running): keep them and stop
            if let st = try? await client.photosDone(scan: scan) {
                for n in st.done { try? fm.removeItem(at: dir.appendingPathComponent(n)) }
                names.removeAll { st.done.contains($0) }
                if st.pcAge < 0 || st.pcAge > 90 {
                    status = "Photos wait on this phone until the PC is on (\(Self.count()) files)"
                    return false
                }
                if names.isEmpty { break }
            } else {
                status = "Photos wait on this phone until Home Assistant can be reached"
                return false
            }
            status = "Sending photos to the PC: \(Self.count()) files left - keep the app open"
            // a batch, then ask what the PC has saved
            for n in names.prefix(25) where fm.fileExists(atPath: dir.appendingPathComponent(n).path) {
                if n == "index.json" && names.count > 1 { continue }       // the index goes last
                guard let data = try? Data(contentsOf: dir.appendingPathComponent(n)) else { continue }
                var tries = 0
                while true {
                    do { try await client.photo(scan: scan, name: n, data: data); break }
                    catch let e as NSError where e.domain == "HomeAssistant" && e.code == 503 && tries < 30 {
                        tries += 1; try? await Task.sleep(for: .seconds(1))     // Home Assistant's queue is full: the PC catches up
                    } catch { status = "Photos wait on this phone (sending failed: \(error.localizedDescription))"; return false }
                }
                sentSince += 1
            }
            try? await Task.sleep(for: .milliseconds(sentSince > 0 ? 300 : 2000))
            sentSince = 0
        }
        try? fm.removeItem(at: dir)
        ScanLog.shared.add("photos of \(scan): all on the PC")
        return true
    }
}
