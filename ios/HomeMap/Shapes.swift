import simd

/// A room's outline seen from above (x, z) while RoomPlan is still scanning it. RoomPlan only works out a room's floor
/// when the room is finished - while scanning, `floors` is empty - so the outline comes from its walls: the hull around
/// every wall's two ends. (Reading the floor instead is why going through a door never started a new room and the
/// floor area stayed at 0 m² in app 1.6.)
enum RoomShape {
    /// a wall's two ends, from its middle, the way it runs (x, z) and its length
    static func ends(center c: SIMD2<Float>, along d: SIMD2<Float>, length l: Float) -> (SIMD2<Float>, SIMD2<Float>) {
        let u = simd_length(d) > 1e-6 ? simd_normalize(d) : SIMD2<Float>(1, 0)
        return (c - u * (l / 2), c + u * (l / 2))
    }

    /// convex hull, counter-clockwise (Andrew's monotone chain); fewer than 3 distinct points: what there is
    static func hull(_ pts: [SIMD2<Float>]) -> [SIMD2<Float>] {
        let p = Array(Set(pts.map { SIMD2<Float>(($0.x * 1000).rounded() / 1000, ($0.y * 1000).rounded() / 1000) }))
            .sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard p.count >= 3 else { return p }
        func cross(_ o: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lower: [SIMD2<Float>] = [], upper: [SIMD2<Float>] = []
        for q in p {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], q) <= 0 { lower.removeLast() }
            lower.append(q)
        }
        for q in p.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], q) <= 0 { upper.removeLast() }
            upper.append(q)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// area of a simple polygon (m²)
    static func area(_ poly: [SIMD2<Float>]) -> Float {
        guard poly.count >= 3 else { return 0 }
        var a: Float = 0
        for i in 0..<poly.count { let j = (i + 1) % poly.count; a += poly[i].x * poly[j].y - poly[j].x * poly[i].y }
        return abs(a) / 2
    }

    /// width and depth of the box around it
    static func size(_ poly: [SIMD2<Float>]) -> SIMD2<Float> {
        guard let f = poly.first else { return .zero }
        var lo = f, hi = f
        for q in poly { lo = simd_min(lo, q); hi = simd_max(hi, q) }
        return hi - lo
    }

    /// grown past one room: walked on into a hallway or the next room through an opening RoomPlan didn't mark
    static func tooBig(_ poly: [SIMD2<Float>]) -> Bool {
        let s = size(poly)
        return poly.count >= 3 && (max(s.x, s.y) > 9 || area(poly) > 45)
    }

    /// How much of the outline the walls close (0...1), and the middle of the biggest stretch with no wall (nil = closed).
    /// The outline is walked every 10 cm; a spot counts as closed when a wall runs within 35 cm of it (doors and windows
    /// sit in walls, so they count). A wall RoomPlan never saw leaves its side of the outline open.
    static func closure(_ poly: [SIMD2<Float>], walls: [(SIMD2<Float>, SIMD2<Float>)]) -> (Float, SIMD2<Float>?) {
        guard poly.count >= 3, !walls.isEmpty else { return (0, nil) }
        func near(_ p: SIMD2<Float>) -> Bool {
            walls.contains { a, b in
                let ab = b - a, t = max(0, min(1, simd_dot(p - a, ab) / max(simd_dot(ab, ab), 1e-6)))
                return simd_distance(p, a + ab * t) < 0.35
            }
        }
        var samples: [(SIMD2<Float>, Bool)] = []
        for i in 0..<poly.count {
            let a = poly[i], b = poly[(i + 1) % poly.count], n = max(1, Int(simd_distance(a, b) / 0.1))
            for k in 0..<n { let p = a + (b - a) * (Float(k) / Float(n)); samples.append((p, near(p))) }
        }
        let shut = samples.filter(\.1).count
        guard shut < samples.count else { return (1, nil) }
        // the longest run of open samples, around the loop
        let start = samples.firstIndex { $0.1 } ?? 0
        var best = (len: 0, from: 0), run = 0, from = 0
        for j in 0..<samples.count {
            let i = (start + j) % samples.count
            if samples[i].1 { run = 0 } else { if run == 0 { from = i }; run += 1; if run > best.len { best = (run, from) } }
        }
        let mid = samples[(best.from + best.len / 2) % samples.count].0
        return (Float(shut) / Float(samples.count), mid)
    }

    /// where a spot is from where you stand and face (x, z): "in front of you", "on your left"...
    static func direction(of p: SIMD2<Float>, from eye: SIMD2<Float>, facing f: SIMD2<Float>) -> String {
        let to = p - eye
        guard simd_length(to) > 0.3, simd_length(f) > 1e-4 else { return "right here" }
        let a = atan2(to.y, to.x) - atan2(f.y, f.x)
        // -180...180; ARKit's x is to the right and z toward you, so seen from above + is a turn to the right
        let deg = (a * 180 / .pi + 540).truncatingRemainder(dividingBy: 360) - 180
        switch deg {
        case -45...45: return "in front of you"
        case 45...135: return "on your right"
        case -135 ... -45: return "on your left"
        default: return "behind you"
        }
    }
}

/// The floors of a home, counted like in the US: the floor at street level is the First floor. The ids are what
/// Home Assistant's map stores (they never change); the names are what you read.
enum Levels {
    static let ids = ["ground", "first", "second", "third"]
    static let garden = "outdoor"

    /// "First floor" for 0, "Second floor" for 1...
    static func name(_ index: Int) -> String {
        let n = ["First", "Second", "Third", "Fourth"]
        return (index >= 0 && index < n.count ? n[index] : "Floor \(index + 1)") + " floor"
    }

    static func id(_ index: Int) -> String { ids[max(0, min(ids.count - 1, index))] }

    /// a start level id (ground / first / outdoor) as a floor number; the garden counts as the first floor
    static func index(of id: String) -> Int { ids.firstIndex(of: id) ?? 0 }
}
