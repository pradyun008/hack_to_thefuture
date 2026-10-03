import CoreGraphics
import Foundation

/// Mode 1: a tour the user walks themselves. house.tour is split into
/// checkpoints, one per narrated stop; the unnarrated points before a stop only
/// set which way you face when the tour starts there. The app says where the next
/// stop is, relative to the way you're facing, and plays a stop's narration
/// only once the avatar actually gets there. You can wander anywhere (walls
/// still block); the directions come back if you walk for a while without
/// getting closer.
final class GuidedTour {
    struct Checkpoint {
        let floor: Int
        let point: CGPoint
        let say: String
        let name: String      // room name, for the guidance
        let room: Int?        // reaching this room counts as arriving
        let stairs: Bool      // the stop before a climb; stepping onto the stairs counts
        let heading: Double   // facing along the tour path, for the start
        let step: Int         // index into house.tour, which pins it to the rail
    }

    let checkpoints: [Checkpoint]
    private let explorer: Explorer
    private let speech: Speaker
    private(set) var running = false
    private var target = 0          // checkpoint being walked to
    private var reached: Int?       // checkpoint last narrated
    private var narrating = false
    private var run = 0             // bumps on every restart so a stale narration can't advance a new one
    private var timer: Timer?
    private var lastFloor = 0
    private var lastPosition = CGPoint.zero
    private var lastMoved = Date.distantPast
    private var lastGuidance = Date.distantPast
    private var distanceAtGuidance = Double.infinity
    var onFinish: (() -> Void)?

    static let reach = 2.5      // ft from a checkpoint that counts as there
    static let regreet = 10.0   // s of walking without getting 3 ft closer before directions repeat

    init(explorer: Explorer, speech: Speaker) {
        self.explorer = explorer
        self.speech = speech
        checkpoints = Self.checkpoints(explorer.house)
        explorer.shouldAnnounceRoom = { [weak self] room in
            guard let self, self.running, self.target < self.checkpoints.count else { return true }
            let cp = self.checkpoints[self.target]
            return !(cp.floor == self.explorer.floorIndex && cp.room == room)
        }
    }

    private static func checkpoints(_ house: House) -> [Checkpoint] {
        var result: [Checkpoint] = []
        for (i, step) in house.tour.enumerated() {
            guard let say = step.say else { continue }
            let floor = house.floors[step.floor]
            let stairs = i + 1 < house.tour.count && house.tour[i + 1].climb == true
            let room = stairs ? floor.stairsIndex : floor.roomIndex(at: step.point)
            let before = i > 0 ? house.tour[i - 1] : nil
            let heading = before.map { $0.floor == step.floor ? bearing(from: $0.point, to: step.point) : house.entranceHeading }
                ?? house.entranceHeading
            result.append(Checkpoint(floor: step.floor, point: step.point, say: say,
                                     name: room.map { floor.rooms[$0].name } ?? "Outside",
                                     room: room, stairs: stairs, heading: heading, step: i))
        }
        return result
    }

    // MARK: Controls

    /// `preface` is said first, as part of the same narration so nothing cuts it off.
    func start(preface: String? = nil) {
        let intro = "Guided tour. Drag to walk to each stop. Single tap repeats directions."
        jump(to: 0, intro: [preface, intro].compactMap { $0 }.joined(separator: " "))
    }

    /// Puts the avatar at a checkpoint and narrates it right away.
    private func jump(to index: Int, intro: String? = nil) {
        guard checkpoints.indices.contains(index) else { return }
        begin()
        let cp = checkpoints[index]
        explorer.teleport(to: cp.point, floor: cp.floor, heading: cp.heading, tourStep: cp.step)
        lastFloor = cp.floor
        target = index
        arrive(intro: intro)
    }

    func stop(silently: Bool = false) {
        guard running else { return }
        running = false
        narrating = false
        run += 1
        timer?.invalidate()
        timer = nil
        speech.stop()
        if !silently { speech.say("Tour stopped.", interrupt: true) }
    }

    /// Single tap during the tour: the room you're in and the way to the next stop.
    func repeatGuidance() {
        guard running, !narrating, target < checkpoints.count else { return }
        if speech.request(explorer.roomLabel + ". " + guidance()) { noteGuidance() }
    }

    // MARK: Walking

