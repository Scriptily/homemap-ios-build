import simd
import XCTest
@testable import HomeMap

/// App 1.8: the lock-on check against the saved surfaces, the saved map's file, and chaining a fresh map section
final class SurfaceTests: XCTestCase {

    // MARK: a corner of a room: two walls and the floor, as surface points

    /// points on the wall x = 0 (facing +x), the wall z = 0 (facing +z) and the floor y = 0, every `step` m, moved by `shift`
    private func corner(step: Float, offset: Float = 0, shift: SIMD3<Float> = .zero) -> [LivePoint] {
        var out: [LivePoint] = []
        var a: Float = offset
        while a < 3 {
            var b: Float = offset
            while b < 2.5 {
                out.append(LivePoint(p: SIMD3(0, b, a) + shift, n: SIMD3(1, 0, 0)))
                out.append(LivePoint(p: SIMD3(a, b, 0) + shift, n: SIMD3(0, 0, 1)))
                b += step
            }
            var c: Float = offset
            while c < 3 { out.append(LivePoint(p: SIMD3(a, 0, c) + shift, n: SIMD3(0, 1, 0))); c += step }
            a += step
        }
        return out
    }

    private func index(_ pts: [LivePoint]) -> SurfaceIndex {
        var b = SurfaceIndex.Builder()
        for p in pts { b.add(p.p, p.n) }
        return b.finish()
    }

    func testTheSameCornerLinesUp() {
        let saved = index(corner(step: 0.05))
        let c = saved.check(corner(step: 0.1, offset: 0.025))
        XCTAssertTrue(c.isGood, c.summary)
        XCTAssertFalse(c.isMismatch, c.summary)
        XCTAssertLessThan(c.median ?? 1, 0.01, c.summary)
        XCTAssertGreaterThanOrEqual(c.spreadDegrees, 45)
    }

    /// 30 cm along one wall: that wall still "fits", the other doesn't - never good
    func testAShiftAlongOneWallIsNotGood() {
        let saved = index(corner(step: 0.05))
        let c = saved.check(corner(step: 0.1, offset: 0.025, shift: SIMD3(0.3, 0, 0)))
        XCTAssertFalse(c.isGood, c.summary)
    }

    /// the wrong spot: walls where the map has none (15 cm off both ways) - a mismatch, the lock-on starts over
    func testTheWrongSpotIsAMismatch() {
        let saved = index(corner(step: 0.05))
        let c = saved.check(corner(step: 0.1, offset: 0.025, shift: SIMD3(0.15, 0, 0.15)))
        XCTAssertFalse(c.isGood, c.summary)
        XCTAssertTrue(c.isMismatch, c.summary)
    }

    /// one flat wall can't show a slide along itself: it asks for a corner instead of saying yes
    func testOneWallAsksForACorner() {
        let saved = index(corner(step: 0.05))
        let wall = corner(step: 0.1, offset: 0.025).filter { $0.n.x == 1 }
        let c = saved.check(wall)
        XCTAssertFalse(c.isGood, c.summary)
        XCTAssertTrue(c.needsCorner, c.summary)
    }

    func testNothingNearbyIsNeitherGoodNorAMismatch() {
        let saved = index(corner(step: 0.05))
        let c = saved.check(corner(step: 0.1, offset: 0.025, shift: SIMD3(20, 0, 20)))
        XCTAssertEqual(c.known, 0)
        XCTAssertFalse(c.isGood)
        XCTAssertFalse(c.isMismatch)
    }

    // MARK: the cloud's file

    func testCloudRoundTrip() throws {
        let cells: [(p: SIMD3<Float>, n: SIMD3<Float>, c: SIMD3<Float>?)] = [
            (SIMD3(-3.2, 0.01, 7.5), SIMD3(0, 1, 0), SIMD3(200, 180, 150)),
            (SIMD3(12.345, 2.6, -4.0), simd_normalize(SIMD3(1, 0, 1)), nil),
            (SIMD3(0, 1.2, 0), SIMD3(0, 0, -1), SIMD3(0, 255, 10)),
        ]
        let d = SurfaceCloud.encode(cells)
        XCTAssertEqual(d.count, 20 + 13 * cells.count)
        let back = try XCTUnwrap(SurfaceCloud.decode(d))
        XCTAssertEqual(back.count, cells.count)
        for (a, b) in zip(cells, back) {
            XCTAssertLessThan(simd_distance(a.p, b.p), 0.001)
            XCTAssertLessThan(simd_distance(a.n, b.n), 0.02)
            XCTAssertEqual(a.c == nil, b.c == nil)
            if let ca = a.c, let cb = b.c { XCTAssertLessThan(simd_distance(ca, cb), 0.6) }
        }
        XCTAssertNil(SurfaceCloud.decode(Data("nope".utf8)))
        XCTAssertNil(SurfaceCloud.decode(d.prefix(25)))           // cut short
        let idx = try XCTUnwrap(SurfaceCloud.index(d))
        XCTAssertEqual(idx.points.count, 3)
    }

    // MARK: real colors

