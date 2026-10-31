import SwiftUI

struct HomeScanScreen: View {
    @StateObject var model: HomeScanModel
    @ObservedObject var recognizer: Recognizer
    @ObservedObject var live = LiveSession.shared
    @ObservedObject var photos = PhotoSender.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    var mapLink: (app: URL, web: URL?)?

    init(model: HomeScanModel, mapLink: (app: URL, web: URL?)? = nil) {
        _model = StateObject(wrappedValue: model)
        recognizer = model.recognizer
        self.mapLink = mapLink
    }

    /// anything open that you're reading or choosing in: nothing happens by itself meanwhile
    private var holdKey: String {
        "\(model.tagging)\(model.showTags)\(model.renaming ?? -1)\(model.showMenu)\(model.confirmDiscard)\(model.confirmRedo)"
    }

    var body: some View {
        ZStack {
            if model.demo { DemoCamera() } else { HomeScanContainer(controller: model.controller).ignoresSafeArea() }
            if model.scanningPhases { crosshair }
            VStack(spacing: 10) {
                topBar
                messages
                Spacer(minLength: 0)
                panel
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .animation(Theme.spring, value: model.phase)
        .onChange(of: holdKey) { _, _ in model.hold(false) }
        .sheet(isPresented: $model.showTags) { TagList(model: model).presentationDetents([.medium, .large]) }
        .sheet(isPresented: $model.tagging) {
            TagPicker(distance: model.aimText.isEmpty ? "?" : model.aimText,
                      onPick: { k, n in model.finishTag(k, name: n) }, onCancel: { model.finishTag(nil, name: "") })
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: Binding(get: { model.renaming != nil }, set: { if !$0 { model.renaming = nil } })) {
            if let i = model.renaming {
                RoomNamer(current: model.rooms.first { $0.id == i }?.name ?? "") { model.renameRoom(i, $0); model.renaming = nil }
                    .presentationDetents([.medium])
            }
        }
        .sheet(isPresented: $model.showMenu) {
            ScanMenu(model: model, close: { dismiss() }).presentationDetents([.height(model.phase == .scanning ? 330 : 270)])
        }
        .interactiveDismissDisabled()
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true; live.attach(model) }    // no sleeping screen mid-scan
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false; live.attach(nil) }
        .alert("Start this room over?", isPresented: $model.confirmRedo) {
            Button("Start over", role: .destructive) { Task { await model.redoRoom() } }
            Button("Keep scanning", role: .cancel) {}
        } message: { Text("What's scanned of the room you're in is thrown away. Finished rooms, tags and named things stay.") }
        .alert(model.roomsDone > 0 ? "Throw away \(model.roomsDone) scanned room\(model.roomsDone == 1 ? "" : "s")?" : "Throw this scan away?",
               isPresented: $model.confirmDiscard) {
            Button("Throw it away", role: .destructive) { model.discard(); dismiss() }
            Button("Keep it", role: .cancel) {}
        } message: { Text("Nothing of this scan is kept on the phone or sent to Home Assistant. This can't be undone.") }
    }

    // MARK: top

    private var topBar: some View {
        HStack(alignment: .center, spacing: 10) {
            if ![.uploading, .done, .failed].contains(model.phase) {
                RoundButton(icon: model.phase == .intro ? "xmark" : "ellipsis", label: model.phase == .intro ? "Close" : "Menu") {
                    if model.phase == .intro { dismiss() } else { model.showMenu = true }
                }
            } else { Color.clear.frame(width: 38, height: 38) }
            Spacer(minLength: 0)
            if model.scanningPhases { where_.transition(.drop) }
            Spacer(minLength: 0)
            if model.scanningPhases && (HomeScanController.hasTorch || model.demo) {
                RoundButton(icon: model.torch ? "flashlight.on.fill" : "flashlight.off.fill", label: model.torch ? "Flashlight off" : "Flashlight on") { model.toggleTorch() }
                    .foregroundStyle(model.torch ? Theme.accent : Theme.text)
            } else { Color.clear.frame(width: 38, height: 38) }
        }
    }

