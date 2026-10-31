import ARKit
import Foundation
import simd

// The home's surfaces as a point cloud (5 cm cells: position, which way it faces, its color), built up while you scan
// and saved with the phone's map of the place. Two uses:
// - the next scan checks that it really locked on: the LiDAR mesh it sees has to sit on these saved surfaces
//   (SurfaceIndex.check), before anything is scanned into the map
// - Home Assistant / the PC can rebuild walls and furniture from it (tools/cloud.py writes a .ply)
// Only colors are kept, never pictures.
//
// SurfaceIndex, its alignment check and the live mesh sampling are adapted from "3D Model Anything" by Wes Bos
// (github.com/wesbos/3d-model-anything, MIT license - see THIRD_PARTY_NOTICES.md).

/// Voxel hash of a surface: one centroid + mean normal per cell, plus which way the surfaces face in each coarse 20 cm
/// cell. Directions matter: ARKit's normals face the side that was scanned, so the far side of a wall scanned from the
/// next room isn't "known" here.
struct SurfaceIndex {
    static let voxel: Float = 0.05
    static let coarse: Float = 0.2

    var cells: [Int64: Int32] = [:]
    var points: [SIMD3<Float>] = []
    /// mean of the normals in the cell: length ~1 = one clear side, short = both sides of something thin
    var normals: [SIMD3<Float>] = []
    /// coarse cell -> bit mask of facing directions (bits 0-5: +x -x +y -y +z -z, bit 6: unknown)
    var facing: [Int64: UInt8] = [:]

    var isEmpty: Bool { points.isEmpty }

    static func key(_ p: SIMD3<Float>, _ size: Float) -> Int64 {
        let q = (p / size).rounded(.down)
        return pack(Int64(q.x), Int64(q.y), Int64(q.z))
    }

    static func pack(_ x: Int64, _ y: Int64, _ z: Int64) -> Int64 {
        ((x & 0x1F_FFFF) << 42) | ((y & 0x1F_FFFF) << 21) | (z & 0x1F_FFFF)
    }

    private static let axes: [SIMD3<Float>] = [SIMD3(1, 0, 0), SIMD3(-1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, -1, 0), SIMD3(0, 0, 1), SIMD3(0, 0, -1)]

    static func facingBit(_ n: SIMD3<Float>) -> UInt8 {
        guard simd_length_squared(n) > 0.25 else { return 1 << 6 }
        var best = 0
        var bestDot: Float = -2
        for (i, a) in axes.enumerated() {
            let d = simd_dot(a, n)
            if d > bestDot { bestDot = d; best = i }
        }
        return 1 << UInt8(best)
    }

    /// facing bits a live normal is compatible with (a 45° wall touches two axes)
    static func compatibleBits(_ n: SIMD3<Float>) -> UInt8 {
        guard simd_length_squared(n) > 0.25 else { return 0x7F }
        var mask: UInt8 = 1 << 6
        for (i, a) in axes.enumerated() where simd_dot(a, n) > 0.3 { mask |= 1 << UInt8(i) }
        return mask
    }

    /// within ~20-40 cm of a saved surface facing the same way
    func isNearSurface(_ p: SIMD3<Float>, normal: SIMD3<Float>) -> Bool {
        let want = Self.compatibleBits(normal)
        let q = (p / Self.coarse).rounded(.down)
        let x = Int64(q.x), y = Int64(q.y), z = Int64(q.z)
        for dx: Int64 in -1...1 {
            for dy: Int64 in -1...1 {
                for dz: Int64 in -1...1 {
                    if let bits = facing[Self.pack(x + dx, y + dy, z + dz)], bits & want != 0 { return true }
                }
            }
        }
        return false
    }

