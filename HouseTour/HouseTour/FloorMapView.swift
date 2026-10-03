import Combine
import SwiftUI
import UIKit

/// The touch surface, used like a laptop trackpad. One finger drags the avatar
/// by the finger's movement, never to where the finger is, so seeing the map
/// gives no shortcut. Single tap says the room; double tap steps off the route
/// or snaps back onto it; triple tap says where you are. Extra fingers are
/// ignored so a second one can't drag the avatar. Marked
/// `allowsDirectInteraction` so raw touches reach it while VoiceOver is on.
final class FloorMapView: UIView {
    var explorer: Explorer!
    var onTouch: (() -> Void)?
    var onSingleTap: (() -> Void)?
    var onToggleRail: (() -> Void)?
    var onWhereAmI: (() -> Void)?

    /// Top walking speed, in feet per second, at full deflection. A house is
    /// about 60 ft across, so crossing it takes roughly 20 seconds: a walk, not
    /// a sprint. The footstep every `Explorer.stride` feet then lands a little
    /// under once a second, which is what makes it read as walking.
    static let maxSpeed = 3.0
    /// Points of finger offset that count as full deflection. Within a thumb's
    /// reach, so the far end of the stick is always comfortable.
    static let maxDeflection = 90.0
    /// Offset below this does nothing, so a resting finger never creeps.
    static let deadzone = 6.0

    /// Off: a plain dark surface. On: the plan and the avatar, for people watching.
    var showMap = false {
        didSet {
            guard showMap != oldValue else { return }
            backgroundColor = showMap ? UIColor(white: 0.93, alpha: 1) : UIColor(white: 0.08, alpha: 1)
            hint.isHidden = showMap
            setNeedsDisplay()
            updateDot()
        }
    }
    var floorIndex = 0 { didSet { setNeedsDisplay() } }

    private var images: [Int: UIImage] = [:]
    private let dot = CAShapeLayer()
    private let pointer = CAShapeLayer()   // the avatar's head, showing which way it faces
    private let hint = UILabel()

    private var tracking: UITouch?
    private var touchStart = Date()
    private var startPoint = CGPoint.zero
    private var lastPoint = CGPoint.zero
    private var movedFar = false
    private var extraFingers = false
    private var tapTimes: [Date] = []
    private var announceWork: DispatchWorkItem?
    /// How far the finger is held above (negative) or below its landing point,
    /// in points. The AirPods own turning, so only this axis walks.
    private var stick = 0.0
    private var ticker: CADisplayLink?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = UIColor(white: 0.08, alpha: 1)
        contentMode = .redraw
        dot.fillColor = UIColor.systemRed.withAlphaComponent(0.55).cgColor
        dot.strokeColor = UIColor.white.cgColor
        dot.lineWidth = 2
        layer.addSublayer(dot)
        pointer.fillColor = UIColor.systemRed.cgColor
        pointer.strokeColor = UIColor.white.cgColor
        pointer.lineWidth = 2
        pointer.lineJoin = .round
        layer.addSublayer(pointer)