    /// where you are: the floor (tap to correct it) and the room / garden, with how far along the room is
    private var where_: some View {
        Menu {
            Section("You're on") {
                ForEach(0..<Levels.ids.count, id: \.self) { i in
                    Button { model.setFloor(i) } label: { if i == model.floor { Label(Levels.name(i), systemImage: "checkmark") } else { Text(Levels.name(i)) } }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: model.phase == .outside ? "tree" : "stairs").foregroundStyle(Theme.accent)
                Text(model.phase == .outside ? "Garden" : model.mode == .tags ? model.floorName : "\(model.floorName) · Room \(model.roomsDone + 1)")
                if model.phase == .scanning && model.progress.percent > 0 {
                    Text("\(model.progress.percent)%").foregroundStyle(model.progress.percent >= 90 ? Theme.green : Theme.accent).monospacedDigit()
                        .contentTransition(.numericText())
                }
                if model.phase == .paused { Text("Paused").foregroundStyle(Theme.accent) }
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 13).padding(.vertical, 9)
            .background(Capsule().fill(.ultraThinMaterial).overlay(Capsule().strokeBorder(Theme.line)))
        }
        .disabled(model.phase == .outside)
        .accessibilityLabel("\(model.floorName). Tap to change the floor you're on")
    }

    @ViewBuilder private var messages: some View {
        VStack(spacing: 8) {
            if live.on && !live.message.isEmpty {
                // instructions from Claude during a live session
                Label(live.message, systemImage: "bubble.left.fill")
                    .font(.callout.weight(.semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Theme.blue.opacity(0.85), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .transition(.drop)
            }
            if !model.tip.isEmpty && [.scanning, .outside, .locking].contains(model.phase) {
                Capsule2(text: model.tip, icon: "lightbulb.max").transition(.drop)
            }
            if model.gardenHint && model.phase == .scanning {
                HStack(spacing: 10) {
                    Image(systemName: "tree").foregroundStyle(Theme.accent)
                    Text("Outside? Scan the garden").font(.footnote.weight(.semibold)).foregroundStyle(Theme.text)
                    Button("Garden") { Task { await model.goOutside() } }.font(.footnote.weight(.bold)).foregroundStyle(Theme.accent)
                    Button("No") { withAnimation(Theme.spring) { model.gardenHint = false } }.font(.footnote).foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Capsule().fill(.ultraThinMaterial).overlay(Capsule().strokeBorder(Theme.line)))
                .transition(.drop)
            }
            if model.phase == .outside && !model.gardenText.isEmpty {
                Capsule2(text: model.gardenText, icon: "arrow.down.to.line").transition(.drop)
            }
            if let s = model.saved, [.scanning, .paused, .outside].contains(model.phase) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
                    Text("\(s.name.isEmpty ? "Room" : s.name) saved").font(.footnote.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    Button("Rename") { model.renaming = s.id }.font(.footnote.weight(.bold)).foregroundStyle(Theme.accent)
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Capsule().fill(.ultraThinMaterial).overlay(Capsule().strokeBorder(Theme.line)))
                .transition(.drop)
            }
            if !model.undoText.isEmpty {
                HStack(spacing: 10) {
                    Text(model.undoText).font(.footnote.weight(.semibold)).foregroundStyle(Theme.text)
                    Button("Undo") { model.undoLastTag() }.font(.footnote.weight(.bold)).foregroundStyle(Theme.accent)
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Capsule().fill(.ultraThinMaterial).overlay(Capsule().strokeBorder(Theme.line)))
                .transition(.drop)
            }
            if !model.flash.isEmpty {
                Capsule2(text: model.flash, accent: true).transition(.drop)
            }
        }
        .animation(Theme.spring, value: model.tip)
        .animation(Theme.spring, value: model.flash)
        .animation(Theme.spring, value: model.saved)
        .animation(Theme.spring, value: live.message)
    }

    // MARK: middle

    /// the circle in the middle + how far away the thing under it is + what the phone just recognized
    private var crosshair: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().strokeBorder(model.measuring ? Theme.accent : .white, lineWidth: 2).frame(width: 28, height: 28)
                Circle().fill(.white).frame(width: 4, height: 4)
                if recognizer.enabled && !recognizer.thinking && recognizer.dwell > 0.02 {
                    // fills while you hold still; blue = it's already named, holding on names it again
                    Circle().trim(from: 0, to: recognizer.dwell)
                        .stroke(recognizer.dwellAgain ? Theme.blue : Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 40, height: 40)
                        .animation(.linear(duration: 0.33), value: recognizer.dwell)
                }
                if recognizer.thinking { Spinner().frame(width: 40, height: 40) }
            }
            .shadow(color: .black.opacity(0.5), radius: 2)
            if !model.aimText.isEmpty {
                Text(model.aimText).font(.caption2.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(.black.opacity(0.45), in: Capsule()).foregroundStyle(.white)
            }
            if !recognizer.lastName.isEmpty {
                Label(recognizer.lastName, systemImage: "sparkles").font(.footnote.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Theme.accent)).foregroundStyle(Theme.onAccent)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .animation(Theme.spring, value: recognizer.lastName)
        .offset(y: 14)
        .allowsHitTesting(false)
    }

