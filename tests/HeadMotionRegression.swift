import Foundation

// Core Motion stand-in for exercising the actual controller's lifecycle and
// angle handling without motion hardware. Controller source is appended by
// run-regressions.sh, so these checks never use a copied implementation.
protocol CMHeadphoneMotionManagerDelegate: NSObjectProtocol {}
enum MotionAuthorization { case notDetermined, authorized, denied, restricted }
struct MotionAttitude { let yaw: Double }
struct TestMotion { let attitude: MotionAttitude }
final class CMHeadphoneMotionManager {
    static weak var latest: CMHeadphoneMotionManager?
    static var authorization = MotionAuthorization.authorized
    weak var delegate: CMHeadphoneMotionManagerDelegate?
    var isDeviceMotionAvailable = true
    var isDeviceMotionActive = false
    var connectionUpdates = false
    var handler: ((TestMotion?, Error?) -> Void)?
    init() { Self.latest = self }
    static func authorizationStatus() -> MotionAuthorization { authorization }
    func startDeviceMotionUpdates(to queue: OperationQueue,
                                  withHandler handler: @escaping (TestMotion?, Error?) -> Void) {
        isDeviceMotionActive = true
        self.handler = handler
    }
    func stopDeviceMotionUpdates() { isDeviceMotionActive = false }
    func startConnectionStatusUpdates() { connectionUpdates = true }
    func stopConnectionStatusUpdates() { connectionUpdates = false }
    func emit(_ yaw: Double) { handler?(TestMotion(attitude: MotionAttitude(yaw: yaw)), nil) }
}

@main struct HeadMotionRegression {
    static func main() {
        let controller = HeadMotion()
        let manager = CMHeadphoneMotionManager.latest!
        var headings: [Double] = []
        var messages: [String] = []
        controller.onHeading = { headings.append($0) }
        controller.onStatus = { messages.append($0) }
        controller.start()
        precondition(manager.isDeviceMotionActive && manager.connectionUpdates)
        manager.emit(179 * .pi / 180)
        precondition(headings == [0], "Initial forward pose did not point straight up")
        manager.emit(-179 * .pi / 180)
        precondition(abs(headings.last! + 2 * .pi / 180) < 1e-9, "Yaw wrap caused wrong direction")
        manager.emit(179 * .pi / 180)
        precondition(abs(headings.last!) < 1e-9, "Returning to forward did not point straight up")
        controller.calibrate()
        precondition(headings.last == 0)
        manager.emit(169 * .pi / 180)
        precondition(abs(headings.last! - 10 * .pi / 180) < 1e-9, "Right turn did not rotate clockwise")
        controller.calibrate()
        precondition(headings.last == 0, "Manual calibration did not recenter immediately")
        manager.emit(159 * .pi / 180)
        precondition(abs(headings.last! - 10 * .pi / 180) < 1e-9)
        manager.emit(179 * .pi / 180)
        precondition(abs(headings.last! + 10 * .pi / 180) < 1e-9, "Left turn did not rotate counterclockwise")
        manager.emit(169 * .pi / 180)
        precondition(abs(headings.last!) < 1e-9, "Manual forward reference was not retained")
        let beforeJump = headings.count
        manager.emit(0)
        precondition(headings.count == beforeJump, "Reference-frame jump rotated avatar")
        manager.emit(-0.1)
        precondition(abs(headings.last! - 0.1) < 1e-9, "Reference jump corrupted the calibrated heading")
        manager.emit(.nan)
        manager.emit(.infinity)
        let beforeStop = headings.count
        let oldHandler = manager.handler!
        controller.stop()
        manager.emit(0.1)
        precondition(headings.count == beforeStop && !manager.connectionUpdates,
                     "Stopped controller processed queued samples")
        controller.headphoneMotionManagerDidConnect(manager)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        precondition(!manager.isDeviceMotionActive, "Reconnect restarted background tracking")
        controller.start()
        manager.emit(1)
        precondition(headings.last == 0, "Restart retained stale yaw")
        let afterRestart = headings.count
        oldHandler(TestMotion(attitude: MotionAttitude(yaw: 2)), nil)
        precondition(headings.count == afterRestart, "Prior session callback changed new calibration")
        manager.emit(0.9)
        precondition(abs(headings.last! - 0.1) < 1e-9, "Clockwise conversion failed")
        controller.headphoneMotionManagerDidDisconnect(manager)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        precondition(!manager.isDeviceMotionActive)
        controller.headphoneMotionManagerDidConnect(manager)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        precondition(manager.isDeviceMotionActive, "Foreground reconnect failed")
        manager.emit(-2)
        precondition(headings.last == 0, "Reconnect did not establish a new forward pose")
        controller.stop()
        CMHeadphoneMotionManager.authorization = .denied
        controller.start()
        precondition(!manager.isDeviceMotionActive && messages.last!.contains("Motion access"))
        controller.stop()
        print("PASS: forward calibration, left/right signs, return to neutral, yaw wrap, sensor jumps, lifecycle and denied permission")
    }
}
