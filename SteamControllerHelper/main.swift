/// SteamControllerHelper: long-running CLI that opens a Valve Steam Controller
/// (wired PID 0x1102, wireless dongle 0x1142) via raw HID, disables its
/// built-in keyboard/mouse emulation ("lizard mode") so we can read the raw
/// 64-byte vendor input reports, parses the report, and emits the controller's state
/// on stdout one line per report.
///
/// Lizard mode is turned off only while the app asks for it ("L1" on
/// stdin, sent while a preset runs) and turned back on with "L0" and on
/// exit. While off, the disable is re-sent every
/// ~800 ms.
///
/// Line format on stdout (newline terminated):
///   R ready                      (device opened)
///   W 1 / W 0                    (dongle reports controller connected /
///                                 disconnected)
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

// The app's end of the pipe can vanish (a crash, a force quit). Writing then
// raised SIGPIPE, which killed the helper before it could give the
// controller its own mouse and keys back; a failed write restores instead.
signal(SIGPIPE, SIG_IGN)

func emit(_ line: String) {
    let bytes = Array((line + "\n").utf8)
    let written = bytes.withUnsafeBytes { write(1, $0.baseAddress, $0.count) }
    if written < 0 { restoreAndExit() }
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
    /// The input report buffer, freed when the device goes away.
    var buffer: UnsafeMutablePointer<UInt8>?
    /// A controller is there: always for a wired one; for a dongle slot,
    /// once it reports connected or sends state. Empty dongle slots get no
    /// lizard commands.
    var active = false
    /// Lizard mode is currently off on this device (we turned it off).
    var lizardOff = false

    init(device: IOHIDDevice, pid: Int32) {
        self.device = device
        self.pid = pid
    }
}

/// Track every opened device so its callback context pointer stays valid for
/// the lifetime of the process.
var managedContexts: [SCDeviceCtx] = []

/// The app wants lizard mode off (a preset is running).
var lizardOffWanted = false
/// The one controller whose state is reported. Every interface and every
/// controller fed the app's single state, so with two controllers held
/// buttons chattered and one's disconnect wiped the other.
var primary: SCDeviceCtx? {
    // Only the controller being read has its lizard mode turned off; a
    // second one keeps its own mouse and keys.
    didSet {
        guard oldValue !== primary else { return }
        if let oldValue { applyLizardMode(oldValue) }
        if let primary { applyLizardMode(primary) }
    }
}

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

/// Size of every vendor-interface report from the Steam Controller (2015),
/// wired or through the wireless dongle.
let scReportSize = 64

/// Message types carried in byte 2 of a report (Valve's ID_CONTROLLER_*
/// values, as SDL's controller_constants.h lists them). Only the ones
/// acted on are listed.
let scMsgControllerState: UInt8 = 0x01
let scMsgWireless: UInt8 = 0x03

