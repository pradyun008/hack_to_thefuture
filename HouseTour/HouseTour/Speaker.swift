import AVFoundation
import UIKit

/// Spoken words. With VoiceOver on, speech goes through VoiceOver so the user
/// keeps their own voice and rate; otherwise through AVSpeechSynthesizer.
///
/// Tour narration is protected: once it starts, only `stop()` cuts it off.
/// Anything else that asks to interrupt waits in line behind it instead.
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var completions: [ObjectIdentifier: () -> Void] = [:]
    private var narrationUtterance: ObjectIdentifier?
    private var narrationText = ""
    private var lastSaid: [String: Date] = [:]

    /// VoiceOver announcements still playing, oldest first. VoiceOver has no
    /// "is speaking" flag, so this queue is how we know.
    private struct Announcement {
        let id = UUID()
        let text: String
        let narration: Bool
        let until: Date   // when it should be done if the finish notification never comes
        let done: (() -> Void)?
    }
    private var voiceOver: [Announcement] = []

    /// While the mic is open nothing is spoken, so the recognizer doesn't hear
    /// the app's own voice. Anything asked to be said meanwhile waits here.
    private var held: [() -> Void]?
    /// Narration the mic cut off, said again once the answer is done. Its
    /// completion goes with it, so the tour doesn't move on as if it was heard.
    private var cutNarration: (text: String, done: (() -> Void)?)?

    override init() {
        super.init()
        synth.delegate = self
        NotificationCenter.default.addObserver(
            forName: UIAccessibility.announcementDidFinishNotification, object: nil, queue: .main
        ) { [weak self] note in
            let text = note.userInfo?[UIAccessibility.announcementStringValueUserInfoKey] as? String
            if let id = self?.voiceOver.first(where: { $0.text == text })?.id { self?.finishVoiceOver(id) }
        }
    }

    /// Every phrase actually spoken, for the laptop viewer's caption.
    var onSay: ((String) -> Void)?
    /// A requested phrase dropped because something else was being said.
    var onSkip: ((String) -> Void)?

    /// Something is being said or is waiting to be said.
    var isSpeaking: Bool {
        UIAccessibility.isVoiceOverRunning ? !voiceOver.isEmpty : synth.isSpeaking
    }

    /// Tour narration is playing.
    var isNarrating: Bool {
        UIAccessibility.isVoiceOverRunning ? voiceOver.contains(where: \.narration) : narrationUtterance != nil
    }

    /// `interrupt` cuts off whatever is playing (location changes are stale fast),
    /// except tour narration. `dedupe` skips a phrase said within that many
    /// seconds. `narration` marks tour narration, which nothing but `stop()` cuts off.
    func say(_ text: String, interrupt: Bool = false, dedupe: TimeInterval = 0, narration: Bool = false,
             completion: (() -> Void)? = nil) {
        if held != nil {
            // Without `interrupt`, so it lines up behind the answer.
            held?.append { [weak self] in self?.say(text, dedupe: dedupe, narration: narration, completion: completion) }
            return
        }
        if dedupe > 0, let last = lastSaid[text], Date().timeIntervalSince(last) < dedupe {
            completion?()
            return
        }
        lastSaid[text] = Date()
        onSay?(text)
        let interrupt = interrupt && !isNarrating

        if UIAccessibility.isVoiceOverRunning {
            if interrupt { flushVoiceOver() }
            // Queued announcements start when the one before them ends.
            let start = max(Date(), voiceOver.last?.until ?? .distantPast)
            // VoiceOver sometimes drops the finish notification; don't stall the tour on it.
            let until = start.addingTimeInterval(Double(text.count) * 0.075 + 1.5)
            let item = Announcement(text: text, narration: narration, until: until, done: completion)
            voiceOver.append(item)
            let attributed = NSAttributedString(string: text, attributes: [.accessibilitySpeechQueueAnnouncement: !interrupt])
            UIAccessibility.post(notification: .announcement, argument: attributed)
            DispatchQueue.main.asyncAfter(deadline: .now() + until.timeIntervalSinceNow) { [weak self] in
                self?.finishVoiceOver(item.id)
            }
            return
        }

        if interrupt, synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.53
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        if let completion { completions[ObjectIdentifier(utterance)] = completion }
        if narration {
            narrationUtterance = ObjectIdentifier(utterance)
            narrationText = text
        }
        synth.speak(utterance)
    }

    /// Something the user asked for with a tap or a button. Said only when
    /// nothing else is being said, so asking never cuts off or piles up speech.
    /// Returns false when it was dropped.
    @discardableResult
    func request(_ text: String) -> Bool {
        guard !isSpeaking else {
            onSkip?(text)
            return false
        }
        say(text, interrupt: true)
        return true
    }

    func sayAndWait(_ text: String) async {
        await withCheckedContinuation { cont in
            say(text, interrupt: true) { cont.resume() }
        }
    }

    /// The mic opened: cut off everything, narration included, and hold
    /// anything new until `resume`. Narration is kept to say again after.
    func hold() {
        let cut = takeNarration()
        held = []
        stop()
        cutNarration = cut
    }

    /// The mic closed. `first` says the answer, then the narration it cut off
    /// (unless the answer stopped everything), then whatever waited.
    func resume(first: () -> Void) {
        let waiting = held ?? []
        held = nil
        first()
        if let cut = cutNarration {
            cutNarration = nil
            say(cut.text, narration: true, completion: cut.done)
        }
        waiting.forEach { $0() }
    }

    /// The narration playing now, with its completion taken out so cutting it
    /// off doesn't run it.
    private func takeNarration() -> (text: String, done: (() -> Void)?)? {
        if UIAccessibility.isVoiceOverRunning {
            guard let i = voiceOver.firstIndex(where: \.narration) else { return nil }
            let item = voiceOver.remove(at: i)
            return (item.text, item.done)
        }
        guard let id = narrationUtterance else { return nil }
        return (narrationText, completions.removeValue(forKey: id))
    }

    /// Cuts off everything, narration included.
    func stop() {
        cutNarration = nil
        narrationUtterance = nil
        synth.stopSpeaking(at: .immediate)
        flushVoiceOver()
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { finish(u) }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { finish(u) }

    private func finish(_ u: AVSpeechUtterance) {
        let id = ObjectIdentifier(u)
        DispatchQueue.main.async { [weak self] in
            if self?.narrationUtterance == id { self?.narrationUtterance = nil }
            self?.completions.removeValue(forKey: id)?()
        }
    }

    private func finishVoiceOver(_ id: UUID) {
        guard let i = voiceOver.firstIndex(where: { $0.id == id }) else { return }
        voiceOver.remove(at: i).done?()
    }

    private func flushVoiceOver() {
        let cut = voiceOver
        voiceOver = []
        cut.forEach { $0.done?() }
    }
}
