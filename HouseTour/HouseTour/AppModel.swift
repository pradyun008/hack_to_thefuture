import Combine
import Foundation
import CoreMotion
#if DEBUG && targetEnvironment(simulator)
import Network
#endif

final class AppModel: ObservableObject {
    /// The house being explored. Switching houses replaces it, the explorer, and
    /// the tour; sound, haptics, speech, and the laptop viewer carry over.
    @Published private(set) var house: House
    let headMotion = HeadMotion()
    let haptics = Haptics()
    let speech = Speaker()
    let audio: SpatialAudio
    private(set) var explorer: Explorer
    private var tour: GuidedTour
    private var guide: Guide
    private let viewer = LaptopViewer()
    /// What the user asked and tapped and what the app said, for testing.
    let transcript = Transcript()
#if DEBUG && targetEnvironment(simulator)
    private let simulatorMotion = SimulatorMotionBridge()
#endif

    /// UserDefaults key: the first-run tour reached its last stop.
    static let didTourKey = "didTour"

    @Published private(set) var tourRunning = false
    @Published private(set) var tutorialRunning = false
    /// The hold-to-talk button is down and the mic is open.
    @Published private(set) var listening = false
    private let listener = Listener()
    private var listenStart = Date.distantPast
    private var tutorialTask: Task<Void, Never>?
    private var tutorialRun = 0   // bumps on each start so a replaced tutorial's follow-up doesn't run
    private var bag = Set<AnyCancellable>()
    private var houseBag = Set<AnyCancellable>()   // subscriptions to the current explorer

    init() {
        let demo = DemoHouse.current
        let house = House.bundled(demo)
        let audio = SpatialAudio(frontDoor: house.frontDoor.point)
        let explorer = Explorer(house: house, haptics: haptics, audio: audio, speech: speech, onRail: false)
        self.house = house
        self.audio = audio
        self.explorer = explorer
        tour = GuidedTour(explorer: explorer, speech: speech)
        guide = Guide(explorer: explorer, speech: speech, haptics: haptics, audio: audio)
        connectHouse(demo)
        connectViewer()
        headMotion.onHeading = { [weak self] heading in self?.explorer.faceHead(heading) }
        headMotion.onStatus = { [weak self] message in self?.speech.request(message) }
#if DEBUG && targetEnvironment(simulator)
        simulatorMotion.onHeading = { [weak self] heading in self?.explorer.faceHead(heading) }
        simulatorMotion.onWarning = { [weak self] in self?.audio.wallWarning() }
        simulatorMotion.start()
#endif
    }

