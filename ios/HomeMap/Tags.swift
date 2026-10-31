import SwiftUI

/// Things RoomPlan can't recognize by itself (ACs, cameras, sensors, lamps...): aim the crosshair at one and tag it.
/// `kind` is the id of the same thing in the dashboard card's catalog.
struct TagKind: Identifiable, Hashable {
    let kind: String
    let name: String
    let icon: String
    var id: String { kind }
}

struct TagGroup: Identifiable {
    let title: String
    let items: [TagKind]
    var id: String { title }
}

enum TagCatalog {
    static let groups: [TagGroup] = [
        TagGroup(title: "Mirrors, doors & windows", items: [
            TagKind(kind: "mirrorwall", name: "Mirror wall (whole wall)", icon: "rectangle.portrait.on.rectangle.portrait"),
            TagKind(kind: "mirror", name: "Mirror", icon: "rectangle.portrait"),
            TagKind(kind: "style:frosted", name: "Frosted glass door", icon: "door.left.hand.closed"),
            TagKind(kind: "style:glass", name: "Glass door", icon: "door.sliding.left.hand.closed"),
            TagKind(kind: "style:doorway", name: "Doorway without a door", icon: "door.left.hand.open"),
            TagKind(kind: "style:sliding", name: "Sliding door", icon: "door.sliding.right.hand.closed"),
            TagKind(kind: "style:curtains", name: "Curtains (window or doorway)", icon: "curtains.closed"),
            TagKind(kind: "style:grille", name: "Window with bars / grille", icon: "square.grid.3x3"),
            TagKind(kind: "railing:wood", name: "Railing: wooden balusters", icon: "line.3.horizontal"),
            TagKind(kind: "railing:metal", name: "Railing: metal bars", icon: "line.3.horizontal"),
            TagKind(kind: "railing:glass", name: "Railing: glass", icon: "rectangle"),
        ]),
        TagGroup(title: "Air conditioning & climate", items: [
            TagKind(kind: "ac", name: "Split AC (wall unit)", icon: "air.conditioner.horizontal"),
            TagKind(kind: "acoutdoor", name: "Split AC outdoor unit", icon: "fan"),
            TagKind(kind: "windowac", name: "Window AC", icon: "air.conditioner.horizontal"),
            TagKind(kind: "towerac", name: "Floor-standing AC", icon: "air.conditioner.vertical"),
            TagKind(kind: "portableac", name: "Portable AC", icon: "air.conditioner.vertical"),
            TagKind(kind: "cassetteac", name: "Ceiling cassette AC", icon: "square.grid.3x3"),
            TagKind(kind: "vent", name: "Ceiling vent", icon: "square.grid.3x3"),
            TagKind(kind: "ceilingfan", name: "Ceiling fan", icon: "fan.ceiling"),
            TagKind(kind: "pedestalfan", name: "Fan", icon: "fan.floor"),
            TagKind(kind: "airpurifier", name: "Air purifier", icon: "air.purifier"),
            TagKind(kind: "dehumidifier", name: "Dehumidifier", icon: "humidity"),
            TagKind(kind: "radiator", name: "Heater / radiator", icon: "heater.vertical"),
            TagKind(kind: "waterheater", name: "Water heater", icon: "drop"),
            TagKind(kind: "thermostat", name: "Thermostat", icon: "thermometer.medium"),
        ]),
        TagGroup(title: "Network, security & smart home", items: [
            TagKind(kind: "router", name: "Router", icon: "wifi.router"),
            TagKind(kind: "meshnode", name: "Mesh node", icon: "wifi"),
            TagKind(kind: "camera", name: "Camera", icon: "video"),
            TagKind(kind: "domecam", name: "Dome camera", icon: "video.circle"),
            TagKind(kind: "doorbell", name: "Video doorbell", icon: "video.doorbell"),
            TagKind(kind: "smokedetector", name: "Smoke detector", icon: "smoke"),
            TagKind(kind: "motionsensor", name: "Motion sensor", icon: "sensor"),
            TagKind(kind: "doorsensor", name: "Door / window sensor", icon: "sensor"),
            TagKind(kind: "smartlock", name: "Smart lock", icon: "lock"),
            TagKind(kind: "alarmpanel", name: "Alarm keypad", icon: "shield"),
            TagKind(kind: "smartspeaker", name: "Smart speaker", icon: "homepod"),
            TagKind(kind: "walltablet", name: "Wall tablet", icon: "ipad.landscape"),
            TagKind(kind: "lightswitch", name: "Light switch", icon: "switch.2"),
            TagKind(kind: "outlet", name: "Power outlet", icon: "powerplug"),
            TagKind(kind: "nas", name: "NAS / server", icon: "server.rack"),
            TagKind(kind: "extinguisher", name: "Fire extinguisher", icon: "flame"),
        ]),
        TagGroup(title: "Lights", items: [
            TagKind(kind: "ceilinglight", name: "Ceiling light", icon: "light.recessed"),
            TagKind(kind: "spotlight", name: "Downlight", icon: "light.recessed"),
            TagKind(kind: "pendant", name: "Pendant light", icon: "lamp.ceiling"),
            TagKind(kind: "chandelier", name: "Chandelier", icon: "lamp.ceiling"),
            TagKind(kind: "sconce", name: "Wall light", icon: "light.panel"),
            TagKind(kind: "floorlamp", name: "Floor lamp", icon: "lamp.floor"),
            TagKind(kind: "tablelamp", name: "Table lamp", icon: "lamp.table"),
            TagKind(kind: "ledstrip", name: "LED strip", icon: "light.strip.2"),
            TagKind(kind: "outdoorlight", name: "Outdoor light", icon: "light.panel"),
        ]),
        TagGroup(title: "Electronics & appliances", items: [
            TagKind(kind: "tv65", name: "TV", icon: "tv"),
            TagKind(kind: "soundbar", name: "Soundbar", icon: "hifispeaker"),
            TagKind(kind: "speaker", name: "Speaker", icon: "hifispeaker"),
            TagKind(kind: "console", name: "Game console", icon: "gamecontroller"),
            TagKind(kind: "desktoppc", name: "Computer", icon: "desktopcomputer"),
            TagKind(kind: "monitor", name: "Monitor", icon: "display"),
            TagKind(kind: "printer", name: "Printer", icon: "printer"),
            TagKind(kind: "projector", name: "Projector", icon: "videoprojector"),
            TagKind(kind: "microwave", name: "Microwave", icon: "microwave"),
            TagKind(kind: "coffeemachine", name: "Coffee machine", icon: "cup.and.saucer"),
            TagKind(kind: "waterdispenser", name: "Water dispenser", icon: "drop"),
            TagKind(kind: "robotvac", name: "Robot vacuum dock", icon: "circle.circle"),
        ]),
        TagGroup(title: "Around the home", items: [
            TagKind(kind: "plant", name: "Plant", icon: "leaf"),
            TagKind(kind: "art", name: "Picture / wall art", icon: "photo.artframe"),
            TagKind(kind: "clock", name: "Wall clock", icon: "clock"),
            TagKind(kind: "curtains", name: "Curtains", icon: "curtains.closed"),
            TagKind(kind: "shelf", name: "Wall shelf", icon: "books.vertical"),
            TagKind(kind: "safe", name: "Safe", icon: "lock.square"),
            TagKind(kind: "aquarium", name: "Aquarium", icon: "fish"),
            TagKind(kind: "piano", name: "Piano", icon: "pianokeys"),
            TagKind(kind: "treadmill", name: "Treadmill", icon: "figure.run"),
            TagKind(kind: "exercisebike", name: "Exercise bike", icon: "bicycle"),
            TagKind(kind: "crib", name: "Baby crib", icon: "bed.double"),
            TagKind(kind: "steps", name: "Steps (a few)", icon: "stairs"),
            TagKind(kind: "ramp", name: "Ramp / slope", icon: "arrow.up.right"),
            TagKind(kind: "box", name: "Something else", icon: "cube"),
        ]),
        TagGroup(title: "Outside", items: [
            TagKind(kind: "roof:cone", name: "Cone / tent roof (aim under it)", icon: "triangle"),
            TagKind(kind: "roof:flat", name: "Flat roof (aim under it)", icon: "rectangle"),
            TagKind(kind: "gate", name: "Gate / street door", icon: "door.garage.double.bay.closed"),
            TagKind(kind: "watertank", name: "Water tank", icon: "cylinder"),
            TagKind(kind: "satellite", name: "Satellite dish", icon: "antenna.radiowaves.left.and.right"),
            TagKind(kind: "grill", name: "Grill", icon: "flame"),
            TagKind(kind: "car", name: "Car", icon: "car"),
            TagKind(kind: "bicycle", name: "Bicycle", icon: "bicycle"),
            TagKind(kind: "generator", name: "Generator", icon: "bolt"),
            TagKind(kind: "tree", name: "Tree", icon: "tree"),
        ]),
    ]

