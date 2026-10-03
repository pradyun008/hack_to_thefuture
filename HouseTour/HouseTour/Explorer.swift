import Combine
import CoreGraphics
import Foundation

/// Owns the avatar and turns its movement into haptic, audio, and speech events.
/// The avatar has its own position in feet. The finger only nudges it, like a
/// laptop trackpad, so a blind user can't skip to a spot they can't see, and
/// walls stop it the way they stop a person.
final class Explorer: ObservableObject {
    @Published private(set) var floorIndex = 0
    @Published private(set) var position: CGPoint
    @Published private(set) var roomName = ""
    /// The way the avatar faces, in radians (0 = up the screen, clockwise). The
    /// trackpad turns with it: finger up walks ahead, finger right walks to your
    /// right. It holds still while the finger is down, so a sideways drag can't
    /// spin you, and on lift turns to the way you walked (unless you backed up).
    @Published private(set) var heading: Double {
        didSet { audio.face(heading) }
    }
    /// Whether the avatar is locked to the route. On the rail it can only slide
    /// forward and back, which is what makes a big room impossible to get lost
    /// in. A double tap steps off and back on.
    @Published private(set) var onRail: Bool

    let house: House
    /// The route through the house, or nil if this house has none.
    let rail: Rail?
    private let haptics: Haptics
    private let audio: SpatialAudio
    private let speech: Speaker

    /// Called after every move, room change, and floor change. The guided tour
    /// watches it for checkpoint arrivals.
    var onUpdate: (() -> Void)?
    /// Asked before a room's name is spoken on entry. The tour says no for the
    /// room it's about to narrate, so the name isn't said twice.
    var shouldAnnounceRoom: ((Int?) -> Bool)?

    var floor: Floor { house.floors[floorIndex] }

    private(set) var currentRoom: Int?    // room last announced; nil = outside
    private var touching = false
    private var lastLabel: Int?      // room under the avatar
    private var pending: (room: Int?, since: Date, origin: CGPoint)?
    private var strideDistance = 0.0
    private var trail: [CGPoint] = []  // recent path, newest last, for the heading
    private var travelHeading: Double?  // way this drag walked, applied on lift
    private var atDoors = Set<Int>()  // doors already announced on this arrival
    private var lastCrossed: [String: Date] = [:]  // when each room was entered or door reached
    private var contact: [CellKind?] = [nil, nil]   // what each axis (x, y) last bumped
    private var lastHit = [Date.distantPast, Date.distantPast]
    private var lastKnock = Date.distantPast
    private var currentFixture: String?
    private var stairsHold: (since: Date, origin: CGPoint)?
    private var stairsArmed = true
    private var railRun = 0      // which storey's stretch of the route
    private var railPos = 0.0    // feet along that stretch
    private var timer: Timer?

    static let stride = 2.5          // ft per virtual footstep
    static let warningZone = 1.5     // ft from a wall where the hum starts
    static let doorReach = 1.0       // ft from a door's opening that counts as "at the door"
    static let doorRearm = 2.0       // ft away before the same door is announced again
    static let repeatQuiet = 8.0     // s before a room or door you keep crossing is named again
    static let headingWindow = 1.5   // ft of travel the heading is taken over
    static let knockRepeat = 0.3     // s between knocks while pushing into a wall

    init(house: House, haptics: Haptics, audio: SpatialAudio, speech: Speaker) {
        self.house = house
        self.haptics = haptics
        self.audio = audio
        self.speech = speech
        let rail = Rail(tour: house.tour)
        self.rail = rail
        onRail = rail != nil
        let index = house.frontDoor.floor
        // Exploring starts at the head of the route, which the tour lays down
        // just inside the front door.
        var start = house.entrance
        var facing = house.entranceHeading
        if let rail, let run = rail.run(onFloor: index) {
            railRun = run
            start = rail.point(run: run, at: 0)
            let t = rail.tangent(run: run, at: 0)
            facing = atan2(t.dx, -t.dy)
        }
        position = start
        heading = facing
        floorIndex = index
        let plan = house.floors[index]
        lastLabel = plan.roomIndex(at: start)
        currentRoom = lastLabel
        roomName = currentRoom.map { plan.rooms[$0].name } ?? "Outside"
        trail = [start]
        audio.moveListener(to: start)
        audio.face(facing)
    }

    var isOnStairs: Bool { currentRoom.map { floor.rooms[$0].isStairs } ?? false }

