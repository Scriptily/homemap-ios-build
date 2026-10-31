import simd
import UIKit
import XCTest
@testable import HomeMap

/// The app's logic that doesn't need a LiDAR phone: tags, icons, pairing, the unsent-scan queue,
/// reading Home Assistant's answer, the transform layout the dashboard expects, the door-size readout.
final class HomeMapTests: XCTestCase {

    // MARK: tags

    func testTagKindsAreUniqueAndNamed() {
        let kinds = TagCatalog.groups.flatMap(\.items).map(\.kind)
        XCTAssertFalse(kinds.isEmpty)
        XCTAssertEqual(Set(kinds).count, kinds.count, "a tag kind is listed twice: \(kinds.filter { k in kinds.filter { $0 == k }.count > 1 })")
        for t in TagCatalog.groups.flatMap(\.items) {
            XCTAssertFalse(t.name.trimmingCharacters(in: .whitespaces).isEmpty, t.kind)
            XCTAssertFalse(t.kind.contains(" "), t.kind)
        }
        XCTAssertEqual(Set(TagCatalog.roomNames).count, TagCatalog.roomNames.count)
    }

    /// the dashboard understands exactly these door / window styles (home-map-card.js _styleTag)
    func testStyleTagsAreOnesTheDashboardKnows() {
        let styles = TagCatalog.groups.flatMap(\.items).map(\.kind).filter { $0.hasPrefix("style:") }
        XCTAssertEqual(Set(styles), ["style:frosted", "style:glass", "style:doorway", "style:sliding", "style:curtains", "style:grille"])
        // 1.8: wall finishes and floors are never picked by hand - the phone notices them (Recognizer) and sends
        // exactly the kinds the dashboard draws
        let kinds = TagCatalog.groups.flatMap(\.items).map(\.kind)
        XCTAssertFalse(kinds.contains { $0.hasPrefix("finish:") || $0.hasPrefix("floor:") }, "materials are automatic now")
        XCTAssertEqual(Set(Recognizer.finishNames.keys).union(["paint"]), ["concrete", "wood", "wallpaper", "brick", "stone", "tile", "paint"])
        XCTAssertEqual(Set(Recognizer.floorNames.keys), ["wood", "tile", "marble", "carpet", "concrete", "stone", "grass"])
    }

    /// every SF Symbol the app shows exists on iOS 17 (a missing one silently draws nothing)
    func testEverySymbolExists() throws {
        var names = Set(TagCatalog.groups.flatMap(\.items).map(\.icon))
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("HomeMap")
        if let files = try? FileManager.default.contentsOfDirectory(at: src, includingPropertiesForKeys: nil) {
            let re = try NSRegularExpression(pattern: #"(?:systemImage|systemName|icon):\s*"([^"\\]+)""#)
            for f in files where f.pathExtension == "swift" {
                let text = try String(contentsOf: f, encoding: .utf8)
                for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    if let r = Range(m.range(at: 1), in: text) { names.insert(String(text[r])) }
                }
            }
        }
        XCTAssertGreaterThan(names.count, 40)
        let missing = names.filter { UIImage(systemName: $0) == nil }.sorted()
        XCTAssertEqual(missing, [], "SF Symbols that don't exist: \(missing)")
    }

    // MARK: pairing

