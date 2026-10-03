import Combine
import Foundation

final class AppModel: ObservableObject {
    let house: House
    let haptics = Haptics()
    let speech = Speaker()
    let audio: SpatialAudio
    let explorer: Explorer
    private let tour: GuidedTour
    private let viewer = LaptopViewer()

    @Published private(set) var tourRunning = false
    @Published private(set) var tutorialRunning = false
    private var tutorialTask: Task<Void, Never>?
    private var bag = Set<AnyCancellable>()

    init() {
        house = House.bundled()
        audio = SpatialAudio(frontDoor: house.frontDoor.point)
        explorer = Explorer(house: house, haptics: haptics, audio: audio, speech: speech)
        tour = GuidedTour(explorer: explorer, speech: speech)
        tour.onFinish = { [weak self] in self?.tourRunning = false }
        // Re-render SwiftUI when the explorer's room or floor changes.
        explorer.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        connectViewer()
    }

    /// Mirror position, room, floor, and speech to the laptop viewer, and start or
    /// stop its server when the setting changes.
    private func connectViewer() {
        let viewer = self.viewer
        explorer.$position.sink { p in viewer.update { $0.x = p.x; $0.y = p.y } }.store(in: &bag)
        explorer.$floorIndex.sink { f in viewer.update { $0.floor = f } }.store(in: &bag)
        explorer.$roomName.sink { name in viewer.update { $0.room = name } }.store(in: &bag)
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

    /// Any touch on the map takes over from the tour or tutorial.
    func interrupt() {
        if tourRunning {
            tour.stop()
            tourRunning = false
        }
        if tutorialRunning { stopTutorial() }
    }

    func toggleTour() {
        if tourRunning {
            tour.stop()
            tourRunning = false
        } else {
            stopTutorial()
            tourRunning = true
            tour.start()
        }
    }

    func toggleFloor() {
        interrupt()
        explorer.changeFloor()
    }

    /// With the map hidden, a smaller step per swipe is what makes a narrow
    /// doorway easy to line up with.
    func announceFineMovement(_ on: Bool) {
        interrupt()
        speech.say(on ? "Fine movement. Each swipe moves a third as far." : "Normal movement.", interrupt: true)
    }

    func findFrontDoor() {
        interrupt()
        explorer.findFrontDoor()
    }

    func runTutorial() {
        interrupt()
        stopTutorial()
        tutorialRunning = true
        let tutorial = Tutorial(haptics: haptics, audio: audio, speech: speech)
        tutorialTask = Task { @MainActor [weak self] in
            await tutorial.run()
            self?.tutorialRunning = false
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
