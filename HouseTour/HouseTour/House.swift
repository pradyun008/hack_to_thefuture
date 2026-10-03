import CoreGraphics
import Foundation

/// What occupies one 0.25 ft grid cell. Everything except `.open` blocks the walker.
enum CellKind: UInt8 {
    case open, wall, window, screen, railing, void

    init(_ c: UInt8) {
        switch c {
        case UInt8(ascii: "#"): self = .wall
        case UInt8(ascii: "w"): self = .window
        case UInt8(ascii: "s"): self = .screen
        case UInt8(ascii: "r"): self = .railing
        case UInt8(ascii: "v"): self = .void
        default: self = .open
        }
    }

    var blocks: Bool { self != .open }
}

enum FloorType: String, Decodable, CaseIterable {
    case hardwood, carpet, tile, concrete, deck, unknown

    var spoken: String {
        switch self {
        case .hardwood: "Hardwood"
        case .carpet: "Carpet"
        case .tile: "Tile"
        case .concrete: "Concrete"
        case .deck: "Deck boards"
        case .unknown: "Floor type not listed"
        }
    }
}

struct Room: Decodable {
    let name: String
    let floor: FloorType
    let kind: String
    let bounds: [Double]
    let size: [Double]?
    let note: String?

    var rect: CGRect { CGRect(x: bounds[0], y: bounds[1], width: bounds[2], height: bounds[3]) }
    var isStairs: Bool { kind == "stairs" }
    var isCloset: Bool { kind == "closet" }

    /// "Kitchen. 14 by 13 feet. Tile."
    var entrySentence: String {
        var parts = [name]
        if let size { parts.append("\(Int(size[0].rounded())) by \(Int(size[1].rounded())) feet") }
        if !isCloset { parts.append(floor.spoken) }
        return parts.joined(separator: ". ") + "."
    }
}

struct Door: Decodable {
    let x, y, width: Double
    let a, b: Int          // room indices; b == -1 means outside
    let kind: String       // doorway | opening | exterior
    let name: String?
    let front: Bool?

    var point: CGPoint { CGPoint(x: x, y: y) }
    var isFront: Bool { front == true }
}

struct Fixture: Decodable {
    let name: String
    let rect: [Double]
    var cgRect: CGRect { CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3]) }
}

struct TourStep: Decodable {
    let floor: Int
    let x, y: Double
    let say: String?
    let climb: Bool?
    var point: CGPoint { CGPoint(x: x, y: y) }
}

struct FrontDoor: Decodable {
    let floor: Int
    let x, y: Double
    var point: CGPoint { CGPoint(x: x, y: y) }
}

/// One storey. Positions everywhere are in feet, origin top-left, y grows toward
/// the front of the house (the bottom of the screen).
final class Floor {
    let name: String
    let cols, rows: Int
    let cellSize: Double
    let rooms: [Room]
    let doors: [Door]
    let fixtures: [Fixture]
    /// Each door's gap as a line segment along its wall, so "at the door" means
    /// near the opening itself, not just near its center.
    let doorSpans: [(CGPoint, CGPoint)]
    private let cells: [CellKind]
    private let roomIDs: [Int8]

    init(_ raw: RawFloor, cellSize: Double) {
        name = raw.name
        cols = raw.cols
        rows = raw.rows
        self.cellSize = cellSize
        rooms = raw.roomList
        doors = raw.doors
        fixtures = raw.fixtures
        cells = raw.cells.utf8.map(CellKind.init)
        roomIDs = raw.rooms.utf8.map { $0 == UInt8(ascii: ".") ? -1 : Int8($0) - 65 }
        doorSpans = raw.doors.map { Floor.span(of: $0, rooms: raw.roomList) }
    }

    /// The door records only a center and a width. Its wall is whichever edge of
    /// the rooms it joins the center sits on.
    private static func span(of door: Door, rooms: [Room]) -> (CGPoint, CGPoint) {
        let p = door.point, half = door.width / 2
        let rects = [door.a, door.b].filter { $0 >= 0 }.map { rooms[$0].rect }
        let onEdge = { (v: Double, lo: Double, hi: Double) in abs(v - lo) < 0.4 || abs(v - hi) < 0.4 }
        if rects.contains(where: { onEdge(p.y, $0.minY, $0.maxY) && p.x > $0.minX - 0.5 && p.x < $0.maxX + 0.5 }) {
            return (CGPoint(x: p.x - half, y: p.y), CGPoint(x: p.x + half, y: p.y))
        }
        if rects.contains(where: { onEdge(p.x, $0.minX, $0.maxX) && p.y > $0.minY - 0.5 && p.y < $0.maxY + 0.5 }) {
            return (CGPoint(x: p.x, y: p.y - half), CGPoint(x: p.x, y: p.y + half))
        }
        return (p, p)
    }

