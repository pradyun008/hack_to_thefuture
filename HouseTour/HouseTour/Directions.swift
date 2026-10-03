import CoreGraphics
import Foundation

/// Spoken answers about the way to a room and what's around you. Every
/// direction is from where you stand, turned to the way you face right now, so
/// "turn 90 degrees right" means your right. Kept short: the place, how far
/// to turn, how many steps.
enum Directions {
    /// Ends a line when the avatar is locked to the route, since walking the
    /// way you face needs you off it.
    static let leaveRail = "Triple tap to leave the path."

    /// "Family room, 22 steps. Formal dining room, turn 45 degrees left, 3 steps."
    /// When the next door opens straight into the room, just that:
    /// "Kitchen, turn 90 degrees right, 4 steps."
    static func stepsTo(room goal: Int, onFloor f: Int, _ e: Explorer) -> String {
        let name = e.house.floors[f].rooms[goal].name
        guard f != e.floorIndex || goal != e.currentRoom else { return "You're in the \(name)." }
        guard let trip = trip(to: goal, onFloor: f, e) else { return "\(name), no way there from here." }
        let next = trip.next.prefix(1).uppercased() + trip.next.dropFirst()
        let floorName = f == e.floorIndex ? "" : ", \(e.house.floors[f].name.lowercased())"
        // A door straight into the room already names it.
        let text = trip.firstDoorIsGoal ? next : "\(name)\(floorName), \(steps(trip.feet)). \(next)"
        return text + "." + (e.onRail ? " " + leaveRail : "")
    }

    /// The next leg only: "Kitchen, turn 90 degrees right, 5 steps.", and the
    /// spot it points at. Nil once in the room.
    static func leg(to goal: Int, onFloor f: Int, _ e: Explorer) -> (text: String, aim: CGPoint?)? {
        guard f != e.floorIndex || goal != e.currentRoom else { return nil }
        guard let trip = trip(to: goal, onFloor: f, e) else { return ("No way there from here.", nil) }
        return (trip.next.prefix(1).uppercased() + trip.next.dropFirst() + ".", trip.aim)
    }

    /// The whole walk's length and how to start it. The length stops at the
    /// goal's doorway, since walking in is when "You're there" is said. `next`
    /// is the first door's room and where it is ("kitchen, turn 90 degrees
    /// right, 5 steps"), or the stairs when the goal is on the other floor.
    /// `way` is `next` without the room's name ("turn 90 degrees right, 5
    /// steps"). `aim` is the spot `next` points at, nil when there's nothing to
    /// turn toward.
    static func trip(to goal: Int, onFloor f: Int, _ e: Explorer)
        -> (feet: Double, next: String, way: String, firstDoorIsGoal: Bool, aim: CGPoint?)? {
        let p = e.position
        let plan = e.floor
        guard let here = e.currentRoom ?? plan.roomIndex(at: p) else { return nil }
        let target = e.house.floors[f].rooms[goal]
        let center = CGPoint(x: target.rect.midX, y: target.rect.midY)
        guard f != e.floorIndex else {
            let end = target.isStairs ? e.house.stairLanding ?? center : center
            guard let walk = plan.walk(from: p, in: here, to: goal, end: end) else { return nil }
            guard let door = walk.doors.first else {
                let way = place(from: p, to: center, heading: e.heading)
                return (walk.feet, way, way, true, center)
            }
            let feet = toDoorway(walk, end: end, plan)
            let spot = plan.nearestPoint(onDoor: door, from: p)
            return (feet, doorLeg(door, from: here, e), place(from: p, to: spot, heading: e.heading),
                    walk.doors.count == 1, spot)
        }
        // The other floor: to the stairs here, then from the stairs there.
        guard let stairs = plan.stairsIndex, let landing = e.house.stairLanding,
              let there = e.house.floors[f].stairsIndex,
              let up = plan.walk(from: p, in: here, to: stairs, end: landing),
              let down = e.house.floors[f].walk(from: landing, in: there, to: goal, end: center) else { return nil }
        let feet = up.feet + toDoorway(down, end: center, e.house.floors[f])
        let next: String, way: String
        var aim: CGPoint? = landing
        if here == stairs {
            next = f > e.floorIndex ? "hold still on the stairs to climb" : "hold still on the stairs to go down"
            way = next
            aim = nil
        } else if let door = up.doors.first, up.doors.count > 1 {
            let spot = plan.nearestPoint(onDoor: door, from: p)
            next = doorLeg(door, from: here, e)
            way = place(from: p, to: spot, heading: e.heading)
            aim = spot
        } else {
            way = place(from: p, to: landing, heading: e.heading)
            next = "stairs, " + way
        }
        return (feet, next, way, false, aim)
    }