    /// The room's name, or "Outside the house".
    var roomLabel: String { currentRoom.map { floor.rooms[$0].name } ?? "Outside the house" }

    // MARK: Input

    /// A finger landed. It doesn't move the avatar; it only wakes the channels
    /// that run while touching.
    func touchDown() {
        touching = true
        trail = [position]
        travelHeading = nil
        updateBeacon()
        audio.setWind(Setting.wind.isOn && currentRoom == nil)
        stairsHold = nil
        updateProximity(position)
        startTimer()
    }

    /// Trackpad input: move by `delta` feet, stopping at walls. `delta` is in
    /// screen terms (up is -y) and gets turned to the heading, so up is ahead.
    func drag(by delta: CGVector) {
        guard touching else { return }
        let s = sin(heading), c = cos(heading)
        let step = CGVector(dx: delta.dx * c - delta.dy * s, dy: delta.dx * s + delta.dy * c)
        if onRail, let rail {
            slideRail(rail, by: step)
            return
        }
        let move = floor.slide(from: position, by: step)
        bump(x: move.hitX, y: move.hitY, pushing: step, at: move.end)
        walk(to: move.end)
    }

    /// On the rail the avatar has one degree of freedom, so the finger's move is
    /// projected onto the route's own direction: dragging onward walks onward,
    /// and a sideways drag does nothing instead of grinding into a wall. The two
    /// ends of the route knock like walls, because they're where it runs out.
    private func slideRail(_ rail: Rail, by step: CGVector) {
        let t = rail.tangent(run: railRun, at: railPos)
        let ds = step.dx * t.dx + step.dy * t.dy
        guard abs(ds) > 0.0001 else { return }
        let next = max(0, min(railPos + ds, rail.length(of: railRun)))
        guard next != railPos else {
            if Date().timeIntervalSince(lastKnock) >= Self.knockRepeat {
                haptics.blocked(.wall)
                lastKnock = Date()
            }
            return
        }
        // Walk the corners in between. Going straight from one arc length to
        // another cuts the corner, and a cut corner can cross a wall even
        // though every segment of the route is clear.
        for corner in rail.corners(run: railRun, from: railPos, to: next) { walk(to: corner) }
        railPos = next
        walk(to: rail.point(run: railRun, at: next))
        // The trackpad turns with the route, so "drag up" keeps meaning "onward"
        // around a corner. There's no spin risk the way there is in open floor:
        // on a track, a sideways drag can't turn you.
        heading = railHeading(rail)
    }

    /// The compass angle of the route where the avatar stands, facing onward.
    private func railHeading(_ rail: Rail) -> Double {
        let t = rail.tangent(run: railRun, at: railPos)
        return atan2(t.dx, -t.dy)
    }

    /// Double tap: step off the route, or snap back onto it. Off the rail the
    /// avatar walks freely and walls stop it as usual, for feeling out a room;
    /// back on, it returns to the nearest point of the route on this floor.
    func toggleRail() {
        guard let rail else { return }
        if onRail {
            onRail = false
            speech.request("Off the path. Double tap to come back.")
            return
        }
        guard let run = rail.run(onFloor: floorIndex) else {
            speech.request("The path doesn't come to this floor.")
            return
        }
        onRail = true
        railRun = run
        railPos = rail.project(position, run: run, near: railPos)
        teleport(to: rail.point(run: run, at: railPos), floor: floorIndex, heading: railHeading(rail))
        speech.request("Back on the path. " + roomLabel + ".")
    }

    /// Moves the avatar along a straight, already-clear line and fires whatever it
    /// passes.
    private func walk(to p: CGPoint) {
        let prev = position
        let d = prev.distance(to: p)
        guard d > 0.001 else { return }
        // Sample every 0.1 ft so a fast move can't skip a narrow room or doorway.
        let n = max(1, Int(ceil(d / 0.1)))
        for i in 1...n {
            let t = Double(i) / Double(n)
            sample(CGPoint(x: prev.x + (p.x - prev.x) * t, y: prev.y + (p.y - prev.y) * t))
        }
        position = p
        audio.moveListener(to: p)
        // On the rail the heading comes from the route, not from the way you walked.
        if !onRail { updateHeading(p) }
        strideDistance += d
        if strideDistance >= Self.stride {
            strideDistance = 0
            footstep()
        }
        updateProximity(p)
        checkDoors(p)
        checkFixture(p)
        checkPending(p)
        onUpdate?()
    }