    /// Feet from `p` to the nearest point of door `i`'s opening.
    func distance(toDoor i: Int, from p: CGPoint) -> Double {
        let (a, b) = doorSpans[i]
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        let t = len2 > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2)) : 0
        return p.distance(to: CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }

    private func index(_ p: CGPoint) -> Int? {
        let c = Int(floor(p.x / cellSize)), r = Int(floor(p.y / cellSize))
        guard c >= 0, r >= 0, c < cols, r < rows else { return nil }
        return r * cols + c
    }

    func kind(at p: CGPoint) -> CellKind {
        index(p).map { cells[$0] } ?? .open
    }

    /// What stops the walker at `p`. The edge of the map counts as a wall, so you
    /// can step outside the house but not off the lot.
    func obstacle(at p: CGPoint) -> CellKind? {
        guard let i = index(p) else { return .wall }
        return cells[i].blocks ? cells[i] : nil
    }

    /// Moves from `p` by `delta` feet and stops at anything that blocks. Steps of at
    /// most 0.1 ft so a fast swipe can't tunnel through a 0.5 ft wall, and x and y
    /// are resolved separately so pushing diagonally into a wall slides along it.
    /// Returns where the walker ended up and what stopped it on each axis.
    func slide(from p: CGPoint, by delta: CGVector) -> (end: CGPoint, hitX: CellKind?, hitY: CellKind?) {
        let n = max(1, Int(ceil(max(abs(delta.dx), abs(delta.dy)) / 0.1)))
        let sx = delta.dx / Double(n), sy = delta.dy / Double(n)
        var q = p
        var hitX: CellKind?, hitY: CellKind?
        for _ in 0..<n {
            if sx != 0, hitX == nil {
                let next = CGPoint(x: q.x + sx, y: q.y)
                if let k = obstacle(at: next) { hitX = k } else { q = next }
            }
            if sy != 0, hitY == nil {
                let next = CGPoint(x: q.x, y: q.y + sy)
                if let k = obstacle(at: next) { hitY = k } else { q = next }
            }
        }
        return (q, hitX, hitY)
    }

    /// Room index under `p`, or nil when outside the house (or inside a wall).
    func roomIndex(at p: CGPoint) -> Int? {
        guard let i = index(p), roomIDs[i] >= 0 else { return nil }
        return Int(roomIDs[i])
    }

    /// Distance in feet to the nearest blocking cell, if one is within `radius`.
    func distanceToBlocking(from p: CGPoint, within radius: Double) -> Double? {
        let span = Int(ceil(radius / cellSize))
        let c0 = Int(floor(p.x / cellSize)), r0 = Int(floor(p.y / cellSize))
        let rLo = max(r0 - span, 0), rHi = min(r0 + span, rows - 1)
        let cLo = max(c0 - span, 0), cHi = min(c0 + span, cols - 1)
        guard rLo <= rHi, cLo <= cHi else { return nil }  // touch is off the map
        var best: Double?
        for r in rLo...rHi {
            for c in cLo...cHi where cells[r * cols + c].blocks {
                // Distance to the nearest point of the cell, not its center.
                let dx = max(Double(c) * cellSize - p.x, 0, p.x - Double(c + 1) * cellSize)
                let dy = max(Double(r) * cellSize - p.y, 0, p.y - Double(r + 1) * cellSize)
                let d = (dx * dx + dy * dy).squareRoot()
                if d <= radius, d < (best ?? .infinity) { best = d }
            }
        }
        return best
    }

    func fixture(at p: CGPoint) -> Fixture? {
        fixtures.first { $0.cgRect.contains(p) }
    }

    var stairsIndex: Int? { rooms.firstIndex { $0.isStairs } }

    func isStairs(at p: CGPoint) -> Bool {
        roomIndex(at: p).map { rooms[$0].isStairs } ?? false
    }
}