    // MARK: bottom

    /// one tool: an icon over a short word (four fit side by side on the smallest iPhone)
    private func tool(_ title: String, _ icon: String, on: Bool = false, _ go: @escaping () -> Void) -> some View {
        Button(action: go) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 19, weight: .medium))
                Text(title).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .foregroundStyle(on ? Theme.onAccent : Theme.text)
            .background(on ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.white.opacity(0.10)), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(on ? .clear : Theme.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(title)
    }

    private var tagTool: some View { tool("Tag", "mappin.and.ellipse") { model.beginTag() } }
    private var measureTool: some View { tool(model.measuring ? "Set end" : "Measure", "ruler", on: model.measuring) { model.measureTap() } }

    private var finishButton: some View {
        Button { Task { await model.finish() } } label: { Label("Finish", systemImage: "checkmark") }
            .buttonStyle(HMButton(kind: .primary))
    }

    /// how far along the room is: its shape (walls all round, floor, ceiling - not the furniture) and what's still missing
    private var roomProgress: some View {
        let p = model.progress
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(p.percent == 0 ? "Scanning this room" : "Room shape \(p.percent)%").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                        .contentTransition(.numericText())
                    if p.size.x > 0 { Text(String(format: "%.1f × %.1f m", p.size.x, p.size.y)).font(.caption.monospacedDigit()).foregroundStyle(Theme.muted) }
                }
                ProgressView(value: Double(p.percent), total: 100).tint(p.percent >= 90 ? Theme.green : Theme.accent)
                HStack(spacing: 10) {
                    part("Walls", p.walls)
                    if let f = p.floor { part("Floor", f) }
                    if let c = p.ceiling { part("Ceiling", c) }
                }
                Text(p.percent == 0 ? "Walk along the walls, pointing at walls, floor and ceiling."
                     : p.missing.isEmpty ? "This room's shape is done - walk on to the next room."
                     : "Still missing: \(p.missing)")
                    .font(.caption).foregroundStyle(p.missing.isEmpty && p.percent > 0 ? Theme.green : Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button { Task { await model.togglePause() } } label: {
                Image(systemName: "pause.fill").font(.system(size: 17, weight: .semibold)).frame(width: 46, height: 46)
                    .background(Color.white.opacity(0.10), in: Circle()).overlay(Circle().strokeBorder(Theme.line))
            }
            .buttonStyle(PressStyle()).foregroundStyle(Theme.text)
            .accessibilityLabel("Pause")
        }
        .animation(Theme.spring, value: p)
    }

    private func part(_ name: String, _ v: Float) -> some View {
        Label(name, systemImage: v >= 0.97 ? "checkmark.circle.fill" : "circle.dashed")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(v >= 0.97 ? Theme.green : Theme.muted)
    }

    @ViewBuilder private var panel: some View {
        VStack(spacing: 12) {
            switch model.phase {
            case .intro: ScanIntro(model: model, recognizer: recognizer)
            case .locking:
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let slow = ctx.date.timeIntervalSince(model.lockStart) > 10
                    VStack(spacing: 12) {
                        ProgressView().tint(Theme.accent).controlSize(.large)
                        Text("Finding your place on the map").font(.headline).foregroundStyle(.white)
                        Text(!model.lockText.isEmpty ? model.lockText
                             : slow ? "Taking a while? You may be somewhere the map doesn't have yet. Start anyway: Home Assistant lines this scan up with your map afterwards by matching the walls."
                                  : "Look around slowly at the walls, doorways and furniture of a room that's already on your map.")
                            .font(.callout).foregroundStyle(Theme.text).multilineTextAlignment(.center)
                            .contentTransition(.opacity)
                        Button { model.skipLock() } label: { Label("Start without locking on", systemImage: "play.fill") }
                            .buttonStyle(HMButton(kind: slow ? .primary : .secondary))
                    }
                    .animation(Theme.spring, value: slow)
                }
            case .scanning:
                roomProgress
                HStack(spacing: 8) {
                    tagTool
                    measureTool
                    if model.mode != .rescan {
                        tool("New room", "arrow.right.square") { Task { await model.nextRoom() } }
                        tool("Garden", "tree") { Task { await model.goOutside() } }
                    }
                }
                finishButton
            case .paused:
                VStack(alignment: .leading, spacing: 4) {
                    Label("Paused", systemImage: "pause.circle.fill").font(.headline).foregroundStyle(Theme.accent)
                    Text("Nothing is being scanned. Walk wherever you like - Resume carries on with this room, or starts a new one if you've moved on.")
                        .font(.footnote).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    tagTool
                    measureTool
                    if model.mode != .rescan { tool("Garden", "tree") { Task { await model.goOutside() } } }
                }
                HStack(spacing: 10) {
                    Button { model.resume() } label: { Label("Resume", systemImage: "play.fill") }.buttonStyle(HMButton(kind: .primary))
                    Button { Task { await model.finish() } } label: { Label("Finish", systemImage: "checkmark") }.buttonStyle(HMButton())
                }
            case .processing:
                HStack(spacing: 10) { ProgressView().tint(Theme.accent); Text("Saving this room…").foregroundStyle(Theme.text) }
                    .frame(maxWidth: .infinity, minHeight: 46)
            case .outside:
                Text("Walk the garden, paths and steps slowly. Going back in? Tap Back inside.")
                    .font(.footnote).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    tagTool
                    measureTool
                    tool("Back inside", "door.left.hand.open") { model.backInside() }
                }
                finishButton
            case .tagging:
                HStack(spacing: 8) { tagTool; measureTool }
                finishButton
            case .review: ScanReview(model: model, recognizer: recognizer)
            case .uploading:
                ProgressView().tint(Theme.accent).controlSize(.large)
                Text(model.result).font(.callout).foregroundStyle(Theme.text).multilineTextAlignment(.center)
                    .contentTransition(.opacity)
            case .done:
                Image(systemName: "checkmark.circle.fill").font(.system(size: 46)).foregroundStyle(Theme.green)
                    .symbolEffect(.bounce, value: model.phase)
                Text("Sent to Home Assistant").font(.title3.weight(.semibold)).foregroundStyle(.white)
                Text(model.result).font(.callout).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                if !photos.status.isEmpty {
                    Label(photos.status, systemImage: "photo.stack").font(.caption).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                }
                if let link = mapLink {
                    Button { openURL(link.app) { ok in if !ok, let w = link.web { openURL(w) } } } label: { Label("Open the map", systemImage: "map") }
                        .buttonStyle(HMButton(kind: .primary))
                }
                Button("Close") { dismiss() }.buttonStyle(HMButton())
            case .failed:
                Image(systemName: "externaldrive.badge.checkmark").font(.system(size: 40)).foregroundStyle(Theme.accent)
                Text(model.result).font(.callout).foregroundStyle(Theme.text).multilineTextAlignment(.center)
                Button { Task { await model.retry() } } label: { Label("Try again", systemImage: "arrow.clockwise") }
                    .buttonStyle(HMButton(kind: .primary))
                Button("Close") { dismiss() }.buttonStyle(HMButton())
            }
        }
        .padding(16)
        .frame(maxWidth: 560)
        .glass(22)
        .transition(.rise)
    }
}

