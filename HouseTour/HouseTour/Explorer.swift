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

    let house: House
    private let haptics: Haptics
    private let audio: SpatialAudio
    private let speech: Speaker

    /// True during the guided tour, which narrates rooms itself.
    private(set) var narrating = false

    var floor: Floor { house.floors[floorIndex] }

    private var touching = false
    private var lastLabel: Int?      // room under the avatar
    private var currentRoom: Int?    // room last announced; nil = outside
    private var pending: (room: Int?, since: Date, origin: CGPoint)?
    private var strideDistance = 0.0
    private var atDoors = Set<Int>()  // doors already announced on this arrival
    private var contact: [CellKind?] = [nil, nil]   // what each axis (x, y) last bumped
    private var lastHit = [Date.distantPast, Date.distantPast]
    private var currentFixture: String?
    private var stairsHold: (since: Date, origin: CGPoint)?
    private var stairsArmed = true
    private var beaconBoostUntil = Date.distantPast
    private var timer: Timer?

    static let stride = 2.5          // ft per virtual footstep
    static let warningZone = 1.5     // ft from a wall where the hum starts
    static let doorReach = 1.0       // ft from a door's opening that counts as "at the door"
    static let doorRearm = 2.0       // ft away before the same door is announced again

    init(house: House, haptics: Haptics, audio: SpatialAudio, speech: Speaker) {
        self.house = house
        self.haptics = haptics
        self.audio = audio
        self.speech = speech
        position = house.entrance
        floorIndex = house.frontDoor.floor
        let start = house.floors[house.frontDoor.floor]
        lastLabel = start.roomIndex(at: house.entrance)
        currentRoom = lastLabel
        roomName = currentRoom.map { start.rooms[$0].name } ?? "Outside"
        audio.moveListener(to: house.entrance)
    }

    // MARK: Input

    /// A finger landed. It doesn't move the avatar; it only wakes the channels
    /// that run while touching.
    func touchDown() {
        touching = true
        updateBeacon()
        audio.setWind(Setting.wind.isOn && currentRoom == nil)
        stairsHold = nil
        updateProximity(position)
        startTimer()
    }

    /// Trackpad input: move by `delta` feet, stopping at walls.
    func drag(by delta: CGVector) {
        guard touching, !narrating else { return }
        let move = floor.slide(from: position, by: delta)
        bump(x: move.hitX, y: move.hitY, at: move.end)
        walk(to: move.end)
    }

    /// Moves the avatar along a straight, already-clear line and fires whatever it
    /// passes. The guided tour calls this directly; its path never crosses a wall.
    func walk(to p: CGPoint) {
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
        strideDistance += d
        if strideDistance >= Self.stride {
            strideDistance = 0
            footstep()
        }
        updateProximity(p)
        checkDoors(p)
        checkFixture(p)
        checkPending(p)
    }

    func touchUp() {
        // A quick swipe into a room and lift still deserves the room's name.
        if let pend = pending, lastLabel == pend.room {
            commit(pend.room)
        }
        touching = false
        pending = nil
        stairsHold = nil
        timer?.invalidate()
        timer = nil
        haptics.proximity(0)
        updateBeacon()
        audio.setWind(false)
    }

    // MARK: Queries

    /// Short location, said on a single tap.
    func announceLocation() {
        speech.say((currentRoom.map { floor.rooms[$0].name } ?? "Outside the house") + ".", interrupt: true)
    }

    /// "First floor, Kitchen. Near the wall ahead. Tile. The front door is behind you on your left, about 9 steps."
    /// Interior doors are left out on purpose: they're announced when you reach them.
    func whereAmI() {
        let p = position
        var parts: [String]
        if let room = currentRoom {
            let r = floor.rooms[room]
            parts = ["\(floor.name), \(r.name)", wallHint(p, in: r.rect)]
            if !r.isCloset { parts.append(r.floor.spoken) }
        } else {
            parts = ["\(floor.name), outside the house"]
        }
        parts.append(frontDoorHint(from: p))
        speech.say(parts.joined(separator: ". ") + ".", interrupt: true)
    }

    /// The reset button for when someone is lost. Points the way and plays the
    /// beacon loudly for a few seconds, even if the beacon is switched off.
    func findFrontDoor() {
        haptics.frontDoor()
        let p = position
        let sameFloor = floorIndex == house.frontDoor.floor
        speech.say(frontDoorHint(from: p) + (sameFloor ? ". Follow the chime." : "."), interrupt: true)
        guard sameFloor else { return }
        beaconBoostUntil = Date().addingTimeInterval(6)
        updateBeacon()
        audio.boostBeacon()
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.1) { [weak self] in self?.updateBeacon() }
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
        guard !narrating else { return }
        var text = floor.name + "."
        if let room = currentRoom, floor.rooms[room].isStairs {
            text += " You're on the stairs."
        } else {
            text += " " + roomSentence(currentRoom)
        }
        speech.say(text, interrupt: true)
    }

    // MARK: Guided tour hooks

    func beginTour(at p: CGPoint, floor index: Int) {
        narrating = true
        if floorIndex != index { floorIndex = index }
        position = p
        audio.moveListener(to: p)
        lastLabel = floor.roomIndex(at: p)
        setRoom(lastLabel)
        pending = nil
        strideDistance = 0
        atDoors = doorsInReach(p)
        currentFixture = floor.fixture(at: p)?.name
        touchDown()
    }

    func endTour() {
        narrating = false
        touchUp()
    }

    // MARK: Event detection

    /// One knock per contact. Pushing into the same wall stays quiet; an axis
    /// re-arms once the avatar is 0.5 ft clear of walls or hasn't touched one for
    /// 0.6 s. Hitting a corner while sliding is a new axis, so it knocks.
    private func bump(x: CellKind?, y: CellKind?, at p: CGPoint) {
        let now = Date()
        let clear = floor.distanceToBlocking(from: p, within: 0.5) == nil
        var fired: CellKind?
        for (axis, hit) in [x, y].enumerated() {
            if clear || now.timeIntervalSince(lastHit[axis]) > 0.6 { contact[axis] = nil }
            guard let hit else { continue }
            lastHit[axis] = now
            if contact[axis] != hit, fired == nil { fired = hit }
            contact[axis] = hit
        }
        guard let fired else { return }
        haptics.blocked(fired)
        if fired != .wall, Setting.speakObstacles.isOn { speech.say(blockedName(fired) + ".", dedupe: 4) }
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
        if !narrating, Setting.speakRooms.isOn { speech.say(roomSentence(room), interrupt: !doorJustSpoken, dedupe: 2) }
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
        if !narrating, Setting.speakDoors.isOn {
            speech.say(doorName(door))
            lastDoorSpeech = Date()
        }
    }

    private func checkFixture(_ p: CGPoint) {
        let name = floor.fixture(at: p)?.name
        guard name != currentFixture else { return }
        currentFixture = name
        if let name {
            haptics.fixture()
            if !narrating, Setting.speakObstacles.isOn { speech.say(name + ".", dedupe: 3) }
        }
    }

    /// Holding still on the stairs for 1.2 s, finger down, climbs (or descends) them.
    private func checkStairsHold() {
        guard touching, !narrating else { return }
        let p = position
        guard currentRoom.map({ floor.rooms[$0].isStairs }) ?? false else {
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
                speech.say("Keep following the stairs. " + stairsGuide(from: p), interrupt: true)
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
        // The tour walks hallways; a constant hum there is just noise.
        guard touching, !narrating, Setting.wallHum.isOn,
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
            self.checkPending(self.position)
            self.checkStairsHold()
        }
    }

    // MARK: Phrases

    private func roomSentence(_ room: Int?) -> String {
        guard let room else { return "Outside the house." }
        let r = floor.rooms[room]
        if r.isStairs {
            let base = floorIndex == 0 ? "Stairs going up." : "Stairs going down."
            guard !house.stairsConnect(at: position) else {
                return base + (floorIndex == 0 ? " Hold still to climb." : " Hold still to go down.")
            }
            return base + " " + stairsGuide(from: position)
        }
        return r.entrySentence
    }

    /// "Follow them on your left, about 3 steps, then hold still."
    private func stairsGuide(from p: CGPoint) -> String {
        guard let target = house.stairLanding else { return "Hold still to change floors." }
        return "Follow them \(relativeDirection(from: p, to: target)), about \(steps(p.distance(to: target))), then hold still."
    }

    private func blockedName(_ k: CellKind) -> String {
        switch k {
        case .wall: "Wall"
        case .window: "Window"
        case .screen: "Porch screen"
        case .railing: "Railing"
        case .void: "Railing. Open to the floor below"
        case .open: ""
        }
    }

    /// "Door to Kitchen", "Opening to Dining area", "Front door". Names the side
    /// you're not on.
    private func doorName(_ door: Door) -> String {
        if let name = door.name { return name }
        let here = lastLabel ?? currentRoom
        let other = door.a == here ? door.b : door.a
        let otherName = other >= 0 ? floor.rooms[other].name : "outside"
        return "\(door.kind == "opening" ? "Opening" : "Door") to \(otherName)"
    }

    private func frontDoorHint(from p: CGPoint) -> String {
        let door = house.frontDoor
        guard floorIndex == door.floor else {
            guard let s = floor.stairsIndex else { return "The front door is downstairs" }
            let r = floor.rooms[s].rect
            let c = CGPoint(x: r.midX, y: r.midY)
            return "The front door is downstairs. The stairs are \(relativeDirection(from: p, to: c)), about \(steps(p.distance(to: c)))"
        }
        return "The front door is \(relativeDirection(from: p, to: door.point)), about \(steps(p.distance(to: door.point)))"
    }

    private func wallHint(_ p: CGPoint, in r: CGRect) -> String {
        let gaps = [
            ("Near the wall ahead", p.y - r.minY),
            ("Near the wall behind you", r.maxY - p.y),
            ("Near the left wall", p.x - r.minX),
            ("Near the right wall", r.maxX - p.x),
        ]
        let closest = gaps.min { $0.1 < $1.1 }!
        return closest.1 < 2.5 ? closest.0 : "In the middle of the room"
    }
}