    /// point-to-plane distance to the nearest saved sample within `maxDistance` facing the same way (so a wall point
    /// doesn't "match" the floor at the skirting board, or the other side of the wall), or nil
    func planeDistance(_ p: SIMD3<Float>, normal: SIMD3<Float>, maxDistance: Float) -> Float? {
        let q = (p / Self.voxel).rounded(.down)
        let x = Int64(q.x), y = Int64(q.y), z = Int64(q.z)
        let r = Int64((maxDistance / Self.voxel).rounded(.up))
        var best: Float = maxDistance * maxDistance
        var hit: Int32 = -1
        let live: SIMD3<Float>? = simd_length_squared(normal) > 0.25 ? normal : nil
        for dx in -r...r {
            for dy in -r...r {
                for dz in -r...r {
                    guard let i = cells[Self.pack(x + dx, y + dy, z + dz)] else { continue }
                    let d2 = simd_distance_squared(points[Int(i)], p)
                    guard d2 < best else { continue }
                    if let live {
                        let n = normals[Int(i)], l = simd_length(n)
                        if l > 0.5, simd_dot(n / l, live) < 0.7 { continue }
                    }
                    best = d2
                    hit = i
                }
            }
        }
        guard hit >= 0 else { return nil }
        let n = normals[Int(hit)], l = simd_length(n), v = p - points[Int(hit)]
        return l > 0.5 ? abs(simd_dot(v, n / l)) : simd_length(v)
    }

    struct Builder {
        private var cells: [Int64: Int32] = [:]
        private var sums: [SIMD3<Float>] = []
        private var normalSums: [SIMD3<Float>] = []
        private var counts: [Float] = []
        private var facing: [Int64: UInt8] = [:]

        mutating func add(_ p: SIMD3<Float>, _ n: SIMD3<Float>) {
            let k = SurfaceIndex.key(p, SurfaceIndex.voxel)
            if let i = cells[k] {
                sums[Int(i)] += p; normalSums[Int(i)] += n; counts[Int(i)] += 1
            } else {
                cells[k] = Int32(sums.count)
                sums.append(p); normalSums.append(n); counts.append(1)
            }
            facing[SurfaceIndex.key(p, SurfaceIndex.coarse), default: 0] |= SurfaceIndex.facingBit(n)
        }

        func finish() -> SurfaceIndex {
            var s = SurfaceIndex()
            s.cells = cells
            s.points = zip(sums, counts).map { $0 / $1 }
            s.normals = zip(normalSums, counts).map { $0 / $1 }
            s.facing = facing
            return s
        }
    }
}

/// A live mesh point and its normal
struct LivePoint {
    var p: SIMD3<Float>
    var n: SIMD3<Float>
}

/// How well the live mesh sits on the saved surfaces. Floors, ceilings and a single flat wall can't see a shift along
/// themselves (a 36 cm shift or a 9° turn still leaves most points "on" some saved surface), so walls are judged on
/// their own, per direction: at least two wall directions 45°+ apart (a corner, furniture, a door frame) must line up.
struct LockCheck: Equatable {
    var sampled = 0
    /// near (≤ ~40 cm) saved surfaces: where the old and the new scan should overlap
    var known = 0
    /// of those, within 8 cm of a saved surface facing the same way
    var matched = 0
    var wallKnown = 0, wallMatched = 0
    var flatKnown = 0, flatMatched = 0
    /// wall directions (folded to 0-180°, 22.5° bins) with ≥ 30 known points and ≥ 50% matched, and the widest angle
    /// between two of them
    var directions = 0
    var spreadDegrees: Float = 0
    /// median point-to-plane distance of the matched wall points (all matched points without walls)
    var median: Float?

    var inlierFraction: Float { known > 0 ? Float(matched) / Float(known) : 0 }
    var wallFraction: Float { wallKnown > 0 ? Float(wallMatched) / Float(wallKnown) : 0 }
    var flatFraction: Float { flatKnown > 0 ? Float(flatMatched) / Float(flatKnown) : 0 }

    /// walls line up, but only one direction is in view: needs a corner
    var needsCorner: Bool { wallKnown >= 100 && wallFraction >= 0.6 && spreadDegrees < 45 }

    var isGood: Bool {
        wallKnown >= 100 && wallMatched >= 80 && wallFraction >= 0.6 && spreadDegrees >= 45
            && (median ?? 1) < 0.04 && (flatKnown < 40 || flatFraction >= 0.5)
    }

    /// plenty of overlap, but it doesn't line up: ARKit recognized the wrong spot (or the world reset)
    var isMismatch: Bool {
        (wallKnown >= 200 && wallFraction < 0.25) || (known >= 300 && inlierFraction < 0.2)
    }