    /// a thing that isn't in the list, tagged with your own name: the list's own "Something else"
    static var other: TagKind { groups.flatMap(\.items).first { $0.name == "Something else" } ?? groups[0].items[0] }

    static let roomNames = ["Living room", "Bedroom", "Kitchen", "Bathroom", "Dining room", "Majlis", "Office", "Kids' room",
                            "Guest room", "Hallway", "Entrance", "Laundry", "Storage", "Outside storage", "Garage", "Stairs", "Chill-out room"]
}

/// The list shown after tapping Tag. The spot was already captured, so the phone can move freely while choosing (and
/// nothing happens by itself meanwhile). One search box: pick what it is from the list, or tag it with your own words.
struct TagPicker: View {
    var distance: String
    var onPick: (TagKind, String) -> Void
    var onCancel: () -> Void
    @State private var search = ""

    private var query: String { search.trimmingCharacters(in: .whitespaces) }

    private var filtered: [TagGroup] {
        let q = query.lowercased()
        guard !q.isEmpty else { return TagCatalog.groups }
        return TagCatalog.groups.compactMap { g in
            let items = g.items.filter { $0.name.lowercased().contains(q) || $0.kind.contains(q) }
            return items.isEmpty ? nil : TagGroup(title: g.title, items: items)
        }
    }

    /// typed something that isn't exactly one of the list: it can be the name itself
    private var custom: String? {
        guard !query.isEmpty, !TagCatalog.groups.flatMap(\.items).contains(where: { $0.name.lowercased() == query.lowercased() }) else { return nil }
        return query
    }

    var body: some View {
        NavigationStack {
            List {
                if let c = custom {
                    Section {
                        Button { onPick(TagCatalog.other, c) } label: { Label("Tag as \u{201C}\(c)\u{201D}", systemImage: "tag") }
                            .foregroundStyle(Theme.accent)
                    } footer: { Text("Your own name for it. Or pick one from the list below, so the map shows the right thing.") }
                }
                ForEach(filtered) { group in
                    Section(group.title) {
                        ForEach(group.items) { k in
                            Button { onPick(k, "") } label: {
                                HStack {
                                    Image(systemName: k.icon).frame(width: 28)
                                    Text(k.name)
                                    Spacer()
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search, or type your own name")
            .navigationTitle("What is it?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text("What is it?").font(.headline)
                        Text("\(distance) away").font(.caption).foregroundStyle(Theme.muted)
                    }
                }
            }
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
    }
}
