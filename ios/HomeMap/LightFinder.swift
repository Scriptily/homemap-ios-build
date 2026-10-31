import ARKit

/// Spots ceiling lights while you scan: when the phone looks up, the brightest patch of the camera image
/// is ray-cast onto the ceiling. Spots seen at least twice in the same place become lights.
final class LightFinder {
    struct Spot {
        var p: SIMD3<Float>
        var hits: Int
    }

    private(set) var spots: [Spot] = []
    var lights: [SIMD3<Float>] { spots.filter { $0.hits >= 2 }.map(\.p) }

    /// a fresh map section: the spots move into the new AR world
    func rebase(_ m: simd_float4x4) { for i in spots.indices { spots[i].p = Frames.apply(m, spots[i].p) } }

    func look(_ frame: ARFrame, session: ARSession) {
        let cam = frame.camera.transform
        let forward = -SIMD3<Float>(cam.columns.2.x, cam.columns.2.y, cam.columns.2.z)
        guard forward.y > 0.3, case .normal = frame.camera.trackingState else { return }   // only while looking up
        guard let pt = brightest(frame.capturedImage) else { return }
        let q = frame.raycastQuery(from: pt, allowing: .estimatedPlane, alignment: .horizontal)
        guard let hit = session.raycast(q).first else { return }
        let p = SIMD3<Float>(hit.worldTransform.columns.3.x, hit.worldTransform.columns.3.y, hit.worldTransform.columns.3.z)
        guard p.y > cam.columns.3.y + 0.5 else { return }   // must be above the phone - the ceiling
        if let i = spots.firstIndex(where: { simd_distance(SIMD2($0.p.x, $0.p.z), SIMD2(p.x, p.z)) < 0.45 && abs($0.p.y - p.y) < 0.6 }) {
            let n = Float(spots[i].hits)
            spots[i].p = (spots[i].p * n + p) / (n + 1)
            spots[i].hits += 1
        } else {
            spots.append(Spot(p: p, hits: 1))
        }
    }

    /// normalized image point of the brightest compact patch (lit bulbs saturate), or nil if nothing is bright enough
    private func brightest(_ pb: CVPixelBuffer) -> CGPoint? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard CVPixelBufferGetPlaneCount(pb) > 0, let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0), row = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let luma = base.assumingMemoryBound(to: UInt8.self)
        let gx = 64, gy = 48
        var best: (Int, Int, Int) = (0, 0, 0)
        var bright: [(Int, Int)] = []
        for j in 0..<gy {
            let y = (j * h) / gy + h / (2 * gy)
            for i in 0..<gx {
                let x = (i * w) / gx + w / (2 * gx)
                let v = Int(luma[y * row + x])
                if v > best.2 { best = (i, j, v) }
                if v >= 248 { bright.append((i, j)) }
            }
        }
        guard best.2 >= 248, bright.count <= gx * gy / 12 else { return nil }   // a patch, not a bright window / wall
        let near = bright.filter { abs($0.0 - best.0) <= 4 && abs($0.1 - best.1) <= 4 }
        let cx = Float(near.map(\.0).reduce(0, +)) / Float(near.count), cy = Float(near.map(\.1).reduce(0, +)) / Float(near.count)
        return CGPoint(x: CGFloat((cx + 0.5) / Float(gx)), y: CGFloat((cy + 0.5) / Float(gy)))
    }
}