        hint.text = "Hold and push up to walk. Double tap: leave the path or rejoin it. Triple tap: where you are."
        hint.textColor = UIColor(white: 0.6, alpha: 1)
        hint.font = .preferredFont(forTextStyle: .body)
        hint.numberOfLines = 0
        hint.textAlignment = .center
        hint.isAccessibilityElement = false
        hint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hint)
        NSLayoutConstraint.activate([
            hint.centerYAnchor.constraint(equalTo: centerYAnchor),
            hint.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            hint.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),
        ])

        isAccessibilityElement = true
        accessibilityLabel = "Touch surface"
        accessibilityHint = "Turn your head with AirPods to face left or right. Press and hold, then push up to walk forward or down to walk back. Further is faster. Single tap for the room. Double tap to leave the path or rejoin it. Triple tap for where you are."
        accessibilityTraits = .allowsDirectInteraction
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Drawing (map shown only)

    private var scale: CGFloat {
        guard let house = explorer?.house, house.width > 0 else { return 1 }
        return min(bounds.width / house.width, bounds.height / house.height)
    }

    private func toPoints(_ p: CGPoint) -> CGPoint {
        guard let house = explorer?.house else { return p }
        let origin = CGPoint(x: (bounds.width - house.width * scale) / 2, y: (bounds.height - house.height * scale) / 2)
        return CGPoint(x: p.x * scale + origin.x, y: p.y * scale + origin.y)
    }

    override func draw(_ rect: CGRect) {
        guard showMap, let explorer else { return }
        let image = images[floorIndex] ?? {
            let img = FloorRenderer.render(explorer.house, floor: floorIndex)
            images[floorIndex] = img
            return img
        }()
        let house = explorer.house
        let topLeft = toPoints(.zero)
        image.draw(in: CGRect(x: topLeft.x, y: topLeft.y, width: house.width * scale, height: house.height * scale))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateDot()
    }

    /// The avatar: a body circle with a pointed head on the side it faces.
    func updateDot() {
        guard showMap, let explorer else {
            dot.path = nil
            pointer.path = nil
            return
        }
        let c = toPoints(explorer.position)
        dot.path = UIBezierPath(ovalIn: CGRect(x: c.x - 11, y: c.y - 11, width: 22, height: 22)).cgPath
        // Heading 0 is up the screen; screen y grows downward.
        let h = explorer.heading
        let ahead = CGVector(dx: sin(h), dy: -cos(h)), side = CGVector(dx: cos(h), dy: sin(h))
        let at = { (forward: CGFloat, across: CGFloat) in
            CGPoint(x: c.x + ahead.dx * forward + side.dx * across, y: c.y + ahead.dy * forward + side.dy * across)
        }
        let head = UIBezierPath()
        head.move(to: at(22, 0))
        head.addLine(to: at(7, 8))
        head.addLine(to: at(7, -8))
        head.close()
        pointer.path = head.cgPath
    }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        onTouch?()
        let all = event?.allTouches?.filter { $0.view === self && $0.phase != .ended && $0.phase != .cancelled } ?? touches
        if all.count >= 2 {
            // A second finger landed. Nothing is bound to it, and it must not
            // walk the avatar, so touches are ignored until the hand lifts.
            announceWork?.cancel()
            if tracking != nil {
                tracking = nil
                stopTicking()
                explorer.touchUp()
            }
            extraFingers = true
            return
        }
        guard tracking == nil, !extraFingers, let t = touches.first else { return }
        tracking = t
        touchStart = Date()
        startPoint = t.location(in: self)
        lastPoint = startPoint
        movedFar = false
        announceWork?.cancel()
        explorer.touchDown()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if extraFingers { return }
        guard let t = tracking, touches.contains(t) else { return }
        let p = t.location(in: self)
        if p.distance(to: startPoint) > 12 { movedFar = true }
        // Ignore finger jitter until it's clearly a push, so taps never nudge the avatar.
        guard movedFar || p.distance(to: startPoint) > Self.deadzone else { return }
        stick = p.y - startPoint.y
        lastPoint = p
        startTicking()
    }

    /// Walks the avatar once per frame while the stick is held. Distance comes
    /// from the frame's own length, so a dropped frame costs no ground and the
    /// footstep cadence stays honest about speed.
    private func startTicking() {
        guard ticker == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        ticker = link
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
        stick = 0
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard tracking != nil else { return stopTicking() }
        let offset = abs(stick)
        guard offset > Self.deadzone else { return }
        // Squared response: gentle near the centre, so lining up with a doorway
        // needs no separate fine mode, and full tilt is a normal walking pace.
        let reach = min((offset - Self.deadzone) / (Self.maxDeflection - Self.deadzone), 1)
        let feet = reach * reach * Self.maxSpeed * (link.targetTimestamp - link.timestamp)
        explorer.drag(by: CGVector(dx: 0, dy: stick < 0 ? -feet : feet))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        endTouches(touches, event: event, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        endTouches(touches, event: event, cancelled: true)
    }

    private func endTouches(_ touches: Set<UITouch>, event: UIEvent?, cancelled: Bool) {
        let remaining = event?.allTouches?.filter {
            $0.view === self && !touches.contains($0) && $0.phase != .ended && $0.phase != .cancelled
        }
        if extraFingers {
            // Wait for every finger to come up, then take touches again.
            if remaining?.isEmpty ?? true { extraFingers = false }
            return
        }
        guard let t = tracking, touches.contains(t) else { return }
        tracking = nil
        stopTicking()
        explorer.touchUp()
        guard !cancelled else { return }

        let isTap = Date().timeIntervalSince(touchStart) < 0.25 && !movedFar
        guard isTap else {
            tapTimes = []
            return
        }
        announceWork?.cancel()
        let now = Date()
        tapTimes = tapTimes.filter { now.timeIntervalSince($0) < 0.9 } + [now]
        if tapTimes.count >= 3 {
            tapTimes = []
            onWhereAmI?()
            return
        }
        // Wait to see whether more taps follow. Each new tap cancels the wait,
        // so only the final count acts: one tap says the room, two step off the
        // route or rejoin it, and three (above) say where you are.
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let count = self.tapTimes.count
            self.tapTimes = []
            if count == 1 { self.onSingleTap?() }
            if count == 2 { self.onToggleRail?() }
        }
        announceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
}

