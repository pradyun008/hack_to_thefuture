import SwiftUI

struct ContentView: View {
    @StateObject private var app = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("didTutorial") private var didTutorial = false
    @AppStorage(Setting.showMap.rawValue) private var showMap = Setting.showMap.defaultValue
    @AppStorage(DemoHouse.key) private var demoHouse = DemoHouse.current
    @State private var showingSettings = false
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

            AskButton(listening: app.listening, onPress: { app.startListening() }, onRelease: { app.stopListening() })
                .padding([.horizontal, .top])
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
}