    func testAFloorsColorIsTheMiddleOfItsColoredCells() throws {
        let square: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(3, 0), SIMD2(3, 3), SIMD2(0, 3)]
        var cells: [(p: SIMD3<Float>, n: SIMD3<Float>, c: SIMD3<Float>?)] = []
        for i in 0..<10 { for j in 0..<10 {
            // a wood-brown floor, with a few odd cells (a rug edge) that mustn't move the middle
            let odd = i == 0 && j < 3
            cells.append((SIMD3(Float(i) * 0.25 + 0.2, 0.01, Float(j) * 0.25 + 0.2), SIMD3(0, 1, 0), odd ? SIMD3(250, 250, 250) : SIMD3(150, 110, 70)))
        } }
        cells.append((SIMD3(1, 1.2, 1), SIMD3(0, 1, 0), SIMD3(0, 0, 255)))        // a table top: not the floor
        cells.append((SIMD3(5, 0, 5), SIMD3(0, 1, 0), SIMD3(0, 255, 0)))          // the next room
        cells.append((SIMD3(1, 0.5, 0), SIMD3(0, 0, 1), SIMD3(255, 0, 0)))        // a wall
        let hex = try XCTUnwrap(SurfaceCloud.floorColor(cells, poly: square, floorY: 0))
        XCTAssertEqual(hex, "#966e46")                                            // 150 110 70, lit evenly enough already
        XCTAssertNil(SurfaceCloud.floorColor(Array(cells.prefix(10)), poly: square, floorY: 0), "too few cells to say")
        XCTAssertNil(SurfaceCloud.floorColor(cells, poly: square, floorY: 2), "nothing at that height")
    }

    func testAPointTakesTheColorOfItsCellOrANeighbor() {
        let p = SIMD3<Float>(1.02, 0.31, -2.04)
        var t: [Int64: SIMD3<UInt8>] = [:]
        XCTAssertNil(SurfaceCloud.color(at: p, t))
        t[SurfaceIndex.key(p + SIMD3(0.05, 0, 0), SurfaceIndex.voxel)] = SIMD3(1, 2, 3)
        XCTAssertEqual(SurfaceCloud.color(at: p, t), SIMD3(1, 2, 3))
        t[SurfaceIndex.key(p, SurfaceIndex.voxel)] = SIMD3(9, 9, 9)
        XCTAssertEqual(SurfaceCloud.color(at: p, t), SIMD3(9, 9, 9))
    }

    // MARK: the saved map's file

    func testWorldPackRoundTrip() throws {
        let archive = Data("bplist00 not a real map".utf8)
        let cloud = SurfaceCloud.encode([(SIMD3(1, 2, 3), SIMD3(0, 1, 0), nil)])
        let to = Frames.yawMove(0.8, SIMD3(4, -0.5, 2))
        let pack = WorldPack(archive: archive, toHome: to, cloud: cloud, rooms: 7, sections: 2)
        let back = try XCTUnwrap(WorldPack(pack.data))
        XCTAssertEqual(back.archive, archive)
        XCTAssertEqual(back.cloud, cloud)
        XCTAssertEqual(back.rooms, 7)
        XCTAssertEqual(back.sections, 2)
        XCTAssertEqual(Export.mat(back.toHome), Export.mat(to))
        // no cloud
        let bare = try XCTUnwrap(WorldPack(WorldPack(archive: archive, toHome: matrix_identity_float4x4, cloud: nil, rooms: 1, sections: 1).data))
        XCTAssertNil(bare.cloud)
        // a map saved by app 1.7: the bare archive still loads
        let old = try XCTUnwrap(WorldPack(archive))
        XCTAssertEqual(old.archive, archive)
        XCTAssertNil(old.cloud)
        XCTAssertEqual(Export.mat(old.toHome), Export.mat(matrix_identity_float4x4))
        XCTAssertNil(WorldPack(Data("garbage data".utf8)))
    }

    // MARK: chaining a fresh map section

    /// the same phone pose seen in the old world and in the fresh one: the chain takes the fresh world into the old one
    func testChainTakesTheFreshWorldIntoTheOldOne() {
        // the phone held tilted (pitch + roll), the same way in both worlds
        let tilt = simd_float4x4(simd_quatf(angle: -0.4, axis: SIMD3(1, 0, 0)) * simd_quatf(angle: 0.1, axis: SIMD3(0, 0, 1)))
        let old = Frames.yawMove(0.9, SIMD3(5, 1.4, -2)) * tilt
        let new = Frames.yawMove(-0.2, SIMD3(0.01, 0.0, -0.02)) * tilt
        let k = Frames.chain(old: old, new: new)
        let moved = k * new
        XCTAssertLessThan(simd_distance(simd_make_float3(moved.columns.3), simd_make_float3(old.columns.3)), 1e-4)
        for c in 0..<3 {
            XCTAssertLessThan(simd_distance(simd_make_float3(moved[c]), simd_make_float3(old[c])), 1e-4)
        }
        // a point a meter in front of the phone lands on the same spot
        let ahead = SIMD4<Float>(0, 0, -1, 1)
        XCTAssertLessThan(simd_distance(simd_make_float3(k * (new * ahead)), simd_make_float3(old * ahead)), 1e-4)
        // only a turn about the vertical: up stays up
        XCTAssertLessThan(simd_distance(simd_make_float3(k.columns.1), SIMD3(0, 1, 0)), 1e-5)
    }

    func testRebasingThereAndBackIsTheSame() {
        let k = Frames.yawMove(1.3, SIMD3(-2, 0.3, 7))
        let p = SIMD3<Float>(1, 2, 3)
        XCTAssertLessThan(simd_distance(Frames.apply(k.inverse, Frames.apply(k, p)), p), 1e-5)
        XCTAssertLessThan(simd_distance(Frames.turn(k, SIMD3(0, 1, 0)), SIMD3(0, 1, 0)), 1e-6)
    }
}