    /// Wires the current explorer and tour to the app and the laptop viewer.
    private func connectHouse(_ demo: DemoHouse) {
        houseBag = []
        tour.onFinish = { [weak self] in
            self?.tourRunning = false
            UserDefaults.standard.set(true, forKey: Self.didTourKey)
        }
        explorer.onUpdate = { [weak self] in
            self?.tour.update()
            self?.guide.update()
        }
        explorer.onEvent = { [weak self] text in self?.log(text, who: "event") }
        explorer.$onRail.dropFirst().removeDuplicates()
            .sink { [weak self] on in self?.log(on ? "Path on" : "Path off", who: "event") }
            .store(in: &houseBag)
        // Re-render SwiftUI when the explorer's room or floor changes.
        explorer.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &houseBag)
        // Mirror position, heading, room, and floor to the laptop viewer.
        let viewer = self.viewer
        viewer.show(demo)
        explorer.$position.sink { p in viewer.update { $0.x = p.x; $0.y = p.y } }.store(in: &houseBag)
        explorer.$heading.sink { h in viewer.update { $0.heading = h } }.store(in: &houseBag)
        explorer.$heading.sink { [weak self] h in self?.guide.headingChanged(to: h) }.store(in: &houseBag)
        explorer.$floorIndex.sink { f in viewer.update { $0.floor = f } }.store(in: &houseBag)
        explorer.$roomName.sink { name in viewer.update { $0.room = name } }.store(in: &houseBag)
        explorer.$onRail.sink { on in viewer.update { $0.onRail = on } }.store(in: &houseBag)
    }

    /// Swaps in another bundled house and names it. You start in free roam at
    /// its front door; the guided tour waits to be asked for.
    func switchHouse(to demo: DemoHouse) {
        log("Switched house to \(demo.title)")
        stopTutorial()
        guide.stop(silently: true)
        if tourRunning {
            tour.stop(silently: true)
            tourRunning = false
        }
        explorer.touchUp()
        house = House.bundled(demo)
        audio.moveBeacon(to: house.frontDoor.point)
        let headHeading = explorer.headHeading
        explorer = Explorer(house: house, haptics: haptics, audio: audio, speech: speech, onRail: false)
        if let headHeading { explorer.faceHead(headHeading) }
        tour = GuidedTour(explorer: explorer, speech: speech)
        guide = Guide(explorer: explorer, speech: speech, haptics: haptics, audio: audio)
        connectHouse(demo)
        speech.request("\(house.address). \(house.summary)")
    }

    /// Mirror the tour state and speech to the laptop viewer, and start or stop
    /// its server when the setting changes.
    private func connectViewer() {
        let viewer = self.viewer
        $tourRunning.sink { on in viewer.update { $0.touring = on } }.store(in: &bag)
        viewer.transcript = transcript
        speech.onSkip = { [weak self] text in self?.log(text, who: "skipped") }
        speech.onSay = { [weak self] text in
            self?.log(text, who: "app")
            viewer.update {
                $0.said = text
                $0.saidAt = Date().timeIntervalSince1970
            }
        }
        let sync = { Setting.laptopViewer.isOn ? viewer.start() : viewer.stop() }
        sync()
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { _ in sync() }
            .store(in: &bag)
    }

    var floorLabel: String { explorer.floor.name }

    /// The wearer looks straight ahead before pressing this control.
    func calibrateForward() {
#if DEBUG && targetEnvironment(simulator)
        simulatorMotion.calibrate()
        speech.request("Look straight ahead. Forward calibration requested from the connected AirPods.")
#else
        headMotion.calibrate()
#endif
    }

    /// Any touch on the map or the settings gear takes over from the tutorial. The guided
    /// tour keeps going, since you walk it yourself.
    func interrupt() {
        if tutorialRunning { stopTutorial() }
    }

    /// First launch: the haptic tutorial. Every launch starts in free roam; the
    /// guided tour waits to be asked for ("start the tour").
    func firstLaunch(tutorial: Bool) {
        if tutorial { runTutorial() }
    }

    func toggleTour() {
        log(tourRunning ? "Stopped the tour" : "Started the tour")
        if tourRunning {
            tour.stop()
            tourRunning = false
        } else {
            startTour()
        }
    }

    private func startTour(preface: String? = nil) {
        stopTutorial()
        let guiding = guide.running
        guide.stop(silently: true)
        tourRunning = true
        let parts = [guiding ? "Guide stopped." : nil, preface].compactMap { $0 }
        tour.start(preface: parts.isEmpty ? nil : parts.joined(separator: " "))
    }

    /// Single tap: while guiding, the next leg; during the tour, the way to the
    /// next stop; otherwise the room.
    func singleTap() {
        log("Single tap")
        if guide.running { return guide.repeatLeg() }
        tourRunning ? tour.repeatGuidance() : explorer.announceLocation()
    }

    /// Triple tap on the touch surface: leave the fixed route, or snap back to it.
    func toggleRail() {
        log("Triple tap")
        interrupt()
        explorer.toggleRail()
        // Off the path you steer yourself, so say which way, after "Off the path".
        if guide.running, !explorer.onRail { guide.repeatLeg(interrupt: false) }
    }

    /// Adds a line to the transcript, tagged with where the avatar is.
    private func log(_ text: String, who: String = "you") {
        transcript.add(who, text, place: "\(explorer.roomName), \(explorer.floor.name)")
    }

    // MARK: Asking aloud

    /// Hold-to-talk pressed: stop talking, hold anything new, and open the mic.
    /// The first press only asks for permission, since the prompts take over
    /// the screen anyway.
    func startListening() {
        interrupt()
        guard !listening else { return }
        switch Listener.permission {
        case .granted:
            break
        case .undetermined:
            Listener.requestPermission { [weak self] ok in
                self?.speech.say(ok ? "Ready. Hold the button and ask." : Self.permissionHelp, interrupt: true)
            }
            return
        case .denied:
            speech.say(Self.permissionHelp, interrupt: true)
            return
        }
        speech.hold()
        guard listener.start(hints: Question.hints(for: house)) else {
            speech.resume { speech.say("The microphone isn't available right now.", interrupt: true) }
            return
        }
        listening = true
        listenStart = Date()
        haptics.listening(true)
        audio.cue(listening: true)
    }

    /// Hold-to-talk released: close the mic and answer what was heard. A press
    /// too short to hold a question is taken as not knowing to hold.
    func stopListening() {
        guard listening else { return }
        listening = false
        haptics.listening(false)
        let held = Date().timeIntervalSince(listenStart)
        guard held >= 0.3 else {
            listener.cancel()
            log("Tapped Ask without holding")
            audio.cue(listening: false)
            speech.resume { speech.say("Hold the button while you ask.", interrupt: true) }
            return
        }
        listener.finish { [weak self] heard in
            guard let self else { return }
            self.logListening(held: held, heard: heard)
            self.speech.resume { self.answer(heard) }
        }
        // After `finish`, which hands the audio session back to playback.
        audio.cue(listening: false)
    }

    /// "Mic held 1.4 s, recognizer final. Guesses: "where", "where am I"."
    /// Guesses are listed only when they say something the answer doesn't.
    private func logListening(held: TimeInterval, heard: String) {
        var text = String(format: "Mic held %.1f s, recognizer %@.", held, listener.ending)
        if listener.guesses != [heard], !listener.guesses.isEmpty {
            text += " Guesses: " + listener.guesses.suffix(5).map { "\"\($0)\"" }.joined(separator: ", ") + "."
        }
        log(text, who: "event")
    }

    private static let permissionHelp =
        "To ask questions, turn on Microphone and Speech Recognition for House Tour in the Settings app."

    private func answer(_ heard: String) {
        let match = Question.match(heard, in: house, from: explorer.floorIndex, at: explorer.position)
        log(heard.isEmpty ? "Asked, but nothing was heard" : "Asked \"\(heard)\" (\(understood(match)))")
        switch match {
        case .whereAmI: explorer.whereAmI()
        case .waysOut: explorer.waysOut()
        case .frontDoor: explorer.wayToFrontDoor()
        case let .room(floor, index): speech.request(Directions.stepsTo(room: index, onFloor: floor, explorer))
        case let .guide(floor, index):
            if tourRunning {
                tour.stop(silently: true)
                tourRunning = false
            }
            guide.start(room: index, onFloor: floor)
        case .listRooms: speech.request(Directions.listRooms(explorer))
        case .aroundMe: speech.request(Directions.aroundMe(explorer))
        case .walls: speech.request(Directions.walls(explorer))
        case .tour:
            if tourRunning {
                speech.say("The tour is already running. Say stop to end it.", interrupt: true)
            } else {
                startTour()
            }
        case .stop:
            if guide.running {
                guide.stop()
            } else if tourRunning {
                toggleTour()
            } else {
                speech.say("Nothing to stop.", interrupt: true)
            }
        case nil:
            let lead = heard.isEmpty ? "I didn't catch that." : "I heard \(heard)."
            speech.say(lead + " " + Question.examples, interrupt: true)
        }
    }

    /// How a question was taken, for the transcript.
    private func understood(_ match: Question?) -> String {
        switch match {
        case .whereAmI: "where am I"
        case .waysOut: "ways out"
        case .frontDoor: "way to the front door"
        case let .room(floor, index): "steps to \(house.floors[floor].rooms[index].name)"
        case let .guide(floor, index): "guide to \(house.floors[floor].rooms[index].name)"
        case .listRooms: "list rooms"
        case .aroundMe: "what's around me"
        case .walls: "walls"
        case .stop: "stop"
        case .tour: "start the tour"
        case nil: "not understood"
        }
    }

    /// `then` runs when the tutorial ends, whether it finished or was stopped,
    /// unless another tutorial replaced it.
    func runTutorial(then next: (() -> Void)? = nil) {
        interrupt()
        if tourRunning {
            tour.stop(silently: true)
            tourRunning = false
        }
        stopTutorial()
        tutorialRunning = true
        tutorialRun += 1
        let run = tutorialRun
        let tutorial = Tutorial(haptics: haptics, audio: audio, speech: speech)
        tutorialTask = Task { @MainActor [weak self] in
            await tutorial.run()
            guard let self, self.tutorialRun == run else { return }
            self.tutorialRunning = false
            next?()
        }
    }

    func stopTutorial() {
        guard tutorialRunning else { return }
        tutorialTask?.cancel()
        tutorialTask = nil
        tutorialRunning = false
        speech.stop()
        haptics.proximity(0)
    }
}

