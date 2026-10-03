import Combine
import Foundation

final class AppModel: ObservableObject {
    /// The house being explored. Switching houses replaces it, the explorer, and
    /// the tour; sound, haptics, speech, and the laptop viewer carry over.
    @Published private(set) var house: House
    let haptics = Haptics()
    let speech = Speaker()
    let audio: SpatialAudio
    private(set) var explorer: Explorer
    private var tour: GuidedTour
    private let viewer = LaptopViewer()

    /// UserDefaults key: the first-run tour reached its last stop.
    static let didTourKey = "didTour"

    @Published private(set) var tourRunning = false
    @Published private(set) var tutorialRunning = false
    private var tutorialTask: Task<Void, Never>?
    private var tutorialRun = 0   // bumps on each start so a replaced tutorial's follow-up doesn't run
    private var bag = Set<AnyCancellable>()
    private var houseBag = Set<AnyCancellable>()   // subscriptions to the current explorer

    init() {
        let demo = DemoHouse.current
        let house = House.bundled(demo)
        let audio = SpatialAudio(frontDoor: house.frontDoor.point)
        let explorer = Explorer(house: house, haptics: haptics, audio: audio, speech: speech)
        self.house = house
        self.audio = audio
        self.explorer = explorer
        tour = GuidedTour(explorer: explorer, speech: speech)
        connectHouse(demo)
        connectViewer()
    }

    /// Wires the current explorer and tour to the app and the laptop viewer.
    private func connectHouse(_ demo: DemoHouse) {
        houseBag = []
        tour.onFinish = { [weak self] in
            self?.tourRunning = false
            UserDefaults.standard.set(true, forKey: Self.didTourKey)
        }
        explorer.onUpdate = { [weak self] in self?.tour.update() }
        // Re-render SwiftUI when the explorer's room or floor changes.
        explorer.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &houseBag)
        // Mirror position, heading, room, and floor to the laptop viewer.
        let viewer = self.viewer
        viewer.show(demo)
        explorer.$position.sink { p in viewer.update { $0.x = p.x; $0.y = p.y } }.store(in: &houseBag)
        explorer.$heading.sink { h in viewer.update { $0.heading = h } }.store(in: &houseBag)
        explorer.$floorIndex.sink { f in viewer.update { $0.floor = f } }.store(in: &houseBag)
        explorer.$roomName.sink { name in viewer.update { $0.room = name } }.store(in: &houseBag)
    }

    /// Swaps in another bundled house and starts its guided tour, since every
    /// room in it is new.
    func switchHouse(to demo: DemoHouse) {
        stopTutorial()
        if tourRunning {
            tour.stop(silently: true)
            tourRunning = false
        }
        explorer.touchUp()
        house = House.bundled(demo)
        audio.moveBeacon(to: house.frontDoor.point)
        explorer = Explorer(house: house, haptics: haptics, audio: audio, speech: speech)
        tour = GuidedTour(explorer: explorer, speech: speech)
        connectHouse(demo)
        startTour(preface: "\(house.address). \(house.summary)")
    }

    /// Mirror the tour state and speech to the laptop viewer, and start or stop
    /// its server when the setting changes.
    private func connectViewer() {
        let viewer = self.viewer
        $tourRunning.sink { on in viewer.update { $0.touring = on } }.store(in: &bag)
        speech.onSay = { text in
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
    var otherFloorLabel: String { explorer.floorIndex == 0 ? "Go upstairs" : "Go downstairs" }
    /// Room names of the tour's stops, in order, for the "Jump to room" menu.
    var tourStops: [String] { tour.checkpoints.map(\.name) }

    /// Any touch on the map or button takes over from the tutorial. The guided
    /// tour keeps going, since you walk it yourself.
    func interrupt() {
        if tutorialRunning { stopTutorial() }
    }

    /// First launch: the haptic tutorial, then the guided tour. Later launches
    /// start the tour only if it was never finished.
    func firstLaunch(tutorial: Bool) {
        if tutorial {
            runTutorial { [weak self] in self?.startTourIfNew() }
        } else {
            startTourIfNew()
        }
    }

    private func startTourIfNew() {
        guard !UserDefaults.standard.bool(forKey: Self.didTourKey), !tourRunning else { return }
        startTour()
    }

    func toggleTour() {
        if tourRunning {
            tour.stop()
            tourRunning = false
        } else {
            startTour()
        }
    }

    private func startTour(preface: String? = nil) {
        stopTutorial()
        tourRunning = true
        tour.start(preface: preface)
    }

    func previousStop() { tour.previous() }
    func restartTour() { tour.restart() }
    func jumpToStop(_ index: Int) { tour.jump(to: index) }

    /// Single tap: during the tour, the way to the next stop; otherwise the room.
    func singleTap() {
        tourRunning ? tour.repeatGuidance() : explorer.announceLocation()
    }

    func toggleFloor() {
        interrupt()
        explorer.changeFloor()
    }

    /// With the map hidden, a smaller step per swipe is what makes a narrow
    /// doorway easy to line up with.
    func announceFineMovement(_ on: Bool) {
        interrupt()
        speech.request(on ? "Fine movement. Each swipe moves a third as far." : "Normal movement.")
    }

    func findFrontDoor() {
        interrupt()
        explorer.findFrontDoor()
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