/// Draws a floor once into an image, for sighted teammates and judges when
/// "Show map" is on.
enum FloorRenderer {
    static let pxPerFoot: CGFloat = 24

    static func color(_ floor: FloorType) -> UIColor {
        switch floor {
        case .hardwood: UIColor(red: 0.93, green: 0.80, blue: 0.62, alpha: 1)
        case .carpet: UIColor(red: 0.84, green: 0.84, blue: 0.95, alpha: 1)
        case .tile: UIColor(red: 0.74, green: 0.89, blue: 0.95, alpha: 1)
        case .concrete: UIColor(white: 0.82, alpha: 1)
        case .deck: UIColor(red: 0.80, green: 0.70, blue: 0.58, alpha: 1)
        case .unknown: UIColor(red: 0.97, green: 0.95, blue: 0.85, alpha: 1)
        }
    }

    static func render(_ house: House, floor index: Int) -> UIImage {
        let floor = house.floors[index]
        let s = pxPerFoot * CGFloat(floor.cellSize)
        let size = CGSize(width: CGFloat(house.width) * pxPerFoot, height: CGFloat(house.height) * pxPerFoot)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            for r in 0..<floor.rows {
                for c in 0..<floor.cols {
                    let center = CGPoint(x: (Double(c) + 0.5) * floor.cellSize, y: (Double(r) + 0.5) * floor.cellSize)
                    let fill: UIColor?
                    switch floor.kind(at: center) {
                    case .wall: fill = .black
                    case .window: fill = .systemBlue
                    case .screen: fill = .systemTeal
                    case .railing: fill = .systemOrange
                    case .void: fill = UIColor(white: 0.6, alpha: 1)
                    case .open: fill = floor.roomIndex(at: center).map { color(floor.rooms[$0].floor) }
                    }
                    guard let fill else { continue }
                    cg.setFillColor(fill.cgColor)
                    cg.fill(CGRect(x: CGFloat(c) * s, y: CGFloat(r) * s, width: s + 0.5, height: s + 0.5))
                }
            }
            // Stair treads.
            cg.setStrokeColor(UIColor(white: 0.35, alpha: 1).cgColor)
            cg.setLineWidth(2)
            for room in floor.rooms where room.isStairs {
                let rect = room.rect.scaled(pxPerFoot)
                var x = rect.minX + 12
                while x < rect.maxX {
                    cg.move(to: CGPoint(x: x, y: rect.minY))
                    cg.addLine(to: CGPoint(x: x, y: rect.maxY))
                    x += 18
                }
            }
            cg.strokePath()
            for fixture in floor.fixtures {
                cg.setFillColor(UIColor.brown.cgColor)
                cg.fill(fixture.cgRect.scaled(pxPerFoot))
            }
            // Front door marker.
            if house.frontDoor.floor == index {
                let p = house.frontDoor.point
                let d = CGRect(x: p.x * pxPerFoot - 22, y: p.y * pxPerFoot - 10, width: 44, height: 20)
                cg.setFillColor(UIColor.systemGreen.cgColor)
                cg.fill(d)
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 26, weight: .semibold),
                .foregroundColor: UIColor(white: 0.15, alpha: 1),
            ]
            for room in floor.rooms where !room.isCloset && !room.isStairs {
                let text = room.name as NSString
                let rect = room.rect.scaled(pxPerFoot)
                let sz = text.size(withAttributes: attrs)
                text.draw(at: CGPoint(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2), withAttributes: attrs)
            }
        }
    }
}

extension CGRect {
    fileprivate func scaled(_ k: CGFloat) -> CGRect {
        CGRect(x: minX * k, y: minY * k, width: width * k, height: height * k)
    }
}

/// SwiftUI wrapper.
struct FloorMap: UIViewRepresentable {
    @ObservedObject var app: AppModel
    let showMap: Bool

    func makeUIView(context: Context) -> FloorMapView {
        let view = FloorMapView()
        view.explorer = app.explorer
        view.onTouch = { app.interrupt() }
        view.onSingleTap = { app.singleTap() }
        view.onToggleRail = { app.toggleRail() }
        view.onWhereAmI = { app.explorer.whereAmI() }
        context.coordinator.positionSink = app.explorer.$position.map { _ in () }
            .merge(with: app.explorer.$heading.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak view] _ in view?.updateDot() }
        return view
    }

    func updateUIView(_ view: FloorMapView, context: Context) {
        if view.floorIndex != app.explorer.floorIndex { view.floorIndex = app.explorer.floorIndex }
        view.showMap = showMap
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var positionSink: AnyCancellable?
    }
}
