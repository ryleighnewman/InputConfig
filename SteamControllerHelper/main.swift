/// SteamControllerHelper: long-running CLI that opens a Valve Steam Controller
/// (wired PID 0x1102, wireless dongle 0x1142) via raw HID, disables its
/// built-in keyboard/mouse emulation ("lizard mode") so we can read the raw
/// 0x42 input reports, parses the report, and emits the controller's state
/// on stdout one line per report.
///
/// Disabling lizard mode is sticky-by-default: if we stop sending the
/// disable feature reports, the controller eventually re-enables it on a
/// timeout. We re-send every ~800 ms while running.
///
/// Line format on stdout (newline terminated):
///   S <seq> <buttonsHex> <lx> <ly> <rx> <ry> <lt> <rt> \
///     <gx> <gy> <gz> <ax> <ay> <az>
///
/// All axes are signed 16-bit. Triggers are 0-255.
///
/// Exits when stdin closes (parent process died) or SIGTERM / SIGINT.

import Foundation
import IOKit
import IOKit.hid

// MARK: - Constants

let valveVID: Int32 = 0x28DE
let scWiredPID: Int32  = 0x1102   // Steam Controller (USB cable, wired mode)
let scDonglePID: Int32 = 0x1142   // Steam Controller wireless USB dongle

let pidSet: Set<Int32> = [scWiredPID, scDonglePID]

// MARK: - Helpers

func emit(_ line: String) {
    if let data = (line + "\n").data(using: .utf8) {
        FileHandle.standardOutput.write(data)
    }
}

func log(_ msg: String) {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8) ?? Data())
}

// MARK: - Device context

final class SCDeviceCtx {
    let device: IOHIDDevice
    let pid: Int32
    var seq: UInt64 = 0
    /// Timer that periodically re-asserts the lizard-mode disable.
    var heartbeat: DispatchSourceTimer?

    init(device: IOHIDDevice, pid: Int32) {
        self.device = device
        self.pid = pid
    }
}

/// Track every opened device so its callback context pointer stays valid for
/// the lifetime of the process.
var managedContexts: [SCDeviceCtx] = []

// MARK: - Report parsing

/// Parsed snapshot of one input report. All numeric fields are raw device
/// units (Int16 axes; UInt8 triggers; bitfield buttons).
struct SCInputSnapshot {
    var buttons: UInt32 = 0
    var leftX: Int16 = 0
    var leftY: Int16 = 0
    var rightX: Int16 = 0
    var rightY: Int16 = 0
    var leftTrigger: UInt8 = 0
    var rightTrigger: UInt8 = 0
    var gyroX: Int16 = 0
    var gyroY: Int16 = 0
    var gyroZ: Int16 = 0
    var accelX: Int16 = 0
    var accelY: Int16 = 0
    var accelZ: Int16 = 0
}

/// Pull a little-endian Int16 out of the buffer at the given offset.
@inline(__always)
func leInt16(_ p: UnsafePointer<UInt8>, _ off: Int) -> Int16 {
    let lo = UInt16(p[off])
    let hi = UInt16(p[off + 1])
    return Int16(bitPattern: (hi << 8) | lo)
}

@inline(__always)
func leUInt32(_ p: UnsafePointer<UInt8>, _ off: Int) -> UInt32 {
    return UInt32(p[off]) |
        (UInt32(p[off + 1]) << 8) |
        (UInt32(p[off + 2]) << 16) |
        (UInt32(p[off + 3]) << 24)
}

/// Parse a Steam Controller input report. The buffer here is the IOHID
/// callback's `report` argument, which does NOT include the leading report
/// ID byte. The report ID is the separate `reportID` parameter.
///
/// Layout (offsets in the data buffer):
///   0       reportType  (0x01 when valid)
///   1       unused
///   2-3     sequence (UInt16 LE), already mirrored to ctx.seq externally
///   4-7     buttons (UInt32 LE, bitfield)
///   8       leftTrigger (UInt8 0-255)
///   9       rightTrigger (UInt8 0-255)
///   10-12   padding
///   13-14   leftX (Int16 LE)  (stick OR left trackpad depending on bit 24 of buttons)
///   15-16   leftY (Int16 LE)
///   17-18   rightX (Int16 LE) (always right trackpad)
///   19-20   rightY (Int16 LE)
///   21-24   unused / accel timestamp
///   25-26   accelX (Int16 LE)
///   27-28   accelY
///   29-30   accelZ
///   31-32   gyroX
///   33-34   gyroY
///   35-36   gyroZ
///   37-44   quaternion (not currently exposed)
func parseSCReport(_ p: UnsafePointer<UInt8>, len: Int) -> SCInputSnapshot? {
    // 44 bytes is the minimum we need to read everything up to gyro.
    guard len >= 44 else { return nil }
    // Report type 0x01 indicates valid input; anything else (e.g. 0x03 for
    // CONFIG_SAVE acknowledgements) we ignore.
    guard p[0] == 0x01 else { return nil }

    var s = SCInputSnapshot()
    s.buttons = leUInt32(p, 4)
    s.leftTrigger = p[8]
    s.rightTrigger = p[9]
    s.leftX  = leInt16(p, 13)
    s.leftY  = leInt16(p, 15)
    s.rightX = leInt16(p, 17)
    s.rightY = leInt16(p, 19)
    s.accelX = leInt16(p, 25)
    s.accelY = leInt16(p, 27)
    s.accelZ = leInt16(p, 29)
    s.gyroX  = leInt16(p, 31)
    s.gyroY  = leInt16(p, 33)
    s.gyroZ  = leInt16(p, 35)
    return s
}