    /// A walk's length up to the doorway into its last room, leaving off the
    /// stretch from there to `end`.
    private static func toDoorway(_ walk: (doors: [Int], feet: Double), end: CGPoint, _ plan: Floor) -> Double {
        guard let last = walk.doors.last else { return walk.feet }
        return walk.feet - plan.doors[last].point.distance(to: end)
    }

    /// "kitchen, turn 90 degrees right, 5 steps": the room door `i` leads into, and
    /// where its nearest point is.
    private static func doorLeg(_ i: Int, from here: Int, _ e: Explorer) -> String {
        let door = e.floor.doors[i]
        let other = door.a == here ? door.b : door.a
        let name = door.name ?? (other >= 0 ? e.floor.rooms[other].name : "Outside")
        return "\(name), " + place(from: e.position, to: e.floor.nearestPoint(onDoor: i, from: e.position), heading: e.heading)
    }

    /// Every room on this floor, as on the map: rows from the top, each read
    /// left to right, one sentence per row. Closets are left out.
    /// "First floor. Screened porch. Formal dining room, Kitchen, Dining area, Family room. ..."
    static func listRooms(_ e: Explorer) -> String {
        let rooms = e.floor.rooms.filter { !$0.isCloset }.sorted { $0.rect.minY < $1.rect.minY }
        // A room joins the row above when it starts above that row's first
        // room's middle; otherwise it starts a new row.
        var rows: [[Room]] = []
        for room in rooms {
            if let first = rows.last?.first, room.rect.minY < first.rect.midY {
                rows[rows.count - 1].append(room)
            } else {
                rows.append([room])
            }
        }
        let lines = rows.map { $0.sorted { $0.rect.minX < $1.rect.minX }.map(\.name).joined(separator: ", ") }
        return ([e.floor.name] + lines).joined(separator: ". ") + "."
    }

    /// What's around you: the room, then up to four things in it or leading
    /// out of it, nearest first. Fixtures first, at most two, then doorways.
    /// "Kitchen. Island, straight ahead, 2 steps. Dining area, turn 90 degrees right, 3 steps."
    static func aroundMe(_ e: Explorer) -> String {
        let p = e.position
        guard let here = e.currentRoom else { return "Outside the house." }
        let room = e.floor.rooms[here]
        let fixtures = e.floor.fixtures
            .filter { room.rect.contains(CGPoint(x: $0.cgRect.midX, y: $0.cgRect.midY)) }
            .map { f -> (String, Double) in
                let spot = CGPoint(x: f.cgRect.midX, y: f.cgRect.midY)
                return ("\(f.name), " + place(from: p, to: spot, heading: e.heading), p.distance(to: spot))
            }
            .sorted { $0.1 < $1.1 }
            .prefix(2)
        let doors = e.floor.doors.indices
            .filter { i in
                let d = e.floor.doors[i]
                guard d.a == here || d.b == here else { return false }
                let other = d.a == here ? d.b : d.a
                return other < 0 || !e.floor.rooms[other].isCloset
            }
            .sorted { e.floor.distance(toDoor: $0, from: p) < e.floor.distance(toDoor: $1, from: p) }
            .map { doorLeg($0, from: here, e) }
        let items = (fixtures.map(\.0) + doors).prefix(4)
        return ([room.name] + items).joined(separator: ". ") + "."
    }

    /// How far the nearest wall is ahead, left, right, and behind, measured
    /// straight out from the way you face. "Walls: ahead 6, left 1, right 8, behind 3 steps."
    static func walls(_ e: Explorer) -> String {
        let sides = [("ahead", 0.0), ("left", -Double.pi / 2), ("right", Double.pi / 2), ("behind", Double.pi)]
        let parts = sides.map { side, turn -> String in
            guard let feet = distanceToWall(e, facing: e.heading + turn) else { return "\(side) open" }
            return "\(side) \(max(1, Int((feet / Explorer.stride).rounded())))"
        }
        return "Walls: " + parts.joined(separator: ", ") + " steps."
    }

    /// Feet to the first thing that blocks walking, straight out at `angle`.
    /// Nil past 60 ft.
    private static func distanceToWall(_ e: Explorer, facing angle: Double) -> Double? {
        let dx = sin(angle), dy = -cos(angle)
        var d = 0.25
        while d <= 60 {
            let q = CGPoint(x: e.position.x + dx * d, y: e.position.y + dy * d)
            if e.floor.obstacle(at: q) != nil { return d }
            d += 0.25
        }
        return nil
    }
}
