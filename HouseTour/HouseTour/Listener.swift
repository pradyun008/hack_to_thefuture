import AVFoundation
import Speech

/// Hold-to-talk speech recognition. The mic is open only while the button is
/// held. Recognition runs on the phone when the phone supports it, so asking
/// works offline.
final class Listener {
    enum Permission { case granted, undetermined, denied }

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var heard = ""
    /// For the transcript: each different guess the recognizer made while
    /// listening, and how the last question ended ("final", "timed out", or
    /// the error). Reset on every start.
    private(set) var guesses: [String] = []
    private(set) var ending = ""
    private var done: ((String) -> Void)?
    private var recording = false
    private var run = 0   // bumps on each start so a stale timeout can't end a newer question

    /// Both the microphone and speech recognition have to be allowed.
    static var permission: Permission {
        let mic = AVAudioApplication.shared.recordPermission
        let speech = SFSpeechRecognizer.authorizationStatus()
        if mic == .denied || speech == .denied || speech == .restricted { return .denied }
        if mic == .undetermined || speech == .notDetermined { return .undetermined }
        return .granted
    }

    /// Shows the system prompts for whichever permission hasn't been asked yet.
    /// `then` gets whether both are now allowed, on the main queue.
    static func requestPermission(_ then: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { _ in
            AVAudioApplication.requestRecordPermission { _ in
                DispatchQueue.main.async { then(permission == .granted) }
            }
        }
    }

    /// Opens the mic. `hints` are words worth listening for, like room names.
    /// Returns false when the mic or the recognizer isn't available.
    func start(hints: [String]) -> Bool {
        cancel()
        guard let recognizer, recognizer.isAvailable else { return false }
        let session = AVAudioSession.sharedInstance()
        do {
            // A2DP keeps headphones in stereo for the spatial audio; the mic is
            // then the phone's own.
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers])
            try session.setActive(true)
        } catch {
            return false
        }
        recording = true
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            stopRecording()
            return false
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.contextualStrings = hints
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stopRecording()
            return false
        }
        run += 1
        heard = ""
        guesses = []
        ending = ""
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.request === request else { return }
                if let result {
                    self.heard = result.bestTranscription.formattedString
                    if !self.heard.isEmpty, self.guesses.last != self.heard { self.guesses.append(self.heard) }
                }
                if result?.isFinal == true {
                    self.deliver(ending: "final")
                } else if let error {
                    self.deliver(ending: "error: \(error.localizedDescription)")
                }
            }
        }
        return true
    }

    /// Closes the mic and hands over what was heard, once the recognizer has
    /// settled on it or 1.5 s have passed, whichever comes first. Empty when
    /// nothing was heard.
    func finish(_ done: @escaping (String) -> Void) {
        guard request != nil else { return done("") }
        self.done = done
        stopRecording()
        request?.endAudio()
        let current = run
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard self?.run == current else { return }
            self?.deliver(ending: "timed out")
        }
    }

    /// Closes the mic and drops whatever was heard.
    func cancel() {
        done = nil
        task?.cancel()
        task = nil
        request = nil
        stopRecording()
    }

    private func deliver(ending: String) {
        guard let done else { return }
        self.done = nil
        self.ending = ending
        task?.cancel()
        task = nil
        request = nil
        done(heard.trimmingCharacters(in: .whitespaces))
    }

    /// Stops the mic and puts the audio session back the way SpatialAudio set it up.
    private func stopRecording() {
        guard recording else { return }
        recording = false
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
    }
}
