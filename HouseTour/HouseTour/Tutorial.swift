import Foundation

/// Plays each pattern with its name, so the vocabulary is learned in about a
/// minute instead of guessed at. Only teaches channels that are switched on.
/// Main actor: Speaker and Haptics aren't thread-safe.
@MainActor
struct Tutorial {
    let haptics: Haptics
    let audio: SpatialAudio
    let speech: Speaker

    func run() async {
        var lessons: [(String, () async -> Void)] = [
            ("Wear AirPods Pro and allow Motion access. Turn your head left or right to face that direction. Drag up to walk forward and down to walk backward. Horizontal drags do nothing. On the fixed path, up follows the route. A short high pitched beep warns when you are within one foot of a virtual wall. You start inside the front door, facing in.", {}),
            ("Wall. A hard knock, repeating while you push.", { haptics.wall() }),
            ("Window. A glassy double tap.", { haptics.window() }),
            ("A railing, where the floor drops away.", { haptics.railing() }),
            ("Door. Two light taps, then its name.", { haptics.doorway() }),
            ("Opening between rooms. One soft tap.", { haptics.opening() }),
            ("The front door.", { haptics.frontDoor(); audio.chime() }),
        ]
        if Setting.textures.isOn {
            lessons += [
                ("Every few steps you feel the floor. Carpet. A smooth swell.", { await repeatStep(.carpet) }),
                ("Concrete. A flat scrape.", { await repeatStep(.concrete) }),
                ("Tile. Two spaced pulses.", { await repeatStep(.tile) }),
                ("Hardwood. Three light ticks.", { await repeatStep(.hardwood) }),
                ("Deck. Long, then short.", { await repeatStep(.deck) }),
            ]
        }
        if Setting.wallHum.isOn {
            lessons.append(("Near a wall. A hum that grows as you get closer.", { await ramp() }))
        }
        lessons += [
            ("Something built in, like a fireplace.", { haptics.fixture() }),
            ("Stairs. Hold still on them, finger down, to change floors.", { haptics.stairs(up: true) }),
            ("With headphones, this chime comes from the front door's direction. The find front door button plays it.", { audio.chime() }),
            ("You walk a set path through the house, so you can't get lost. Drag to go along it, drag back to return. Double tap to step off and feel a room yourself, and double tap again to come back.", {}),
            ("Single tap says your room, and on the tour, the way to the next stop. Triple tap gives the room, nearest wall, and nearest door. Settings can switch off any sound or vibration.", {}),
        ]
        for (line, demo) in lessons {
            guard !Task.isCancelled else { return }
            await speech.sayAndWait(line)
            guard !Task.isCancelled else { return }
            await demo()
            try? await Task.sleep(nanoseconds: 900_000_000)
        }
    }

    private func repeatStep(_ floor: FloorType) async {
        for _ in 0..<3 where !Task.isCancelled {
            haptics.texture(floor)
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
    }

    private func ramp() async {
        for i in 0...15 {
            guard !Task.isCancelled else { return }  // stopTutorial already silenced the hum
            haptics.proximity(0.12 + 0.55 * Float(i) / 15)
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        haptics.proximity(0)
    }
}
