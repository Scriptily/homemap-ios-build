import Foundation
import MetricKit

/// When the app crashes (or a scan ends without finishing), what happened goes to Home Assistant's log the next time
/// the app can reach it - with "Send debug logs to Home Assistant" on. iOS hands the app its own crash reports on the
/// next launch (MetricKit); a scan's debug log is kept on disk while you scan, so the last lines before it ended are
/// there too. Text only: no pictures, nothing from the camera.
final class Diagnostics: NSObject, MXMetricManagerSubscriber {
    static let shared = Diagnostics()

    private var dir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("diagnostics", isDirectory: true)
    }

    /// at launch: listen for crash reports, and pick up a scan that ended without finishing
    func start() {
        MXMetricManager.shared.add(self)
        if let last = ScanLog.leftover() {
            let lines = last.split(separator: "\n", omittingEmptySubsequences: false).suffix(80).joined(separator: "\n")
            save("A scan ended without finishing (the app was closed, crashed or was stopped by iOS). Its last lines:\n" + lines)
            ScanLog.clearLeftover()
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for p in payloads {
            for c in p.crashDiagnostics ?? [] { save(Self.describe(c)) }
            for h in p.hangDiagnostics ?? [] {
                save("The app froze for \(h.hangDuration.formatted()) (app \(h.metaData.applicationBuildVersion), iOS \(h.metaData.osVersion))\n"
                     + Self.stack(h.callStackTree))
            }
        }
    }

    static func describe(_ c: MXCrashDiagnostic) -> String {
        var s = "The app crashed (app \(c.metaData.applicationBuildVersion), \(c.metaData.osVersion), \(c.metaData.deviceType))"
        if let t = c.exceptionType { s += " | exception type \(t)" }
        if let code = c.exceptionCode { s += " code \(code)" }
        if let sig = c.signal { s += " | signal \(sig)" }
        if let r = c.terminationReason { s += " | \(r)" }
        if let why = c.exceptionReason { s += " | \(why.composedMessage)" }
        return s + "\n" + stack(c.callStackTree)
    }

    /// the crashed thread's frames: which library and where (iOS gives offsets, not names)
    static func stack(_ tree: MXCallStackTree) -> String {
        guard let o = try? JSONSerialization.jsonObject(with: tree.jsonRepresentation()) as? [String: Any],
              let stacks = o["callStacks"] as? [[String: Any]] else { return "" }
        let main = stacks.first { ($0["threadAttributed"] as? Bool) == true } ?? stacks.first
        var lines: [String] = []
        var frame = (main?["callStackRootFrames"] as? [[String: Any]])?.first
        while let f = frame, lines.count < 40 {
            lines.append("  \(f["binaryName"] as? String ?? "?") +\(f["offsetIntoBinaryTextSegment"] as? Int ?? 0)")
            frame = (f["subFrames"] as? [[String: Any]])?.first
        }
        return lines.joined(separator: "\n")
    }

    private func save(_ text: String) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "\(Int(Date().timeIntervalSince1970 * 1000)).txt"
        try? String(text.prefix(12_000)).write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// anything waiting goes to Home Assistant's log (each one removed once it's there)
    func send(_ client: HAClient) async {
        guard ScanLog.shared.enabled, let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let text = try? String(contentsOf: f, encoding: .utf8) else { try? FileManager.default.removeItem(at: f); continue }
            do { try await client.report(text); try? FileManager.default.removeItem(at: f) } catch { return }
        }
    }
}
