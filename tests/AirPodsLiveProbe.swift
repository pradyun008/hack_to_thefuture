import AppKit
import AVFoundation
import CoreMotion

/// Uses the app's actual HeadMotion controller, appended by the build script.
/// A native Mac process is required because Simulator cannot read headphone sensors.
final class AirPodsProbe: NSObject, NSApplicationDelegate {
    private let motion = HeadMotion()
    private var window: NSWindow!
    private var status: NSTextField!
    private var headingLabel: NSTextField!
    private var samples = 0
    private var heading = 0.0
    private var minimum = 0.0
    private var maximum = 0.0
    private var lastReport = Date.distantPast
    private var lastForward = Date.distantPast
    private var calibrationID: String?
    private var forwardInFlight = false
    private var calibrationInFlight = false
    private var forwarded = 0
    private var forwardErrors = 0
    private let reportURL = URL(fileURLWithPath: "/tmp/house-tour-airpods-live.json")
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var warningBuffer: AVAudioPCMBuffer!

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 320),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "HouseTour — live AirPods test"
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        let instructions = NSTextField(wrappingLabelWithString:
            "Wear your AirPods, look straight ahead, then click Calibrate forward. That pose points the mobile map arrow straight up. Turn left or right, then return to forward.")
        status = NSTextField(wrappingLabelWithString: "Waiting for headphone motion…")
        headingLabel = NSTextField(labelWithString: "Motion updates: 0 · map direction: 0°")
        let calibrate = NSButton(title: "Calibrate forward", target: self, action: #selector(calibrateForward))
        let beep = NSButton(title: "Play short wall warning", target: self, action: #selector(playWarning))
        [instructions, status, headingLabel, calibrate, beep].forEach(stack.addArrangedSubview)
        window.contentView = stack
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        warningBuffer = makeWallWarning(format)
        motion.onStatus = { [weak self] message in
            self?.status.stringValue = message
            self?.report(message)
        }
        motion.onHeading = { [weak self] angle in
            guard let self else { return }
            self.samples += 1
            self.heading = angle * 180 / .pi
            self.minimum = min(self.minimum, self.heading)
            self.maximum = max(self.maximum, self.heading)
            if !self.forwardInFlight, !self.calibrationInFlight,
               Date().timeIntervalSince(self.lastForward) >= 0.05 {
                self.lastForward = Date()
                self.forwardInFlight = true
                let token = self.calibrationID
                let path = "/heading?angle=\(angle)" + (token.map { "&calibration=\($0)" } ?? "")
                self.sendToSimulator(path) { [weak self] responseToken in
                    guard let self else { return }
                    self.forwardInFlight = false
                    self.syncCalibration(responseToken, requested: token)
                }
            }
            self.status.stringValue = "Receiving live AirPods motion"
            self.headingLabel.stringValue = String(format: "Motion updates: %d · map direction: %.1f° (0° = up)", self.samples, self.heading)
            if Date().timeIntervalSince(self.lastReport) >= 1 {
                self.report("Receiving live AirPods motion")
            }
        }
        report("Starting headphone motion")
        motion.start()
    }

    private func report(_ status: String) {
        lastReport = Date()
        let values: [String: Any] = ["status": status, "updates": samples,
            "headingDegrees": heading, "minimumDegrees": minimum,
            "maximumDegrees": maximum,
            "authorization": CMHeadphoneMotionManager.authorizationStatus().rawValue,
            "calibration": calibrationID ?? "pending",
            "simulatorRequests": forwarded, "simulatorErrors": forwardErrors]
        if let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted]) {
            try? data.write(to: reportURL, options: .atomic)
        }
    }

    @objc private func playWarning() {
        sendToSimulator("/warning") { [weak self] token in
            if token == nil { self?.playLocalWarning() }
        }
    }

    @objc private func calibrateForward() {
        calibrationID = nil
        calibrationInFlight = true
        motion.calibrate()
        sendToSimulator("/calibrate") { [weak self] token in
            guard let self else { return }
            self.calibrationInFlight = false
            self.syncCalibration(token, requested: nil)
        }
    }

    private func syncCalibration(_ token: String?, requested: String?) {
        // A response sent before a local calibration cannot undo the new pose.
        guard requested == calibrationID, let token,
              token != calibrationID else { return }
        calibrationID = token
        motion.calibrate()
    }

    private func playLocalWarning() {
        do {
            if !engine.isRunning { try engine.start() }
            player.scheduleBuffer(warningBuffer, at: nil, options: .interrupts)
            player.play()
        } catch { status.stringValue = "Audio test failed: \(error.localizedDescription)" }
    }

    private func sendToSimulator(_ path: String, completion: @escaping (String?) -> Void) {
        guard let url = URL(string: "http://127.0.0.1:8081" + path) else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if error == nil, (response as? HTTPURLResponse)?.statusCode == 200 {
                    self.forwarded += 1
                    completion(data.flatMap { String(data: $0, encoding: .utf8) })
                } else {
                    self.forwardErrors += 1
                    completion(nil)
                }
            }
        }.resume()
    }

    func applicationWillTerminate(_ notification: Notification) { motion.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main struct AirPodsProbeMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AirPodsProbe()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
