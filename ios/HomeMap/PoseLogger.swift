import ARKit

/// Records where the phone is (in the scan's own coordinates) twice a second, with the wall-clock time.
/// The PC records Wi-Fi signal by time; Home Assistant joins the two to paint the heatmap.
final class PoseLogger {
    struct Sample {
        let t: Double
        let x: Float, y: Float, z: Float
        let yaw: Float
        let ping: Double?
    }

    private(set) var samples: [Sample] = []
    /// off while tracking is settling (just came back, or the world jumped): those positions can be off
    var recording = true
    private var timer: Timer?
    private weak var session: ARSession?
    private var client: HAClient?
    private var lastPing: Double?
    private var pinging = false

    func start(session: ARSession, client: HAClient?) {
        guard timer == nil else { return }
        self.session = session
        self.client = client
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard recording, let frame = session?.currentFrame, case .normal = frame.camera.trackingState else { return }
        let m = frame.camera.transform
        let yaw = atan2(-m.columns.2.x, -m.columns.2.z)
        samples.append(Sample(t: Date().timeIntervalSince1970, x: m.columns.3.x, y: m.columns.3.y, z: m.columns.3.z,
                              yaw: yaw, ping: lastPing))
        lastPing = nil
        if !pinging, let c = client {
            pinging = true
            Task { [weak self] in
                let p = await c.ping()
                DispatchQueue.main.async {
                    self?.lastPing = p
                    self?.pinging = false
                }
            }
        }
    }

    /// a fresh map section: the walk so far moves into the new AR world
    func rebase(_ m: simd_float4x4) { samples = samples.map { Self.moved($0, m) } }

    private static func moved(_ s: Sample, _ m: simd_float4x4) -> Sample {
        let p = Frames.apply(m, SIMD3(s.x, s.y, s.z))
        let f = Frames.turn(m, SIMD3(-sin(s.yaw), 0, -cos(s.yaw)))       // the way the camera looked
        return Sample(t: s.t, x: p.x, y: p.y, z: p.z, yaw: atan2(-f.x, -f.z), ping: s.ping)
    }

    /// the walk, in the home's frame (`to`: the live AR world -> the home)
    func json(to m: simd_float4x4 = matrix_identity_float4x4) -> [[String: Any]] {
        samples.map { Self.moved($0, m) }.map { s in
            var o: [String: Any] = ["t": s.t, "x": s.x, "y": s.y, "z": s.z, "yaw": s.yaw]
            if let p = s.ping { o["ping"] = (p * 10).rounded() / 10 }
            return o
        }
    }
}