    /// The explorer calls this after every move, room change, and floor change.
    func update() {
        guard running, !narrating, target < checkpoints.count else { return }
        let p = explorer.position
        if p.distance(to: lastPosition) > 0.05 {
            lastPosition = p
            lastMoved = Date()
        }
        if isAtTarget() { return arrive() }
        if explorer.floorIndex != lastFloor { guide() }
    }

    /// Repeats the directions while the user walks without getting closer.
    private func tick() {
        guard running, !narrating, target < checkpoints.count else { return }
        let now = Date()
        guard now.timeIntervalSince(lastMoved) < 1.5, now.timeIntervalSince(lastGuidance) >= Self.regreet else { return }
        let d = distanceToTarget()
        if d < distanceAtGuidance - 3 {
            // Getting there. Start the clock again instead of talking.
            distanceAtGuidance = d
            lastGuidance = now
            return
        }
        guard !speech.isSpeaking else { return }
        guide()
    }

    private func begin() {
        restartRun()
        running = true
        lastPosition = explorer.position
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
    }

    /// Cuts off whatever was being said and invalidates its completion.
    private func restartRun() {
        run += 1
        narrating = false
        speech.stop()
    }

    private func isAtTarget() -> Bool {
        let cp = checkpoints[target]
        guard explorer.floorIndex == cp.floor else { return false }
        if explorer.position.distance(to: cp.point) <= Self.reach { return true }
        if cp.stairs { return explorer.isOnStairs }
        // Walking into the stop's room counts, unless the stop before was in the same room.
        guard let room = cp.room, explorer.currentRoom == room else { return false }
        return target == 0 || checkpoints[target - 1].room != room || checkpoints[target - 1].floor != cp.floor
    }

    /// Plays the stop's narration, then points to the next one. Narration is
    /// protected, so nothing the user taps cuts it off.
    private func arrive(intro: String? = nil) {
        let cp = checkpoints[target]
        narrating = true
        reached = target
        let current = run
        let text = [intro, cp.say].compactMap { $0 }.joined(separator: " ")
        speech.say(text, interrupt: true, narration: true) { [weak self] in
            guard let self, self.run == current else { return }
            self.narrating = false
            self.advance()
        }
    }

    private func advance() {
        target = (reached ?? target) + 1
        guard target < checkpoints.count else { return finish() }
        if isAtTarget() { arrive() } else { guide() }
    }

    // MARK: Directions

    private func guide(lead: String = "Next, ") {
        speech.say(guidance(lead: lead))
        noteGuidance()
    }

    private func noteGuidance() {
        lastGuidance = Date()
        distanceAtGuidance = distanceToTarget()
        lastFloor = explorer.floorIndex
    }

    /// "Next, Kitchen. Door on your left, 3 steps."
    /// On the wrong floor, it leads to the stairs instead.
    private func guidance(lead: String = "Next, ") -> String {
        let cp = checkpoints[target]
        var text = lead + cp.name
        guard explorer.floorIndex == cp.floor else {
            let up = cp.floor > explorer.floorIndex
            text += ", \(explorer.house.floors[cp.floor].name.lowercased())."
            if explorer.isOnStairs {
                text += up ? " Hold still on the stairs to climb." : " Hold still on the stairs to go down."
            } else if let s = explorer.floor.stairsIndex {
                text += " " + explorer.route(to: stairsSpot(s), room: s, name: "Stairs")
            }
            return text
        }
        return text + ". " + explorer.route(to: cp.point, room: cp.room, tourStep: cp.step)
    }

    /// Where on this floor's stairs to aim for: the part that connects floors.
    private func stairsSpot(_ s: Int) -> CGPoint {
        if let landing = explorer.house.stairLanding { return landing }
        let r = explorer.floor.rooms[s].rect
        return CGPoint(x: r.midX, y: r.midY)
    }

    private func distanceToTarget() -> Double {
        let cp = checkpoints[target]
        if explorer.floorIndex == cp.floor { return explorer.position.distance(to: cp.point) }
        return explorer.floor.stairsIndex.map { explorer.position.distance(to: stairsSpot($0)) } ?? 0
    }

    private func finish() {
        running = false
        timer?.invalidate()
        timer = nil
        speech.say("End of the tour. You're still on the path. Double tap to step off or back on, triple tap for where you are.")
        onFinish?()
    }
}