// MARK: - Input report callback

let inputCallback: IOHIDReportCallback = { context, _, _, reportType, reportID, report, reportLength in
    guard let context = context else { return }
    let ctx = Unmanaged<SCDeviceCtx>.fromOpaque(context).takeUnretainedValue()
    guard reportType == kIOHIDReportTypeInput else { return }
    // Steam Controller emits report ID 0x01 for input frames over wired and
    // 0x01 over dongle as well. The actual report type byte at offset 0 of
    // the data buffer is 0x01 for valid input frames.
    _ = reportID
    guard let snap = parseSCReport(report, len: reportLength) else { return }

    ctx.seq &+= 1
    emit("S \(ctx.seq) " +
         String(format: "%08x", snap.buttons) +
         " \(snap.leftX) \(snap.leftY) \(snap.rightX) \(snap.rightY)" +
         " \(snap.leftTrigger) \(snap.rightTrigger)" +
         " \(snap.gyroX) \(snap.gyroY) \(snap.gyroZ)" +
         " \(snap.accelX) \(snap.accelY) \(snap.accelZ)")
}

// MARK: - Lizard mode disable

/// Send a feature report to disable the controller's built-in keyboard/mouse
/// emulation. Without this, the device defaults to acting like a regular
/// keyboard+mouse and never sends the 0x42 raw input reports we want.
func sendDisableLizardMode(_ device: IOHIDDevice) {
    // Two SET_FEATURE reports per Linux kernel hid-steam.c:
    //   0x81: disable keyboard emulation
    //   0x87 0x03 0x08 0x07: also disable mouse emulation
    // The report ID is 0x00 on the wire (vendor-specific), with the actual
    // command byte at index 0 of the data payload.

    var disableKeyboard: [UInt8] = [0x81, 0x00, 0x00, 0x00]
    _ = disableKeyboard.withUnsafeBufferPointer { buf in
        IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0x00,
                             buf.baseAddress!, buf.count)
    }

    var disableMouse: [UInt8] = [0x87, 0x03, 0x08, 0x07]
    _ = disableMouse.withUnsafeBufferPointer { buf in
        IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0x00,
                             buf.baseAddress!, buf.count)
    }
}

func startHeartbeat(_ ctx: SCDeviceCtx) {
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 0.8, repeating: 0.8)
    timer.setEventHandler { [weak ctx] in
        guard let ctx = ctx else { return }
        sendDisableLizardMode(ctx.device)
    }
    timer.resume()
    ctx.heartbeat = timer
}

// MARK: - Device matching + open

func openSteamController(_ device: IOHIDDevice) {
    guard let vid = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int32),
          vid == valveVID,
          let pid = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int32),
          pidSet.contains(pid) else {
        return
    }

    // Open WITHOUT seize. The Steam Controller exposes multiple HID
    // interfaces (keyboard, mouse, and the vendor interface that carries
    // report 0x42). We match the vendor interface via usage page below.
    guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
        log("[SteamControllerHelper] could not open device")
        return
    }

    let ctx = SCDeviceCtx(device: device, pid: pid)
    managedContexts.append(ctx)

    // Allocate a 96-byte buffer; reports are 64 max.
    let bufSize = 96
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
    let ptr = Unmanaged.passUnretained(ctx).toOpaque()
    IOHIDDeviceRegisterInputReportCallback(device, buf, bufSize, inputCallback, ptr)
    IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

    // Immediately and periodically disable lizard mode.
    sendDisableLizardMode(device)
    startHeartbeat(ctx)

    let kind = pid == scWiredPID ? "wired" : "dongle"
    log("[SteamControllerHelper] opened Steam Controller (\(kind), pid=\(String(format: "%04x", pid)))")
    emit("R ready")
}

let matchingCallback: IOHIDDeviceCallback = { _, _, _, device in
    openSteamController(device)
}

let removalCallback: IOHIDDeviceCallback = { _, _, _, device in
    managedContexts.removeAll {
        if $0.device == device {
            $0.heartbeat?.cancel()
            return true
        }
        return false
    }
    log("[SteamControllerHelper] device disconnected")
}

// MARK: - Manager setup

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
// Match the Steam Controller's vendor HID collection (usage page 0xFF00).
// The keyboard / mouse interfaces also belong to the same VID/PID but use
// the standard GenericDesktop usage page; we don't want those because they
// don't carry the 54-byte input report we need.
let matching: [CFString: Any] = [
    kIOHIDVendorIDKey as CFString: valveVID,
    kIOHIDDeviceUsagePageKey as CFString: 0xFF00,
]
IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
IOHIDManagerRegisterDeviceMatchingCallback(manager, matchingCallback, nil)
IOHIDManagerRegisterDeviceRemovalCallback(manager, removalCallback, nil)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
    log("[SteamControllerHelper] IOHIDManagerOpen failed")
    exit(2)
}

// MARK: - Lifecycle

// Exit cleanly when the parent process closes our stdin (standard pattern
// for subprocesses on macOS that aren't using a signalfd-style watch).
let stdinSource = DispatchSource.makeReadSource(fileDescriptor: 0, queue: .global())
stdinSource.setEventHandler {
    var buf = [UInt8](repeating: 0, count: 64)
    let n = read(0, &buf, buf.count)
    if n <= 0 { exit(0) }
}
stdinSource.resume()

signal(SIGTERM) { _ in exit(0) }
signal(SIGINT)  { _ in exit(0) }

CFRunLoopRun()
