import Foundation

/// Talks only to the paired Home Assistant (the home_map integration's API).
struct HAClient {
    let base: URL
    let token: String

    init?(_ s: Settings) {
        guard s.paired, let u = URL(string: s.url) else { return nil }
        base = u
        token = s.token
    }

    /// Home Assistant (or the network) is down / unreachable - as opposed to it answering with an error
    static func unreachable(_ error: Error) -> Bool {
        let codes: [URLError.Code] = [.cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost, .notConnectedToInternet,
                                      .dnsLookupFailed, .secureConnectionFailed, .cannotLoadFromNetwork, .internationalRoamingOff, .dataNotAllowed]
        if let u = error as? URLError { return codes.contains(u.code) }
        let n = error as NSError
        return n.domain == "HomeAssistant" && [502, 503, 504].contains(n.code)
    }

    private func request(_ path: String, query: [String: String] = [:], method: String = "POST", body: Data? = nil, timeout: TimeInterval = 180) -> URLRequest {
        var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var r = URLRequest(url: c.url!)
        r.httpMethod = method
        r.timeoutInterval = timeout
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    private func send(_ r: URLRequest) async throws -> Data {
        let (d, resp) = try await URLSession.shared.data(for: r)
        guard let h = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(h.statusCode) else {
            let text = String(data: d, encoding: .utf8).map { String($0.prefix(200)) } ?? ""
            throw NSError(domain: "HomeAssistant", code: h.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Home Assistant answered \(h.statusCode). \(text)"])
        }
        return d
    }

    /// Checks the pairing works and the home_map integration is installed.
    func check() async throws {
        _ = try await send(request("api/home_map/hello", method: "GET", timeout: 8))
    }

    func survey(_ action: String, scan: String, ip: String?) async throws {
        var o: [String: Any] = ["action": action, "scan": scan]
        if let ip { o["ip"] = ip }
        _ = try await send(request("api/home_map/survey", body: try JSONSerialization.data(withJSONObject: o)))
    }

    /// a line in Home Assistant's log (Settings → System → Logs): how the live view ran during a scan (the AR settings
    /// RoomPlan used, whether the LiDAR mesh came, tracking trouble), so a bad scan can be looked into afterwards
    func log(_ message: String) async {
        let o: [String: Any] = ["message": "Home Map app: " + message, "level": "warning", "logger": "home_map.app"]
        guard let body = try? JSONSerialization.data(withJSONObject: o) else { return }
        _ = try? await send(request("api/services/system_log/write", body: body, timeout: 15))
    }

    /// live session: the messages for this phone after `since` (waits up to `wait` s for one)
    func live(since: Int, wait: Int) async throws -> (seq: Int, messages: [[String: Any]]) {
        let d = try await send(request("api/home_map/live", query: ["side": "app", "since": "\(since)", "wait": "\(wait)"], method: "GET",
                                       timeout: TimeInterval(wait + 10)))
        let o = (try JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        return ((o["seq"] as? NSNumber)?.intValue ?? since, o["messages"] as? [[String: Any]] ?? [])
    }

    /// live session: one message to the PC (status, an answer, a screenshot)
    func livePost(_ o: [String: Any]) async throws {
        var b = o; b["to"] = "pc"
        _ = try await send(request("api/home_map/live", body: try JSONSerialization.data(withJSONObject: b), timeout: 15))
    }

    /// a crash report / an unfinished scan's last lines into Home Assistant's log (throws: it's kept and sent again later)
    func report(_ message: String) async throws {
        let o: [String: Any] = ["message": "Home Map app: " + message, "level": "error", "logger": "home_map.app"]
        _ = try await send(request("api/services/system_log/write", body: try JSONSerialization.data(withJSONObject: o), timeout: 15))
    }

    func upload(scan: String, kind: String, level: String, name: String, part: Int, of parts: Int, data: Data) async throws {
        let q = ["scan": scan, "kind": kind, "level": level, "name": name, "part": "\(part)", "parts": "\(parts)"]
        _ = try await send(request("api/home_map/upload", query: q, body: data))
    }

    /// one photo / depth frame / index.json of a scan's photo set, as the raw body (on its way to the PC)
    func photo(scan: String, name: String, data: Data) async throws {
        var r = request("api/home_map/photo", query: ["scan": scan, "name": name], body: data, timeout: 60)
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        _ = try await send(r)
    }

    /// which of a scan's photo files the PC has saved, and how long ago the PC last asked for one (-1 = never)
    func photosDone(scan: String) async throws -> (done: Set<String>, pcAge: Double) {
        let d = try await send(request("api/home_map/photo/done", query: ["scan": scan], method: "GET", timeout: 15))
        let o = (try JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        return (Set(o["done"] as? [String] ?? []), (o["pc_age"] as? NSNumber)?.doubleValue ?? -1)
    }

    /// GET a JSON object (scan parts, saved world map parts)
    func json(path: String) async throws -> [String: Any] {
        let d = try await send(request(path, method: "GET"))
        guard let o = try JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw URLError(.cannotParseResponse) }
        return o
    }

    /// What's in Home Assistant: scans (meta) + the saved layout, over HA's WebSocket API (home_map/get).
    func summary() async throws -> HomeSummary {
        // a quick look first: Home Assistant down shouldn't keep the start screen waiting on a socket for a minute
        try await check()
        guard var c = URLComponents(url: base.appendingPathComponent("api/websocket"), resolvingAgainstBaseURL: false) else { throw URLError(.badURL) }
        c.scheme = c.scheme == "http" ? "ws" : "wss"
        let task = URLSession.shared.webSocketTask(with: c.url!)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }
        func receive() async throws -> [String: Any] {
            let m = try await task.receive()
            let text: String
            switch m {
            case .string(let t): text = t
            case .data(let d): text = String(data: d, encoding: .utf8) ?? "{}"
            @unknown default: text = "{}"
            }
            return (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
        }
        func sendJSON(_ o: [String: Any]) async throws {
            let d = try JSONSerialization.data(withJSONObject: o)
            try await task.send(.string(String(data: d, encoding: .utf8)!))
        }
        _ = try await receive()                                   // auth_required
        try await sendJSON(["type": "auth", "access_token": token])
        let auth = try await receive()
        guard auth["type"] as? String == "auth_ok" else { throw NSError(domain: "HomeAssistant", code: 401, userInfo: [NSLocalizedDescriptionKey: "Home Assistant didn't accept the pairing. Pair again."]) }
        try await sendJSON(["id": 1, "type": "home_map/get"])
        var res: [String: Any] = [:]
        for _ in 0..<20 {
            let m = try await receive()
            if (m["id"] as? Int) == 1 { res = (m["result"] as? [String: Any]) ?? [:]; break }
        }
        return HomeSummary.parse(res)
    }

    /// Round trip to HA in ms (a rough "how good is the connection here" number, logged with each position).
    func ping() async -> Double? {
        let t = Date()
        guard (try? await send(request("api/home_map/hello", method: "GET", timeout: 5))) != nil else { return nil }
        return Date().timeIntervalSince(t) * 1000
    }
}

/// The phone's current Wi-Fi IPv4 address, so the PC can find this phone in the router's client list.
func wifiIPAddress() -> String? {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return nil }
    defer { freeifaddrs(list) }
    for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let i = p.pointee
        guard let sa = i.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), String(cString: i.ifa_name) == "en0" else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        return String(cString: host)
    }
    return nil
}
