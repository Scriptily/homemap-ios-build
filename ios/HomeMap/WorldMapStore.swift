import ARKit
import Foundation

/// The phone's memory of the home (ARKit world map), kept in Home Assistant so the next scan can lock on to it.
/// Stored as a hidden "World: …" upload in a few compressed parts; the dashboard ignores these. The newest one is also
/// kept on the phone, so adding to the map works while Home Assistant is down.
enum WorldMapStore {
    static let chunk = 4_000_000   // bytes per part before base64 (HA accepts up to 15 MB per upload)

    /// a saved map (WorldPack data), under a fixed id (sending it again replaces it instead of adding another).
    /// 1.8: zlib (raw deflate) instead of lzfse, so the PC can read the home's surfaces too (Python has zlib built in)
    static func upload(archive raw: Data, id: String, client: HAClient, name: String) async throws {
        let data = (try? (raw as NSData).compressed(using: .zlib) as Data) ?? raw
        let compressed = data.count < raw.count
        let n = max(1, Int(ceil(Double(data.count) / Double(chunk))))
        for i in 0..<n {
            let part = data.subdata(in: (i * chunk)..<min(data.count, (i + 1) * chunk))
            let body: [String: Any] = ["version": 2, "asset": "worldmap", "seq": i, "total": n, "compressed": compressed ? "zlib" : "", "data": part.base64EncodedString()]
            try await client.upload(scan: id, kind: "mesh", level: "ground", name: "World: \(name)", part: i, of: n, data: try JSONSerialization.data(withJSONObject: body))
        }
    }

    /// newest saved map of the home: from Home Assistant, else the copy on this phone; nil when there's none
    static func latest(client: HAClient?, scans: [ScanMeta]) async -> WorldPack? {
        if let c = client, let w = scans.filter({ $0.name.hasPrefix("World: ") && $0.complete }).max(by: { $0.created < $1.created }),
           let data = try? await download(w, client: c), let pack = WorldPack(data) {
            keepLocal(data)
            return pack
        }
        return local()
    }

    private static func download(_ w: ScanMeta, client: HAClient) async throws -> Data {
        var data = Data()
        var compressed = ""
        for i in 0..<max(1, w.parts) {
            let o = try await client.json(path: "api/home_map/file/\(w.id)/\(i)")
            guard let b = o["data"] as? String, let d = Data(base64Encoded: b) else { throw URLError(.cannotDecodeContentData) }
            compressed = o["compressed"] as? String ?? ""
            data.append(d)
        }
        if compressed == "lzfse" { data = try (data as NSData).decompressed(using: .lzfse) as Data }      // app 1.7 and older
        else if compressed == "zlib" { data = try (data as NSData).decompressed(using: .zlib) as Data }
        return data
    }

    private static var localURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("worldmap.data")
    }

    /// the newest map of the home, kept on the phone
    static func keepLocal(_ archive: Data) { try? archive.write(to: localURL, options: .atomic) }
    static func local() -> WorldPack? { (try? Data(contentsOf: localURL)).flatMap(WorldPack.init) }
    static var hasLocal: Bool { FileManager.default.fileExists(atPath: localURL.path) }
}

/// The phone's map of the home (ARKit world map) with what goes along with it:
/// - `toHome`: where this map's world sits in the home's frame - not the same when a scan had to start a fresh map
///   section partway (RoomPlan ran out of room) and this map is from a later section. Rooms of a scan that locked on to
///   it are moved by it, so they land where the first scan put the home.
/// - `cloud`: the home's surfaces (SurfaceCloud, in the home's frame) - a lock-on is checked against it
/// Stored as "HMW1" | header length UInt32 LE | header JSON | map archive | cloud. A map saved by app 1.7 or older is
/// the bare archive: it still loads (no cloud, toHome = identity).
struct WorldPack {
    let archive: Data
    var toHome = matrix_identity_float4x4
    var cloud: Data?
    /// rooms in the map's section / sections in the scan that saved it (for the log)
    var rooms = 0, sections = 1

    init(archive: Data, toHome: simd_float4x4, cloud: Data?, rooms: Int, sections: Int) {
        self.archive = archive; self.toHome = toHome; self.cloud = cloud; self.rooms = rooms; self.sections = sections
    }

    init?(_ data: Data) {
        guard data.count > 8, data.prefix(4) == Data("HMW1".utf8) else {
            guard NSKeyedUnarchiver.isArchive(data) else { return nil }
            archive = data
            return
        }
        let b = [UInt8](data.subdata(in: 4..<8))
        let hl = Int(UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24)
        guard data.count >= 8 + hl, let head = try? JSONSerialization.jsonObject(with: data.subdata(in: 8..<(8 + hl))) as? [String: Any],
              let mapBytes = (head["map"] as? NSNumber)?.intValue, data.count >= 8 + hl + mapBytes else { return nil }
        archive = data.subdata(in: (8 + hl)..<(8 + hl + mapBytes))
        let rest = data.subdata(in: (8 + hl + mapBytes)..<data.count)
        cloud = rest.isEmpty ? nil : rest
        if let t = head["toHome"] as? [NSNumber], t.count == 16 {
            let f = t.map(\.floatValue)
            toHome = simd_float4x4(SIMD4(f[0], f[1], f[2], f[3]), SIMD4(f[4], f[5], f[6], f[7]), SIMD4(f[8], f[9], f[10], f[11]), SIMD4(f[12], f[13], f[14], f[15]))
        }
        rooms = (head["rooms"] as? NSNumber)?.intValue ?? 0
        sections = (head["sections"] as? NSNumber)?.intValue ?? 1
    }