    func touchUp() {
        // A quick swipe into a room and lift still deserves the room's name.
        if let pend = pending, lastLabel == pend.room {
            commit(pend.room)
        }
        touching = false
        // Face the way you walked. Backing up keeps your heading, the way a
        // person stepping back still faces forward.
        if let h = travelHeading, !onRail {
            var turn = (h - heading).truncatingRemainder(dividingBy: 2 * .pi)
            if turn > .pi { turn -= 2 * .pi }
            if turn < -.pi { turn += 2 * .pi }
            if abs(turn) <= .pi * 3 / 4 { heading = h }
        }
        travelHeading = nil
        pending = nil
        stairsHold = nil
        timer?.invalidate()
        timer = nil
        haptics.proximity(0)
        updateBeacon()
        audio.setWind(false)
        onUpdate?()
    }

    // MARK: Queries

    /// Short location, said on a single tap.
    func announceLocation() {
        speech.request(roomLabel + ".")
    }

    /// Triple tap: where you are, in three facts. Which room, how close you are
    /// to a wall, and the nearest door. Nothing else: this gets asked in the
    /// middle of walking, and a tap can't cut speech off, so every extra clause
    /// is time the user is stuck waiting.
    /// "First floor, Kitchen. Wall on your left. Opening to Dining area on your right, 2 steps."
    func whereAmI() {
        let p = position
        guard let room = currentRoom else {
            speech.request("\(floor.name), outside the house.")
            return
        }
        var parts = ["\(floor.name), \(floor.rooms[room].name)", wallHint(p, in: floor.rooms[room].rect)]
        if let i = nearbyDoors(p).first {
            let spot = floor.nearestPoint(onDoor: i, from: p)
            parts.append("\(doorName(floor.doors[i], from: currentRoom)) \(place(from: p, to: spot, heading: heading))")
        }
        speech.request(parts.joined(separator: ". ") + ".")
    }

    /// Asked aloud: every way out of the room, nearest first, and where each
    /// goes. Closets aren't ways out, so they're left out unless there's
    /// nothing else. "Kitchen, 2 ways out. Opening to Dining area on your
    /// right, 2 steps. Door to Hall behind you, 6 steps."
    func waysOut() {
        let p = position
        guard let room = currentRoom else {
            speech.request("Outside the house. " + frontDoorDirections())
            return
        }
        let doors = floor.doors.indices.filter { floor.doors[$0].a == room || floor.doors[$0].b == room }
        let open = doors.filter { !leadsToCloset($0, from: room) }
        let exits = (open.isEmpty ? doors : open)
            .sorted { floor.distance(toDoor: $0, from: p) < floor.distance(toDoor: $1, from: p) }
        let name = floor.rooms[room].name
        guard !exits.isEmpty else {
            speech.request("\(name). No doors out.")
            return
        }
        // Four is plenty to hold in your head; the rest are farther anyway.
        let list = exits.prefix(4).map {
            "\(doorName(floor.doors[$0], from: room)) \(place(from: p, to: floor.nearestPoint(onDoor: $0, from: p), heading: heading))"
        }
        let count = exits.count == 1 ? "1 way out" : "\(exits.count) ways out"
        speech.request("\(name), \(count). " + list.joined(separator: ". ") + ".")
    }

    /// Asked aloud: the way to the front door, by way of the stairs when it's
    /// on the other floor.
    func wayToFrontDoor() {
        speech.request(frontDoorDirections())
    }

    /// Asked aloud: the way to a room, by way of the stairs when it's on the
    /// other floor. "Kitchen. Through the door to Hall ahead, 4 steps."
    func wayTo(room index: Int, onFloor f: Int) {
        let target = house.floors[f].rooms[index]
        guard f == floorIndex else {
            speech.request("\(target.name), \(house.floors[f].name.lowercased()). " + stairsDirections(up: f > floorIndex))
            return
        }
        guard index != currentRoom else {
            speech.request("You're in the \(target.name).")
            return
        }
        let center = CGPoint(x: target.rect.midX, y: target.rect.midY)
        let spot = target.isStairs ? house.stairLanding ?? center : center
        speech.request("\(target.name). " + route(to: spot, room: index))
    }

