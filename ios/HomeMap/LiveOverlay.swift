import ARKit
import RealityKit
import RoomPlan
import UIKit

/// The live view drawn over the camera while scanning, like a Quest 3 room scan:
/// - everything the LiDAR has seen gets a white triangle wireframe (the real mesh, hugging every surface), so you see
///   at a glance what's covered and what isn't
/// - RoomPlan's rooms: thin cyan edges on the walls, outlined doors (orange) and windows (teal)
/// - furniture: thin outlines with a floating label of what RoomPlan thinks it is (or what the phone named it), so a
///   wrong guess shows right away - no solid blocks
/// Without the mesh (RoomPlan didn't share it), the floor fills in with a dotted grid as before.
final class LiveOverlay {
    let root = AnchorEntity(world: .zero)
    private let committed = Entity()
    private let live = Entity()
    private let planes = Entity()
    private let tags = Entity()
    private let meshes = Entity()
    private var planeEntities: [UUID: (ModelEntity, Int)] = [:]
    private var meshEntities: [UUID: (entity: ModelEntity, updated: Date)] = [:]
    /// which geometry each piece was last built from (ARKit hands over a new geometry when a piece changes)
    private var meshSig: [UUID: String] = [:]
    /// no floor planes before this: on a LiDAR phone the mesh is a second or two away (the blue floor flashed first)
    var planesAfter = Date.distantPast
    /// pieces ARKit dropped, and when: drawn a few more seconds while their replacements come in
    private var goneAt: [UUID: Date] = [:]
    private lazy var floorMaterial: UnlitMaterial = Self.dottedMaterial()
    private lazy var wireMaterial: UnlitMaterial = Self.wireMaterial()
    private var textCache: [String: MeshResource] = [:]
    /// furniture shown (off = rooms only: no outlines, no labels)
    var showObjects = true
    /// what the phone named near a spot (shown on the furniture's label instead of RoomPlan's guess)
    var nameNear: ((SIMD3<Float>, Float) -> String?)?
    /// the LiDAR mesh is coming in
    private(set) var hasMesh = false

    init() {
        root.addChild(meshes)
        root.addChild(planes)
        root.addChild(committed)
        root.addChild(live)
        root.addChild(tags)
    }

    /// a fresh map section: what's drawn of finished rooms and tags moves into the new AR world
    func rebase(_ m: simd_float4x4) {
        for e in [committed, tags] { e.transform = Transform(matrix: m * e.transform.matrix) }
    }

    /// a small orange pin where something was tagged
    @discardableResult
    func addTag(at p: SIMD3<Float>, normal n: SIMD3<Float>) -> Entity {
        let pin = ModelEntity(mesh: .generateSphere(radius: 0.04), materials: [UnlitMaterial(color: .systemOrange)])
        pin.position = p + n * 0.04
        tags.addChild(pin)
        return pin
    }

    // MARK: the LiDAR mesh

    private let meshQueue = DispatchQueue(label: "mesh", qos: .userInitiated)
    /// mesh pieces rebuilt and the time it took (ms), for the debug log
    static var built = 0, buildMs: Double = 0
    private var building = Set<UUID>()

