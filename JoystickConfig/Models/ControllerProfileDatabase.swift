import Foundation

/// Hand-curated list of known HID gamepad profiles. Indexed by (vendor,
/// product) pair so `RawHIDGamepadService` can identify a controller
/// the moment it shows up on the bus and start parsing reports with
/// the correct byte offsets.
///
/// Adding a new controller:
/// 1. Plug it in, note its VID/PID from `system_profiler SPUSBDataType`.
/// 2. If it speaks standard XInput (most "PC Game Controller" pads),
///    add an entry with `.xinput` and you're done.
/// 3. If it has a vendor-specific protocol, capture a few reports with
///    `hidutil monitor` and either add a new `ReportLayout` case or
///    extend the existing decoder.
enum ControllerProfileDatabase {

    /// All hand-coded profiles in priority order. First match wins.
    static let all: [ControllerProfile] = [

        // MARK: 8BitDo

        // The Ultimate 2C *wired* model defaults to XInput and has no
        // physical mode switch (only button-combo modes), so users who
        // can't switch to Apple/Switch mode end up stuck. This profile
        // lets the controller work directly out of the box.
        ControllerProfile(
            identifier: "8bitdo-ultimate-2c-xinput",
            displayName: "8BitDo Ultimate 2C (XInput)",
            vendorID: 0x2DC8,
            productMatches: [.range(0x3100...0x31FF)],
            layout: .xinput,
            physicalButtonNames: xinputButtonNames
        ),

        // Other 8BitDo models in XInput mode share the same wire layout.
        ControllerProfile(
            identifier: "8bitdo-generic-xinput",
            displayName: "8BitDo Controller (XInput)",
            vendorID: 0x2DC8,
            productMatches: [.range(0x3000...0x30FF)],
            layout: .xinput,
            physicalButtonNames: xinputButtonNames
        ),

        // MARK: Microsoft

        // Generic Xbox 360 wired controller and most third-party
        // 360-compatible pads (PowerA, Hori, Mad Catz, etc.) follow
        // the XInput layout exactly.
        ControllerProfile(
            identifier: "xbox-360-wired",
            displayName: "Xbox 360 Controller",
            vendorID: 0x045E,
            productMatches: [.exact(0x028E), .exact(0x028F), .exact(0x02A1)],
            layout: .xinput,
            physicalButtonNames: xinputButtonNames
        ),

        // MARK: Logitech

        ControllerProfile(
            identifier: "logitech-f310",
            displayName: "Logitech F310",
            vendorID: 0x046D,
            productMatches: [.exact(0xC216), .exact(0xC218), .exact(0xC219)],
            layout: .xinput,
            physicalButtonNames: xinputButtonNames
        ),

        ControllerProfile(
            identifier: "logitech-f710",
            displayName: "Logitech F710",
            vendorID: 0x046D,
            productMatches: [.exact(0xC21F)],
            layout: .xinput,
            physicalButtonNames: xinputButtonNames
        ),

        // MARK: PowerA

        ControllerProfile(
            identifier: "powera-xbox-wired",
            displayName: "PowerA Wired Controller",
            vendorID: 0x24C6,
            productMatches: [.range(0x5300...0x55FF)],
            layout: .xinput,
            physicalButtonNames: xinputButtonNames
        ),

        // MARK: Mad Catz

        ControllerProfile(
            identifier: "madcatz-xbox-wired",
            displayName: "Mad Catz Controller",
            vendorID: 0x0738,
            productMatches: [.range(0x4700...0x47FF)],
            layout: .xinput,
            physicalButtonNames: xinputButtonNames
        ),

        // MARK: Sony

        // DualShock 3 over USB. Bluetooth pairing requires extra tooling
        // outside the app's scope, but the wired path works.
        ControllerProfile(
            identifier: "sony-dualshock-3",
            displayName: "DualShock 3",
            vendorID: 0x054C,
            productMatches: [.exact(0x0268)],
            layout: .dualShock3,
            physicalButtonNames: dualShock3ButtonNames
        ),
    ]

    /// Look up the best profile for a (vendor, product) pair. Returns
    /// nil when no hand-coded entry matches; the caller should fall
    /// back to runtime descriptor parsing.
    static func profile(forVendor vid: Int32, product pid: Int32) -> ControllerProfile? {
        return all.first { $0.matches(vendorID: vid, productID: pid) }
    }

    // MARK: - Button name catalogues

    /// Button labels by logical index. Indices 0-12 are the standard
    /// gamepad slots (A/B/X/Y, shoulders, triggers as digital, menu
    /// buttons, stick clicks); D-pad lives in state.hats[0]. Indices
    /// 13+ are reserved for extra buttons that controllers may expose
    /// (paddles on a pro controller, extra macro buttons on a fight
    /// stick, etc.).
    static let xinputButtonNames: [String] = [
        "A", "B", "X", "Y",
        "LB", "RB",
        "LT", "RT",
        "Back", "Start", "Guide",
        "L3", "R3",
    ]

    static let dualShock3ButtonNames: [String] = [
        "Cross", "Circle", "Square", "Triangle",
        "L1", "R1", "L2", "R2",
        "Select", "Start", "PS",
        "L3", "R3",
    ]
}