    /// "Front door. Through the door to Foyer ahead, 4 steps."
    private func frontDoorDirections() -> String {
        let front = house.frontDoor
        guard front.floor == floorIndex else {
            return "Front door, \(house.floors[front.floor].name.lowercased()). " + stairsDirections(up: front.floor > floorIndex)
        }
        guard let i = floor.doors.firstIndex(where: \.isFront) else {
            return "Front door. " + route(to: front.point, room: nil)
        }
        let door = floor.doors[i]
        return "Front door. " + route(to: floor.nearestPoint(onDoor: i, from: position), room: door.a >= 0 ? door.a : door.b)
    }

    /// The way to this floor's stairs, or how to use them when already on them.
    private func stairsDirections(up: Bool) -> String {
        if isOnStairs { return up ? "Hold still on the stairs to climb." : "Hold still on the stairs to go down." }
        guard let s = floor.stairsIndex else { return "" }
        let r = floor.rooms[s].rect
        return route(to: house.stairLanding ?? CGPoint(x: r.midX, y: r.midY), room: s, name: "Stairs")
    }

    /// How to get to `target` in room `room` on this floor: through the first
    /// door on the way when it's in another room, otherwise straight there.
    /// `name` is the goal's name when the caller hasn't just said it. When it
    /// has, a door straight into the goal is only "Door": "Door on your left,
    /// 3 steps." A door to somewhere else starts with "Through" so its room
    /// isn't heard as the goal: "Through the door to Hall ahead, 4 steps."
    func route(to target: CGPoint, room: Int?, tourStep: Int? = nil, name: String? = nil) -> String {
        let p = position
        // On the rail there's nowhere to go but along it, so a bearing would be
        // noise: how far, and which way round, is the whole answer.
        if onRail, let rail, rail.runs[railRun].floor == floorIndex {
            let exact = tourStep.flatMap { rail.location(ofTourStep: $0) }
            let s = exact?.run == railRun ? exact!.s : rail.project(target, run: railRun, near: railPos)
            let d = s - railPos
            if abs(d) < 1.5 { return "Right here on the path." }
            return "\(d > 0 ? "Ahead" : "Back") along the path, \(steps(abs(d)))."
        }
        if let here = currentRoom ?? lastLabel, let goal = room, let i = floor.firstDoor(from: here, to: goal) {
            let spot = floor.nearestPoint(onDoor: i, from: p)
            let door = floor.doors[i]
            let intoGoal = name == nil && door.name == nil && (door.a == goal || door.b == goal)
            let other = doorName(door, from: here)
            let label = intoGoal ? (door.kind == "opening" ? "Opening" : "Door")
                : name == nil ? "Through the " + other.prefix(1).lowercased() + other.dropFirst() : other
            return "\(label) \(place(from: p, to: spot, heading: heading))."
        }
        let there = place(from: p, to: target, heading: heading)
        if let name { return "\(name) \(there)." }
        return there.prefix(1).uppercased() + there.dropFirst() + "."
    }

    /// Switch storeys. On the stairs the avatar keeps its spot (the floors are
    /// aligned there). From the button it lands on the stairs, since the same
    /// spot on the other floor could be inside a wall.
    func changeFloor(viaStairs: Bool = false) {
        let goingUp = floorIndex == 0
        floorIndex = goingUp ? 1 : 0
        if viaStairs { haptics.stairs(up: goingUp) }
        if onRail, let rail, let run = rail.run(onFloor: floorIndex) {
            // The route's two stretches meet on the stairs, so rejoin the new
            // one at whichever of its ends is the staircase.
            let onward = run > railRun
            railRun = run
            railPos = onward ? 0 : rail.length(of: run)
            position = rail.point(run: run, at: railPos)
            heading = railHeading(rail)
            audio.moveListener(to: position)
        } else if !viaStairs, let landing = house.stairLanding {
            position = landing
            audio.moveListener(to: landing)
        }
        trail = [position]
        stairsArmed = false
        stairsHold = nil
        pending = nil
        currentFixture = nil
        contact = [nil, nil]
        let p = position
        atDoors = doorsInReach(p)
        lastLabel = floor.roomIndex(at: p)
        setRoom(lastLabel)
        updateBeacon()
        var text = floor.name + "."
        if let room = currentRoom, floor.rooms[room].isStairs {
            text += " On the stairs."
        } else {
            text += " " + roomSentence(currentRoom)
        }
        // Climbing is movement, so it can cut off stale speech. The button waits
        // its turn: buttons never interrupt.
        speech.say(text, interrupt: viaStairs)
        onUpdate?()
    }

