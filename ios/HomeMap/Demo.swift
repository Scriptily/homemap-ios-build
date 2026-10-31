import SwiftUI

/// Screens filled with made-up data, for screenshots in the simulator (no camera, no LiDAR, no Home Assistant).
/// Started with the launch argument `-demo <screen>`; never shown otherwise.
@MainActor
enum Demo {
    static var screen: String? {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-demo"), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    static func scan(_ d: String) -> HomeScanModel {
        let mode: ScanMode = d.contains("add") ? .add : d.contains("tags") ? .tags : .new
        let m = HomeScanModel(name: "My home", client: nil, mode: mode, demo: true)
        let found = [
            FoundThing(name: "floor lamp", p: [1, 0.8, 2], n: [0, 0, 1], confidence: 0.92, seen: 3),
            FoundThing(name: "split air conditioner", p: [2, 2.2, 0], n: [0, 0, 1], confidence: 0.88),
            FoundThing(name: "shoe rack", p: [0, 0.4, 1], n: [1, 0, 0], confidence: 0.74, seen: 2),
            FoundThing(name: "aquarium", p: [3, 1, 2], n: [0, 0, -1], confidence: 0.81),
            FoundThing(name: "wall clock", p: [1, 1.9, 0], n: [0, 0, 1], confidence: 0.67),
        ]
        let rooms = [
            RoomRow(id: 0, name: "Bedroom", guessed: true, floor: 1, area: 19, warn: ""),
            RoomRow(id: 1, name: "Hallway", guessed: false, floor: 1, area: 10, warn: ""),
            RoomRow(id: 2, name: "", guessed: true, floor: 1, area: 37, warn: "A door came out an unusual size - use Measure on it, or fix it on the map (Edit → tap the door)."),
            RoomRow(id: 3, name: "Majlis", guessed: false, floor: 0, area: 24, warn: ""),
        ]
        func scanning() {
            m.phase = .scanning; m.roomsDone = 3; m.area = 54; m.objects = 17; m.lights = 6; m.tagCount = 2; m.floor = 1
            m.aimText = "1.8 m"
            m.progress = RoomProgress(percent: 72, walls: 0.84, floor: 0.9, ceiling: 0.35, missing: "a wall on your left", size: [4.2, 3.6], area: 15)
            m.recognizer.preview(Array(found.prefix(3)), last: "Floor lamp")
        }
        switch d {
        case "scan-intro-new", "scan-intro-add", "scan-intro-tags": m.phase = .intro
        case "scan-locking": m.phase = .locking
        case "scan-scanning": scanning(); m.tip = "Slow down a little"
        case "scan-done-room": scanning(); m.progress = RoomProgress(percent: 100, walls: 1, floor: 1, ceiling: 1, missing: "", size: [4.2, 3.6], area: 15)
        case "scan-saved": scanning(); m.saved = rooms[0]; m.progress = RoomProgress()
        case "scan-rename": scanning(); m.rooms = rooms; m.renaming = 0
        case "scan-paused": scanning(); m.phase = .paused
        case "scan-garden-hint": scanning(); m.gardenHint = true
        case "scan-live": scanning(); LiveSession.shared.message = "Point the phone at the ceiling above the door for a few seconds"; LiveSession.shared.on = true
        case "scan-outside": scanning(); m.phase = .outside; m.floor = 0; m.tip = "Walk the garden and side paths slowly. Sweep across walls, steps and the ground."; m.gardenText = "The ground here is 55 cm below the house floor"
        case "scan-tags": scanning(); m.phase = .tagging
        case "scan-tagpicker": scanning(); m.phase = .tagging; m.tagging = true
        case "scan-menu": scanning(); m.showMenu = true
        case "scan-review": m.recognizer.preview(found, last: ""); m.rooms = rooms; m.roomsDone = rooms.count; m.phase = .review
        case "scan-uploading": m.phase = .uploading; m.result = "Sending to Home Assistant (1 of 3)…"
        case "scan-done": m.phase = .done; m.roomsDone = 7; m.result = "7 rooms, 41 pieces of furniture, 12 lights, 3 tags, 5 things named and the garden."
        case "scan-failed": m.phase = .failed; m.result = "Home Assistant can't be reached right now. Your scan is saved on this phone and sends by itself when it's back - or tap Try again."
        default: m.phase = .intro
        }
        return m
    }
}
