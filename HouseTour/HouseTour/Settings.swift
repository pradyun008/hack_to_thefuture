import SwiftUI

/// One switch per feedback channel, stored in UserDefaults. Defaults are calm:
/// testers found everything-on overwhelming, so only what's needed to walk the
/// house is on at first. The settings sheet and Explorer read the same keys.
enum Setting: String, CaseIterable, Identifiable {
    case wallHum, beacon, textures, wind, speakRooms, speakDoors, speakObstacles, fineMovement, showMap, laptopViewer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wallHum: "Wall approach hum"
        case .beacon: "Front door chime while touching"
        case .textures: "Floor texture vibration"
        case .wind: "Wind sound outside"
        case .speakRooms: "Speak room names"
        case .speakDoors: "Speak doors when you reach them"
        case .speakObstacles: "Speak windows, railings, and fixtures"
        case .fineMovement: "Fine movement"
        case .showMap: "Show map"
        case .laptopViewer: "Laptop viewer"
        }
    }

    var detail: String {
        switch self {
        case .wallHum: "A vibration that grows as you get close to a wall."
        case .beacon: "A repeating chime placed at the front door. The find front door button plays it for a few seconds either way."
        case .textures: "A pattern every few steps that tells hardwood, carpet, tile, concrete, and deck apart."
        case .wind: "Loops quietly while you are outside the house."
        case .speakRooms: "Says the room name when you walk into it."
        case .speakDoors: "Says where a door goes when you are standing in it."
        case .speakObstacles: "Says the name when you bump something other than a plain wall."
        case .fineMovement: "Each swipe moves you a third as far."
        case .showMap: "For sighted people watching. Movement works the same either way."
        case .laptopViewer: "Lets a laptop on the same Wi-Fi watch the map live while this screen stays blank."
        }
    }

    var defaultValue: Bool {
        switch self {
        case .textures, .speakRooms, .speakDoors, .laptopViewer: true
        case .wallHum, .beacon, .wind, .speakObstacles, .fineMovement, .showMap: false
        }
    }

    var isOn: Bool { UserDefaults.standard.bool(forKey: rawValue) }

    /// UserDefaults returns false for unset keys, so register the real defaults
    /// before anything reads them.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: Dictionary(uniqueKeysWithValues: allCases.map { ($0.rawValue, $0.defaultValue) }))
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(DemoHouse.key) private var demoHouse = DemoHouse.current

    private var viewerHint: String {
        let urls = LaptopViewer.urls
        guard !urls.isEmpty else { return "Laptop viewer: connect this phone to Wi-Fi or turn on Personal Hotspot." }
        return "Laptop viewer: open " + urls.joined(separator: " or ") + " in a browser on the same network."
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("House", selection: $demoHouse) {
                        ForEach(DemoHouse.allCases) { Text($0.title).tag($0) }
                    }
                } footer: {
                    Text("Switching houses starts its guided tour.")
                }
                Section {
                    ForEach(Setting.allCases) { SettingRow(setting: $0) }
                } footer: {
                    Text(viewerHint)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

private struct SettingRow: View {
    let setting: Setting
    @AppStorage private var isOn: Bool

    init(setting: Setting) {
        self.setting = setting
        _isOn = AppStorage(wrappedValue: setting.defaultValue, setting.rawValue)
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(setting.title)
                Text(setting.detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