struct RawFloor: Decodable {
    let name: String
    let cols, rows: Int
    let cells: String
    let rooms: String
    let roomList: [Room]
    let doors: [Door]
    let fixtures: [Fixture]
}

final class House {
    let address: String
    let summary: String
    let width, height: Double
    let frontDoor: FrontDoor
    let floors: [Floor]
    let tour: [TourStep]

    private struct Raw: Decodable {
        let address, summary: String
        let cellSize, width, height: Double
        let frontDoor: FrontDoor
        let floors: [RawFloor]
        let tour: [TourStep]
    }

    init(data: Data) throws {
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        address = raw.address
        summary = raw.summary
        width = raw.width
        height = raw.height
        frontDoor = raw.frontDoor
        floors = raw.floors.map { Floor($0, cellSize: raw.cellSize) }
        tour = raw.tour
        stairLanding = House.overlapCenter(floors, cellSize: raw.cellSize)
        entrance = House.inside(raw.frontDoor, floors)
    }

    /// Where exploring starts: just inside the front door, so the first thing the
    /// user learns is the one landmark they can always ask for again.
    let entrance: CGPoint

    /// Steps from the front door toward the middle of the room it opens into until
    /// the walker is on open floor in that room, at least 1.5 ft in.
    private static func inside(_ front: FrontDoor, _ floors: [Floor]) -> CGPoint {
        let floor = floors[front.floor]
        guard let door = floor.doors.first(where: \.isFront) else { return front.point }
        let room = door.a >= 0 ? door.a : door.b
        let r = floor.rooms[room].rect
        let center = CGPoint(x: r.midX, y: r.midY)
        let length = door.point.distance(to: center)
        var d = 1.5
        while d < length {
            let q = CGPoint(x: door.point.x + (center.x - door.point.x) * d / length,
                            y: door.point.y + (center.y - door.point.y) * d / length)
            if floor.obstacle(at: q) == nil, floor.roomIndex(at: q) == room { return q }
            d += 0.25
        }
        return front.point
    }

    /// Center of the stretch of stairs drawn on both floors. Changing floors only
    /// happens there, so you arrive on the stairs, not in a closet or a void.
    let stairLanding: CGPoint?

    func stairsConnect(at p: CGPoint) -> Bool {
        floors.count == 2 && floors[0].isStairs(at: p) && floors[1].isStairs(at: p)
    }

    private static func overlapCenter(_ floors: [Floor], cellSize: Double) -> CGPoint? {
        guard floors.count == 2 else { return nil }
        var sx = 0.0, sy = 0.0, n = 0.0
        for r in 0..<floors[0].rows {
            for c in 0..<floors[0].cols {
                let p = CGPoint(x: (Double(c) + 0.5) * cellSize, y: (Double(r) + 0.5) * cellSize)
                if floors[0].isStairs(at: p), floors[1].isStairs(at: p) {
                    sx += p.x; sy += p.y; n += 1
                }
            }
        }
        return n > 0 ? CGPoint(x: sx / n, y: sy / n) : nil
    }

    static func bundled() -> House {
        let url = Bundle.main.url(forResource: "house", withExtension: "json")!
        return try! House(data: Data(contentsOf: url))
    }
}

extension CGPoint {
    func distance(to o: CGPoint) -> Double { hypot(x - o.x, y - o.y) }
}

/// Where `target` is relative to someone at `from` facing up the screen (toward
/// the back of the house). Up is always "ahead" so the phone's edges stay a
/// fixed frame of reference.
func relativeDirection(from: CGPoint, to target: CGPoint) -> String {
    let dx = target.x - from.x, dy = target.y - from.y
    if hypot(dx, dy) < 1.5 { return "right here" }
    let angle = atan2(dx, -dy) * 180 / .pi   // 0 = ahead, 90 = right
    switch angle {
    case -22.5..<22.5: return "ahead"
    case 22.5..<67.5: return "ahead on your right"
    case 67.5..<112.5: return "on your right"
    case 112.5..<157.5: return "behind you on your right"
    case -67.5 ..< -22.5: return "ahead on your left"
    case -112.5 ..< -67.5: return "on your left"
    case -157.5 ..< -112.5: return "behind you on your left"
    default: return "behind you"
    }
}

/// Feet to footsteps, using a 2.5 ft stride.
func steps(_ feet: Double) -> String {
    let n = max(1, Int((feet / 2.5).rounded()))
    return n == 1 ? "1 step" : "\(n) steps"
}