    var summary: String {
        String(format: "known %d matched %d (walls %d/%d, %d directions, %.0f°), median %@", known, matched, wallMatched, wallKnown,
               directions, spreadDegrees, median.map { String(format: "%.1f cm", $0 * 100) } ?? "-")
    }
}

extension SurfaceIndex {
    /// live points (already in this index's frame) against the saved surfaces
    func check(_ points: [LivePoint]) -> LockCheck {
        var c = LockCheck(sampled: points.count)
        var wallDistances: [Float] = [], allDistances: [Float] = []
        var binKnown = [Int](repeating: 0, count: 8), binMatched = [Int](repeating: 0, count: 8)
        for lp in points {
            guard isNearSurface(lp.p, normal: lp.n) else { continue }
            c.known += 1
            let vertical = abs(lp.n.y) < 0.5, flat = abs(lp.n.y) > 0.8
            var bin = -1
            if vertical {
                c.wallKnown += 1
                var a = atan2(lp.n.z, lp.n.x)          // fold: parallel and opposite walls pin down the same axis
                if a < 0 { a += .pi }
                if a >= .pi { a -= .pi }
                bin = min(7, Int(a / (.pi / 8)))
                binKnown[bin] += 1
            } else if flat {
                c.flatKnown += 1
            }
            guard let d = planeDistance(lp.p, normal: lp.n, maxDistance: 0.08) else { continue }
            c.matched += 1
            allDistances.append(d)
            if vertical {
                c.wallMatched += 1; wallDistances.append(d); binMatched[bin] += 1
            } else if flat {
                c.flatMatched += 1
            }
        }
        let good = (0..<8).filter { binKnown[$0] >= 30 && binMatched[$0] * 2 >= binKnown[$0] }
        c.directions = good.count
        for i in good {
            for j in good where j > i {
                let diff = min(j - i, 8 - (j - i))      // circular over 180°
                c.spreadDegrees = max(c.spreadDegrees, Float(diff) * 22.5)
            }
        }
        let ds = wallDistances.isEmpty ? allDistances : wallDistances
        if !ds.isEmpty { c.median = ds.sorted()[ds.count / 2] }
        return c
    }
}

enum LiveMeshSampler {
    /// up to `limit` vertices (+ normals) of the live LiDAR mesh the camera is looking at (0.3-4.5 m away, inside a
    /// ~100° cone), moved by `to` (the scan's frame -> the saved cloud's frame)
    static func sample(_ anchors: [ARMeshAnchor], camera: simd_float4x4, to m: simd_float4x4 = matrix_identity_float4x4, limit: Int = 3000) -> [LivePoint] {
        let eye = simd_make_float3(camera.columns.3)
        let forward = -simd_normalize(simd_make_float3(camera.columns.2))
        let near = anchors.filter { simd_distance(simd_make_float3($0.transform.columns.3), eye) < 7 }
        let total = near.reduce(0) { $0 + $1.geometry.vertices.count }
        guard total > 0 else { return [] }
        let step = max(1, total / (limit * 3))          // oversampled: many vertices are outside the view cone
        let rot = Frames.rotation(m)
        var out: [LivePoint] = []
        out.reserveCapacity(limit)
        var counter = 0
        for a in near {
            let vs = a.geometry.vertices, ns = a.geometry.normals
            guard ns.count == vs.count else { continue }
            let vp = vs.buffer.contents(), np = ns.buffer.contents()
            let arot = Frames.rotation(a.transform)
            for i in 0..<vs.count {
                counter += 1
                guard counter % step == 0 else { continue }
                let q = vp.advanced(by: vs.offset + vs.stride * i).assumingMemoryBound(to: Float.self)
                let w = simd_make_float3(a.transform * SIMD4<Float>(q[0], q[1], q[2], 1))
                let to = w - eye, d = simd_length(to)
                guard d > 0.3, d < 4.5, simd_dot(to / d, forward) > 0.64 else { continue }
                let nq = np.advanced(by: ns.offset + ns.stride * i).assumingMemoryBound(to: Float.self)
                let n = simd_normalize(arot * SIMD3<Float>(nq[0], nq[1], nq[2]))
                out.append(LivePoint(p: simd_make_float3(m * SIMD4<Float>(w, 1)), n: rot * n))
                if out.count >= limit { return out }
            }
        }
        return out
    }
}

