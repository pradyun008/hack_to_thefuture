import SwiftUI

struct ContentView: View {
    @StateObject private var app = AppModel()
    @AppStorage("didTutorial") private var didTutorial = false
    @AppStorage(Setting.showMap.rawValue) private var showMap = Setting.showMap.defaultValue
    @AppStorage(Setting.fineMovement.rawValue) private var fineMovement = Setting.fineMovement.defaultValue
    @AppStorage(DemoHouse.key) private var demoHouse = DemoHouse.current
    @State private var showingSettings = false
    @State private var lastPress = Date.distantPast
    @State private var launched = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.house.address).font(.headline)
                    Text("\(app.floorLabel) · \(app.explorer.roomName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                Button {
                    app.interrupt()
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape").font(.title2)
                }
                .accessibilityLabel("Settings")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            FloorMap(app: app, showMap: showMap)
                .id(ObjectIdentifier(app.explorer))   // a new house gets a fresh touch surface
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                control(app.tourRunning ? "Stop tour" : "Guided tour", "figure.walk") { app.toggleTour() }
                control("Where am I", "location") {
                    app.interrupt()
                    app.explorer.whereAmI()
                }
                if app.tourRunning {
                    control("Previous room", "arrow.uturn.backward") { app.previousStop() }
                    control("Restart tour", "arrow.counterclockwise") { app.restartTour() }
                    jumpMenu
                }
                control(app.otherFloorLabel, "stairs") { app.toggleFloor() }
                control(fineMovement ? "Normal movement" : "Fine movement", "scope") {
                    fineMovement.toggle()
                    app.announceFineMovement(fineMovement)
                }
                control("Find front door", "door.left.hand.open") { app.findFrontDoor() }
                control(app.tutorialRunning ? "Stop tutorial" : "Haptic tutorial", "hand.tap") {
                    app.tutorialRunning ? app.stopTutorial() : app.runTutorial()
                }
            }
            .padding()
        }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .onChange(of: demoHouse) { _, demo in app.switchHouse(to: demo) }
        .onAppear {
            guard !launched else { return }
            launched = true
            let firstRun = !didTutorial
            didTutorial = true
            app.firstLaunch(tutorial: firstRun)
        }
    }

    /// Lists the tour's stops; picking one moves you there and plays its narration.
    private var jumpMenu: some View {
        Menu {
            ForEach(Array(app.tourStops.enumerated()), id: \.offset) { i, name in
                Button(name) { pressed { app.jumpToStop(i) } }
            }
        } label: {
            Label("Jump to room", systemImage: "list.bullet")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 50)
        }
        .menuStyle(.button)
        .buttonStyle(.borderedProminent)
    }

    private func control(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button { pressed(action) } label: {
            Label(title, systemImage: icon)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(.borderedProminent)
    }

    /// Drops a press that comes within 0.6 s of the last one, so a double press
    /// can't start and stop the tour or stack two announcements.
    private func pressed(_ action: () -> Void) {
        guard Date().timeIntervalSince(lastPress) > 0.6 else { return }
        lastPress = Date()
        action()
    }
}
