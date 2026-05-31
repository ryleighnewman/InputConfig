import Foundation
import GameController

/// Controls DualSense / DualShock 4 light bars by invoking a helper tool
/// that runs as a separate process, kills the gamecontrolleragentd to release
/// the HID device, and sends the output report matching HIDAPI/SDL2 format.
final class HIDLightController: @unchecked Sendable {
    nonisolated(unsafe) static let shared = HIDLightController()

    private let queue = DispatchQueue(label: "com.joystickconfig.hidlight")
    /// Last (r, g, b, brightness) we actually sent to the helper. Used
    /// to skip redundant spawns when the requested color matches what
    /// the controller already has - the connect-time retry pattern in
    /// GameControllerService used to spawn the helper 3 times per
    /// controller per plug-in, even when nothing changed.
    private var lastWritten: (r: UInt8, g: UInt8, b: UInt8, br: UInt8)?
    private let lastWrittenLock = NSLock()

    private init() {}

    /// Set light color with brightness. Brightness: 0=off, 1=dim, 2=bright.
    ///
    /// Pass `force: true` to bypass the dedupe and re-send even if the
    /// color is unchanged. Used when macOS has reset the light behind our
    /// back (e.g. gamecontrolleragentd repaints the player color when the
    /// app loses focus), so we need to re-assert the same color.
    func setLightColor(red: UInt8, green: UInt8, blue: UInt8, brightness: UInt8 = 2, force: Bool = false) {
        // Skip the spawn entirely when the requested state matches the
        // last successful write. Saves three subprocess spawns per
        // controller-connect retry burst.
        if !force {
            lastWrittenLock.lock()
            let same = lastWritten.map {
                $0.r == red && $0.g == green && $0.b == blue && $0.br == brightness
            } ?? false
            lastWrittenLock.unlock()
            guard !same else { return }
        } else {
            // Clear the cache so the dedupe doesn't suppress this write.
            lastWrittenLock.lock()
            lastWritten = nil
            lastWrittenLock.unlock()
        }

        queue.async { [weak self] in
            self?.runHelper(red: red, green: green, blue: blue, brightness: brightness)
        }
    }

    private func runHelper(red: UInt8, green: UInt8, blue: UInt8, brightness: UInt8) {
        guard let helperURL = helperPath() else {
            #if DEBUG
            print("[HIDLight] LightHelper not found in bundle")
            #endif
            return
        }

        let task = Process()
        task.executableURL = helperURL
        task.arguments = [String(red), String(green), String(blue), String(brightness)]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        // Async exit notification so we don't block this serial queue
        // for the helper's ~1.2 s lifetime. Previously `waitUntilExit`
        // would head-of-line block every subsequent light change,
        // causing visible color-cycle stutter.
        task.terminationHandler = { [weak self] proc in
            guard let self = self else { return }
            if proc.terminationStatus == 0 {
                self.lastWrittenLock.lock()
                self.lastWritten = (red, green, blue, brightness)
                self.lastWrittenLock.unlock()
            }
        }

        do {
            try task.run()
            // Don't `waitUntilExit()`. The serial queue stays free to
            // process the next color change; the terminationHandler
            // above records success so the dedupe check can apply.
        } catch {
            #if DEBUG
            print("[HIDLight] Helper launch failed: \(error)")
            #endif
        }
    }

    private func helperPath() -> URL? {
        // App bundle MacOS directory
        if let bundlePath = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("LightHelper") {
            if FileManager.default.isExecutableFile(atPath: bundlePath.path) {
                return bundlePath
            }
        }
        // Resources
        if let resourcePath = Bundle.main.url(forResource: "LightHelper", withExtension: nil) {
            return resourcePath
        }
        // Development fallback
        let devPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("LightHelper/LightHelper")
        if FileManager.default.isExecutableFile(atPath: devPath.path) {
            return devPath
        }
        return nil
    }
}