/// Coordinate frames: the scan's live frame, a fresh section after RoomPlan ran out of room, the home's frame.
enum Frames {
    static func rotation(_ m: simd_float4x4) -> simd_float3x3 {
        simd_float3x3(simd_make_float3(m.columns.0), simd_make_float3(m.columns.1), simd_make_float3(m.columns.2))
    }

    static func apply(_ m: simd_float4x4, _ p: SIMD3<Float>) -> SIMD3<Float> { simd_make_float3(m * SIMD4<Float>(p, 1)) }
    static func turn(_ m: simd_float4x4, _ n: SIMD3<Float>) -> SIMD3<Float> { rotation(m) * n }

    /// a turn about the vertical axis + a move
    static func yawMove(_ yaw: Float, _ t: SIMD3<Float>) -> simd_float4x4 {
        let c = cos(yaw), s = sin(yaw)
        return simd_float4x4(SIMD4(c, 0, -s, 0), SIMD4(0, 1, 0, 0), SIMD4(s, 0, c, 0), SIMD4(t.x, t.y, t.z, 1))
    }

    /// Where a fresh AR world sits in the old one: the same phone pose seen in both (held still across the restart).
    /// ARKit keeps "up" in both worlds, so only a turn about the vertical and a move are left.
    static func chain(old: simd_float4x4, new: simd_float4x4) -> simd_float4x4 {
        // the turn from one world to the other: the phone's tilt is the same in both and cancels out
        let rel = rotation(old) * rotation(new).transpose
        let x = rel.columns.0
        let yaw = atan2(-x.z, x.x)
        let r = yawMove(yaw, .zero)
        let t = simd_make_float3(old.columns.3) - apply(r, simd_make_float3(new.columns.3))
        return yawMove(yaw, t)
    }
}

/// The cloud being built while you scan: every ~2 s the mesh near you goes in (with colors from the camera where it
/// can see the surface). Thread-safe: the work runs on its own queue.
final class SurfaceCloud {
    struct Cell {
        var p = SIMD3<Float>.zero, n = SIMD3<Float>.zero, w: Float = 0
        var c = SIMD3<Float>.zero, cw: Float = 0
    }

    private var cells: [Int64: Cell] = [:]
    private let queue = DispatchQueue(label: "cloud", qos: .utility)
    private var busy = false
    /// cells, for the debug log
    private(set) var count = 0

    /// a small copy of the camera picture (RGB, row-major) and how to project into it
    struct Picture {
        let w: Int, h: Int
        let rgb: [UInt8]
        let fx: Float, fy: Float, cx: Float, cy: Float
        let camera: simd_float4x4
        /// LiDAR depth (m) at the same size, when ARKit hands it out
        let depth: [Float]?
    }

    /// the mesh pieces near the camera go in, moved by `to` (live frame -> the home's frame). Skipped while the last
    /// one is still running.
    func feed(_ anchors: [ARMeshAnchor], camera: simd_float4x4, to m: simd_float4x4, picture: Picture?) {
        guard !busy else { return }
        let eye = simd_make_float3(camera.columns.3)
        let near = anchors.filter { simd_distance(simd_make_float3($0.transform.columns.3), eye) < 6 }
        guard !near.isEmpty else { return }
        busy = true
        queue.async { [weak self] in
            guard let self else { return }
            self.add(near, eye: eye, to: m, picture: picture)
            DispatchQueue.main.async { self.busy = false }
        }
    }

