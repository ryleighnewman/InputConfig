import Foundation
import IOKit
import IOKit.hid

/// A HID gamepad that JoystickConfig is reading directly via IOKit
/// (i.e. *not* through Apple's GameController framework). The Steam
/// Controller has its own dedicated service; this type covers
/// everything else: 8BitDo in XInput mode, Xbox 360 wired pads,
/// PowerA/Hori/MadCatz Xbox-compatibles, Logitech F310/F710, etc.
///
/// The instance owns the underlying `IOHIDDevice` for the duration of
/// its lifetime. Lock-protected access to `state` so the input report
/// callback (which fires on a background queue) and the mapping
/// engine (which reads from the main thread) don't race.
final class RawHIDGamepad: Identifiable, @unchecked Sendable {

    let id: UInt64                  // IOKit location ID; stable per physical attachment
    let vendorID: Int32
    let productID: Int32
    let productName: String
    let manufacturer: String?
    let transport: String           // "USB", "Bluetooth", etc.
    let profile: ControllerProfile?

    /// Underlying HID device. Held strongly so it isn't released while
    /// the input report callback is registered.
    let device: IOHIDDevice

    private let lock = NSLock()
    private var _state = ControllerState()

    init(device: IOHIDDevice,
         id: UInt64,
         vendorID: Int32,
         productID: Int32,
         productName: String,
         manufacturer: String?,
         transport: String,
         profile: ControllerProfile?) {
        self.device = device
        self.id = id
        self.vendorID = vendorID
        self.productID = productID
        self.productName = productName
        self.manufacturer = manufacturer
        self.transport = transport
        self.profile = profile
    }

    /// Atomic snapshot of the latest decoded controller state. Safe to
    /// call from any thread.
    var state: ControllerState {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    /// Replace the published state. Called from the HID report
    /// callback after `HIDReportDecoder` finishes its work.
    func updateState(_ newValue: ControllerState) {
        lock.lock()
        _state = newValue
        lock.unlock()
    }

    /// Stable identifier the preset store can persist bindings against.
    /// Combines vendor + product so the same physical model on a
    /// different USB port still picks up its existing bindings.
    var persistentIdentifier: String {
        let vid = String(format: "%04X", UInt16(truncatingIfNeeded: vendorID))
        let pid = String(format: "%04X", UInt16(truncatingIfNeeded: productID))
        return "hid:\(vid):\(pid)"
    }

    /// Display label shown in the controller chip popover and binding
    /// editor. Prefers the profile's display name, falls back to the
    /// HID-reported product string.
    var displayName: String {
        return profile?.displayName ?? productName
    }
}
