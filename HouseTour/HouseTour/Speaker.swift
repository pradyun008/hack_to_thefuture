import AVFoundation
import UIKit

/// Spoken words. With VoiceOver on, speech goes through VoiceOver so the user
/// keeps their own voice and rate; otherwise through AVSpeechSynthesizer.
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var completions: [ObjectIdentifier: () -> Void] = [:]
    private var voiceOverCompletion: (text: String, done: () -> Void)?
    private var lastSaid: [String: Date] = [:]

    override init() {
        super.init()
        synth.delegate = self
        NotificationCenter.default.addObserver(
            forName: UIAccessibility.announcementDidFinishNotification, object: nil, queue: .main
        ) { [weak self] note in
            let text = note.userInfo?[UIAccessibility.announcementStringValueUserInfoKey] as? String
            if let pending = self?.voiceOverCompletion, pending.text == text {
                self?.voiceOverCompletion = nil
                pending.done()
            }
        }
    }

    /// `interrupt` cuts off whatever is playing (location changes are stale fast).
    /// `dedupe` skips a phrase said within that many seconds.
    /// Every phrase actually spoken, for the laptop viewer's caption.
    var onSay: ((String) -> Void)?

    func say(_ text: String, interrupt: Bool = false, dedupe: TimeInterval = 0, completion: (() -> Void)? = nil) {
        if dedupe > 0, let last = lastSaid[text], Date().timeIntervalSince(last) < dedupe {
            completion?()
            return
        }
        lastSaid[text] = Date()
        onSay?(text)

        if UIAccessibility.isVoiceOverRunning {
            if let pending = voiceOverCompletion {
                voiceOverCompletion = nil
                pending.done()
            }
            let attributed = NSAttributedString(string: text, attributes: [.accessibilitySpeechQueueAnnouncement: !interrupt])
            UIAccessibility.post(notification: .announcement, argument: attributed)
            if let completion {
                voiceOverCompletion = (text, completion)
                // VoiceOver sometimes drops the finish notification; don't stall the tour on it.
                let estimate = Double(text.count) * 0.075 + 1.5
                DispatchQueue.main.asyncAfter(deadline: .now() + estimate) { [weak self] in
                    if let pending = self?.voiceOverCompletion, pending.text == text {
                        self?.voiceOverCompletion = nil
                        pending.done()
                    }
                }
            }
            return
        }

        if interrupt, synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.53
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        if let completion { completions[ObjectIdentifier(utterance)] = completion }
        synth.speak(utterance)
    }

    func sayAndWait(_ text: String) async {
        await withCheckedContinuation { cont in
            say(text, interrupt: true) { cont.resume() }
        }
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        if let pending = voiceOverCompletion {
            voiceOverCompletion = nil
            pending.done()
        }
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { finish(u) }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { finish(u) }

    private func finish(_ u: AVSpeechUtterance) {
        let id = ObjectIdentifier(u)
        DispatchQueue.main.async { [weak self] in self?.completions.removeValue(forKey: id)?() }
    }
}