    private func add(_ anchors: [ARMeshAnchor], eye: SIMD3<Float>, to m: simd_float4x4, picture: Picture?) {
        let total = anchors.reduce(0) { $0 + $1.geometry.vertices.count }
        let step = max(1, total / 80_000)
        let rot = Frames.rotation(m)
        let view = picture.map { simd_inverse($0.camera) }
        var k = 0
        for a in anchors {
            let vs = a.geometry.vertices, ns = a.geometry.normals
            guard ns.count == vs.count else { continue }
            let vp = vs.buffer.contents(), np = ns.buffer.contents(), arot = Frames.rotation(a.transform)
            for i in 0..<vs.count {
                k += 1
                guard k % step == 0 else { continue }
                let q = vp.advanced(by: vs.offset + vs.stride * i).assumingMemoryBound(to: Float.self)
                let w = simd_make_float3(a.transform * SIMD4<Float>(q[0], q[1], q[2], 1))
                let nq = np.advanced(by: ns.offset + ns.stride * i).assumingMemoryBound(to: Float.self)
                let n = simd_normalize(arot * SIMD3<Float>(nq[0], nq[1], nq[2]))
                var color: SIMD3<Float>?
                if let pic = picture, let view { color = Self.colorAt(w, normal: n, eye: eye, view: view, pic) }
                let h = simd_make_float3(m * SIMD4<Float>(w, 1)), hn = rot * n
                let key = SurfaceIndex.key(h, SurfaceIndex.voxel)
                var c = cells[key] ?? Cell()
                // newest counts most (ARKit refines surfaces as you look again): weights stop growing at 6
                if c.w >= 6 { c.p *= 5 / c.w; c.n *= 5 / c.w; c.w = 5 }
                c.p += h; c.n += hn; c.w += 1
                if let color {
                    if c.cw >= 6 { c.c *= 5 / c.cw; c.cw = 5 }
                    c.c += color; c.cw += 1
                }
                cells[key] = c
            }
        }
        count = cells.count
    }

    /// the color the camera sees at a point, if it sees it: in the picture, facing the camera, not behind something
    static func colorAt(_ w: SIMD3<Float>, normal: SIMD3<Float>, eye: SIMD3<Float>, view: simd_float4x4, _ pic: Picture) -> SIMD3<Float>? {
        let to = w - eye, d = simd_length(to)
        guard d > 0.3, d < 4, simd_dot(normal, to / d) < -0.25 else { return nil }
        let c = view * SIMD4<Float>(w, 1)
        guard c.z < -0.2 else { return nil }
        let u = pic.fx * (c.x / -c.z) + pic.cx, v = pic.fy * (-c.y / -c.z) + pic.cy
        let x = Int(u), y = Int(v)
        guard x >= 1, y >= 1, x < pic.w - 1, y < pic.h - 1 else { return nil }
        if let depth = pic.depth {
            let seen = depth[y * pic.w + x]
            guard seen > 0, abs(seen - -c.z) < 0.12 else { return nil }
        } else if d > 2.5 {
            return nil                                  // no depth to check against: only close up
        }
        let i = (y * pic.w + x) * 3
        return SIMD3(Float(pic.rgb[i]), Float(pic.rgb[i + 1]), Float(pic.rgb[i + 2]))
    }

