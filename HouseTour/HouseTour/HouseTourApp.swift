import SwiftUI

@main
struct HouseTourApp: App {
    init() { Setting.registerDefaults() }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
