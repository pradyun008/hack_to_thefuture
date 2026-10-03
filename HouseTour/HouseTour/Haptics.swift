import CoreHaptics

/// The haptic vocabulary. Everything the avatar touches is felt here; audio
/// only carries direction, distance, and words. Patterns differ in rhythm, not
/// just intensity, because small sharpness changes are hard to tell apart.
final class Haptics {
    private var engine: CHHapticEngine?
    private var hum: CHHapticAdvancedPatternPlayer?
    private var humOn = false
    private var lastHumUpdate = Date.distantPast

    init() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            let engine = try CHHapticEngine()
            engine.playsHapticsOnly = true
            engine.isAutoShutdownEnabled = false
            // The engine stops when the app backgrounds or audio is interrupted.
            // Handlers arrive on an internal queue; all other access is on main.
            engine.resetHandler = { [weak self] in DispatchQueue.main.async { self?.restart() } }
            engine.stoppedHandler = { [weak self] _ in
                DispatchQueue.main.async {
                    self?.hum = nil
                    self?.humOn = false
                }
            }
            try engine.start()
            self.engine = engine
            makeHum()
        } catch {
            print("Haptics unavailable: \(error)")
        }
    }

    private func restart() {
        do {
            try engine?.start()
            makeHum()
        } catch {
            print("Haptic restart failed: \(error)")
        }
    }

    // MARK: Vocabulary

    /// Hard, crisp knock. The only full-strength, full-sharpness single hit in
    /// the vocabulary, so it can't be mistaken for a floor.
    func wall() { play([tap(0, 1.0, 1.0)]) }

    /// Glassy double ping.
    func window() { play([tap(0, 0.8, 1.0), tap(0.07, 0.45, 1.0)]) }

    /// Light knock with a short fizz, for the porch screens.
    func screen() { play([tap(0, 0.6, 0.8), buzz(0.02, 0.1, 0.3, 0.9)]) }

    /// Dull, heavy thud: a railing or the edge of an open drop.
    func railing() { play([tap(0, 0.9, 0.15), buzz(0, 0.12, 0.5, 0.1, release: 0.1)]) }

    func blocked(_ kind: CellKind) {
        switch kind {
        case .wall: wall()
        case .window: window()
        case .screen: screen()
        case .railing, .void: railing()
        case .open: break
        }
    }

    /// Two quick light taps.
    func doorway() { play([tap(0, 0.55, 0.6), tap(0.09, 0.55, 0.6)]) }

    /// One soft tap where open-plan rooms meet.
    func opening() { play([tap(0, 0.35, 0.5)]) }

    /// Tap, tap, pause, tap.
    func frontDoor() { play([tap(0, 0.85, 0.8), tap(0.13, 0.85, 0.8), tap(0.45, 1.0, 0.8)]) }

    /// Soft, dull bump for built-ins you can walk around.
    func fixture() { play([buzz(0, 0.12, 0.6, 0.1, attack: 0.03, release: 0.06)]) }

    /// Rising ladder of taps (falling when going down).
    func stairs(up: Bool) {
        let levels: [Float] = [0.3, 0.42, 0.54, 0.66, 0.78, 0.9]
        let ordered = up ? levels : levels.reversed()
        play(ordered.enumerated().map { tap(Double($0.offset) * 0.11, $0.element, 0.5) })
    }

    /// Strength of every footstep, against the base values below. Testers found
    /// the originals too faint to feel while walking; at 1.8 the strongest step
    /// is 0.81, still under the wall's full-strength knock.
    static let stepGain: Float = 1.8

    /// One footstep's worth of floor texture. Each floor is a different rhythm
    /// (a smooth swell, a flat scrape, two soft pulses, three light ticks, a
    /// long-short), because with eyes closed counting is easier than judging
    /// sharpness. All under 200 ms with no crisp hits, so a floor never feels
    /// like the wall's hard knock: that difference lives in sharpness, which
    /// stays low, so strength can be raised with `stepGain` without blurring it.
    func texture(_ floor: FloorType) {
        let g = Self.stepGain
        switch floor {
        case .carpet:    // no hits at all: one soft smooth swell
            play([buzz(0, 0.18, 0.4 * g, 0.05, attack: 0.07, release: 0.08)])
        case .concrete:  // flat gritty scrape: hard-edged, no swell, no taps
            play([buzz(0, 0.15, 0.45 * g, 0.35, release: 0.02)])
        case .tile:      // two short smooth pulses, far apart: mm ... mm
            play([buzz(0, 0.04, 0.4 * g, 0.5, release: 0.02), buzz(0.15, 0.04, 0.4 * g, 0.5, release: 0.02)])
        case .hardwood:  // three fast light ticks, fading: tk-tk-tk
            play([tap(0, 0.4 * g, 0.45), tap(0.06, 0.33 * g, 0.45), tap(0.12, 0.26 * g, 0.45)])
        case .deck:      // long then short: a hollow drone, then a dull knock
            play([buzz(0, 0.09, 0.45 * g, 0.2), tap(0.15, 0.45 * g, 0.3)])
        case .unknown:
            break
        }
    }

    /// The mic opening (a swell) or closing (a fade), for the hold-to-talk button.
    func listening(_ on: Bool) {
        play([buzz(0, 0.2, 0.7, 0.6, attack: on ? 0.18 : 0, release: on ? 0 : 0.18)])
    }

    /// Continuous hum that rises as the avatar nears a wall. 0 turns it off.
    func proximity(_ level: Float) {
        guard engine != nil else { return }
        if hum == nil { makeHum() }
        guard let hum else { return }
        do {
            if level <= 0.01 {
                if humOn {
                    try hum.stop(atTime: CHHapticTimeImmediate)
                    humOn = false
                }
                return
            }
            if !humOn {
                try hum.start(atTime: CHHapticTimeImmediate)
                humOn = true
            }
            // Parameter updates faster than ~30 Hz just queue up.
            guard Date().timeIntervalSince(lastHumUpdate) > 0.03 else { return }
            lastHumUpdate = Date()
            let p = CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: level, relativeTime: 0)
            try hum.sendParameters([p], atTime: CHHapticTimeImmediate)
        } catch {
            humOn = false
            restart()
        }
    }

    // MARK: Building blocks

    private func tap(_ time: Double, _ intensity: Float, _ sharpness: Float) -> CHHapticEvent {
        CHHapticEvent(eventType: .hapticTransient, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
        ], relativeTime: time)
    }

    private func buzz(_ time: Double, _ duration: Double, _ intensity: Float, _ sharpness: Float,
                      attack: Float = 0, release: Float = 0) -> CHHapticEvent {
        CHHapticEvent(eventType: .hapticContinuous, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            CHHapticEventParameter(parameterID: .attackTime, value: attack),
            CHHapticEventParameter(parameterID: .releaseTime, value: release),
        ], relativeTime: time, duration: duration)
    }

    private func play(_ events: [CHHapticEvent]) {
        guard let engine else { return }
        do {
            let player = try engine.makePlayer(with: CHHapticPattern(events: events, parameters: []))
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            // Most often the engine was stopped by the system. Restart and drop this one.
            restart()
        }
    }

    private func makeHum() {
        guard let engine else { return }
        do {
            let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.25),
            ], relativeTime: 0, duration: 30)
            let player = try engine.makeAdvancedPlayer(with: CHHapticPattern(events: [event], parameters: []))
            player.loopEnabled = true
            hum = player
            humOn = false
        } catch {
            print("Hum player failed: \(error)")
        }
    }
}