    /// called 10x a second: the pieces that changed are rebuilt in the background, so the wireframe fills in as you look
    /// around - only where the LiDAR has seen. As the phone warms up, pieces are rebuilt less often (it got hot and choppy
    /// rebuilding everything 4x a second while RoomPlan, hand depth and the naming model all ran too)
    func updateMesh(_ frame: ARFrame) {
        let anchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        if !anchors.isEmpty && !hasMesh { hasMesh = true; planes.isEnabled = false; live.children.removeAll() }
        let now = Date()
        let (every, most): (TimeInterval, Int) = switch ProcessInfo.processInfo.thermalState {
        case .nominal: (0.5, 3)
        case .fair: (1.0, 2)
        case .serious: (2.0, 1)
        default: (4.0, 1)
        }
        // only pieces that changed since they were built (rebuilding all of them on a timer kept the phone busy and
        // starved the newest pieces - squares that stayed empty, gaps at seams); new pieces first, then the nearest
        let cam = frame.camera.transform.columns.3, eye = SIMD3<Float>(cam.x, cam.y, cam.z)
        var seen = Set<UUID>()
        var todo: [(a: ARMeshAnchor, isNew: Bool, d: Float, sig: String)] = []
        for a in anchors {
            seen.insert(a.identifier)
            let g = a.geometry
            let sig = "\(ObjectIdentifier(g).hashValue)-\(g.faces.count)-\(g.vertices.count)"
            let c = a.transform.columns.3
            let far = simd_distance(SIMD3(c.x, c.y, c.z), eye) > 7
            if let e = meshEntities[a.identifier] {
                e.entity.transform = Transform(matrix: a.transform)
                // only what's around you is drawn (walking a whole floor, every piece drawn halved the frame rate)
                if e.entity.isEnabled == far { e.entity.isEnabled = !far }
                if far || meshSig[a.identifier] == sig || now.timeIntervalSince(e.updated) < every { continue }
            }
            guard !building.contains(a.identifier), !far else { continue }
            todo.append((a, meshEntities[a.identifier] == nil, simd_distance(SIMD3(c.x, c.y, c.z), eye), sig))
        }
        todo.sort { $0.isNew != $1.isNew ? $0.isNew : $0.d < $1.d }
        for t in todo.prefix(most) {
            let a = t.a
            building.insert(a.identifier)
            meshSig[a.identifier] = t.sig
            let id = a.identifier, tf = a.transform, geo = a.geometry
            meshQueue.async { [weak self] in
                let t0 = Date()
                let data = Self.wireData(geo)
                let ms = Date().timeIntervalSince(t0) * 1000
                DispatchQueue.main.async { Self.built += 1; Self.buildMs += ms }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.building.remove(id)
                    guard let data, let mesh = Self.wireMesh(data) else { return }
                    if let e = self.meshEntities[id] {
                        e.entity.model?.mesh = mesh
                        self.meshEntities[id] = (e.entity, Date())
                    } else {
                        let m = ModelEntity(mesh: mesh, materials: [self.wireMaterial])
                        m.transform = Transform(matrix: tf)
                        self.meshes.addChild(m)
                        self.meshEntities[id] = (m, Date())
                    }
                }
            }
        }
        for id in seen { goneAt[id] = nil }
        for (id, e) in meshEntities where !seen.contains(id) {
            let since = goneAt[id] ?? now
            goneAt[id] = since
            guard now.timeIntervalSince(since) > 6 else { continue }
            e.entity.removeFromParent()
            meshEntities[id] = nil
            meshSig[id] = nil
            goneAt[id] = nil
        }
    }

    /// every triangle on its own with the same texture coordinates, so the texture draws its three edges
    /// (corners at (0, 0.5), (1, 0), (1, 1): the same triangle if the texture is flipped, so it can't come out wrong)
    static func wireMesh(_ w: (pos: [SIMD3<Float>], uv: [SIMD2<Float>], ind: [UInt32])) -> MeshResource? {
        var d = MeshDescriptor(name: "wire")
        d.positions = MeshBuffers.Positions(w.pos)
        d.textureCoordinates = MeshBuffers.TextureCoordinates(w.uv)
        d.primitives = .triangles(w.ind)
        return try? MeshResource.generate(from: [d])
    }

    /// (off the main thread) the triangles of a mesh piece, each with its own corners
    static func wireData(_ g: ARMeshGeometry) -> (pos: [SIMD3<Float>], uv: [SIMD2<Float>], ind: [UInt32])? {
        let vs = g.vertices, fs = g.faces, ns = g.normals
        guard fs.count > 0, fs.indexCountPerPrimitive == 3 else { return nil }
        let vp = vs.buffer.contents(), ip = fs.buffer.contents(), np = ns.buffer.contents()
        let lift: Float = 0.015
        var pos = [SIMD3<Float>](), uv = [SIMD2<Float>]()
        pos.reserveCapacity(fs.count * 3)
        uv.reserveCapacity(fs.count * 3)
        let corner: [SIMD2<Float>] = [[0, 0.5], [1, 0], [1, 1]]
        for f in 0..<fs.count {
            for k in 0..<3 {
                let n = f * 3 + k
                let i = fs.bytesPerIndex == 4 ? Int(ip.advanced(by: n * 4).assumingMemoryBound(to: UInt32.self).pointee)
                                              : Int(ip.advanced(by: n * 2).assumingMemoryBound(to: UInt16.self).pointee)
                let p = vp.advanced(by: vs.offset + vs.stride * i).assumingMemoryBound(to: Float.self)
                var v = SIMD3<Float>(p[0], p[1], p[2])
                if i < ns.count {
                    let q = np.advanced(by: ns.offset + ns.stride * i).assumingMemoryBound(to: Float.self)
                    v += SIMD3<Float>(q[0], q[1], q[2]) * lift
                }
                pos.append(v)
                uv.append(corner[k])
            }
        }
        // one side only - the material draws both (half the triangles of doubling them)
        return (pos, uv, (0..<UInt32(pos.count)).map { $0 })
    }

    /// white triangle edges with a faint white fill: the right edge and the two lines to the left middle. The picture is
    /// how see-through each spot is (white = edge, 7% = the fill), used as the opacity: RealityKit ignored the alpha of a
    /// color texture, so the fill came out solid dark grey over the floor (the "shadow")
    static func wireMaterial() -> UnlitMaterial {
        let size = 128
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let s = CGFloat(size), mid = CGPoint(x: 1.5, y: s / 2)
        ctx.setFillColor(UIColor(white: 0, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
        ctx.setFillColor(UIColor(white: 0.07, alpha: 1).cgColor)
        ctx.move(to: mid); ctx.addLine(to: CGPoint(x: s, y: 0)); ctx.addLine(to: CGPoint(x: s, y: s)); ctx.closePath(); ctx.fillPath()
        ctx.setStrokeColor(UIColor(white: 0.85, alpha: 1).cgColor)
        ctx.setLineWidth(3.5)
        ctx.move(to: CGPoint(x: s - 1.75, y: 0)); ctx.addLine(to: CGPoint(x: s - 1.75, y: s))
        ctx.move(to: mid); ctx.addLine(to: CGPoint(x: s, y: 1.5))
        ctx.move(to: mid); ctx.addLine(to: CGPoint(x: s, y: s - 1.5))
        ctx.strokePath()
        var m = UnlitMaterial(color: .white)
        if let img = ctx.makeImage(), let tex = try? TextureResource.generate(from: img, options: .init(semantic: .raw)) {
            let sd = MTLSamplerDescriptor()
            sd.minFilter = .linear
            sd.magFilter = .linear
            sd.mipFilter = .linear
            var t = MaterialParameters.Texture(tex)
            t.sampler = MaterialParameters.Texture.Sampler(sd)
            m.blending = .transparent(opacity: .init(scale: 1, texture: t))
        } else {
            m.blending = .transparent(opacity: .init(floatLiteral: 0.3))
        }
        m.faceCulling = .none
        return m
    }

    // MARK: rooms

    func showLive(_ room: CapturedRoom) {
        live.children.removeAll()
        add(room, to: live, finished: false)
    }

    func commit(_ room: CapturedRoom) {
        live.children.removeAll()
        add(room, to: committed, finished: true)
    }

    private func add(_ room: CapturedRoom, to parent: Entity, finished: Bool) {
        let edge = UIColor(red: 0.25, green: 0.9, blue: 1, alpha: 1)
        if !hasMesh { for f in room.floors { if let e = floorEntity(f) { parent.addChild(e) } } }
        for w in room.walls where !hasMesh {
            let e = Entity()
            e.transform = Transform(matrix: w.transform)
            e.addChild(box(w.dimensions.x, w.dimensions.y, 0.006, UIColor.white, finished ? 0.08 : 0.12))
            for y in [w.dimensions.y / 2, -w.dimensions.y / 2] {
                let line = box(w.dimensions.x, 0.012, 0.012, edge, 0.9)
                line.position = [0, y, 0]
                e.addChild(line)
            }
            parent.addChild(e)
        }
        for d in room.doors { parent.addChild(frame(d.transform, d.dimensions.x, d.dimensions.y, UIColor.orange)) }
        for d in room.windows { parent.addChild(frame(d.transform, d.dimensions.x, d.dimensions.y, UIColor.systemTeal)) }
        for o in room.objects where showObjects || o.category == .stairs {
            let stairs = o.category == .stairs
            let c: UIColor = stairs ? .systemYellow : UIColor(red: 0.55, green: 0.8, blue: 1, alpha: 1)
            let e = outline(o.transform, o.dimensions, c)
            if !finished || !hasMesh { e.addChild(label(for: o)) }
            parent.addChild(e)
        }
    }

    private static let names: [CapturedRoom.Object.Category: String] = [
        .storage: "Cabinet", .refrigerator: "Fridge", .stove: "Stove", .bed: "Bed", .sink: "Sink", .washerDryer: "Washer",
        .toilet: "Toilet", .bathtub: "Bathtub", .oven: "Oven", .dishwasher: "Dishwasher", .table: "Table", .sofa: "Sofa",
        .chair: "Chair", .fireplace: "Fireplace", .television: "TV", .stairs: "Stairs",
    ]

    /// what it is, floating above it, always facing you
    private func label(for o: CapturedRoom.Object) -> Entity {
        let p = SIMD3<Float>(o.transform.columns.3.x, o.transform.columns.3.y, o.transform.columns.3.z)
        let named = nameNear?(p, max(o.dimensions.x, o.dimensions.z) / 2 + 0.1)
        let text = named.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? (Self.names[o.category] ?? "Thing")
        let mesh = textCache[text] ?? MeshResource.generateText(text, extrusionDepth: 0.001, font: .systemFont(ofSize: 0.07, weight: .semibold))
        textCache[text] = mesh
        let t = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: named == nil ? .white : UIColor(red: 0.55, green: 1, blue: 0.7, alpha: 1))])
        let b = mesh.bounds
        t.position = [-b.center.x, -b.center.y, 0]
        let holder = Entity()
        holder.addChild(t)
        holder.position = [0, o.dimensions.y / 2 + 0.12, 0]
        holder.components.set(BillboardComponent())
        return holder
    }

    /// the 12 edges of a box, thin
    private func outline(_ tf: simd_float4x4, _ s: SIMD3<Float>, _ c: UIColor) -> Entity {
        let e = Entity()
        e.transform = Transform(matrix: tf)
        let t: Float = 0.008, h = s / 2
        for y in [-h.y, h.y] { for z in [-h.z, h.z] { let l = box(s.x, t, t, c, 0.85); l.position = [0, y, z]; e.addChild(l) } }
        for y in [-h.y, h.y] { for x in [-h.x, h.x] { let l = box(t, t, s.z, c, 0.85); l.position = [x, y, 0]; e.addChild(l) } }
        for x in [-h.x, h.x] { for z in [-h.z, h.z] { let l = box(t, s.y, t, c, 0.85); l.position = [x, 0, z]; e.addChild(l) } }
        return e
    }

    /// a door / window: its frame only
    private func frame(_ tf: simd_float4x4, _ w: Float, _ h: Float, _ c: UIColor) -> Entity {
        let e = Entity()
        e.transform = Transform(matrix: tf)
        let t: Float = 0.02
        for y in [-h / 2, h / 2] { let l = box(w, t, t, c, 0.95); l.position = [0, y, 0]; e.addChild(l) }
        for x in [-w / 2, w / 2] { let l = box(t, h, t, c, 0.95); l.position = [x, 0, 0]; e.addChild(l) }
        return e
    }

    private func box(_ w: Float, _ h: Float, _ d: Float, _ c: UIColor, _ alpha: Float) -> ModelEntity {
        var m = UnlitMaterial(color: c)
        m.blending = .transparent(opacity: .init(floatLiteral: alpha))
        return ModelEntity(mesh: .generateBox(width: max(w, 0.005), height: max(h, 0.005), depth: max(d, 0.005)), materials: [m])
    }

    private func floorEntity(_ s: CapturedRoom.Surface) -> ModelEntity? {
        let corners = s.polygonCorners
        guard corners.count >= 3 else { return nil }
        let pts2 = corners.map { SIMD2<Float>($0.x, $0.y) }
        guard let mesh = Self.mesh(positions: corners, uv: pts2.map { $0 * 5 }, indices: Triangulate.polygon(pts2)) else { return nil }
        let e = ModelEntity(mesh: mesh, materials: [floorMaterial])
        e.transform = Transform(matrix: s.transform)
        return e
    }

    // MARK: floor planes from ARKit - these grow live as the LiDAR sees more floor (only without the mesh)

    func updatePlanes(_ frame: ARFrame, cameraY: Float) {
        guard !hasMesh, Date() > planesAfter else { return }
        var seen = Set<UUID>()
        for case let p as ARPlaneAnchor in frame.anchors where p.alignment == .horizontal {
            let isFloor: Bool
            if ARPlaneAnchor.isClassificationSupported { isFloor = p.classification == .floor || (p.classification == .none(.unknown) && p.transform.columns.3.y < cameraY - 0.7) }
            else { isFloor = p.transform.columns.3.y < cameraY - 0.7 }
            guard isFloor else { continue }
            seen.insert(p.identifier)
            let g = p.geometry
            if let (e, n) = planeEntities[p.identifier], n == g.vertices.count {
                e.transform = Transform(matrix: p.transform)
                continue
            }
            let uv = g.vertices.map { SIMD2<Float>($0.x * 5, $0.z * 5) }
            let idx = g.triangleIndices.map { UInt32($0) }
            guard let mesh = Self.mesh(positions: g.vertices, uv: uv, indices: idx) else { continue }
            if let (old, _) = planeEntities[p.identifier] { old.removeFromParent() }
            let e = ModelEntity(mesh: mesh, materials: [floorMaterial])
            e.transform = Transform(matrix: p.transform)
            planes.addChild(e)
            planeEntities[p.identifier] = (e, g.vertices.count)
        }
        for (id, (e, _)) in planeEntities where !seen.contains(id) && frame.anchors.first(where: { $0.identifier == id }) == nil {
            e.removeFromParent()
            planeEntities[id] = nil
        }
    }

    // MARK: helpers

    static func mesh(positions: [SIMD3<Float>], uv: [SIMD2<Float>], indices: [UInt32]) -> MeshResource? {
        guard !indices.isEmpty else { return nil }
        var d = MeshDescriptor(name: "fill")
        d.positions = MeshBuffers.Positions(positions)
        d.textureCoordinates = MeshBuffers.TextureCoordinates(uv)
        // both windings, so it's visible from either side
        var both = indices
        for i in stride(from: 0, to: indices.count - 2, by: 3) { both += [indices[i], indices[i + 2], indices[i + 1]] }
        d.primitives = .triangles(both)
        return try? MeshResource.generate(from: [d])
    }

    /// see-through blue with a cyan dot every 20 cm. RealityKit ignores the texture's own alpha (it came out solid blue,
    /// painted over everything), so the texture is opaque and the whole surface gets one see-through opacity instead.
    static func dottedMaterial() -> UnlitMaterial {
        let size = 64
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(UIColor(red: 0.16, green: 0.5, blue: 1, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setFillColor(UIColor(red: 0.8, green: 1, blue: 1, alpha: 1).cgColor)
        ctx.fillEllipse(in: CGRect(x: size / 2 - 5, y: size / 2 - 5, width: 10, height: 10))
        var m = UnlitMaterial(color: UIColor(red: 0.2, green: 0.55, blue: 1, alpha: 1))
        if let img = ctx.makeImage(), let tex = try? TextureResource.generate(from: img, options: .init(semantic: .color)) {
            let s = MTLSamplerDescriptor()
            s.sAddressMode = .repeat
            s.tAddressMode = .repeat
            s.minFilter = .linear
            s.magFilter = .linear
            s.mipFilter = .linear
            var t = MaterialParameters.Texture(tex)
            t.sampler = MaterialParameters.Texture.Sampler(s)
            m.color = .init(tint: .white, texture: t)
        }
        m.blending = .transparent(opacity: .init(floatLiteral: 0.32))
        return m
    }
}

/// Ear-clipping triangulation for simple polygons (room floors).
enum Triangulate {
    static func polygon(_ p: [SIMD2<Float>]) -> [UInt32] {
        var idx = Array(0..<p.count)
        if signedArea(p) < 0 { idx.reverse() }
        var out: [UInt32] = []
        var guardCount = 0
        while idx.count > 3 && guardCount < 5000 {
            guardCount += 1
            var clipped = false
            for i in 0..<idx.count {
                let a = idx[(i + idx.count - 1) % idx.count], b = idx[i], c = idx[(i + 1) % idx.count]
                if cross(p[b] - p[a], p[c] - p[b]) <= 0 { continue }
                var inside = false
                for j in idx where j != a && j != b && j != c {
                    if inTriangle(p[j], p[a], p[b], p[c]) { inside = true; break }
                }
                if inside { continue }
                out += [UInt32(a), UInt32(b), UInt32(c)]
                idx.remove(at: i)
                clipped = true
                break
            }
            if !clipped { break }
        }
        if idx.count == 3 { out += idx.map { UInt32($0) } }
        return out
    }

    static func signedArea(_ p: [SIMD2<Float>]) -> Float {
        var a: Float = 0
        for i in 0..<p.count { let j = (i + 1) % p.count; a += p[i].x * p[j].y - p[j].x * p[i].y }
        return a / 2
    }

    private static func cross(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { a.x * b.y - a.y * b.x }

    private static func inTriangle(_ q: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Bool {
        let d1 = cross(b - a, q - a), d2 = cross(c - b, q - b), d3 = cross(a - c, q - c)
        return d1 >= 0 && d2 >= 0 && d3 >= 0
    }
}
