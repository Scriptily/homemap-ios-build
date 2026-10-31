import Foundation
import os
import UIKit

/// Debug log of a scan ("Send debug logs to Home Assistant" in the menu, on by default): what happened and when -
/// phases, locking on, the AR settings RoomPlan ran with, the live mesh, tracking trouble, rooms saved or lost, what the
/// phone named, how warm the phone got. Lines go to Home Assistant's log in small batches while you scan (so even a scan
/// that's thrown away can be looked at), and the whole log rides along with the scan when it's sent. Text only: never
/// a camera picture.
final class ScanLog {
    static let shared = ScanLog()
    var enabled: Bool { UserDefaults.standard.object(forKey: "debugLogs") as? Bool ?? true }
    private let q = DispatchQueue(label: "scanlog")
    private var client: HAClient?
    private var scan = ""
    private var t0 = Date()
    private var all: [String] = []
    private var pending: [String] = []
    private var flushing = false

    /// a new scan: the device and what's being done
    func begin(scan: String, client: HAClient?, what: String) {
        q.sync { self.scan = scan; self.client = client; t0 = Date(); all = []; pending = [] }
        var u = utsname(); uname(&u)
        let model = withUnsafeBytes(of: &u.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let app = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        add("scan \(scan) - \(what) | \(model), iOS \(UIDevice.current.systemVersion), app \(app) | \(Self.health())", now: true)
    }

    /// one line (now: send it right away, for errors)
    func add(_ s: String, now: Bool = false) {
        guard enabled else { return }
        q.async {
            let line = String(format: "[+%.1fs] ", Date().timeIntervalSince(self.t0)) + s
            if self.all.count < 4000 { self.all.append(line) }
            self.pending.append(line)
            if now { self.flush() } else if !self.flushing {
                self.flushing = true
                self.q.asyncAfter(deadline: .now() + 6) { self.flush() }
            }
        }
    }

    /// everything so far (sent along with the scan)
    var text: String { q.sync { all.joined(separator: "\n") } }

    /// the last few lines (live session status)
    func tail(_ n: Int) -> [String] { q.sync { Array(all.suffix(n)) } }

    /// the end of a scan: the rest goes out now, and the copy on disk goes (the scan ended properly)
    func end(_ s: String) {
        add(s, now: true)
        q.async { try? FileManager.default.removeItem(at: Self.fileURL) }
    }

    /// while a scan runs its log is also on disk: if the app dies, the next launch finds it (Diagnostics sends it)
    private static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("scanlog-current.txt")
    }
    static func leftover() -> String? { try? String(contentsOf: fileURL, encoding: .utf8) }
    static func clearLeftover() { try? FileManager.default.removeItem(at: fileURL) }

    private func flush() {                              // on q
        flushing = false
        try? all.joined(separator: "\n").write(to: Self.fileURL, atomically: true, encoding: .utf8)
        guard !pending.isEmpty, let c = client else { pending = []; return }
        let batch = "scan \(scan)\n" + pending.joined(separator: "\n")
        pending = []
        Task { await c.log(batch) }
    }

    /// how the phone is doing: heat and free memory
    static func health() -> String {
        let th: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: th = "cool"
        case .fair: th = "warm"
        case .serious: th = "hot"
        case .critical: th = "very hot"
        @unknown default: th = "?"
        }
        return "phone \(th), \(os_proc_available_memory() / 1_048_576) MB free"
    }
}
