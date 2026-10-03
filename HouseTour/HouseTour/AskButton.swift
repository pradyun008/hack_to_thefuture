import SwiftUI
import UIKit

/// Hold to talk: the mic is open while a finger is down. It fills the bottom
/// of the screen, the easiest place to find without looking, and well away
/// from the touch surface's walking.
struct AskButton: View {
    let listening: Bool
    let onPress: () -> Void
    let onRelease: () -> Void

    var body: some View {
        Label(listening ? "Listening" : "Hold to ask", systemImage: listening ? "waveform" : "mic.fill")
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 140)
            .background(listening ? Color.red : Color.indigo, in: RoundedRectangle(cornerRadius: 14))
            .accessibilityHidden(true)
            .overlay(PressSurface(onPress: onPress, onRelease: onRelease))
    }
}

/// The touches for `AskButton`. UIKit, like the floor map, so that with
/// `allowsDirectInteraction` a VoiceOver user's finger presses it directly
/// instead of only moving focus.
private struct PressSurface: UIViewRepresentable {
    let onPress: () -> Void
    let onRelease: () -> Void

    func makeUIView(context: Context) -> PressView { PressView() }

    func updateUIView(_ view: PressView, context: Context) {
        view.onPress = onPress
        view.onRelease = onRelease
    }
}

private final class PressView: UIView {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    private var finger: UITouch?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityLabel = "Ask a question"
        accessibilityHint = "Touch and hold, ask, then let go. " + Question.examples
        accessibilityTraits = .allowsDirectInteraction
    }

    required init?(coder: NSCoder) { fatalError() }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard finger == nil, let t = touches.first else { return }
        finger = t
        onPress?()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches) }

    private func lift(_ touches: Set<UITouch>) {
        guard let t = finger, touches.contains(t) else { return }
        finger = nil
        onRelease?()
    }
}