/// the menu behind the top-left button: finish, start this room over, or throw the scan away (that one asks again)
struct ScanMenu: View {
    @ObservedObject var model: HomeScanModel
    var close: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This scan").font(.headline).foregroundStyle(.white)
            Text("\(model.roomsDone) room\(model.roomsDone == 1 ? "" : "s") saved so far\(model.tagCount > 0 ? ", \(model.tagCount) tag\(model.tagCount == 1 ? "" : "s")" : "").")
                .font(.footnote).foregroundStyle(Theme.muted)
            if [.scanning, .paused, .outside, .tagging].contains(model.phase) {
                Button { dismiss(); Task { await model.finish() } } label: { Label("Finish and review", systemImage: "checkmark") }
                    .buttonStyle(HMButton(kind: .primary))
            }
            if model.phase == .scanning {
                Button { dismiss(); model.confirmRedo = true } label: { Label("Start this room over", systemImage: "arrow.counterclockwise") }
                    .buttonStyle(HMButton())
            }
            if model.tagCount > 0 {
                Button { dismiss(); model.showTags = true } label: { Label("Tags in this scan", systemImage: "mappin") }
                    .buttonStyle(HMButton())
            }
            Button(role: .destructive) { dismiss(); model.confirmDiscard = true } label: { Label("Throw this scan away", systemImage: "trash") }
                .buttonStyle(HMButton(kind: .danger))
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.background)
        .preferredColorScheme(.dark)
    }
}

