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

    let house: House
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
    private var contact: [CellKind?] = [nil, nil]   // what each axis (x, y) last bumped
    private var lastHit = [Date.distantPast, Date.distantPast]
    private var lastKnock = Date.distantPast
    private var currentFixture: String?
    private var stairsHold: (since: Date, origin: CGPoint)?
    private var stairsArmed = true
    private var beaconBoostUntil = Date.distantPast
    private var timer: Timer?

    static let stride = 2.5          // ft per virtual footstep
    static let warningZone = 1.5     // ft from a wall where the hum starts
    static let doorReach = 1.0       // ft from a door's opening that counts as "at the door"
    static let doorRearm = 2.0       // ft away before the same door is announced again
    static let headingWindow = 1.5   // ft of travel the heading is taken over
    static let knockRepeat = 0.3     // s between knocks while pushing into a wall

    init(house: House, haptics: Haptics, audio: SpatialAudio, speech: Speaker) {
        self.house = house
        self.haptics = haptics
        self.audio = audio
        self.speech = speech
        position = house.entrance
        heading = house.entranceHeading
        floorIndex = house.frontDoor.floor
        let start = house.floors[house.frontDoor.floor]
        lastLabel = start.roomIndex(at: house.entrance)
        currentRoom = lastLabel
        roomName = currentRoom.map { start.rooms[$0].name } ?? "Outside"
        trail = [house.entrance]
        audio.moveListener(to: house.entrance)
        audio.face(heading)
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
        let move = floor.slide(from: position, by: step)
        bump(x: move.hitX, y: move.hitY, pushing: step, at: move.end)
        walk(to: move.end)
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
        updateHeading(p)
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
        if let h = travelHeading {
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

    /// "First floor, Kitchen. Wall on your left. Tile. Front door back left, 9 steps."
    /// Interior doors are left out on purpose: they're announced when you reach them.
    func whereAmI() {
        let p = position
        var parts: [String]
        if let room = currentRoom {
            let r = floor.rooms[room]
            parts = ["\(floor.name), \(r.name)", wallHint(p, in: r.rect)]
            if !r.isCloset, r.floor != .unknown { parts.append(r.floor.spoken) }
        } else {
            parts = ["\(floor.name), outside the house"]
        }
        parts.append(frontDoorHint(from: p))
        speech.request(parts.joined(separator: ". ") + ".")
    }

    /// Double tap: what's around you. The room and floor, the nearest doors and
    /// where they go, the nearest built-in, and the front door.
    /// "Kitchen, first floor. Opening to Dining area on your right, 2 steps. Front door behind you, 7 steps."
    func describeSurroundings() {
        let p = position
        var parts = [currentRoom.map { "\(floor.rooms[$0].name), \(floor.name.lowercased())" }
                     ?? "Outside the house, \(floor.name.lowercased())"]
        let doors = nearbyDoors(p)
        for i in doors {
            let spot = floor.nearestPoint(onDoor: i, from: p)
            parts.append("\(doorName(floor.doors[i], from: currentRoom)) \(place(from: p, to: spot, heading: heading))")
        }
        // Say where the stairs are once: a door to them, or the landmark, or
        // (off the front door's floor) the front door hint.
        let stairsNamed = doors.contains { floor.doors[$0].a == floor.stairsIndex || floor.doors[$0].b == floor.stairsIndex }
        let offFrontFloor = floorIndex != house.frontDoor.floor
        if let landmark = nearestLandmark(p, skipStairs: stairsNamed || offFrontFloor) { parts.append(landmark) }
        parts.append(frontDoorHint(from: p, stairsSaid: stairsNamed))
        speech.request(parts.joined(separator: ". ") + ".")
    }

    /// The reset button for when someone is lost. Points the way and plays the
    /// beacon loudly for a few seconds, even if the beacon is switched off.
    /// Dropped entirely while something is being said.
    func findFrontDoor() {
        let p = position
        let sameFloor = floorIndex == house.frontDoor.floor
        guard speech.request(frontDoorHint(from: p) + (sameFloor ? ". Follow the chime." : ".")) else { return }
        haptics.frontDoor()
        guard sameFloor else { return }
        beaconBoostUntil = Date().addingTimeInterval(6)
        updateBeacon()
        audio.boostBeacon()
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.1) { [weak self] in self?.updateBeacon() }
    }

    /// How to get to `target` in room `room` on this floor: through the first
    /// door on the way when it's in another room, otherwise straight there.
    /// `name` is the goal's name when the caller hasn't just said it. When it
    /// has, a door straight into the goal is only "Door": "Door on your left,
    /// 3 steps." A door to somewhere else starts with "Through" so its room
    /// isn't heard as the goal: "Through the door to Hall ahead, 4 steps."
    func route(to target: CGPoint, room: Int?, name: String? = nil) -> String {
        let p = position
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
        if viaStairs {
            haptics.stairs(up: goingUp)
        } else if let landing = house.stairLanding {
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
    func teleport(to p: CGPoint, floor index: Int, heading: Double) {
        if floorIndex != index { floorIndex = index }
        position = p
        self.heading = heading
        trail = [p]
        audio.moveListener(to: p)
        lastLabel = floor.roomIndex(at: p)
        setRoom(lastLabel)
        pending = nil
        strideDistance = 0
        atDoors = doorsInReach(p)
        currentFixture = floor.fixture(at: p)?.name
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
        // Queue behind a door name said a moment ago instead of cutting it off.
        let doorJustSpoken = Date().timeIntervalSince(lastDoorSpeech) < 1.5
        // Not over tour narration: queued behind it, the name would be stale.
        if Setting.speakRooms.isOn, !speech.isNarrating, shouldAnnounceRoom?(room) ?? true {
            speech.say(roomSentence(room), interrupt: !doorJustSpoken, dedupe: 2)
        }
    }

    private var lastDoorSpeech = Date.distantPast

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
        if Setting.speakDoors.isOn, !speech.isNarrating {
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

    /// The beacon plays while touching if it's switched on, and for a few
    /// seconds after "find the front door" regardless.
    private func updateBeacon() {
        let boosted = Date() < beaconBoostUntil
        audio.setBeacon(floorIndex == house.frontDoor.floor && (boosted || (touching && Setting.beacon.isOn)))
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
        let isCloset = { (i: Int) -> Bool in
            let d = self.floor.doors[i]
            let other = d.a == here ? d.b : d.a
            return other >= 0 && self.floor.rooms[other].isCloset
        }
        let doors = floor.doors.indices
            .filter { (floor.doors[$0].a == here || floor.doors[$0].b == here) && !floor.doors[$0].isFront }
            .sorted { floor.distance(toDoor: $0, from: p) < floor.distance(toDoor: $1, from: p) }
        let main = doors.filter { !isCloset($0) }
        guard let first = main.first else { return Array(doors.prefix(1)) }
        if main.count > 1, floor.distance(toDoor: main[1], from: p) <= 10 { return [first, main[1]] }
        return [first]
    }

    /// The nearest built-in in this room, or the stairs, within 30 ft.
    /// "Fireplace ahead, 4 steps." A built-in behind a wall is no landmark.
    private func nearestLandmark(_ p: CGPoint, skipStairs: Bool = false) -> String? {
        let here = currentRoom.map { floor.rooms[$0].rect }
        var marks = floor.fixtures.filter { here?.intersects($0.cgRect) ?? false }.map { ($0.name, $0.cgRect) }
        if !isOnStairs, !skipStairs, let s = floor.stairsIndex { marks.append(("Stairs", floor.rooms[s].rect)) }
        let nearest = marks
            .map { mark in (mark.0, p.clamped(to: mark.1)) }
            .min { p.distance(to: $0.1) < p.distance(to: $1.1) }
        guard let nearest, p.distance(to: nearest.1) <= 30 else { return nil }
        return "\(nearest.0) \(place(from: p, to: nearest.1, heading: heading))"
    }

    /// Always names the front door, never just "the door". Off its floor it
    /// also points to the stairs, unless `stairsSaid`.
    private func frontDoorHint(from p: CGPoint, stairsSaid: Bool = false) -> String {
        let door = house.frontDoor
        guard floorIndex == door.floor else {
            let side = floorIndex > door.floor ? "downstairs" : "upstairs"
            if isOnStairs { return "Front door \(side). You're on the stairs" }
            guard !stairsSaid, let s = floor.stairsIndex else { return "Front door \(side)" }
            let r = floor.rooms[s].rect
            let c = CGPoint(x: r.midX, y: r.midY)
            return "Front door \(side). Stairs \(place(from: p, to: c, heading: heading))"
        }
        return "Front door \(place(from: p, to: door.point, heading: heading))"
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

extension CGPoint {
    /// The closest point inside `r`.
    fileprivate func clamped(to r: CGRect) -> CGPoint {
        CGPoint(x: min(max(x, r.minX), r.maxX), y: min(max(y, r.minY), r.maxY))
    }
}