#if DEBUG && targetEnvironment(simulator)
/// Mac AirPods sensors cannot be read inside Simulator. This development-only
/// listener accepts real motion from the native probe on this Mac, over loopback.
/// It is excluded from every physical-device and Release build.
private final class SimulatorMotionBridge {
    private var listener: NWListener?
    private var calibrationID = UUID().uuidString
    var onHeading: ((Double) -> Void)?
    var onWarning: (() -> Void)?

    func calibrate() {
        calibrationID = UUID().uuidString
        onHeading?(0)
    }

    func start() {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 8081)
        do {
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .main)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
                    guard let self, let data,
                          let request = String(data: data, encoding: .utf8),
                          let firstLine = request.components(separatedBy: "\r\n").first else {
                        connection.cancel()
                        return
                    }
                    let parts = firstLine.split(separator: " ")
                    guard parts.count >= 2, parts[0] == "GET",
                          let url = URLComponents(string: "http://localhost" + String(parts[1])) else {
                        connection.cancel()
                        return
                    }
                    DispatchQueue.main.async {
                        var accepted = false
                        if url.path == "/heading",
                           let value = url.queryItems?.first(where: { $0.name == "angle" })?.value,
                           let heading = Double(value), heading.isFinite, abs(heading) <= .pi {
                            // Ignore samples from before a recenter request. The probe
                            // receives the new token and recalibrates its actual sensor.
                            let token = url.queryItems?.first(where: { $0.name == "calibration" })?.value
                            if token == self.calibrationID { self.onHeading?(heading) }
                            accepted = true
                        } else if url.path == "/calibrate" {
                            self.calibrate()
                            accepted = true
                        } else if url.path == "/warning" {
                            self.onWarning?()
                            accepted = true
                        }
                        let body = accepted ? self.calibrationID : "invalid request"
                        let response = "HTTP/1.1 \(accepted ? "200 OK" : "400 Bad Request")\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
                        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch { print("Simulator motion bridge unavailable: \(error)") }
    }

