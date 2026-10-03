import CoreGraphics
import Foundation

/// The fixed route through the house, as a track the avatar can only slide
/// along. Big rooms are where a blind explorer gets lost: a swipe across an
/// empty 20 ft family room gives nothing back, and there's no landmark to
/// recover from. On the rail there is only forward and back, so getting lost
/// isn't possible, and the user can step off whenever they want to feel a room
/// for themselves.
///
/// The points are `house.tour` itself, the same polyline the guided tour walks.
/// Reusing it means the rail inherits the tracer's guarantee that no segment
/// crosses a wall, and that the tour's stops are all on the track.
///
/// The route changes floors once, on the stairs. Each storey's stretch is its
/// own `Run` with its own arc length, because a distance along the path can't
/// run continuously through a floor change.
final class Rail {
    /// One storey's stretch of the route.
    struct Run {
        let floor: Int
        let points: [CGPoint]
        /// Arc length from the start of the run to each point. Same count as `points`.
        let marks: [Double]

        var length: Double { marks.last ?? 0 }
    }

    let runs: [Run]
    /// Where each step of `house.tour` sits on the track. The route doubles back
    /// over itself, so projecting a tour stop's coordinates can't tell which
    /// pass it belongs to; its step number can. Tour jumps use this instead of
    /// `project`, which makes them exact rather than merely close.
    private let stepMarks: [Int: (run: Int, s: Double)]

    /// Nil when the house has no usable route (fewer than two points on a floor).
    init?(tour: [TourStep]) {
        var runs: [Run] = []
        var marksByStep: [Int: (run: Int, s: Double)] = [:]
        var i = 0
        while i < tour.count {
            let floor = tour[i].floor
            let runIndex = runs.count
            var points: [CGPoint] = []
            var marks: [Double] = []
            var steps: [Int] = []   // which tour step each kept point came from
            while i < tour.count, tour[i].floor == floor {
                // A repeated point would make a zero-length segment with no
                // tangent, so it folds into the one before it.
                if let last = points.last, last.distance(to: tour[i].point) <= 0.01 {
                    marksByStep[i] = (runIndex, marks[marks.count - 1])
                } else {
                    let s = points.isEmpty ? 0 : marks[marks.count - 1] + points[points.count - 1].distance(to: tour[i].point)
                    points.append(tour[i].point)
                    marks.append(s)
                    steps.append(i)
                    marksByStep[i] = (runIndex, s)
                }
                i += 1
            }
            guard points.count >= 2 else {
                // Not a run after all; forget the marks that pointed into it.
                for step in steps { marksByStep[step] = nil }
                continue
            }
            runs.append(Run(floor: floor, points: points, marks: marks))
        }
        guard !runs.isEmpty else { return nil }
        self.runs = runs
        stepMarks = marksByStep
    }

    /// Exactly where tour step `i` sits on the track, by step number rather than
    /// by coordinates, so a doubled-back route can't put it on the wrong pass.
    func location(ofTourStep i: Int) -> (run: Int, s: Double)? { stepMarks[i] }

    func length(of run: Int) -> Double { runs[run].length }

    /// The run that walks `floor`, if the route visits it.
    func run(onFloor floor: Int) -> Int? {
        runs.firstIndex { $0.floor == floor }
    }

    /// Where `s` feet along `run` lands. Clamped, so the ends of the route are
    /// walls you can't push past.
    func point(run: Int, at s: Double) -> CGPoint {
        let r = runs[run]
        let (i, t) = segment(r, at: s)
        let a = r.points[i], b = r.points[i + 1]
        return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    /// Which way the route runs at `s`, as a unit vector pointing forward along
    /// it. This is the avatar's heading on the rail, so "ahead" means onward.
    func tangent(run: Int, at s: Double) -> CGVector {
        let r = runs[run]
        let (i, _) = segment(r, at: s)
        let a = r.points[i], b = r.points[i + 1]
        let d = a.distance(to: b)
        guard d > 0 else { return CGVector(dx: 0, dy: -1) }
        return CGVector(dx: (b.x - a.x) / d, dy: (b.y - a.y) / d)
    }

    /// The corners strictly between `from` and `to`, in travel order. Moving
    /// straight from one arc length to another would cut a corner, and a cut
    /// corner can cross a wall even though every segment of the route is clear.
    func corners(run: Int, from: Double, to: Double) -> [CGPoint] {
        let r = runs[run]
        let lo = min(from, to), hi = max(from, to)
        let inside = zip(r.points, r.marks).filter { $0.1 > lo + 0.001 && $0.1 < hi - 0.001 }.map(\.0)
        return to >= from ? inside : inside.reversed()
    }

    /// How much farther a candidate may be, in feet, and still beat the closest
    /// one on continuity. It has to be at least as wide as the distance someone
    /// can stray off the track, or their own pass falls outside the window and
    /// loses to a different pass running a few inches away. One footstep.
    static let tie = 2.5

    /// The arc length on `run` closest to `p`, for snapping back onto the route.
    ///
    /// The route doubles back — out to the half bath and in again, along very
    /// nearly the same line — so one spot on the floor can be two places on the
    /// track, 40 ft apart in arc length. Taking the globally nearest would let a
    /// snap-back land on the wrong pass, facing backwards, with the next tour
    /// stop behind it. `near` breaks the tie the way a person would: of the
    /// candidates that are about equally close, pick the one nearest where you
    /// already were.
    func project(_ p: CGPoint, run: Int, near: Double? = nil) -> Double {
        let r = runs[run]
        var candidates: [(distance: Double, s: Double)] = []
        for i in 0..<(r.points.count - 1) {
            let a = r.points[i], b = r.points[i + 1]
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            let t = len2 > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2)) : 0
            let q = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
            candidates.append((p.distance(to: q), r.marks[i] + t * len2.squareRoot()))
        }
        guard let closest = candidates.min(by: { $0.distance < $1.distance }) else { return 0 }
        guard let near else { return closest.s }
        return candidates
            .filter { $0.distance <= closest.distance + Self.tie }
            .min { abs($0.s - near) < abs($1.s - near) }?.s ?? closest.s
    }

    /// Which segment `s` falls in, and how far along it, as a fraction.
    private func segment(_ r: Run, at s: Double) -> (index: Int, t: Double) {
        let clamped = max(0, min(s, r.length))
        // The last mark is the end of the run, so stop one short of it.
        var i = 0
        while i + 2 < r.points.count, r.marks[i + 1] <= clamped { i += 1 }
        let span = r.marks[i + 1] - r.marks[i]
        return (i, span > 0 ? (clamped - r.marks[i]) / span : 0)
    }
}