/// the first screen of a scan: what to do, and the few choices that matter for this kind of scan
struct ScanIntro: View {
    @ObservedObject var model: HomeScanModel
    @ObservedObject var recognizer: Recognizer

    private var title: String {
        switch model.mode {
        case .new: return model.replaceAll ? "Scan the whole home again" : "Scan your home"
        case .add: return "Add to your map"
        case .rescan: return "Redo one room"
        case .tags: return "Tag & measure"
        }
    }

    private var steps: [(String, String)] {
        switch model.mode {
        case .tags:
            return [("location.viewfinder", "Start in a room that's on your map and look around until it finds your place."),
                    ("mappin.and.ellipse", "Aim the circle at a thing and tap **Tag**, or **Measure** between two points.")]
        case .rescan:
            return [("location.viewfinder", "Stand in the room and look around until it finds your place on the map."),
                    ("arrow.triangle.2.circlepath", "Scan the room, then **Finish**. Only this room is replaced; your edits on the map stay.")]
        case .add:
            return [("location.viewfinder", "Start in a room that's on your map and look around until it finds your place."),
                    ("figure.walk", "Then just walk into what's missing: rooms, another floor, the garden. Rooms and floors are found by themselves."),
                    ("checkmark", "**Finish** when you're done. You can name the rooms at the end.")]
        case .new:
            return [("figure.walk", "Walk through the home at an easy pace, pointing at walls, floors and ceilings."),
                    ("door.left.hand.open", "Nothing to tap between rooms: going through a door starts a new room, the stairs a new floor. The top shows how much of each room is done."),
                    ("tree", "Stepping outside? Tap **Garden**. **Finish** when you're done - you can name the rooms at the end.")]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title2.bold()).foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(steps, id: \.1) { icon, text in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 24)
                        Text(.init(text)).font(.callout).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Divider().overlay(Theme.line)
            if model.mode != .tags {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.mode == .new ? "You're starting on" : "You're starting on (if it can't find your place)").font(.caption).foregroundStyle(Theme.muted)
                    Picker("Starting on", selection: $model.startLevel) {
                        Text("First floor").tag("ground"); Text("Second floor").tag("first"); Text("Garden").tag("outdoor")
                    }
                    .pickerStyle(.segmented)
                }
            }
            if model.mode == .rescan {
                Toggle(isOn: $model.keepRoom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Only add its furniture").font(.callout.weight(.semibold)).foregroundStyle(Theme.text)
                        Text("The walls and floor on the map stay as they are.").font(.caption).foregroundStyle(Theme.muted)
                    }
                }
                .tint(Theme.accent)
            }
            if Recognizer.available {
                Toggle(isOn: $recognizer.enabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Name things as I scan").font(.callout.weight(.semibold)).foregroundStyle(Theme.text)
                        Text("Hold the circle still on something until the ring fills; Apple Intelligence on this iPhone names it.")
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                }
                .tint(Theme.accent)
            }
            Button { model.start() } label: { Label("Start", systemImage: "camera.metering.matrix") }
                .buttonStyle(HMButton(kind: .primary))
        }
    }
}