    deinit { listener?.cancel() }
}
#endif

/// The wearer's calibrated forward pose is map heading zero (straight up).
/// Core Motion yaw is counterclockwise; the map heading is clockwise.
final class HeadMotion: NSObject, CMHeadphoneMotionManagerDelegate {
    private let manager = CMHeadphoneMotionManager()
    private var previousYaw: Double?
    private var forwardYaw: Double?
    private var wantsUpdates = false
    private var updateGeneration = 0
    private(set) var heading: Double?
    var onHeading: ((Double) -> Void)?
    var onStatus: ((String) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
    }

    deinit {
        manager.stopDeviceMotionUpdates()
        manager.stopConnectionStatusUpdates()
    }

    func start() {
        wantsUpdates = true
        manager.startConnectionStatusUpdates()
        beginUpdates()
    }

    /// Capture the latest live pose as forward, or wait for the first sample.
    func calibrate() {
        forwardYaw = previousYaw
        if previousYaw != nil {
            heading = 0
            onHeading?(0)
            onStatus?("Forward calibrated. Looking straight ahead points up on the map.")
        } else {
            onStatus?("Look straight ahead with your AirPods connected. Forward will calibrate when head tracking starts.")
        }
    }

    private func beginUpdates() {
        guard wantsUpdates, !manager.isDeviceMotionActive else { return }
        previousYaw = nil
        forwardYaw = nil
        guard manager.isDeviceMotionAvailable else {
            onStatus?("Connect motion-capable AirPods Pro to turn your head.")
            return
        }
        let authorization = CMHeadphoneMotionManager.authorizationStatus()
        guard authorization != .denied, authorization != .restricted else {
            onStatus?("Allow Motion access in Settings to use AirPods head turning.")
            return
        }
        updateGeneration += 1
        let generation = updateGeneration
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            guard let self, self.wantsUpdates, self.updateGeneration == generation else { return }
            guard let motion, error == nil else {
                self.previousYaw = nil
                self.forwardYaw = nil
                self.onStatus?("Head tracking unavailable. Check AirPods and Motion access in Settings.")
                return
            }
            let yaw = motion.attitude.yaw
            guard yaw.isFinite else { return }
            defer { self.previousYaw = yaw }
            guard let forward = self.forwardYaw, let previous = self.previousYaw else {
                self.forwardYaw = yaw
                self.heading = 0
                self.onHeading?(0)
                return
            }
            let delta = atan2(sin(yaw - previous), cos(yaw - previous))
            // A sudden sensor reference-frame jump should preserve the last
            // direction instead of snapping the arrow or losing the zero pose.
            guard abs(delta) < .pi / 4 else {
                self.forwardYaw = yaw + (self.heading ?? 0)
                return
            }
            let heading = atan2(sin(forward - yaw), cos(forward - yaw))
            self.heading = heading
            self.onHeading?(heading)
        }
    }

    func stop() {
        wantsUpdates = false
        manager.stopConnectionStatusUpdates()
        manager.stopDeviceMotionUpdates()
        updateGeneration += 1
        previousYaw = nil
        forwardYaw = nil
    }

    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        DispatchQueue.main.async { [weak self] in self?.beginUpdates() }
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        DispatchQueue.main.async { [weak self] in
            self?.manager.stopDeviceMotionUpdates()
            self?.updateGeneration += 1
            self?.previousYaw = nil
            self?.forwardYaw = nil
            self?.onStatus?("AirPods disconnected. Head turning is paused.")
        }
    }
}