    /// Puts the avatar somewhere directly, for the tour's restart and jump.
    /// Says nothing; the tour narrates.
    /// `tourStep` is the step of `house.tour` being jumped to, when the caller
    /// knows it. On the rail that's better than the coordinates: the route
    /// doubles back, so two arc lengths share one spot on the floor, and only
    /// the step number says which of them is meant.
    func teleport(to p: CGPoint, floor index: Int, heading: Double, tourStep: Int? = nil) {
        if floorIndex != index { floorIndex = index }
        position = p
        self.heading = heading
        if onRail, let rail {
            let exact = tourStep.flatMap { rail.location(ofTourStep: $0) }
            if let spot = exact ?? rail.run(onFloor: index).map({ ($0, rail.project(p, run: $0, near: railPos)) }) {
                railRun = spot.0
                railPos = spot.1
                position = rail.point(run: railRun, at: railPos)
                self.heading = railHeading(rail)
            }
        }
        let landed = position
        trail = [landed]
        audio.moveListener(to: landed)
        lastLabel = floor.roomIndex(at: landed)
        setRoom(lastLabel)
        pending = nil
        strideDistance = 0
        atDoors = doorsInReach(landed)
        currentFixture = floor.fixture(at: landed)?.name
        contact = [nil, nil]
        stairsHold = nil
        stairsArmed = false
        updateBeacon()
    }

    // MARK: Event detection

    /// The first knock of a contact says what you hit (and its name, if that's
    /// switched on). Pushing on keeps knocking about three times a second so
    /// you can tell you're still against it; the name isn't repeated. An axis
    /// counts as a new contact once the avatar is 0.5 ft clear of walls or
    /// hasn't touched one for 0.6 s. Grazing a wall while sliding along it at a
    /// shallow angle doesn't repeat.
    private func bump(x: CellKind?, y: CellKind?, pushing delta: CGVector, at p: CGPoint) {
        let now = Date()
        let clear = floor.distanceToBlocking(from: p, within: 0.5) == nil
        let push = [abs(delta.dx), abs(delta.dy)]
        let total = hypot(delta.dx, delta.dy)
        var fresh: CellKind?, pressing: CellKind?
        for (axis, hit) in [x, y].enumerated() {
            if clear || now.timeIntervalSince(lastHit[axis]) > 0.6 { contact[axis] = nil }
            guard let hit else { continue }
            lastHit[axis] = now
            if contact[axis] != hit, fresh == nil { fresh = hit }
            contact[axis] = hit
            // At least half the push goes into the wall, not along it.
            if push[axis] >= total * 0.5, pressing == nil { pressing = hit }
        }
        if let fresh {
            haptics.blocked(fresh)
            lastKnock = now
            // Not over tour narration, and never queued behind it: by then it's stale.
            if fresh != .wall, Setting.speakObstacles.isOn, !speech.isNarrating {
                speech.say(blockedName(fresh) + ".", dedupe: 4)
            }
        } else if let pressing, now.timeIntervalSince(lastKnock) >= Self.knockRepeat {
            haptics.blocked(pressing)
            lastKnock = now
        }
    }

    /// The way you walked is the direction from where the avatar was 1.5 ft of
    /// walking ago to where it is now. Jiggling back and forth covers distance
    /// without going anywhere, so it only counts when that line is long enough.
    /// It's held until lift: turning mid-drag would turn the trackpad under the
    /// finger and walk you in circles.
    private func updateHeading(_ p: CGPoint) {
        if let last = trail.last, last.distance(to: p) < 0.1 { return }
        trail.append(p)
        var length = 0.0
        var oldest = trail.count - 1
        while oldest > 0, length < Self.headingWindow {
            length += trail[oldest].distance(to: trail[oldest - 1])
            oldest -= 1
        }
        trail.removeFirst(oldest)
        guard length >= Self.headingWindow, let tail = trail.first,
              tail.distance(to: p) >= Self.headingWindow * 0.6 else { return }
        travelHeading = bearing(from: tail, to: p)
    }

    private func sample(_ q: CGPoint) {
        let label = floor.roomIndex(at: q)
        guard label != lastLabel else { return }
        lastLabel = label
        propose(label, at: q)
    }

    private func propose(_ room: Int?, at q: CGPoint) {
        pending = room == currentRoom ? nil : (room, Date(), q)
    }

