import AVFoundation

/// Non-speech sound. Units are feet: the listener stands where the avatar is,
/// facing up the screen (-z), so the front door beacon pans and fades as the
/// avatar moves. Works on any stereo headphones. Bluetooth adds ~200 ms of lag,
/// so nothing time-critical lives here; wall hits are haptic only.
final class SpatialAudio {
    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    private let beacon = AVAudioPlayerNode()
    private let wind = AVAudioPlayerNode()
    private let effects = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!

    private lazy var beaconLoop = Synth.beaconLoop(format)
    private lazy var chimeBuffer = Synth.chime(format, gain: 0.8)
    private lazy var windLoop = Synth.wind(format)

    private var beaconOn = false
    private var windOn = false

    init(frontDoor: CGPoint) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)

        [environment, beacon, wind, effects].forEach(engine.attach)
        engine.connect(environment, to: engine.mainMixerNode, format: nil)
        engine.connect(beacon, to: environment, format: format)
        engine.connect(wind, to: engine.mainMixerNode, format: format)
        engine.connect(effects, to: engine.mainMixerNode, format: format)

        beacon.renderingAlgorithm = .HRTFHQ
        beacon.sourceMode = .pointSource
        environment.outputType = .headphones
        environment.distanceAttenuationParameters.distanceAttenuationModel = .inverse
        environment.distanceAttenuationParameters.referenceDistance = 6
        environment.distanceAttenuationParameters.maximumDistance = 120
        environment.distanceAttenuationParameters.rolloffFactor = 0.9
        environment.listenerAngularOrientation = AVAudio3DAngularOrientation(yaw: 0, pitch: 0, roll: 0)
        beacon.position = AVAudio3DPoint(x: Float(frontDoor.x), y: 0, z: Float(frontDoor.y))
        beacon.volume = 0.55
        wind.volume = 0.22

        let center = NotificationCenter.default
        center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                           queue: .main) { [weak self] _ in self?.recover() }
        // Siri, a phone call, or another app can stop the engine.
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                           queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if raw == AVAudioSession.InterruptionType.ended.rawValue { self?.recover() }
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil,
                           queue: .main) { [weak self] _ in self?.recover() }
        start()
    }

    /// Playing a node on a stopped engine throws an Objective-C exception, so
    /// every play goes through here.
    @discardableResult
    private func start() -> Bool {
        if engine.isRunning { return true }
        try? AVAudioSession.sharedInstance().setActive(true)
        do { try engine.start() } catch { print("Audio engine failed: \(error)") }
        return engine.isRunning
    }

    /// Headphones plugged in or AirPods connected: the engine stops and drops its schedule.
    private func recover() {
        start()
        if beaconOn { beaconOn = false; setBeacon(true) }
        if windOn { windOn = false; setWind(true) }
    }

    func moveListener(to p: CGPoint) {
        environment.listenerPosition = AVAudio3DPoint(x: Float(p.x), y: 0, z: Float(p.y))
    }

    func setBeacon(_ on: Bool) {
        guard on != beaconOn else { return }
        beaconOn = on
        if on {
            guard start() else { beaconOn = false; return }
            beacon.scheduleBuffer(beaconLoop, at: nil, options: [.loops, .interrupts])
            beacon.play()
        } else {
            beacon.stop()
        }
    }

    /// Louder beacon for a few seconds, after "find the front door".
    func boostBeacon() {
        beacon.volume = 1.0
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.beacon.volume = 0.55 }
    }

    func setWind(_ on: Bool) {
        guard on != windOn else { return }
        windOn = on
        if on {
            guard start() else { windOn = false; return }
            wind.scheduleBuffer(windLoop, at: nil, options: [.loops, .interrupts])
            wind.play()
        } else {
            wind.stop()
        }
    }

    /// Front door chime, played in the head (not spatial).
    func chime() {
        guard start() else { return }
        effects.scheduleBuffer(chimeBuffer, at: nil, options: .interrupts)
        effects.play()
    }
}

/// Every sound is synthesized, so there are no audio assets to manage.
enum Synth {
    static func buffer(_ format: AVAudioFormat, seconds: Double, _ sample: (Int, Double) -> Float) -> AVAudioPCMBuffer {
        let n = AVAudioFrameCount(seconds * format.sampleRate)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n)!
        buf.frameLength = n
        let data = buf.floatChannelData![0]
        for i in 0..<Int(n) { data[i] = sample(i, Double(i) / format.sampleRate) }
        return buf
    }

    static func normalize(_ buf: AVAudioPCMBuffer, peak: Float) -> AVAudioPCMBuffer {
        let data = buf.floatChannelData![0]
        var m: Float = 0.0001
        for i in 0..<Int(buf.frameLength) { m = max(m, abs(data[i])) }
        for i in 0..<Int(buf.frameLength) { data[i] *= peak / m }
        return buf
    }

    static func chime(_ f: AVAudioFormat, gain: Float) -> AVAudioPCMBuffer {
        normalize(buffer(f, seconds: 0.6) { _, t in
            let env = Float(min(t / 0.005, 1) * exp(-t / 0.16))
            return env * Float(sin(2 * .pi * 1046.5 * t) + 0.5 * sin(2 * .pi * 1568 * t))
        }, peak: gain)
    }

    /// Two-note chime, then silence, 1.5 s per loop.
    static func beaconLoop(_ f: AVAudioFormat) -> AVAudioPCMBuffer {
        normalize(buffer(f, seconds: 1.5) { _, t in
            func note(_ start: Double, _ hz: Double) -> Double {
                let u = t - start
                guard u >= 0 else { return 0 }
                return min(u / 0.005, 1) * exp(-u / 0.12) * sin(2 * .pi * hz * u)
            }
            return Float(note(0, 1318.5) + note(0.16, 1046.5))
        }, peak: 0.7)
    }

    /// Low rumbling noise with a slow swell, looped while outside the house.
    static func wind(_ f: AVAudioFormat) -> AVAudioPCMBuffer {
        var low: Double = 0
        let seconds = 4.0
        return normalize(buffer(f, seconds: seconds) { _, t in
            low += 0.02 * (Double.random(in: -1...1) - low)
            let swell = 0.6 + 0.4 * sin(2 * .pi * t / seconds)  // whole cycles, so the loop is seamless
            let fade = min(t / 0.05, 1, (seconds - t) / 0.05)
            return Float(low * swell * fade)
        }, peak: 0.5)
    }
}
