import CoreGraphics
import Foundation

/// The questions the hold-to-talk button understands. Matching is by keyword:
/// the set is small, so a list of phrasings is enough, and it works offline.
enum Question: Equatable {
    case whereAmI
    case waysOut
    case frontDoor
    /// How many steps, and which way, to a room. Said once.
    case room(floor: Int, index: Int)
    /// Directions to a room, one leg per room walked into.
    case guide(floor: Int, index: Int)
    case listRooms
    case aroundMe
    case walls
    case stop
    /// Start the guided tour. There's no button for it, so it's asked aloud.
    case tour

    /// Said when nothing matched, and as the button's hint.
    static let examples = "Ask where am I, what's around me, list rooms, walls, take me to a room, or start the tour."

    /// Phrases to bias the recognizer toward: the questions and every room name.
    static func hints(for house: House) -> [String] {
        ["where am I", "ways out", "front door", "take me to", "guide me to", "how many steps to",
         "list rooms", "what's around me", "landmarks", "walls", "stop", "start the tour"]
            + house.floors.flatMap { $0.rooms.map(\.name) }
    }

    /// What was heard, matched to a question. Checked in order, so "how do I
    /// get out of the kitchen" is a ways-out question, not a trip to the
    /// kitchen. Nil when nothing fits.
    static func match(_ heard: String, in house: House, from floor: Int, at p: CGPoint) -> Question? {
        let text = " " + normalize(heard)
        let has = { (phrases: [String]) in phrases.contains { text.contains(" " + $0) } }
        if has(["stop", "cancel", "never mind", "nevermind"]) { return .stop }
        if has(["tour", "show me around", "show me the house"]) { return .tour }
        if has(["wall"]) { return .walls }
        if has(["list", "all rooms", "all the rooms", "every room", "what rooms", "which rooms", "rooms are there",
                "rooms on this floor", "how many rooms"]) {
            return .listRooms
        }
        if has(["around", "nearby", "near me", "landmark", "next to me", "close to me", "surround"]) { return .aroundMe }
        if has(["front door", "main door", "entrance", "out of the house", "leave the house", "outside"]) {
            return .frontDoor
        }
        if has(["way out", "ways out", "exit", "get out", "leave", "door"]) { return .waysOut }
        if has(["where am i", "what room", "which room", "my location"]) { return .whereAmI }
        if case let .room(f, i)? = room(in: text, house: house, from: floor, at: p) {
            let guiding = has(["take me", "guide", "navigate", "bring me", "lead me", "walk me", "get me to"])
            return guiding ? .guide(floor: f, index: i) : .room(floor: f, index: i)
        }
        if has(["where"]) { return .whereAmI }
        return nil
    }

    /// A room named in `text`. A full name wins ("bedroom 2"); failing that, a
    /// kind of room ("bathroom", "closet", "porch"), taking the nearest one.
    private static func room(in text: String, house: House, from floor: Int, at p: CGPoint) -> Question? {
        var rooms: [(floor: Int, index: Int, room: Room)] = []
        for (f, plan) in house.floors.enumerated() {
            for (i, r) in plan.rooms.enumerated() { rooms.append((f, i, r)) }
        }
        // The longest name wins, so "bedroom 2 closet" isn't taken for "bedroom 2".
        let named = rooms
            .filter { text.contains(" " + normalize($0.room.name)) }
            .max { normalize($0.room.name).count < normalize($1.room.name).count }
        if let named, let pick = nearest(rooms.filter { $0.room.name == named.room.name }, from: floor, at: p) {
            return .room(floor: pick.floor, index: pick.index)
        }
        let words = Set(text.split(separator: " ").map(String.init))
        let kinds: [(words: Set<String>, fits: (Room) -> Bool)] = [
            (["bathroom", "restroom", "toilet", "washroom", "bath"], { $0.kind == "bath" }),
            (["stairs", "staircase", "upstairs", "downstairs", "stairway"], \.isStairs),
            (["bedroom"], { $0.name.lowercased().contains("bedroom") }),
            (["closet"], \.isCloset),
            (["hall", "hallway"], { $0.name.lowercased().contains("hall") && $0.kind != "bath" }),
        ]
        for kind in kinds where !kind.words.isDisjoint(with: words) {
            if let pick = nearest(rooms.filter { kind.fits($0.room) }, from: floor, at: p) {
                return .room(floor: pick.floor, index: pick.index)
            }
        }
        // A room's last word on its own: "porch", "garage", "nook". "Room" and
        // "area" are left out, since they'd match "what room" and the like.
        let last = rooms.filter {
            guard let w = normalize($0.room.name).split(separator: " ").last.map(String.init) else { return false }
            return w != "room" && w != "area" && words.contains(w)
        }
        return nearest(last, from: floor, at: p).map { .room(floor: $0.floor, index: $0.index) }
    }

    /// This floor first, then the closest by straight-line distance.
    private static func nearest(_ rooms: [(floor: Int, index: Int, room: Room)], from floor: Int,
                                at p: CGPoint) -> (floor: Int, index: Int, room: Room)? {
        rooms.min { a, b in
            if (a.floor == floor) != (b.floor == floor) { return a.floor == floor }
            let ca = CGPoint(x: a.room.rect.midX, y: a.room.rect.midY)
            let cb = CGPoint(x: b.room.rect.midX, y: b.room.rect.midY)
            return p.distance(to: ca) < p.distance(to: cb)
        }
    }

    /// Lowercase words separated by single spaces, with number words as digits
    /// and "master" as "primary", so "Master bedroom two" finds "Primary bedroom 2".
    static func normalize(_ s: String) -> String {
        let swaps = ["one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "master": "primary"]
        return s.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .map { swaps[$0] ?? $0 }
            .joined(separator: " ")
    }
}
