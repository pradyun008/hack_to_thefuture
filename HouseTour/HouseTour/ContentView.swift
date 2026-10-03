import SwiftUI

struct ContentView: View {
    @StateObject private var app = AppModel()
    @AppStorage("didTutorial") private var didTutorial = false
    @AppStorage(Setting.showMap.rawValue) private var showMap = Setting.showMap.defaultValue
    @AppStorage(Setting.fineMovement.rawValue) private var fineMovement = Setting.fineMovement.defaultValue
    @State private var showingSettings = false

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
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                control(app.tourRunning ? "Stop tour" : "Guided tour", "figure.walk") { app.toggleTour() }
                control("Where am I", "location") {
                    app.interrupt()
                    app.explorer.whereAmI()
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
        .onAppear {
            guard !didTutorial else { return }
            didTutorial = true
            app.runTutorial()
        }
    }

    private func control(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(.borderedProminent)
    }
}
