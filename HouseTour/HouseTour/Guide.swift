import CoreGraphics
import Foundation

/// "Take me to the family room": directions one room at a time. It says the
/// first leg, then the next one each time you walk into a new room, turned to
/// the way you face then. Wandering off the shortest way isn't an error; the
/// next leg is simply worked out from wherever you are.
///
/// Each leg says how far to turn, to the nearest 45 degrees. Turning your head
/// until you face the leg's door gives a tick and "Facing it", so you know
/// when to stop turning. Until then a soft tick repeats in the ear on the side
/// to turn toward.
final class Guide {
    private let explorer: Explorer
    private let speech: Speaker
    private let haptics: Haptics
    private let audio: SpatialAudio
    private var goal: (floor: Int, room: Int)?
    private var lastRoom: (floor: Int, room: Int?)?
    /// Where the leg just spoken points: a door, the stairs, or the room itself.
    private var aim: CGPoint?
    /// Whether facing `aim` should tick. Off once it has, back on after
    /// turning well away, so wobbling at the edge doesn't tick over and over.
    private var facingArmed = false
    private var heading: Double
    /// Repeats the turn tick until you face the aim or give up turning.
    private var tickTimer: Timer?
    private var ticksLeft = 0

    /// Within this many degrees of the aim counts as facing it. Turning past
    /// `rearmDegrees` away arms the tick again.
    static let facingDegrees = 10.0
    static let rearmDegrees = 25.0
    /// Seconds between turn ticks, and how many before they stop on their own.
    static let tickInterval = 0.9
    static let maxTicks = 15

    var running: Bool { goal != nil }

    init(explorer: Explorer, speech: Speaker, haptics: Haptics, audio: SpatialAudio) {
        self.explorer = explorer
        self.speech = speech
        self.haptics = haptics
        self.audio = audio
        heading = explorer.heading
    }

    /// "Guiding to Family room, 22 steps. Formal dining room, turn 45 degrees left, 3 steps."
    /// When the first door is the goal's, one number, not two for the same
    /// place: "Guiding to Half bath, turn 45 degrees right, 5 steps."
    func start(room: Int, onFloor f: Int) {
        let name = explorer.house.floors[f].rooms[room].name
        guard f != explorer.floorIndex || room != explorer.currentRoom else {
            speech.say("You're in the \(name).", interrupt: true)
            return
        }
        goal = (f, room)
        lastRoom = (explorer.floorIndex, explorer.currentRoom)
        guard let trip = Directions.trip(to: room, onFloor: f, explorer) else {
            goal = nil
            speech.say("\(name), no way there from here.", interrupt: true)
            return
        }
        aimAt(trip.aim)
        let next = trip.next.prefix(1).uppercased() + trip.next.dropFirst()
        let rail = explorer.onRail ? " " + Directions.leaveRail : ""
        let way = trip.firstDoorIsGoal ? "\(trip.way)." : "\(steps(trip.feet)). \(next)."
        speech.say("Guiding to \(name), \(way)\(rail)", interrupt: true)
    }

    func stop(silently: Bool = false) {
        guard running else { return }
        goal = nil
        aimAt(nil)
        if !silently { speech.say("Guide stopped.", interrupt: true) }
    }

    /// The current leg again, from the way you face now: on a single tap, which
    /// cuts off whatever's playing, and after stepping off the path, which
    /// waits behind "Off the path".
    func repeatLeg(interrupt: Bool = true) {
        guard let goal, let leg = Directions.leg(to: goal.room, onFloor: goal.floor, explorer) else { return }
        aimAt(leg.aim)
        speech.say(leg.text, interrupt: interrupt)
    }

    /// Called on every head turn. Ticks once when you come to face the leg's
    /// aim. Off the path only: on it, walking follows the path whichever way
    /// you face.
    func headingChanged(to heading: Double) {
        self.heading = heading
        guard let aim, !explorer.onRail, explorer.position.distance(to: aim) >= 1.5 else { return }
        let off = abs(turnAngle(from: explorer.position, to: aim, heading: heading))
        if off > Self.rearmDegrees {
            facingArmed = true
        } else if off <= Self.facingDegrees, facingArmed {
            facingArmed = false
            stopTicks()
            haptics.facing()
            speech.request("Facing it.")
        }
    }

    /// Points the facing tick at a new leg. Already facing it means no tick
    /// until you've turned away.
    private func aimAt(_ point: CGPoint?) {
        aim = point
        stopTicks()
        guard let point else { return }
        facingArmed = abs(turnAngle(from: explorer.position, to: point, heading: heading)) > Self.facingDegrees
        if facingArmed, Setting.turnTicks.isOn, !explorer.onRail { startTicks() }
    }

    /// Ticks in the ear to turn toward, from the way you face at each tick,
    /// so turning past the aim moves the tick to the other ear.
    private func startTicks() {
        ticksLeft = Self.maxTicks
        tickTimer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            // Within reach the voice says "right here" and the angle swings
            // with every inch, so there's nothing to turn toward.
            guard let self, let aim, ticksLeft > 0, !explorer.onRail,
                  explorer.position.distance(to: aim) >= 1.5 else { self?.stopTicks(); return }
            let off = turnAngle(from: explorer.position, to: aim, heading: heading)
            guard abs(off) > Self.facingDegrees else { return }
            ticksLeft -= 1
            audio.turnTick(right: off > 0)
        }
    }

    private func stopTicks() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    /// The explorer calls this after every move, room change, and floor change.
    /// Only a new room (or floor) says anything.
    func update() {
        guard let goal else { return }
        let now = (floor: explorer.floorIndex, room: explorer.currentRoom)
        guard now.floor != lastRoom?.floor || now.room != lastRoom?.room else { return }
        lastRoom = now
        if now.floor == goal.floor, now.room == goal.room {
            self.goal = nil
            aimAt(nil)
            // Walking in already says the room's name, unless that's switched off.
            let name = explorer.house.floors[goal.floor].rooms[goal.room].name
            speech.say(Setting.speakRooms.isOn ? "You're there." : "\(name). You're there.")
            return
        }
        guard let leg = Directions.leg(to: goal.room, onFloor: goal.floor, explorer) else { return }
        aimAt(leg.aim)
        speech.say(leg.text)
    }
}