/// Parse a Steam Controller input report. Offsets follow Valve's own
/// layout as SDL reads it (SDL_hidapi_steam.c and controller_structs.h,
/// zlib license).
///
/// Report ID: the vendor interface declares no report IDs, so IOKit hands
/// the input report callback the raw 64-byte payload with no leading report
/// ID byte (the callback's `reportID` argument is 0), the same unnumbered
/// payload SDL reads, so its offsets apply unchanged.
///
/// Envelope (all messages are 64 bytes, little endian):
///   0-1     always 0x01 0x00
///   2       message type (0x01 input, 0x03 wireless, 0x04 battery status)
///   3       payload length (not checked)
/// Input (type 0x01) payload:
///   4-7     sequence number (UInt32 LE)
///   8-10    buttons (24-bit bitfield, byte 8 holds bits 0-7)
///   11      leftTrigger (UInt8 0-255)
///   12      rightTrigger (UInt8 0-255)
///   13-15   always 0
///   16-17   leftX (Int16 LE)  (stick OR left trackpad, see buttons bit 19)
///   18-19   leftY (Int16 LE)
///   20-21   rightX (Int16 LE) (always right trackpad)
///   22-23   rightY (Int16 LE)
///   24-27   triggers as Int16 (wired only, unused here)
///   28-29   accelX
///   30-31   accelY
///   32-33   accelZ
///   34-35   gyroX
///   36-37   gyroY
///   38-39   gyroZ
///   40-47   quaternion (not currently exposed)
func parseSCReport(_ p: UnsafePointer<UInt8>, len: Int) -> SCInputSnapshot? {
    guard len == scReportSize, p[0] == 0x01, p[1] == 0x00,
          p[2] == scMsgControllerState else { return nil }

    var s = SCInputSnapshot()
    s.buttons = UInt32(p[8]) | (UInt32(p[9]) << 8) | (UInt32(p[10]) << 16)
    s.leftTrigger = p[11]
    s.rightTrigger = p[12]
    s.leftX  = leInt16(p, 16)
    s.leftY  = leInt16(p, 18)
    s.rightX = leInt16(p, 20)
    s.rightY = leInt16(p, 22)
    s.accelX = leInt16(p, 28)
    s.accelY = leInt16(p, 30)
    s.accelZ = leInt16(p, 32)
    s.gyroX  = leInt16(p, 34)
    s.gyroY  = leInt16(p, 36)
    s.gyroZ  = leInt16(p, 38)
    return s
}

/// Wireless connect / disconnect event (type 0x03) sent by the dongle.
/// Returns true for connected, false for disconnected, nil for anything
/// else. Payload byte 4: 0x01 disconnected, 0x02 connected.
func parseSCWirelessEvent(_ p: UnsafePointer<UInt8>, len: Int) -> Bool? {
    guard len == scReportSize, p[0] == 0x01, p[1] == 0x00,
          p[2] == scMsgWireless else { return nil }
    switch p[4] {
    case 0x01: return false
    case 0x02: return true
    default: return nil
    }
}

// MARK: - Input report callback

let inputCallback: IOHIDReportCallback = { context, _, _, reportType, reportID, report, reportLength in
    guard let context = context else { return }
    let ctx = Unmanaged<SCDeviceCtx>.fromOpaque(context).takeUnretainedValue()
    guard reportType == kIOHIDReportTypeInput else { return }
    // The vendor interface uses unnumbered reports, so reportID is 0 and
    // the buffer starts with the 0x01 0x00 envelope, not a report ID.
    _ = reportID
    if let connected = parseSCWirelessEvent(report, len: reportLength) {
        ctx.active = connected
        applyLizardMode(ctx)
        if connected {
            if primary == nil { primary = ctx }
            if primary === ctx { emit("W 1") }
        } else if primary === ctx {
            emit("W 0")
            primary = nil
        }
        return
    }
    guard let snap = parseSCReport(report, len: reportLength) else { return }
    if !ctx.active { ctx.active = true; applyLizardMode(ctx) }
    if primary == nil { primary = ctx }
    guard primary === ctx else { return }

    ctx.seq &+= 1
    emit("S \(ctx.seq) " +
         String(format: "%08x", snap.buttons) +
         " \(snap.leftX) \(snap.leftY) \(snap.rightX) \(snap.rightY)" +
         " \(snap.leftTrigger) \(snap.rightTrigger)" +
         " \(snap.gyroX) \(snap.gyroY) \(snap.gyroZ)" +
         " \(snap.accelX) \(snap.accelY) \(snap.accelZ)")
}

// MARK: - Lizard mode disable

/// Send one 64-byte feature report on report ID 0, always the full report
/// length: the controller ignores short writes on some firmware.
@discardableResult
func sendSCFeature(_ device: IOHIDDevice, _ cmd: [UInt8], label: String) -> IOReturn {
    var buf = [UInt8](repeating: 0, count: scReportSize)
    for (i, b) in cmd.prefix(scReportSize).enumerated() { buf[i] = b }
    let result = buf.withUnsafeBufferPointer { ptr in
        IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0x00,
                             ptr.baseAddress!, ptr.count)
    }
    if result != kIOReturnSuccess {
        log("[SteamControllerHelper] \(label) failed: IOReturn 0x\(String(format: "%08x", UInt32(bitPattern: result)))")
    }
    return result
}

