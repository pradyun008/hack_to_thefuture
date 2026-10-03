import Foundation
import CoreGraphics

// Hardware adapters are replaced; these tests exercise the real Explorer,
// Floor and Rail on macOS without an iPhone or AirPods.
final class Haptics {
    func blocked(_ kind: CellKind) {}
    func proximity(_ value: Float) {}
    func frontDoor() {}
    func stairs(up: Bool) {}
    func opening() {}
    func doorway() {}
    func fixture() {}
    func path(on: Bool) {}
    func texture(_ type: FloorType) {}
}
final class SpatialAudio {
    var warnings = 0
    func wallWarning() { warnings += 1 }
    func face(_ heading: Double) {}
    func moveListener(to point: CGPoint) {}
    func setWind(_ on: Bool) {}
    func setBeacon(_ on: Bool) {}
    func boostBeacon() {}
    func chime() {}
}
final class Speaker {
    var isNarrating = false
    @discardableResult func request(_ message: String) -> Bool { true }
    func say(_ message: String, interrupt: Bool = false, dedupe: Double = 0) {}
}
enum Setting {
    case wind, speakObstacles, speakRooms, speakDoors, textures, wallHum, beacon
    var isOn: Bool { false }
}

@main struct Regression {
    static func main() throws {
        for name in ["house", "waterville"] {
            let path = "HouseTour/HouseTour/\(name).json"
            let house = try House(data: Data(contentsOf: URL(fileURLWithPath: path)))
            let audio = SpatialAudio()
            let explorer = Explorer(house: house, haptics: Haptics(), audio: audio, speech: Speaker())
            let roaming = Explorer(house: house, haptics: Haptics(), audio: audio, speech: Speaker(), onRail: false)
            precondition(!roaming.onRail && roaming.position == explorer.position,
                         "Free roam did not start off the path at the front door")
            roaming.toggleRail()
            precondition(roaming.onRail, "Triple tap could not join the path from free roam")
            let start = explorer.position
            explorer.touchDown()
            explorer.drag(by: CGVector(dx: 50, dy: 0))
            precondition(explorer.position == start, "Horizontal drag moved avatar")
            explorer.faceHead(0)
            precondition(explorer.heading == 0, "Forward calibration did not point straight up")
            explorer.faceHead(.pi / 3)
            let turned = explorer.heading
            precondition(abs(turned - .pi / 3) < 1e-9)
            explorer.drag(by: CGVector(dx: 0, dy: -2))
            precondition(explorer.position.distance(to: start) > 0, "Forward rail movement failed")
            precondition(explorer.heading == turned, "Rail movement overwrote head direction")
            explorer.touchUp()
            precondition(explorer.heading == turned, "Lifting overwrote head direction")
            explorer.toggleRail()
            let freeStart = explorer.position
            explorer.touchDown()
            explorer.drag(by: CGVector(dx: -50, dy: 0))
            precondition(explorer.position == freeStart, "Horizontal free movement was not disabled")
            explorer.touchUp()
            explorer.toggleRail()
            precondition(explorer.onRail && explorer.heading == turned, "Rejoining route overwrote calibration")
            explorer.changeFloor()
            precondition(explorer.heading == turned, "Changing floor overwrote calibration")
            explorer.changeFloor()
            explorer.teleport(to: start, floor: 0, heading: -.pi / 2, tourStep: 0)
            precondition(explorer.heading == turned, "Tour teleport overwrote calibration")
            explorer.faceHead(0)
            precondition(explorer.heading == 0, "Returning to forward did not point straight up")
            explorer.faceHead(.nan)
            precondition(explorer.heading == 0, "Invalid head pose corrupted heading")
            explorer.toggleRail()

            // Find a real open point in the one-foot zone and one beyond rearm.
            let floor = house.floors[0]
            var near: CGPoint?, far: CGPoint?
            for r in 0..<floor.rows {
                for c in 0..<floor.cols {
                    let p = CGPoint(x: (Double(c) + 0.5) * floor.cellSize,
                                    y: (Double(r) + 0.5) * floor.cellSize)
                    guard floor.obstacle(at: p) == nil else { continue }
                    if floor.distanceToBlocking(from: p, within: 1) != nil { near = near ?? p }
                    if floor.distanceToBlocking(from: p, within: 1.25) == nil { far = far ?? p }
                }
            }
            precondition(near != nil && far != nil)
            explorer.teleport(to: near!, floor: 0, heading: 0)
            let warningCount = audio.warnings
            explorer.touchDown()
            explorer.touchUp()
            explorer.touchDown()
            explorer.touchUp()
            precondition(audio.warnings == warningCount, "Stationary touches repeated warning")
            explorer.teleport(to: far!, floor: 0, heading: 0)
            explorer.teleport(to: near!, floor: 0, heading: 0)
            precondition(audio.warnings == warningCount + 1, "Reentry did not warn")
            print("PASS: \(name) forward calibration, route/floor/tour preservation, horizontal input and wall warnings")
        }
        // Exact rectangle distance: a cell center approximation would fail.
        let raw = RawFloor(name: "Test", cols: 5, rows: 1, cells: "#....",
                           rooms: ".....", roomList: [], doors: [], fixtures: [])
        let floor = Floor(raw, cellSize: 1)
        precondition(floor.distanceToBlocking(from: CGPoint(x: 2, y: 0.5), within: 1) == 1)
        precondition(floor.distanceToBlocking(from: CGPoint(x: 2.01, y: 0.5), within: 1) == nil)
        print("PASS: exact one-foot wall threshold")
        let cells = String(repeating: "#", count: 10)
            + String(repeating: "#........#", count: 8)
            + String(repeating: "#", count: 10)
        let data = try JSONSerialization.data(withJSONObject: [
            "address": "Test", "summary": "", "cellSize": 1, "width": 10, "height": 10,
            "frontDoor": ["floor": 0, "x": 5, "y": 5], "tour": [],
            "floors": [["name": "Test", "cols": 10, "rows": 10, "cells": cells,
                         "rooms": String(repeating: ".", count: 100),
                         "roomList": [], "doors": [], "fixtures": []]]
        ])
        let audio = SpatialAudio()
        let explorer = Explorer(house: try House(data: data), haptics: Haptics(),
                                audio: audio, speech: Speaker())
        explorer.touchDown()
        explorer.drag(by: CGVector(dx: 0, dy: -20))
        precondition(audio.warnings == 1, "Fast drag skipped the warning zone")
        precondition(explorer.position.y >= 1, "Fast drag crossed the wall")
        explorer.drag(by: CGVector(dx: 0, dy: -1))
        precondition(audio.warnings == 1, "Pushing into wall repeated warning")
        explorer.drag(by: CGVector(dx: 0, dy: 3))
        explorer.drag(by: CGVector(dx: 0, dy: -3))
        precondition(audio.warnings == 2, "Walking away and reentering did not rearm")
        explorer.touchUp()
        explorer.teleport(to: CGPoint(x: 5, y: 5), floor: 0, heading: .pi / 2)
        explorer.touchDown()
        explorer.drag(by: CGVector(dx: 100, dy: -1))
        precondition(abs(explorer.position.x - 6) < 1e-9 && abs(explorer.position.y - 5) < 1e-9,
                     "Free walking did not follow the head-controlled direction")
        explorer.touchUp()
        print("PASS: fast wall approach, collision, retreat/reentry and free head-directed movement")

    }
}
