import ARKit
import RoomPlan
import simd

/// Turns RoomPlan results and ARKit meshes into plain JSON for Home Assistant.
/// Transforms are 16 floats, column-major (same layout three.js Matrix4.fromArray expects).
enum Export {
    static func mat(_ t: simd_float4x4) -> [Float] {
        [t.columns.0, t.columns.1, t.columns.2, t.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }

    static func vec(_ v: simd_float3) -> [Float] { [v.x, v.y, v.z] }

    /// `to`: the room's AR world -> the home's frame (identity unless the scan locked on to a map from a later section
    /// or started a fresh section itself). The polygons are in the surface's own frame and don't change.
    static func surface(_ s: CapturedRoom.Surface, to: simd_float4x4 = matrix_identity_float4x4) -> [String: Any] {
        var o: [String: Any] = [
            "id": s.identifier.uuidString,
            "cat": String(describing: s.category),
            "dim": vec(s.dimensions),
            "tf": mat(to * s.transform),
            "conf": String(describing: s.confidence),
            "poly": s.polygonCorners.map(vec),
        ]
        if let p = s.parentIdentifier { o["parent"] = p.uuidString }
        return o
    }

    static func object(_ o: CapturedRoom.Object, to: simd_float4x4 = matrix_identity_float4x4) -> [String: Any] {
        var out: [String: Any] = [
            "id": o.identifier.uuidString,
            "cat": String(describing: o.category),
            "dim": vec(o.dimensions),
            "tf": mat(to * o.transform),
            "conf": String(describing: o.confidence),
        ]
        // chair / sofa / table / storage sub-types (stool, L-shaped, coffee table, shelf...) pick the right model
        let attrs = o.attributes.map { String(describing: $0) }
        if !attrs.isEmpty { out["attrs"] = attrs }
        return out
    }

    /// `name` is what you called the room in the app; `center` (x, z) tells the dashboard which floor it belongs to
    static func room(_ r: CapturedRoom, name: String?, objects: Bool = true, to: simd_float4x4 = matrix_identity_float4x4) -> [String: Any] {
        var out = room(r, objects: objects, to: to)
        if let name, let f = r.floors.first {
            out["name"] = name
            let c = to * f.transform.columns.3
            out["center"] = [c.x, c.z]
        }
        return out
    }

    /// a room scanned in two goes (a popup over the app stopped RoomPlan): the bigger part's walls, floor, doors and
    /// windows, and the furniture of both - a piece seen in both parts only once
    static func merged(_ a: CapturedRoom, _ b: CapturedRoom, name: String?, objects: Bool = true, to: simd_float4x4 = matrix_identity_float4x4) -> [String: Any] {
        func area(_ r: CapturedRoom) -> Float {
            r.floors.reduce(0) { $0 + abs(Triangulate.signedArea($1.polygonCorners.map { SIMD2($0.x, $0.y) })) }
        }
        let (base, extra) = area(a) >= area(b) ? (a, b) : (b, a)
        var out = room(base, name: name, objects: objects, to: to)
        func at(_ o: CapturedRoom.Object) -> SIMD3<Float> { SIMD3(o.transform.columns.3.x, o.transform.columns.3.y, o.transform.columns.3.z) }
        let more = extra.objects.filter { e in
            (objects || e.category == .stairs) && !base.objects.contains { $0.category == e.category && simd_distance(at($0), at(e)) < 0.6 }
        }
        out["objects"] = ((out["objects"] as? [[String: Any]]) ?? []) + more.map { object($0, to: to) }
        return out
    }

    /// objects false: rooms only (stairs stay - they're part of the building)
    static func room(_ r: CapturedRoom, objects: Bool = true, to: simd_float4x4 = matrix_identity_float4x4) -> [String: Any] {
        let sf = { (s: CapturedRoom.Surface) in surface(s, to: to) }
        return [
            "walls": r.walls.map(sf),
            "doors": r.doors.map(sf),
            "windows": r.windows.map(sf),
            "openings": r.openings.map(sf),
            "floors": r.floors.map(sf),
            "objects": r.objects.filter { objects || $0.category == .stairs }.map { object($0, to: to) },
            "sections": r.sections.map { ["label": String(describing: $0.label), "center": vec(point(to, $0.center))] },
        ]
    }

    static func structure(_ s: CapturedStructure, objects: Bool = true, to: simd_float4x4 = matrix_identity_float4x4) -> [String: Any] {
        let sf = { (x: CapturedRoom.Surface) in surface(x, to: to) }
        return [
            "walls": s.walls.map(sf),
            "doors": s.doors.map(sf),
            "windows": s.windows.map(sf),
            "openings": s.openings.map(sf),
            "floors": s.floors.map(sf),
            "objects": s.objects.filter { objects || $0.category == .stairs }.map { object($0, to: to) },
            "sections": s.sections.map { ["label": String(describing: $0.label), "center": vec(point(to, $0.center))] },
        ]
    }

    static func point(_ m: simd_float4x4, _ p: simd_float3) -> simd_float3 { simd_make_float3(m * simd_float4(p, 1)) }

    private static func b64<T>(_ a: [T]) -> String { a.withUnsafeBytes { Data($0).base64EncodedString() } }

    /// One ARKit mesh piece: world-space vertices (Float32 xyz), triangle indices (UInt32), per-face class (UInt8).
    /// `colors`: the scan's surface colors (SurfaceCloud) - each vertex gets the color the camera saw there: "rgb" =
    /// base64 UInt8 r g b a per vertex (a 255 = seen, 0 = no color: the dashboard keeps its own there)
    static func mesh(_ a: ARMeshAnchor, to: simd_float4x4 = matrix_identity_float4x4, colors: [Int64: SIMD3<UInt8>]? = nil) -> [String: Any] {
        let g = a.geometry
        let vs = g.vertices
        var pos = [Float]()
        pos.reserveCapacity(vs.count * 3)
        let vp = vs.buffer.contents()
        let m = to * a.transform
        for i in 0..<vs.count {
            let p = vp.advanced(by: vs.offset + vs.stride * i).assumingMemoryBound(to: Float.self)
            let w = m * simd_float4(p[0], p[1], p[2], 1)
            pos.append(w.x); pos.append(w.y); pos.append(w.z)
        }
        let f = g.faces
        var idx = [UInt32]()
        let n = f.count * f.indexCountPerPrimitive
        idx.reserveCapacity(n)
        let ip = f.buffer.contents()
        for i in 0..<n {
            if f.bytesPerIndex == 4 {
                idx.append(ip.advanced(by: i * 4).assumingMemoryBound(to: UInt32.self).pointee)
            } else {
                idx.append(UInt32(ip.advanced(by: i * 2).assumingMemoryBound(to: UInt16.self).pointee))
            }
        }
        var cls = [UInt8]()
        if let c = g.classification {
            cls.reserveCapacity(c.count)
            let cp = c.buffer.contents()
            for i in 0..<c.count { cls.append(cp.advanced(by: c.offset + c.stride * i).assumingMemoryBound(to: UInt8.self).pointee) }
        }
        var out: [String: Any] = ["p": b64(pos), "i": b64(idx), "c": Data(cls).base64EncodedString()]
        if let colors, !colors.isEmpty {
            var rgb = [UInt8](repeating: 0, count: vs.count * 4)
            var seen = 0
            for v in 0..<vs.count {
                guard let c = SurfaceCloud.color(at: SIMD3(pos[v * 3], pos[v * 3 + 1], pos[v * 3 + 2]), colors) else { continue }
                rgb[v * 4] = c.x; rgb[v * 4 + 1] = c.y; rgb[v * 4 + 2] = c.z; rgb[v * 4 + 3] = 255
                seen += 1
            }
            if seen > 0 { out["rgb"] = Data(rgb).base64EncodedString() }
        }
        return out
    }
}