    /// Announce a new room only once the avatar has settled in it: 0.35 s or 1 ft
    /// past the boundary. Wiggling across a doorway shouldn't chatter.
    private func checkPending(_ p: CGPoint) {
        guard let pend = pending, lastLabel == pend.room else { return }
        if Date().timeIntervalSince(pend.since) >= 0.35 || p.distance(to: pend.origin) >= 1.0 {
            pending = nil
            commit(pend.room)
        }
    }

    private func commit(_ room: Int?) {
        guard room != currentRoom else { return }
        setRoom(room)
        guard !crossedRecently("room \(room ?? -1)") else { return }
        // Queue behind a door name said a moment ago instead of cutting it off.
        let doorJustSpoken = Date().timeIntervalSince(lastDoorSpeech) < 1.5
        // Not over tour narration: queued behind it, the name would be stale.
        if Setting.speakRooms.isOn, !speech.isNarrating, shouldAnnounceRoom?(room) ?? true {
            speech.say(roomSentence(room), interrupt: !doorJustSpoken, dedupe: 2)
        }
    }

    private var lastDoorSpeech = Date.distantPast

    /// Pacing back and forth through a doorway would name the same rooms and
    /// door on every pass. Each pass restarts the clock, so the names stay quiet
    /// until you've been away from that spot for `repeatQuiet` seconds. The
    /// haptics still play every time.
    private func crossedRecently(_ what: String) -> Bool {
        let key = "\(floorIndex) \(what)"
        let now = Date()
        defer { lastCrossed[key] = now }
        return lastCrossed[key].map { now.timeIntervalSince($0) < Self.repeatQuiet } ?? false
    }

    private func setRoom(_ room: Int?) {
        currentRoom = room
        roomName = room.map { floor.rooms[$0].name } ?? "Outside"
        audio.setWind(touching && Setting.wind.isOn && room == nil)
    }

    private func doorsInReach(_ p: CGPoint) -> Set<Int> {
        Set(floor.doors.indices.filter { floor.distance(toDoor: $0, from: p) <= Self.doorReach })
    }

    /// Doors are only mentioned when you're standing in one. Each arrival plays
    /// the door's pattern once and says where it goes; moving 2 ft away re-arms it.
    private func checkDoors(_ p: CGPoint) {
        var arrived: (index: Int, distance: Double)?
        for i in floor.doors.indices {
            // Reach is a circle, so near a wall it can poke into the room behind it.
            // Only count doors that open off the room you're actually in.
            let door = floor.doors[i]
            guard door.a == (lastLabel ?? -1) || door.b == (lastLabel ?? -1) else {
                atDoors.remove(i)
                continue
            }
            let d = floor.distance(toDoor: i, from: p)
            if d > Self.doorRearm {
                atDoors.remove(i)
            } else if d <= Self.doorReach, !atDoors.contains(i) {
                atDoors.insert(i)
                if d < arrived?.distance ?? .infinity { arrived = (i, d) }
            }
        }
        // Closet doors can sit side by side; only the nearest one speaks.
        guard let arrived else { return }
        let door = floor.doors[arrived.index]
        if door.isFront {
            haptics.frontDoor()
            audio.chime()
        } else if door.kind == "opening" {
            haptics.opening()
        } else {
            haptics.doorway()
        }
        if !crossedRecently("door \(arrived.index)"), Setting.speakDoors.isOn, !speech.isNarrating {
            speech.say(doorName(door, from: lastLabel ?? currentRoom))
            lastDoorSpeech = Date()
        }
    }

    private func checkFixture(_ p: CGPoint) {
        let name = floor.fixture(at: p)?.name
        guard name != currentFixture else { return }
        currentFixture = name
        if let name {
            haptics.fixture()
            if Setting.speakObstacles.isOn, !speech.isNarrating { speech.say(name + ".", dedupe: 3) }
        }
    }

    /// Holding still on the stairs for 1.2 s, finger down, climbs (or descends) them.
    private func checkStairsHold() {
        guard touching else { return }
        let p = position
        guard isOnStairs else {
            stairsArmed = true
            stairsHold = nil
            return
        }
        guard stairsArmed else { return }
        if let hold = stairsHold, hold.origin.distance(to: p) < 0.75 {
            guard Date().timeIntervalSince(hold.since) > 1.2 else { return }
            if house.stairsConnect(at: p) {
                changeFloor(viaStairs: true)
            } else {
                // This part of the stairs isn't drawn on the other floor. Point to the part that is.
                stairsHold = (Date.distantFuture, p)
                speech.say("Not here. " + stairsGuide(from: p), interrupt: true)
            }
        } else {
            stairsHold = (Date(), p)
        }
    }

