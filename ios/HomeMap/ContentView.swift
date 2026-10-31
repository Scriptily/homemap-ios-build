import ARKit
import RoomPlan
import SwiftUI
import VisionKit

struct ContentView: View {
    @EnvironmentObject var settings: Settings
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var live = LiveSession.shared
    @ObservedObject private var photos = PhotoSender.shared
    var demo: String? = nil
    @State private var scan: HomeScanModel?
    @State private var pairing = false
    @State private var toast = ""
    @State private var summary: HomeSummary?
    /// can Home Assistant be reached: nil = checking
    @State private var reachable: Bool?
    @State private var busy = ""
    @State private var pending: [PendingScan] = []
    @State private var sending = false
    @State private var confirmStartOver = false
    @State private var confirmUnpair = false
    @State private var confirmDelete: PendingScan?
    @AppStorage("homeName") private var homeName = "My home"

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background
                ScrollView {
                    VStack(spacing: 16) {
                        if live.on && !live.message.isEmpty {
                            Label(live.message, systemImage: "bubble.left.fill").font(.callout.weight(.semibold)).foregroundStyle(.white)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                .background(Theme.blue.opacity(0.85), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        if !settings.paired { pairCard.transition(.rise) } else {
                            connection
                            if !pending.isEmpty { pendingCard.transition(.rise) }
                            if photos.left > 0 { photoCard.transition(.rise) }
                            if let s = summary, s.newest != nil { homeCard(s).transition(.rise) } else { firstScanCard.transition(.rise) }
                        }
                    }
                    .padding(16)
                    .animation(Theme.spring, value: settings.paired)
                    .animation(Theme.spring, value: summary?.scans.count)
                    .animation(Theme.spring, value: pending.count)
                    .animation(Theme.spring, value: reachable)
                }
                .refreshable { await refresh() }
                if !toast.isEmpty {
                    VStack { Spacer(); Capsule2(text: toast, icon: "info.circle").padding(.bottom, 20) }
                        .transition(.rise)
                        .task(id: toast) { try? await Task.sleep(for: .seconds(3.5)); withAnimation(Theme.spring) { toast = "" } }
                }
            }
            .navigationTitle("Home Map")
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                if settings.paired {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button { testConnection() } label: { Label("Test connection", systemImage: "antenna.radiowaves.left.and.right") }
                            Toggle(isOn: $settings.debugLogs) { Label("Send debug logs to Home Assistant", systemImage: "ladybug") }
                            Toggle(isOn: $live.on) { Label("Live session with Claude", systemImage: "bubble.left.and.text.bubble.right") }
                            Button(role: .destructive) { confirmUnpair = true } label: { Label("Unpair from Home Assistant", systemImage: "link.badge.plus") }
                        } label: { Image(systemName: "ellipsis.circle").foregroundStyle(Theme.text) }
                        .accessibilityLabel("Menu")
                    }
                }
            }
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .task {
            if let demo { setUpDemo(demo); return }
            LiveSession.shared.configure(HAClient(settings))
            // while this screen is open: check every 30 s, so scans waiting to be sent go as soon as Home Assistant is back
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .onChange(of: scenePhase) { _, p in if p == .active && demo == nil { Task { await refresh() } } }
        .sheet(isPresented: $pairing) {
            QRScanner { text in
                pairing = false
                say(settings.pair(fromQR: text) ? "Paired with Home Assistant." : "That isn't a Home Map pairing code.")
                LiveSession.shared.configure(HAClient(settings))
                Task { await refresh() }
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: Binding(get: { scan != nil }, set: { if !$0 { scan = nil; Task { await refresh() } } })) {
            if let s = scan { HomeScanScreen(model: s, mapLink: mapLink) }
        }
        .confirmationDialog("Scan the whole home again?", isPresented: $confirmStartOver, titleVisibility: .visible) {
            Button("Scan the whole home again") { begin(.new, replaceAll: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The new scan replaces the whole map. The current one is kept as a backup you can bring back on the dashboard (Edit → Scans → History).")
        }
        .confirmationDialog("Unpair this iPhone?", isPresented: $confirmUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) { withAnimation(Theme.spring) { settings.unpair(); summary = nil; LiveSession.shared.configure(nil) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Scans stay in Home Assistant. Pair again from the dashboard to scan more.") }
        .alert("Delete this scan?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) { confirmDelete?.remove(); confirmDelete = nil; withAnimation(Theme.spring) { pending = PendingScan.all() } }
            Button("Keep it", role: .cancel) {}
        } message: { Text("It hasn't reached Home Assistant, so it's gone for good.") }
    }

    private func say(_ t: String) { withAnimation(Theme.spring) { toast = t } }

    /// the map in the Home Assistant app (or the browser when the app isn't installed)
    private var mapLink: (app: URL, web: URL?)? {
        guard let app = URL(string: "homeassistant://navigate/home-map/map") else { return nil }
        return (app, URL(string: settings.url + "/home-map/map"))
    }

    /// what Home Assistant has (or the last copy of it while it's down); scans waiting on this phone go out when it's up
    private func refresh() async {
        if demo != nil { return }
        pending = PendingScan.all()
        if scan == nil { PhotoSender.cleanOrphans() }
        photos.refresh()
        guard let c = HAClient(settings) else { return }
        do {
            let s = try await c.summary()
            HomeSummary.cached = s
            withAnimation(Theme.spring) { summary = s; reachable = true }
            await Diagnostics.shared.send(c)
            await sendWaiting(c)
            // the photos of a scan follow it to the PC (rooms first: they're what the map needs)
            if PendingScan.all().isEmpty { photos.send(client: c) }
        } catch {
            withAnimation(Theme.spring) { summary = summary ?? HomeSummary.cached; reachable = false }
        }
    }

    /// finished scans that couldn't be sent: they go by themselves (unfinished ones wait for you to decide)
    private func sendWaiting(_ c: HAClient) async {
        guard !sending, scan == nil else { return }
        let waiting = PendingScan.all().filter { !$0.unfinished }
        guard !waiting.isEmpty else { return }
        sending = true
        defer { sending = false }
        for p in waiting {
            do {
                try await Uploader.send(p, client: c) { t in Task { @MainActor in busy = t } }
                say("\(p.name) sent to Home Assistant.")
            } catch { break }
        }
        withAnimation(Theme.spring) { busy = ""; pending = PendingScan.all() }
    }

    private func testConnection() {
        Task {
            guard let c = HAClient(settings) else { return }
            do { try await c.check(); say("Connected to \(settings.url)") } catch { say(error.localizedDescription) }
            await refresh()
        }
    }

    // MARK: cards

    /// is Home Assistant there: scans wait on the phone while it isn't
    @ViewBuilder private var connection: some View {
        switch reachable {
        case nil: EmptyView()
        case true?:
            Label("Connected to Home Assistant", systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
        case false?:
            VStack(alignment: .leading, spacing: 6) {
                Label("Home Assistant can't be reached", systemImage: "wifi.exclamationmark").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                Text("You can still scan. Scans wait on this phone and are sent by themselves when it's back.").font(.footnote).foregroundStyle(Theme.text)
                Button { Task { await refresh() } } label: { Label("Check again", systemImage: "arrow.clockwise") }
                    .buttonStyle(HMButton(full: false))
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading).glass()
        }
    }

    private var pairCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Connect to Home Assistant", systemImage: "house.and.flag").font(.headline).foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 8) {
                step(1, "On your dashboard open **Home Map**, tap **Edit**, then **Scans → Pair iPhone**.")
                step(2, "Scan the code it shows with this phone.")
            }
            Button { pairing = true } label: { Label("Scan pairing code", systemImage: "qrcode.viewfinder") }
                .buttonStyle(HMButton(kind: .primary))
                .disabled(!DataScannerViewController.isSupported && demo == nil)
        }
        .padding(16).glass()
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.caption.weight(.bold)).foregroundStyle(Theme.onAccent).frame(width: 20, height: 20).background(Circle().fill(Theme.accent))
            Text(.init(text)).font(.callout).foregroundStyle(Theme.text)
        }
    }

    /// photos of a scan still on the phone (they go to the PC by themselves; the map doesn't need them)
    private var photoCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "photo.stack").foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("Scan photos for the PC: \(photos.left) files").font(.callout.weight(.semibold)).foregroundStyle(Theme.text)
                Text(photos.status.isEmpty ? "They go to the PC by themselves and leave the phone once it has them. Your map works without them."
                                           : photos.status)
                    .font(.caption).foregroundStyle(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16).glass()
    }

    private var pendingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Not sent yet", systemImage: "exclamationmark.icloud").font(.headline).foregroundStyle(Theme.accent)
            ForEach(pending) { p in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.unfinished ? String(p.name.dropLast(13)) : p.name).font(.callout.weight(.semibold)).foregroundStyle(Theme.text)
                            Text(p.created.formatted(date: .abbreviated, time: .shortened) + (p.rooms.map { " · \($0) room\($0 == 1 ? "" : "s")" } ?? ""))
                                .font(.caption).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        Button(p.unfinished ? "Send" : "Send now") { resend(p) }.buttonStyle(HMButton(kind: .primary, full: false))
                            .disabled(sending)
                        Button { confirmDelete = p } label: { Image(systemName: "trash") }
                            .buttonStyle(HMButton(kind: .danger, full: false)).accessibilityLabel("Delete \(p.name)")
                    }
                    Text(p.unfinished
                         ? "Stopped before Finish (the app was closed). Send the rooms it has, or delete it. A scan can't be picked up where it stopped - for the rest, use Add to your map."
                         : "Finished, waiting for Home Assistant. It sends by itself when Home Assistant can be reached.")
                        .font(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(Theme.raise, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            if !busy.isEmpty { HStack(spacing: 8) { ProgressView().tint(Theme.accent); Text(busy).font(.footnote).foregroundStyle(Theme.muted) } }
        }
        .padding(16).glass()
    }

    /// nothing scanned yet: one walk builds the whole map
    private var firstScanCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Scan your home", systemImage: "camera.metering.matrix").font(.headline).foregroundStyle(.white)
            Text("One walk through the whole home builds the map: every room and floor, doors, windows, stairs, furniture, lights and the garden. Rooms and floors are found as you walk; your Wi-Fi signal is recorded on the way.")
                .font(.callout).foregroundStyle(Theme.text)
            TextField("Name of your home", text: $homeName)
                .padding(.horizontal, 12).frame(minHeight: 44)
                .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
            if reachable == nil && settings.paired { ProgressView().tint(Theme.accent).frame(maxWidth: .infinity) }
            Button { begin(.new) } label: { Label("Start scanning", systemImage: "camera.metering.matrix") }
                .buttonStyle(HMButton(kind: .primary))
            noLidar
        }
        .padding(16).glass()
        .disabled(!canScan)
    }

    private func homeCard(_ s: HomeSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(homeName, systemImage: "house.fill").font(.headline).foregroundStyle(.white)
                Spacer()
                if let n = s.newest { Text("last scan \(Date(timeIntervalSince1970: n.created).formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(Theme.muted) }
            }
            HStack(spacing: 8) {
                FactTile(value: "\(s.floors)", label: s.floors == 1 ? "floor" : "floors")
                FactTile(value: "\(s.homeScans.count)", label: s.homeScans.count == 1 ? "scan" : "scans")
                FactTile(value: "\(s.things)", label: "things")
            }
            if let link = mapLink {
                Button { openURL(link.app) { ok in if !ok, let w = link.web { openURL(w) } } } label: { Label("Open the map", systemImage: "map") }
                    .buttonStyle(HMButton(kind: .blue))
            }
            Text("What do you want to do?").font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted).padding(.top, 2)
            VStack(spacing: 8) {
                action("Add to your map", "plus.square.on.square",
                       "Rooms that are missing, another floor or the garden. Start in a room that's already on the map, so the new part lines up.") { begin(.add) }
                action("Redo one room", "arrow.triangle.2.circlepath",
                       "A room that came out wrong: scan it again and only that room is replaced.") { begin(.rescan) }
                action("Tag & measure", "mappin.and.ellipse",
                       canTag(s) ? "No room scanning: walk around tagging ACs, cameras, mirrors and more, or measuring things."
                                 : "Needs a scan made with this app first, to find its place on the map.") { begin(.tags) }
                    .disabled(!canTag(s))
                action("Scan the whole home again", "arrow.counterclockwise",
                       "Start fresh: replaces the whole map. The current one is kept as a backup.") { confirmStartOver = true }
            }
            noLidar
        }
        .padding(16).glass()
        .disabled(!canScan)
    }

    private func canTag(_ s: HomeSummary) -> Bool { s.hasWorldMap || WorldMapStore.hasLocal || demo != nil }

    private var canScan: Bool { RoomCaptureSession.isSupported || demo != nil }

    @ViewBuilder private var noLidar: some View {
        if !canScan { Label("This iPhone has no LiDAR scanner.", systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Theme.red) }
    }

    private func action(_ title: String, _ icon: String, _ sub: String, _ go: @escaping () -> Void) -> some View {
        Button(action: go) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.title3).foregroundStyle(Theme.accent).frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.semibold)).foregroundStyle(Theme.text)
                    Text(sub).font(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
            }
            .padding(12)
            .background(Theme.raise, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(title)
    }

    // MARK: actions

    /// start a scan; add / re-scan / tags first get the saved world map (Home Assistant, else the copy on this phone)
    private func begin(_ mode: ScanMode, replaceAll: Bool = false) {
        let client = HAClient(settings)
        let name = homeName.isEmpty ? "My home" : homeName
        let base = summary?.newest?.id
        guard mode != .new else {
            scan = HomeScanModel(name: name, client: client, mode: .new, replaceAll: replaceAll)
            return
        }
        withAnimation(Theme.spring) { busy = "Getting the map of your home…" }
        Task {
            let map = await WorldMapStore.latest(client: reachable == true ? client : nil, scans: summary?.scans ?? [])
            withAnimation(Theme.spring) { busy = "" }
            if mode == .tags && map == nil { say("This needs a scan made with this app first, to find its place on the map."); return }
            let label = mode == .rescan ? "\(name): room again" : mode == .tags ? "\(name): tags" : "\(name): more"
            scan = HomeScanModel(name: label, client: client, mode: mode, pack: map, baseScan: base)
        }
    }

    private func resend(_ p: PendingScan) {
        guard let c = HAClient(settings) else { return }
        withAnimation(Theme.spring) { busy = "Sending…" }
        sending = true
        Task {
            do {
                try await Uploader.send(p, client: c) { t in Task { @MainActor in busy = t } }
                say("Sent to Home Assistant.")
            } catch { say(HAClient.unreachable(error) ? "Home Assistant can't be reached - it'll be sent when it's back." : "Couldn't send: \(error.localizedDescription)") }
            sending = false
            withAnimation(Theme.spring) { busy = ""; pending = PendingScan.all() }
            await refresh()
        }
    }

    // MARK: demo (screenshots in the simulator: -demo <screen>)

    private func setUpDemo(_ d: String) {
        let s = HomeSummary(scans: [
            ScanMeta(id: "h1", name: "My home", kind: "rooms", parts: 2, complete: true, created: Date().timeIntervalSince1970 - 86400 * 2),
            ScanMeta(id: "w1", name: "World: My home", kind: "mesh", parts: 2, complete: true, created: Date().timeIntervalSince1970 - 86400 * 2)],
            levels: ["First floor", "Second floor", "Garden"], things: 64, rooms: 0)
        switch d {
        case "home-unpaired": settings.demo(paired: false)
        case "home-new": settings.demo(paired: true); reachable = true
        case "home":
            settings.demo(paired: true); summary = s; reachable = true
            pending = [PendingScan(id: "h9", name: "My home: more (unfinished)", kind: "rooms", parts: 1, created: Date().addingTimeInterval(-3600), rooms: 3)]
        case "home-offline":
            settings.demo(paired: true); summary = s; reachable = false
            pending = [PendingScan(id: "h8", name: "My home", kind: "rooms", parts: 3, created: Date().addingTimeInterval(-600), rooms: 9)]
        default:
            settings.demo(paired: true); summary = s; reachable = true
            if d.hasPrefix("scan-") { scan = Demo.scan(d) }
        }
    }
}

/// a gentle press for list-style rows
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.75), value: configuration.isPressed)
    }
}

struct QRScanner: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced, isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        DispatchQueue.main.async { try? vc.startScanning() }
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var done = false
        init(_ f: @escaping (String) -> Void) { onCode = f }

        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let code) = item, let text = code.payloadStringValue, !done {
                    done = true
                    scanner.stopScanning()
                    onCode(text)
                }
            }
        }
    }
}