/// After Finish: the rooms (name them if you like - the phone's guess is filled in) and what the phone named
struct ScanReview: View {
    @ObservedObject var model: HomeScanModel
    @ObservedObject var recognizer: Recognizer

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Almost done").font(.title3.bold()).foregroundStyle(.white)
                Text("Check the names, then send. A room left without a name gets one on the map from what's in it.")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if !model.rooms.isEmpty {
                        Text("Rooms").font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                        ForEach(model.rooms) { r in
                            Button { model.renaming = r.id } label: {
                                HStack(spacing: 11) {
                                    Image(systemName: "square.split.2x2").foregroundStyle(Theme.accent).frame(width: 26)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(r.name.isEmpty ? "No name" : r.name).font(.callout.weight(.semibold))
                                            .foregroundStyle(r.name.isEmpty ? Theme.muted : Theme.text)
                                        Text("\(Levels.name(r.floor)) · \(String(format: "%.0f", r.area)) m²\(r.guessed && !r.name.isEmpty ? " · the phone's guess" : "")")
                                            .font(.caption).foregroundStyle(Theme.muted)
                                        if !r.warn.isEmpty { Text(r.warn).font(.caption2).foregroundStyle(Theme.accent).fixedSize(horizontal: false, vertical: true) }
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "pencil").foregroundStyle(Theme.muted)
                                }
                                .padding(10)
                                .background(Theme.raise, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PressStyle())
                            .accessibilityLabel("Rename \(r.name.isEmpty ? "room" : r.name)")
                        }
                    }
                    if !recognizer.items.isEmpty {
                        Text("Things the phone named").font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted).padding(.top, 6)
                        ForEach(recognizer.items) { it in FoundRow(item: it, recognizer: recognizer).transition(.opacity.combined(with: .move(edge: .trailing))) }
                    }
                }
                .animation(Theme.spring, value: recognizer.items)
            }
            .frame(maxHeight: 380)
            .scrollBounceBehavior(.basedOnSize)
            Button { Task { await model.send() } } label: { Label("Send to Home Assistant", systemImage: "paperplane.fill") }
                .buttonStyle(HMButton(kind: .primary))
        }
    }
}

