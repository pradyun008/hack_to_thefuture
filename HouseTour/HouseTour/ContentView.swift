import SwiftUI

struct ContentView: View {
    @StateObject private var app = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("didTutorial") private var didTutorial = false
    @AppStorage(Setting.showMap.rawValue) private var showMap = Setting.showMap.defaultValue
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

            Button { pressed { app.toggleTour() } } label: {
                Label(app.tourRunning ? "Stop tour" : "Guided tour", systemImage: "figure.walk")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .padding()
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(calibrateForward: app.calibrateForward) {
                showingSettings = false
                app.runTutorial()
            }
        }
        .onChange(of: demoHouse) { _, demo in app.switchHouse(to: demo) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { app.headMotion.start() } else { app.headMotion.stop() }
        }
        .onDisappear { app.headMotion.stop() }
        .onAppear {
            app.headMotion.start()
            guard !launched else { return }
            launched = true
            let firstRun = !didTutorial
            didTutorial = true
            app.firstLaunch(tutorial: firstRun)
        }
    }

    /// Drops a press that comes within 0.6 s of the last one, so a double press
    /// can't start and stop the tour.
    private func pressed(_ action: () -> Void) {
        guard Date().timeIntervalSince(lastPress) > 0.6 else { return }
        lastPress = Date()
        action()
    }
}
