import CoreGraphics
import Foundation

/// Mode 1: the app walks a preset path from the front door, narrating like a
/// realtor. It moves the avatar directly (not through trackpad input), and the
/// Explorer fires the same doorways and floor textures the user will meet when
/// exploring alone.
final class GuidedTour {
    private let explorer: Explorer
    private let speech: Speaker
    private let steps: [TourStep]
    private var index = 0
    private var walker = CGPoint.zero
    private var waiting = false
    private var timer: Timer?
    private var lastTick = Date()
    private var run = 0   // bumps on start/stop so a stale pause can't resume a new tour
    var onFinish: (() -> Void)?

    static let speed = 3.0   // ft/s; slower than walking pace so there's time to feel things

    init(explorer: Explorer, speech: Speaker) {
        self.explorer = explorer
        self.speech = speech
        steps = explorer.house.tour
    }

    func start() {
        guard let first = steps.first else { return }
        stop(silently: true)
        run += 1
        index = 0
        walker = first.point
        explorer.beginTour(at: walker, floor: first.floor)
        lastTick = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        arrive(at: first)
    }

    func stop(silently: Bool = false) {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        waiting = false
        run += 1
        explorer.endTour()
        if !silently { speech.say("Tour stopped.", interrupt: true) }
    }

    private func tick() {
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now
        guard !waiting else { return }
        guard index < steps.count else { return finish() }
        let target = steps[index]
        let d = walker.distance(to: target.point)
        let move = Self.speed * dt
        if d <= move {
            walker = target.point
            explorer.walk(to: walker)
            arrive(at: target)
        } else {
            walker = CGPoint(x: walker.x + (target.x - walker.x) * move / d,
                             y: walker.y + (target.y - walker.y) * move / d)
            explorer.walk(to: walker)
        }
    }

    private func arrive(at step: TourStep) {
        index += 1
        if step.climb == true {
            explorer.changeFloor(viaStairs: true)
            pause(for: 1.0)
        } else if let say = step.say {
            waiting = true
            let current = run
            speech.say(say, interrupt: true) { [weak self] in
                if self?.run == current { self?.pause(for: 0.4) }
            }
        }
    }

    private func pause(for seconds: Double) {
        waiting = true
        let current = run
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard self?.run == current else { return }
            self?.waiting = false
            self?.lastTick = Date()
        }
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        explorer.endTour()
        onFinish?()
    }
}
