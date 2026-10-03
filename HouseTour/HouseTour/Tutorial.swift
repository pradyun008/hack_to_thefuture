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
            ("Drag one finger to walk, like a laptop trackpad. Lifting your finger never moves you. The top of the screen is always ahead. You start just inside the front door.", {}),
            ("Walls stop you. When you bump one, you feel a knock.", { haptics.wall() }),
            ("Window. A glassy double tap.", { haptics.window() }),
            ("A railing, where the floor drops away.", { haptics.railing() }),
            ("When you reach a door, two light taps, and its name.", { haptics.doorway() }),
            ("Where open rooms meet, one soft tap.", { haptics.opening() }),
            ("The front door.", { haptics.frontDoor(); audio.chime() }),
        ]
        if Setting.textures.isOn {
            lessons += [
                ("Every few steps you feel the floor. Carpet is a smooth swell.", { await repeatStep(.carpet) }),
                ("Concrete, in the garage, is one heavy thud.", { await repeatStep(.concrete) }),
                ("Tile is two taps, spaced apart.", { await repeatStep(.tile) }),
                ("Hardwood is three fast ticks.", { await repeatStep(.hardwood) }),
                ("The porch deck is long, then short.", { await repeatStep(.deck) }),
            ]
        }
        if Setting.wallHum.isOn {
            lessons.append(("Getting close to a wall. The hum grows.", { await ramp() }))
        }
        lessons += [
            ("Something built in, like the fireplace.", { haptics.fixture() }),
            ("Stairs. Keep your finger down and hold still on them to change floors.", { haptics.stairs(up: true) }),
            ("Triple tap to find the front door. With headphones, this chime comes from its direction.", { audio.chime() }),
            ("Single tap says which room you're in. Two finger tap says more. Settings has a switch for every sound and vibration.", {}),
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