    var data: Data {
        let head: [String: Any] = ["v": 1, "map": archive.count, "toHome": Export.mat(toHome), "cloud": cloud?.count ?? 0,
                                   "rooms": rooms, "sections": sections]
        let h = (try? JSONSerialization.data(withJSONObject: head)) ?? Data("{}".utf8)
        var d = Data("HMW1".utf8)
        withUnsafeBytes(of: UInt32(h.count).littleEndian) { d.append(contentsOf: $0) }
        d.append(h); d.append(archive)
        if let cloud { d.append(cloud) }
        return d
    }

    var map: ARWorldMap? { try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: archive) }
}

private extension NSKeyedUnarchiver {
    /// a keyed archive (a bare world map from app 1.7 or older) starts as a binary property list
    static func isArchive(_ d: Data) -> Bool { d.prefix(6) == Data("bplist".utf8) }
}

/// A finished scan waits on the phone until Home Assistant has every part (survives Wi-Fi drops, Home Assistant being
/// down and closing the app); it's sent again by itself when Home Assistant is back.
struct PendingScan: Codable, Identifiable {
    let id: String
    let name: String
    let kind: String
    let parts: Int
    var created = Date()
    /// rooms in it (shown on the start screen)
    var rooms: Int?

    init(id: String, name: String, kind: String, parts: Int, created: Date = Date(), rooms: Int? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.parts = parts; self.created = created; self.rooms = rooms
    }

    /// cut short (the app closed mid-scan): what was scanned up to the last room
    var unfinished: Bool { name.hasSuffix("(unfinished)") }

    private static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("pending", isDirectory: true)
    }
    private var dir: URL { Self.root.appendingPathComponent(id, isDirectory: true) }

    func save(_ data: [Data]) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (i, d) in data.enumerated() { try d.write(to: dir.appendingPathComponent("part-\(i).json"), options: .atomic) }
        try JSONEncoder().encode(self).write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
    }

    func load(_ i: Int) throws -> Data { try Data(contentsOf: dir.appendingPathComponent("part-\(i).json")) }

    /// the phone's map of the place, sent after the scan
    func saveWorld(_ archive: Data) throws { try archive.write(to: dir.appendingPathComponent("world.data"), options: .atomic) }
    func world() -> Data? { try? Data(contentsOf: dir.appendingPathComponent("world.data")) }

    func remove() { try? FileManager.default.removeItem(at: dir) }

    static func all() -> [PendingScan] {
        let fm = FileManager.default
        guard let ids = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        return ids.compactMap { id in
            guard let d = try? Data(contentsOf: root.appendingPathComponent(id).appendingPathComponent("meta.json")) else { return nil }
            return try? JSONDecoder().decode(PendingScan.self, from: d)
        }.sorted { $0.created > $1.created }
    }
}

/// What Home Assistant has: the scans (meta only) and the saved layout.
struct ScanMeta: Codable {
    let id: String
    let name: String
    let kind: String
    let parts: Int
    let complete: Bool
    let created: Double
}

struct HomeSummary: Codable {
    var scans: [ScanMeta]
    var levels: [String]
    var things: Int
    var rooms: Int

    /// the result of the integration's `home_map/get` (scans keyed by id + the saved layout)
    static func parse(_ res: [String: Any]) -> HomeSummary {
        let scans = ((res["scans"] as? [String: Any]) ?? [:]).values.compactMap { $0 as? [String: Any] }.map {
            ScanMeta(id: $0["id"] as? String ?? "", name: $0["name"] as? String ?? "", kind: $0["kind"] as? String ?? "",
                     parts: ($0["parts"] as? NSNumber)?.intValue ?? 1, complete: $0["complete"] as? Bool ?? false,
                     created: ($0["created"] as? NSNumber)?.doubleValue ?? 0)
        }
        let layout = res["layout"] as? [String: Any] ?? [:]
        let levels = (layout["levels"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        let objects = (layout["objects"] as? [[String: Any]] ?? []).filter { ($0["placed"] as? Bool) != false }
        let rooms = (layout["rooms"] as? [Any])?.count ?? 0
        return HomeSummary(scans: scans, levels: levels, things: objects.count, rooms: rooms)
    }

    /// real scans (not the demo, not hidden helper uploads)
    var homeScans: [ScanMeta] { scans.filter { !$0.name.hasPrefix("World: ") && !$0.name.hasPrefix("Version: ") && !$0.name.hasPrefix("File: ") && !$0.name.hasPrefix("Model: ") && !$0.name.hasPrefix("DEMO") } }
    var newest: ScanMeta? { homeScans.max { $0.created < $1.created } }
    var hasWorldMap: Bool { scans.contains { $0.name.hasPrefix("World: ") && $0.complete } }
    /// floors of the house (not the garden)
    var floors: Int { max(1, levels.filter { $0 != "Garden" }.count) }

    /// the last answer from Home Assistant, kept so the start screen still knows your home while it's down
    static var cached: HomeSummary? {
        get { UserDefaults.standard.data(forKey: "summary").flatMap { try? JSONDecoder().decode(HomeSummary.self, from: $0) } }
        set { UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "summary") }
    }
}