/// Disable the controller's built-in keyboard/mouse emulation ("lizard
/// mode") on the Steam Controller (2015), with the commands SDL sends for
/// it (SDL_hidapi_steam.c, Valve's constants):
///   0x81 ID_CLEAR_DIGITAL_MAPPINGS: disable esc, enter, cursor keys
///   0x87 ID_SET_SETTINGS_VALUES, len 6:
///        SETTING_LEFT_TRACKPAD_MODE (7)  = TRACKPAD_NONE (7)
///        SETTING_RIGHT_TRACKPAD_MODE (8) = TRACKPAD_NONE (7)
/// Values are UInt16 LE, so each setting is reg, lo, hi.
func sendDisableLizardMode(_ device: IOHIDDevice) {
    sendSCFeature(device, [0x81], label: "clear digital mappings")
    sendSCFeature(device, [0x87, 0x06,
                           0x07, 0x07, 0x00,
                           0x08, 0x07, 0x00],
                  label: "disable trackpad mouse")
}

/// Turn lizard mode back on, with Valve's commands as SDL sends them:
///   0x85 ID_SET_DEFAULT_DIGITAL_MAPPINGS, 0x8E ID_LOAD_DEFAULT_SETTINGS.
func sendEnableLizardMode(_ device: IOHIDDevice) {
    sendSCFeature(device, [0x85], label: "default digital mappings")
    sendSCFeature(device, [0x8E], label: "default settings")
}

/// Lizard mode off while the app wants it and a controller is there, on
/// again otherwise.
func applyLizardMode(_ ctx: SCDeviceCtx) {
    let wantOff = lizardOffWanted && ctx.active && ctx === primary
    if wantOff && !ctx.lizardOff {
        sendDisableLizardMode(ctx.device)
        startHeartbeat(ctx)
        ctx.lizardOff = true
    } else if !wantOff && ctx.lizardOff {
        ctx.heartbeat?.cancel()
        ctx.heartbeat = nil
        sendEnableLizardMode(ctx.device)
        ctx.lizardOff = false
    }
}

/// Give every controller its own mouse and keys back, then exit.
func restoreAndExit() -> Never {
    lizardOffWanted = false
    for ctx in managedContexts { applyLizardMode(ctx) }
    exit(0)
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
    // raw input reports). We match the vendor interface via usage page below.
    guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
        log("[SteamControllerHelper] could not open device")
        return
    }

    let ctx = SCDeviceCtx(device: device, pid: pid)
    ctx.active = pid == scWiredPID
    managedContexts.append(ctx)
    // A wired controller is the one to read from the start: some firmware
    // sends no vendor state report while lizard mode is on, so waiting for
    // one left lizard mode on and the controller unread.
    if pid == scWiredPID, primary == nil { primary = ctx }

    // Allocate a 96-byte buffer; reports are 64 max.
    let bufSize = 96
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
    ctx.buffer = buf
    let ptr = Unmanaged.passUnretained(ctx).toOpaque()
    IOHIDDeviceRegisterInputReportCallback(device, buf, bufSize, inputCallback, ptr)
    IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

    // Lizard mode goes off only while a preset runs (see applyLizardMode).
    applyLizardMode(ctx)
    // A dongle whose controller was already on says so only when asked
    // (Valve's ID_DONGLE_GET_WIRELESS_STATE), with a 0x03 event.
    if pid == scDonglePID { sendSCFeature(device, [0xB4], label: "wireless state") }

    let kind = pid == scWiredPID ? "wired" : "dongle"
    log("[SteamControllerHelper] opened Steam Controller (\(kind), pid=\(String(format: "%04x", pid)))")
    emit("R ready")
}