    private func footstep() {
        guard Setting.textures.isOn, let room = lastLabel else { return }
        haptics.texture(floor.rooms[room].floor)
    }

    private func updateProximity(_ p: CGPoint) {
        guard touching, Setting.wallHum.isOn,
              let d = floor.distanceToBlocking(from: p, within: Self.warningZone) else {
            return haptics.proximity(0)
        }
        haptics.proximity(Float(0.12 + 0.55 * (1 - d / Self.warningZone)))
    }

    /// The beacon plays while touching, if it's switched on.
    private func updateBeacon() {
        audio.setBeacon(floorIndex == house.frontDoor.floor && touching && Setting.beacon.isOn)
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Settling into a room while holding still is still an arrival the tour must see.
            let room = self.currentRoom
            self.checkPending(self.position)
            if self.currentRoom != room { self.onUpdate?() }
            self.checkStairsHold()
        }
    }

    // MARK: Phrases

    private func roomSentence(_ room: Int?) -> String {
        guard let room else { return "Outside the house." }
        let r = floor.rooms[room]
        if r.isStairs {
            let base = floorIndex == 0 ? "Stairs up." : "Stairs down."
            guard !house.stairsConnect(at: position) else {
                return base + (floorIndex == 0 ? " Hold still to climb." : " Hold still to go down.")
            }
            return base + " " + stairsGuide(from: position)
        }
        return r.entrySentence
    }

    /// "Follow the stairs on your left, 3 steps, then hold still."
    private func stairsGuide(from p: CGPoint) -> String {
        guard let target = house.stairLanding else { return "Hold still to change floors." }
        guard p.distance(to: target) >= 1.5 else { return "Hold still right here." }
        return "Follow the stairs \(place(from: p, to: target, heading: heading)), then hold still."
    }

    private func blockedName(_ k: CellKind) -> String {
        switch k {
        case .wall: "Wall"
        case .window: "Window"
        case .screen: "Porch screen"
        case .railing: "Railing"
        case .void: "Railing, open below"
        case .open: ""
        }
    }

    /// "Door to Kitchen", "Opening to Dining area", "Front door". Names the side
    /// you're not on.
    private func doorName(_ door: Door, from here: Int?) -> String {
        if let name = door.name { return name }
        let other = door.a == here ? door.b : door.a
        let otherName = other >= 0 ? floor.rooms[other].name : "outside"
        return "\(door.kind == "opening" ? "Opening" : "Door") to \(otherName)"
    }

    /// The doors out of the room you're in, nearest first: the closest one, plus
    /// a second if it's within 10 ft. Closets only when there's nothing else.
    /// The front door is left out; it always gets its own sentence.
    private func nearbyDoors(_ p: CGPoint) -> [Int] {
        let here = currentRoom ?? -1
        let doors = floor.doors.indices
            .filter { (floor.doors[$0].a == here || floor.doors[$0].b == here) && !floor.doors[$0].isFront }
            .sorted { floor.distance(toDoor: $0, from: p) < floor.distance(toDoor: $1, from: p) }
        let main = doors.filter { !leadsToCloset($0, from: here) }
        guard let first = main.first else { return Array(doors.prefix(1)) }
        if main.count > 1, floor.distance(toDoor: main[1], from: p) <= 10 { return [first, main[1]] }
        return [first]
    }

    /// Door `i` opens from room `here` into a closet.
    private func leadsToCloset(_ i: Int, from here: Int) -> Bool {
        let d = floor.doors[i]
        let other = d.a == here ? d.b : d.a
        return other >= 0 && floor.rooms[other].isCloset
    }

    /// "Wall on your left", turned to the way you're facing.
    private func wallHint(_ p: CGPoint, in r: CGRect) -> String {
        let walls = [
            CGPoint(x: p.x, y: r.minY), CGPoint(x: p.x, y: r.maxY),
            CGPoint(x: r.minX, y: p.y), CGPoint(x: r.maxX, y: p.y),
        ]
        let nearest = walls.min { p.distance(to: $0) < p.distance(to: $1) }!
        guard p.distance(to: nearest) < 2.5 else { return "Middle of the room" }
        return "Wall " + relativeSide(from: p, to: nearest, heading: heading)
    }
}