    func testPairingQR() {
        let s = Settings()
        let before = (s.url, s.token)
        defer { s.save(url: before.0, token: before.1) }
        let token = String(repeating: "a", count: 40)
        XCTAssertTrue(s.pair(fromQR: #"{"u":"https://ha.example.com/","t":"\#(token)"}"#))
        XCTAssertEqual(s.url, "https://ha.example.com")   // trailing slash dropped
        XCTAssertEqual(s.token, token)
        XCTAssertTrue(s.paired)
        XCTAssertFalse(s.pair(fromQR: #"{"u":"http://ha.example.com","t":"\#(token)"}"#), "plain http is refused")
        XCTAssertFalse(s.pair(fromQR: #"{"u":"https://ha.example.com","t":"short"}"#))
        XCTAssertFalse(s.pair(fromQR: "not json"))
        XCTAssertFalse(s.pair(fromQR: #"{"url":"https://x","token":"\#(token)"}"#))
    }

    // MARK: unsent scans

    func testPendingScanSurvivesUntilRemoved() throws {
        let p = PendingScan(id: "test" + UUID().uuidString.prefix(8), name: "Test scan", kind: "rooms", parts: 2)
        try p.save([Data(#"{"a":1}"#.utf8), Data(#"{"b":2}"#.utf8)])
        XCTAssertTrue(PendingScan.all().contains { $0.id == p.id && $0.parts == 2 && $0.name == "Test scan" })
        XCTAssertEqual(String(data: try p.load(1), encoding: .utf8), #"{"b":2}"#)
        p.remove()
        XCTAssertFalse(PendingScan.all().contains { $0.id == p.id })
    }

    // MARK: Home Assistant's answer (home_map/get)

    func testSummaryFromHomeAssistant() throws {
        let json = #"""
        {"scans": {
          "demohome": {"id": "demohome", "created": 1792893382.85, "kind": "rooms", "level": "ground", "name": "DEMO Whole home", "parts": 2, "complete": true},
          "v1": {"id": "v1", "created": 1792893447.55, "kind": "mesh", "level": "ground", "name": "Version: Saved in Edit", "parts": 1, "complete": true},
          "w1": {"id": "w1", "created": 1792893500, "kind": "mesh", "level": "ground", "name": "World: Whole home", "parts": 3, "complete": true},
          "h1": {"id": "h1", "created": 1792893600.5, "kind": "rooms", "level": "ground", "name": "Whole home", "parts": 2, "complete": true},
          "h2": {"id": "h2", "created": 1792893700.5, "kind": "rooms", "level": "first", "name": "Upstairs", "parts": 1, "complete": false},
          "f1": {"id": "f1", "created": 1792893800, "kind": "mesh", "level": "ground", "name": "File: receipt.pdf", "parts": 1, "complete": true}},
         "layout": {"version": 3, "levels": [{"id": "ground", "name": "Ground floor"}, {"id": "first", "name": "First floor"}, {"id": "outdoor", "name": "Garden"}],
           "objects": [{"id": "a"}, {"id": "b", "placed": true}, {"id": "c", "placed": false}], "rooms": [{"id": "r1"}]},
         "survey": {}}
        """#
        let res = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let s = HomeSummary.parse(res)
        XCTAssertEqual(s.scans.count, 6)
        XCTAssertEqual(Set(s.homeScans.map(\.id)), ["h1", "h2"], "the demo, versions, world maps and files aren't scans of the home")
        XCTAssertEqual(s.newest?.id, "h2")
        XCTAssertTrue(s.hasWorldMap)
        XCTAssertEqual(s.levels, ["Ground floor", "First floor", "Garden"])
        XCTAssertEqual(s.things, 2, "things not placed yet don't count")
        XCTAssertEqual(s.rooms, 1)
        XCTAssertEqual(s.scans.first { $0.id == "w1" }?.parts, 3)
        XCTAssertEqual(s.scans.first { $0.id == "w1" }?.created, 1792893500)
        XCTAssertFalse(HomeSummary.parse([:]).hasWorldMap)
        XCTAssertNil(HomeSummary.parse([:]).newest)
    }

    // MARK: export format

    /// 16 floats, column-major: what three.js Matrix4.fromArray expects (translation at 12, 13, 14)
    func testTransformLayout() {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(1, 2, 3, 1)
        m.columns.0 = SIMD4<Float>(0, 0, -1, 0)   // turned 90°
        m.columns.2 = SIMD4<Float>(1, 0, 0, 0)
        let a = Export.mat(m)
        XCTAssertEqual(a.count, 16)
        XCTAssertEqual(Array(a[12...15]), [1, 2, 3, 1])
        XCTAssertEqual(Array(a[0...3]), [0, 0, -1, 0])
        XCTAssertEqual(Array(a[8...11]), [1, 0, 0, 0])
        XCTAssertEqual(Export.vec(SIMD3<Float>(0.9, 2.05, 0.1)), [0.9, 2.05, 0.1])
    }

    // MARK: door / window sizes after a room

    func testDoorSizeReadout() {
        let ok = HomeScanModel.openingsText(doors: [SIMD3(0.9, 2.0, 0.1), SIMD3(0.88, 2.05, 0.1)], windows: [SIMD3(1.4, 1.2, 0.1)])
        XCTAssertEqual(ok.0, "Doors 90×200, 88×205 · Window 140×120 cm (W×H)")
        XCTAssertEqual(ok.1, "")
        let odd = HomeScanModel.openingsText(doors: [SIMD3(0.9, 1.6, 0.1)], windows: [])
        XCTAssertEqual(odd.0, "Door 90×160 cm (W×H)")
        XCTAssertTrue(odd.1.hasPrefix("A door came out an unusual size"))
        let two = HomeScanModel.openingsText(doors: [SIMD3(0.5, 2.0, 0.1), SIMD3(2.2, 2.0, 0.1)], windows: [])
        XCTAssertTrue(two.1.hasPrefix("2 doors"))
        XCTAssertEqual(HomeScanModel.openingsText(doors: [], windows: []).0, "")
    }

    // MARK: recognizer (on-device naming)

    func testNamesAreCleanedUp() {
        XCTAssertEqual(Recognizer.clean("A Floor Lamp."), "floor lamp")
        XCTAssertEqual(Recognizer.clean("  the split air conditioner "), "split air conditioner")
        XCTAssertEqual(Recognizer.clean("None"), "none")
        XCTAssertEqual(Recognizer.clean("an old wooden shoe rack by the door with shoes"), "old wooden shoe rack by")
        XCTAssertLessThanOrEqual(Recognizer.clean(String(repeating: "x", count: 90)).count, 40)
    }

    /// walk anywhere: how far outside a room's floor you are (a 4 x 3 m room)
    func testFloorplanOutside() {
        let room: [SIMD2<Float>] = [[0, 0], [4, 0], [4, 3], [0, 3]]
        XCTAssertTrue(Floorplan.inside([2, 1.5], room))
        XCTAssertEqual(Floorplan.outside([2, 1.5], room), 0)
        XCTAssertEqual(Floorplan.outside([5, 1.5], room), 1, accuracy: 1e-4)        // 1 m past the right wall
        XCTAssertEqual(Floorplan.outside([2, -0.5], room), 0.5, accuracy: 1e-4)     // in the doorway, just out
        XCTAssertEqual(Floorplan.outside([5, 4], room), sqrt(2), accuracy: 1e-4)    // past a corner
    }

    // MARK: the live room outline (from its walls - RoomPlan has no floor until a room is finished)

    /// a 4 x 3 m room from its four walls: the hull, its area and size
    private let box: [(SIMD2<Float>, SIMD2<Float>)] = [
        RoomShape.ends(center: [2, 0], along: [1, 0], length: 4), RoomShape.ends(center: [4, 1.5], along: [0, 1], length: 3),
        RoomShape.ends(center: [2, 3], along: [-1, 0], length: 4), RoomShape.ends(center: [0, 1.5], along: [0, -1], length: 3)]

    func testRoomOutlineFromWalls() {
        let hull = RoomShape.hull(box.flatMap { [$0.0, $0.1] })
        XCTAssertEqual(hull.count, 4)
        XCTAssertEqual(RoomShape.area(hull), 12, accuracy: 1e-3)
        XCTAssertEqual(RoomShape.size(hull).x, 4, accuracy: 1e-3)
        XCTAssertEqual(RoomShape.size(hull).y, 3, accuracy: 1e-3)
        XCTAssertFalse(RoomShape.tooBig(hull))
        XCTAssertTrue(RoomShape.tooBig([[0, 0], [10, 0], [10, 1], [0, 1]]), "10 m long: past one room")
        XCTAssertTrue(RoomShape.tooBig([[0, 0], [7, 0], [7, 7], [0, 7]]), "49 m²: past one room")
        XCTAssertTrue(RoomShape.hull([[0, 0], [1, 1]]).count == 2, "two points: no hull, no crash")
        // walked 1 m out through a door in the right wall: outside by 1 m
        XCTAssertEqual(Floorplan.outside([5, 1.5], hull), 1, accuracy: 1e-3)
    }

    func testRoomClosureAndWhatsMissing() {
        let hull = RoomShape.hull(box.flatMap { [$0.0, $0.1] })
        XCTAssertEqual(RoomShape.closure(hull, walls: box).0, 1, accuracy: 1e-3)
        XCTAssertNil(RoomShape.closure(hull, walls: box).1)
        // the right wall (x = 4) never scanned: its middle 2.3 m are open (35 cm at each end count as the corners' walls),
        // 11.7 of 14 m closed, and the gap is there
        let (c, gap) = RoomShape.closure(hull, walls: [box[0], box[2], box[3]])
        XCTAssertEqual(c, 0.836, accuracy: 0.02)
        let g = try! XCTUnwrap(gap)
        XCTAssertEqual(g.x, 4, accuracy: 0.4)
        // standing in the middle facing -z (ARKit's "forward"): x = 4 is on your right, x = 0 on your left
        XCTAssertEqual(RoomShape.direction(of: [4, 1.5], from: [2, 1.5], facing: [0, -1]), "on your right")
        XCTAssertEqual(RoomShape.direction(of: [0, 1.5], from: [2, 1.5], facing: [0, -1]), "on your left")
        XCTAssertEqual(RoomShape.direction(of: [2, 0], from: [2, 1.5], facing: [0, -1]), "in front of you")
        XCTAssertEqual(RoomShape.direction(of: [2, 3], from: [2, 1.5], facing: [0, -1]), "behind you")
        XCTAssertEqual(RoomShape.closure(hull, walls: []).0, 0)
    }

    func testFloorsAreCountedTheUSWay() {
        XCTAssertEqual(Levels.name(0), "First floor")
        XCTAssertEqual(Levels.name(1), "Second floor")
        XCTAssertEqual(Levels.id(0), "ground")
        XCTAssertEqual(Levels.id(1), "first")
        XCTAssertEqual(Levels.id(9), "third", "past the top: the highest the map knows")
        XCTAssertEqual(Levels.index(of: "first"), 1)
        XCTAssertEqual(Levels.index(of: "outdoor"), 0, "starting in the garden counts as the first floor")
    }

    /// a finished scan waiting on the phone keeps the phone's map of the place with it
    func testPendingScanKeepsTheWorldMap() throws {
        let p = PendingScan(id: "test" + UUID().uuidString.prefix(8), name: "Home (unfinished)", kind: "rooms", parts: 1, rooms: 3)
        try p.save([Data("{}".utf8)])
        try p.saveWorld(Data([1, 2, 3]))
        let back = try XCTUnwrap(PendingScan.all().first { $0.id == p.id })
        XCTAssertEqual(back.rooms, 3)
        XCTAssertTrue(back.unfinished)
        XCTAssertEqual(back.world(), Data([1, 2, 3]))
        p.remove()
    }

    /// Home Assistant down vs. answering with an error
    func testUnreachable() {
        XCTAssertTrue(HAClient.unreachable(URLError(.cannotConnectToHost)))
        XCTAssertTrue(HAClient.unreachable(URLError(.timedOut)))
        XCTAssertTrue(HAClient.unreachable(NSError(domain: "HomeAssistant", code: 502)))
        XCTAssertFalse(HAClient.unreachable(NSError(domain: "HomeAssistant", code: 401)))
        XCTAssertFalse(HAClient.unreachable(URLError(.badURL)))
    }

    /// bare surfaces the model names like things never become things on the map
    func testSurfacesAreNotThings() {
        for s in ["floor", "white wall", "blank wall", "tile", "black tiles", "wooden floor", "ceiling", "door", "none", "ring", "white circle"] { XCTAssertTrue(Recognizer.isSurface(s), s) }
        for s in ["floor lamp", "wall clock", "tile cutter", "door mat", "window ac", "recliner", "ceiling fan"] { XCTAssertFalse(Recognizer.isSurface(s), s) }
    }

    /// a spot on / in a RoomPlan furniture box (turned 90°, 12 cm margin) belongs to it
    func testSpotInsideFurnitureBox() {
        var t = matrix_identity_float4x4
        t.columns.0 = SIMD4<Float>(0, 0, -1, 0); t.columns.2 = SIMD4<Float>(1, 0, 0, 0)   // turned 90° about y
        t.columns.3 = SIMD4<Float>(2, 0.4, 1, 1)
        let size = SIMD3<Float>(2.0, 0.8, 0.9)                                              // a sofa: 2 m wide (now along z)
        XCTAssertTrue(Recognizer.inside(SIMD3(2, 0.8, 1.9), transform: t, size: size, margin: 0.12))
        XCTAssertFalse(Recognizer.inside(SIMD3(3.0, 0.4, 1), transform: t, size: size, margin: 0.12))
        XCTAssertTrue(Recognizer.inside(SIMD3(2.5, 0.4, 1), transform: t, size: size, margin: 0.12))
    }
}