let matchingCallback: IOHIDDeviceCallback = { _, _, _, device in
    openSteamController(device)
}

let removalCallback: IOHIDDeviceCallback = { _, _, _, device in
    // Only a device this helper opened: the manager also matches other
    // Valve devices (an Index, a second dongle interface), and their
    // removal wiped the state of a Steam Controller still in use.
    guard let index = managedContexts.firstIndex(where: { $0.device == device }) else { return }
    let ctx = managedContexts.remove(at: index)
    ctx.heartbeat?.cancel()
    // Stop the report callback before the context it points at is
    // dropped, then close the device and free its buffer.
    if let buf = ctx.buffer { IOHIDDeviceRegisterInputReportCallback(device, buf, 0, nil, nil) }
    IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    ctx.buffer?.deallocate()
    ctx.buffer = nil
    // Another controller's removal leaves the reported one alone.
    guard primary == nil || primary === ctx else { return }
    // Gone: nothing is sent to it when it stops being the primary.
    ctx.active = false
    ctx.lizardOff = false
    primary = nil
    log("[SteamControllerHelper] device disconnected")
    // Tell the app, which otherwise kept the last state (buttons held at
    // the moment of unplugging stayed held) and a slot for a gone pad.
    emit("D")
}

// MARK: - Manager setup

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
// Match the Steam Controller's vendor HID collection (usage page 0xFF00).
// The keyboard / mouse interfaces also belong to the same VID/PID but use
// the standard GenericDesktop usage page; we don't want those because they
// don't carry the 64-byte input report we need.
// Only the two 2015 product IDs: matching every Valve vendor-page device
// took in 2026 controllers, Pucks and Bluetooth devices with a keyboard.
let matching: [[CFString: Any]] = pidSet.sorted().map { pid in
    [kIOHIDVendorIDKey as CFString: valveVID,
     kIOHIDProductIDKey as CFString: pid,
     kIOHIDDeviceUsagePageKey as CFString: 0xFF00]
}
IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
IOHIDManagerRegisterDeviceMatchingCallback(manager, matchingCallback, nil)
IOHIDManagerRegisterDeviceRemovalCallback(manager, removalCallback, nil)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
// No IOHIDManagerOpen: it opened every matched device and failed on the
// first it could not open (which could also raise the Input Monitoring
// prompt), and the helper exited. openSteamController opens each
// interface it wants itself.

// MARK: - Lifecycle

// Exit cleanly when the parent process closes our stdin (standard pattern
// for subprocesses on macOS that aren't using a signalfd-style watch).
// Commands from the app on stdin: "L1" lizard mode off (a preset is
// running), "L0" back on. The last one in a read wins.
let stdinSource = DispatchSource.makeReadSource(fileDescriptor: 0, queue: .main)
stdinSource.setEventHandler {
    var buf = [UInt8](repeating: 0, count: 64)
    let n = read(0, &buf, buf.count)
    if n <= 0 { restoreAndExit() }
    let text = String(decoding: buf.prefix(n), as: UTF8.self)
    let l1 = text.range(of: "L1", options: .backwards)?.lowerBound
    let l0 = text.range(of: "L0", options: .backwards)?.lowerBound
    let wanted: Bool?
    switch (l1, l0) {
    case let (a?, b?): wanted = a > b
    case (_?, nil): wanted = true
    case (nil, _?): wanted = false
    default: wanted = nil
    }
    if let wanted, wanted != lizardOffWanted {
        lizardOffWanted = wanted
        for ctx in managedContexts { applyLizardMode(ctx) }
    }
}
stdinSource.resume()

// On the main queue, so the restore runs between reports, not inside one.
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termSource.setEventHandler { restoreAndExit() }
termSource.resume()
let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
intSource.setEventHandler { restoreAndExit() }
intSource.resume()

CFRunLoopRun()