    /// a small RGB copy of the camera frame (+ LiDAR depth at the same size) for coloring; ~120 x 160 pixels
    static func picture(_ frame: ARFrame) -> Picture? {
        let pb = frame.capturedImage
        guard CVPixelBufferGetPlaneCount(pb) >= 2 else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0), let cBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return nil }
        let W = CVPixelBufferGetWidthOfPlane(pb, 0), H = CVPixelBufferGetHeightOfPlane(pb, 0)
        let yRow = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), cRow = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        let Y = yBase.assumingMemoryBound(to: UInt8.self), CbCr = cBase.assumingMemoryBound(to: UInt8.self)
        let w = 160, h = max(1, 160 * H / max(W, 1)), sx = Float(W) / Float(w), sy = Float(H) / Float(h)
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for j in 0..<h {
            let py = min(H - 1, Int((Float(j) + 0.5) * sy))
            for i in 0..<w {
                let px = min(W - 1, Int((Float(i) + 0.5) * sx))
                let yy = Float(Y[py * yRow + px])
                let ci = (py / 2) * cRow + (px / 2) * 2
                let cb = Float(CbCr[ci]) - 128, cr = Float(CbCr[ci + 1]) - 128
                let o = (j * w + i) * 3
                rgb[o] = UInt8(max(0, min(255, yy + 1.402 * cr)))
                rgb[o + 1] = UInt8(max(0, min(255, yy - 0.344136 * cb - 0.714136 * cr)))
                rgb[o + 2] = UInt8(max(0, min(255, yy + 1.772 * cb)))
            }
        }
        let k = frame.camera.intrinsics
        var depth: [Float]?
        if let dm = (frame.sceneDepth ?? frame.smoothedSceneDepth)?.depthMap {
            CVPixelBufferLockBaseAddress(dm, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(dm, .readOnly) }
            if let base = CVPixelBufferGetBaseAddress(dm), CVPixelBufferGetPixelFormatType(dm) == kCVPixelFormatType_DepthFloat32 {
                let dw = CVPixelBufferGetWidth(dm), dh = CVPixelBufferGetHeight(dm), row = CVPixelBufferGetBytesPerRow(dm)
                var out = [Float](repeating: 0, count: w * h)
                for j in 0..<h {
                    let dy = min(dh - 1, j * dh / h)
                    let line = base.advanced(by: dy * row).assumingMemoryBound(to: Float32.self)
                    for i in 0..<w { out[j * w + i] = line[min(dw - 1, i * dw / w)] }
                }
                depth = out
            }
        }
        return Picture(w: w, h: h, rgb: rgb, fx: k[0][0] / sx, fy: k[1][1] / sy, cx: k[2][0] / sx, cy: k[2][1] / sy,
                       camera: frame.camera.transform, depth: depth)
    }

    /// waits for the last feed, then every cell: its middle, the way it faces, its color (if the camera saw it)
    func finished() -> [(p: SIMD3<Float>, n: SIMD3<Float>, c: SIMD3<Float>?)] {
        queue.sync { cells.values.map { c in
            (p: c.p / c.w, n: simd_length(c.n) > 0 ? simd_normalize(c.n) : .zero, c: c.cw > 0 ? c.c / c.cw : nil)
        } }
    }

    /// waits for the last feed, then the packed cloud (see `encode`)
    func packed() -> Data { Self.encode(finished()) }

    /// cell -> color, for coloring the garden mesh (home frame)
    func colorTable() -> [Int64: SIMD3<UInt8>] {
        queue.sync {
            var t: [Int64: SIMD3<UInt8>] = [:]
            t.reserveCapacity(cells.count)
            for (k, c) in cells where c.cw > 0 {
                let v = c.c / c.cw
                t[k] = SIMD3(UInt8(max(0, min(255, v.x))), UInt8(max(0, min(255, v.y))), UInt8(max(0, min(255, v.z))))
            }
            return t
        }
    }

    /// the color of a point from the table: its own cell, else the nearest colored neighbor (5 cm cells)
    static func color(at p: SIMD3<Float>, _ t: [Int64: SIMD3<UInt8>]) -> SIMD3<UInt8>? {
        if let c = t[SurfaceIndex.key(p, SurfaceIndex.voxel)] { return c }
        let q = (p / SurfaceIndex.voxel).rounded(.down)
        let x = Int64(q.x), y = Int64(q.y), z = Int64(q.z)
        for dx: Int64 in -1...1 { for dy: Int64 in -1...1 { for dz: Int64 in -1...1 {
            if let c = t[SurfaceIndex.pack(x + dx, y + dy, z + dz)] { return c }
        } } }
        return nil
    }

    /// a room floor's real color: the middle (per channel) of the colored floor cells inside its outline, near its height.
    /// nil with fewer than 20 of them. Brightness evened out a little (rooms are lit differently).
    static func floorColor(_ cells: [(p: SIMD3<Float>, n: SIMD3<Float>, c: SIMD3<Float>?)], poly: [SIMD2<Float>], floorY: Float) -> String? {
        guard poly.count >= 3 else { return nil }
        let lo = poly.reduce(SIMD2<Float>(repeating: .greatestFiniteMagnitude)) { simd_min($0, $1) }
        let hi = poly.reduce(SIMD2<Float>(repeating: -.greatestFiniteMagnitude)) { simd_max($0, $1) }
        var r: [Float] = [], g: [Float] = [], b: [Float] = []
        for c in cells {
            guard let col = c.c, c.n.y > 0.85, abs(c.p.y - floorY) < 0.12,
                  c.p.x > lo.x, c.p.x < hi.x, c.p.z > lo.y, c.p.z < hi.y, Floorplan.inside(SIMD2(c.p.x, c.p.z), poly) else { continue }
            r.append(col.x); g.append(col.y); b.append(col.z)
        }
        guard r.count >= 20 else { return nil }
        func mid(_ a: [Float]) -> Float { a.sorted()[a.count / 2] }
        var v = SIMD3(mid(r), mid(g), mid(b))
        let l = max(1, 0.299 * v.x + 0.587 * v.y + 0.114 * v.z)
        v *= min(1.3, max(1, 110 / l))                  // a dim photo of a floor reads darker than it is
        return String(format: "#%02x%02x%02x", Int(min(255, v.x)), Int(min(255, v.y)), Int(min(255, v.z)))
    }

    /// "HMC1" | count UInt32 | origin 3 x Float32 | per cell: x y z UInt16 (mm from origin), normal 3 x Int8 (x127),
    /// r g b UInt8, flags UInt8 (1 = has color). Little-endian. 13 bytes a cell.
    static func encode(_ cells: [(p: SIMD3<Float>, n: SIMD3<Float>, c: SIMD3<Float>?)]) -> Data {
        var d = Data("HMC1".utf8)
        let lo = cells.reduce(SIMD3<Float>(repeating: .greatestFiniteMagnitude)) { simd_min($0, $1.p) }
        let origin = cells.isEmpty ? SIMD3<Float>.zero : lo
        let keep = cells.filter { simd_reduce_max($0.p - origin) < 65.5 }
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { d.append(contentsOf: $0) } }
        put(UInt32(keep.count).littleEndian)
        for v in [origin.x, origin.y, origin.z] { put(v.bitPattern.littleEndian) }
        for c in keep {
            let q = (c.p - origin) * 1000
            for v in [q.x, q.y, q.z] { put(UInt16(max(0, min(65535, v.rounded()))).littleEndian) }
            for v in [c.n.x, c.n.y, c.n.z] { put(Int8(max(-127, min(127, (v * 127).rounded())))) }
            let col = c.c ?? .zero
            for v in [col.x, col.y, col.z] { put(UInt8(max(0, min(255, v.rounded())))) }
            put(UInt8(c.c == nil ? 0 : 1))
        }
        return d
    }

    static func decode(_ d: Data) -> [(p: SIMD3<Float>, n: SIMD3<Float>, c: SIMD3<Float>?)]? {
        guard d.count >= 20, d.prefix(4) == Data("HMC1".utf8) else { return nil }
        let b = [UInt8](d)
        func u32(_ o: Int) -> UInt32 { UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24 }
        func u16(_ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
        let n = Int(u32(4))
        guard d.count >= 20 + n * 13 else { return nil }
        let origin = SIMD3<Float>(Float(bitPattern: u32(8)), Float(bitPattern: u32(12)), Float(bitPattern: u32(16)))
        var out: [(p: SIMD3<Float>, n: SIMD3<Float>, c: SIMD3<Float>?)] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let o = 20 + i * 13
            let p = origin + SIMD3(Float(u16(o)), Float(u16(o + 2)), Float(u16(o + 4))) / 1000
            let nv = SIMD3(Float(Int8(bitPattern: b[o + 6])), Float(Int8(bitPattern: b[o + 7])), Float(Int8(bitPattern: b[o + 8]))) / 127
            let c: SIMD3<Float>? = b[o + 12] & 1 != 0 ? SIMD3(Float(b[o + 9]), Float(b[o + 10]), Float(b[o + 11])) : nil
            out.append((p, nv, c))
        }
        return out
    }

    /// the saved cloud as a lock-on index
    static func index(_ d: Data) -> SurfaceIndex? {
        guard let cells = decode(d), !cells.isEmpty else { return nil }
        var b = SurfaceIndex.Builder()
        for c in cells { b.add(c.p, c.n) }
        return b.finish()
    }
}
