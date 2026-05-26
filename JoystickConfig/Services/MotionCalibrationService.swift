import Foundation
import GameController

/// One controller's motion calibration: the gyro and accel readings observed
/// while the controller was held perfectly still. The mapping engine
/// subtracts these from every incoming sample so the controller's resting
/// drift never produces fake motion. Stored per controller identity so a
/// DualSense Edge and a DualShock 4 each keep their own zero.
struct MotionCalibration: Codable, Hashable {
    /// Stable identity string for the controller (see `MotionCalibrationService.identityKey`).
    var controllerKey: String
    /// Resting gyro reading (rad/s) when the controller is flat and still.
    var gyroDriftX: Float
    var gyroDriftY: Float
    var gyroDriftZ: Float
    /// Resting user-acceleration reading (g, gravity removed).
    var accelDriftX: Float
    var accelDriftY: Float
    var accelDriftZ: Float
    var savedAt: Date
}

/// Stores per-controller motion drift calibrations on disk, applies them to
/// raw gyro/accel samples, and tracks whether the user has calibrated each
/// controller identity. Lives alongside `TouchpadService` as a separate
/// concern so motion calibration data persists independently.
final class MotionCalibrationService: @unchecked Sendable {
    nonisolated(unsafe) static let shared = MotionCalibrationService()

    private let lock = NSLock()
    private var byKey: [String: MotionCalibration] = [:]

    private init() {
        load()
    }

    // MARK: - Persistence

    private static let fileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("JoystickConfig", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("motionCalibration.json")
    }()

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let decoded = try? JSONDecoder().decode([String: MotionCalibration].self, from: data) else {
            return
        }
        byKey = decoded
    }

    private func saveToDisk() {
        guard let data = try? JSONEncoder().encode(byKey) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    // MARK: - Identity

    /// Stable per-controller identity key. Apple's Game Controller framework
    /// does NOT expose hardware serial numbers, so two physically identical
    /// controllers share a key. That's fine - they have the same drift
    /// characteristics anyway.
    static func identityKey(for controller: GCController) -> String {
        let vendor = controller.vendorName ?? "Controller"
        let category = controller.productCategory
        return "\(vendor)|\(category)"
    }

    // MARK: - Public API

    func calibration(forKey key: String) -> MotionCalibration? {
        lock.lock(); defer { lock.unlock() }
        return byKey[key]
    }

    func isCalibrated(forKey key: String) -> Bool {
        calibration(forKey: key) != nil
    }

    func save(_ calibration: MotionCalibration) {
        lock.lock()
        byKey[calibration.controllerKey] = calibration
        lock.unlock()
        saveToDisk()
        #if DEBUG
        print("[MotionCalibration] saved drift for \(calibration.controllerKey): " +
              "gyro \(calibration.gyroDriftX),\(calibration.gyroDriftY),\(calibration.gyroDriftZ) " +
              "accel \(calibration.accelDriftX),\(calibration.accelDriftY),\(calibration.accelDriftZ)")
        #endif
    }

    func clear(forKey key: String) {
        lock.lock()
        byKey.removeValue(forKey: key)
        lock.unlock()
        saveToDisk()
    }

    /// Subtract the stored drift from a raw gyro value. Returns the value
    /// unchanged if the controller hasn't been calibrated yet - better to
    /// have uncorrected motion than no motion.
    func correctedGyro(x: Float, y: Float, z: Float, forKey key: String) -> (Float, Float, Float) {
        guard let cal = calibration(forKey: key) else { return (x, y, z) }
        return (x - cal.gyroDriftX, y - cal.gyroDriftY, z - cal.gyroDriftZ)
    }

    /// Subtract the stored drift from a raw accel value.
    func correctedAccel(x: Float, y: Float, z: Float, forKey key: String) -> (Float, Float, Float) {
        guard let cal = calibration(forKey: key) else { return (x, y, z) }
        return (x - cal.accelDriftX, y - cal.accelDriftY, z - cal.accelDriftZ)
    }
}