/// a room's name: type your own, or tap a common one
struct RoomNamer: View {
    let current: String
    var done: (String) -> Void
    @State private var name = ""
    @FocusState private var typing: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                TextField("Room name", text: $name)
                    .focused($typing)
                    .submitLabel(.done)
                    .onSubmit { done(name) }
                    .padding(.horizontal, 12).frame(minHeight: 44)
                    .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 7)], alignment: .leading, spacing: 7) {
                        ForEach(TagCatalog.roomNames, id: \.self) { n in
                            Button(n) { done(n) }
                                .font(.subheadline)
                                .lineLimit(1).minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity, minHeight: 34)
                                .background(Capsule().fill(n == current ? Theme.accent : Color.white.opacity(0.10)))
                                .foregroundStyle(n == current ? Theme.onAccent : Theme.text)
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(16)
            .background(Theme.background)
            .navigationTitle("Name this room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { done(name) } }
            }
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .onAppear { name = current }
    }
}

struct FoundRow: View {
    let item: FoundThing
    @ObservedObject var recognizer: Recognizer
    @State private var name = ""

    var body: some View {
        HStack(spacing: 11) {
            Group {
                if let d = item.thumb, let ui = UIImage(data: d) { Image(uiImage: ui).resizable().scaledToFill() }
                else { Image(systemName: "sparkles").foregroundStyle(Theme.accent).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.raise) }
            }
            .frame(width: 46, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                TextField("Name", text: $name)
                    .font(.callout.weight(.semibold)).foregroundStyle(Theme.text)
                    .submitLabel(.done)
                    .onSubmit { recognizer.rename(item.id, to: name) }
                Text("\(Int(item.confidence * 100))% sure\(item.seen > 1 ? " · seen \(item.seen)×" : "")").font(.caption).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
            Button { recognizer.remove(item.id) } label: { Image(systemName: "trash").foregroundStyle(Theme.red).frame(width: 34, height: 34) }
                .buttonStyle(.plain).accessibilityLabel("Remove \(item.name)")
        }
        .padding(8)
        .background(Theme.raise, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear { name = item.name.prefix(1).uppercased() + item.name.dropFirst() }
        .onChange(of: name) { _, v in if v.isEmpty == false { recognizer.rename(item.id, to: v) } }
    }
}

/// the tags (and measurements) of this scan: swipe or tap the bin to take one back
struct TagList: View {
    @ObservedObject var model: HomeScanModel
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.tagList) { t in
                        HStack(spacing: 12) {
                            Image(systemName: t.icon).frame(width: 26).foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.title)
                                if !t.detail.isEmpty { Text(t.detail).font(.caption).foregroundStyle(Theme.muted) }
                            }
                            Spacer()
                            Button(role: .destructive) { withAnimation { model.removeTag(at: t.id) } } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Delete \(t.title)")
                        }
                    }
                    .onDelete { s in s.sorted(by: >).forEach { model.removeTag(at: $0) } }
                } footer: { Text("Things the phone named by itself can be fixed on the map: Edit, then tap the thing.") }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Tags in this scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { model.showTags = false } } }
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
    }
}

/// spins while the phone works out what it's looking at
struct Spinner: View {
    @State private var turn = false
    var body: some View {
        Circle().trim(from: 0, to: 0.28)
            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .rotationEffect(.degrees(turn ? 360 : 0))
            .onAppear { withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { turn = true } }
    }
}

/// stands in for the camera in screenshots / the simulator
struct DemoCamera: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.42, green: 0.39, blue: 0.35), Color(red: 0.23, green: 0.21, blue: 0.2)], startPoint: .top, endPoint: .bottom)
            // a floor and a wall like the live overlay draws them
            Path { p in
                for i in 0...10 { let y = 520 + CGFloat(i) * 34; p.move(to: CGPoint(x: -100, y: y)); p.addLine(to: CGPoint(x: 600, y: y + 40)) }
            }.stroke(Color.white.opacity(0.35), lineWidth: 1)
        }
        .ignoresSafeArea()
    }
}
