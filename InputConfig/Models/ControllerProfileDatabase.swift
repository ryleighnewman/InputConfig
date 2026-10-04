import Foundation

/// Hand-curated list of known HID gamepad profiles. Indexed by (vendor,
/// product) pair so `RawHIDGamepadService` can identify a controller
/// the moment it shows up on the bus and start parsing reports with
/// the correct byte offsets.
///
/// Adding a new controller:
/// 1. Plug it in, note its VID/PID from `system_profiler SPUSBDataType`.
/// 2. Most HID gamepads need no entry: the descriptor parser reads them.
///    Add one only when the reports do not match the descriptor. Pads
///    that speak XInput over the vendor-class XUSB interface are not HID
///    and never reach this list.
/// 3. If it has a vendor-specific protocol, capture a few reports with
///    `hidutil monitor` and either add a new `ReportLayout` case or
///    extend the existing decoder.
enum ControllerProfileDatabase {

    /// All hand-coded profiles in priority order. First match wins.
    static let all: [ControllerProfile] = [

        // MARK: 8BitDo

        // The Ultimate 2C wired (0x310A) and the Ultimate wired in XInput
        // mode (0x3106) send the XInput report layout through a HID
        // interface. Only these two exact IDs: the rest of the 0x30xx and
        // 0x31xx blocks (0x3011-0x3017, 0x301B, 0x301D, 0x3100-0x3105, and
        // others) are ordinary HID gamepads and wireless dongles whose
        // reports the descriptor parser reads correctly and the XInput
        // decoder would drop. USB only: over Bluetooth 8BitDo reuses
        // nearby IDs for identities with short DInput-style reports.
        ControllerProfile(
            identifier: "8bitdo-ultimate-2c-xinput",
            displayName: "8BitDo Ultimate (XInput)",
            vendorID: 0x2DC8,
            productMatches: [.exact(0x3106), .exact(0x310A)],
            layout: .xinput,
            physicalButtonNames: xinputButtonNames,
            requiredTransport: "USB"
        ),

        // MARK: Microsoft

        // NOT REACHABLE ON STOCK macOS. Wired Xbox 360 pads (and nearly
        // every third-party XInput pad: PowerA, Hori, Mad Catz, Logitech F
        // series in X mode) use the vendor-class XUSB interface, not HID,
        // so IOHIDManager never reports them and this profile never
        // matches a real device. `HIDDeviceRegistry` lists such pads in the
        // Devices menu with how to switch them to a readable mode. Kept
        // only as the test bench's XInput decoder fixture. The Logitech
        // C21F, PowerA 24C6:53xx-55xx (24C6:5500-5510 are Hori pads), and
        // Mad Catz 0738:47xx entries that used to follow were the same
        // XUSB class and were removed.
        ControllerProfile(
            identifier: "xbox-360-wired",
            displayName: "Xbox 360 Controller",
            vendorID: 0x045E,
            productMatches: [.exact(0x028E), .exact(0x028F), .exact(0x02A1)],
            layout: .xinput,
            physicalButtonNames: xinputButtonNames
        ),

        // MARK: GameCube adapter

        // Nintendo GameCube controller adapter (WUP-028, also sold for
        // Wii U and Switch). `RawHIDGamepadService` sends its 0x13 start
        // command. Input report 0x21 carries four 9-byte port blocks:
        // status, buttons (A B X Y Left Right Down Up), buttons (Start Z R
        // L), stick X/Y, C-stick X/Y, analog L, analog R. This entry reads
        // port 1; `RawHIDGamepadService` adds ports 2 to 4 as their own
        // controllers with `gameCubeAdapterPort(_:)` when a pad is plugged
        // into them.
        gameCubeAdapterPort(1),

        // MARK: Nintendo

        // Switch 2 Pro Controller over a USB cable. macOS does not support
        // it, and it stays silent until Switch2USBEnabler sends its start-up
        // commands. Nintendo controllers that GameController lists are left
        // to it; the rest (this one, the GameCube adapter, Nintendo Switch
        // Online pads) are read here.
        ControllerProfile(
            identifier: "nintendo-switch2-pro",
            // Labeled Experimental: support was built without the hardware
            // to test on, the decision recorded for 1.6.
            displayName: "Switch 2 Pro Controller (Experimental)",
            vendorID: 0x057E,
            productMatches: [.exact(0x2069)],
            layout: .switch2Pro,
            physicalButtonNames: switch2ProButtonNames,
            requiredTransport: "USB"
        ),

        // Nintendo Switch Online GameCube controller for Switch 2, over a
        // USB cable. Silent until Switch2USBEnabler starts it, like the
        // Switch 2 Pro Controller, and read with the same report.
        ControllerProfile(
            identifier: "nintendo-switch2-gamecube",
            displayName: "GameCube Controller (Switch 2, Experimental)",
            vendorID: 0x057E,
            productMatches: [.exact(0x2073)],
            layout: .switch2GameCube,
            physicalButtonNames: switch2GameCubeButtonNames,
            requiredTransport: "USB"
        ),

        // MARK: Valve

        // The 2026 Steam Controller: 0x1302 on a USB cable, 0x1303 over
        // Bluetooth, and its Steam Controller Puck (0x1304, and 0x1305 for
        // the other dongle) with up to four controllers. Read directly; the
        // 2015 model has its own helper and is not matched here.
        ControllerProfile(
            identifier: "valve-steam-controller-2026",
            displayName: "Steam Controller (2026, Experimental)",
            vendorID: 0x28DE,
            productMatches: [.exact(0x1302), .exact(0x1303), .exact(0x1304), .exact(0x1305)],
            layout: .steamController2026,
            physicalButtonNames: steamController2026ButtonNames
        ),

        // MARK: Elgato Stream Deck

        // Opened only when connected by hand from the Devices menu. Key
        // layouts per model follow the python-elgato-streamdeck library.
    ] + streamDeckProfiles + [

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

    static let streamDeckVendorID: Int32 = 0x0FD9

    /// (product, name, keys, first key byte, mirrored row length)
    private static let streamDeckModels: [(Int32, String, Int, Int, Int)] = [
        (0x0060, "Stream Deck", 15, 1, 5),
        (0x0063, "Stream Deck Mini", 6, 1, 0),
        (0x0090, "Stream Deck Mini", 6, 1, 0),
        (0x00B3, "Stream Deck Mini", 6, 1, 0),
        (0x006D, "Stream Deck", 15, 4, 0),
        (0x0080, "Stream Deck MK.2", 15, 4, 0),
        (0x00A5, "Stream Deck MK.2", 15, 4, 0),
        (0x006C, "Stream Deck XL", 32, 4, 0),
        (0x008F, "Stream Deck XL", 32, 4, 0),
        (0x0084, "Stream Deck +", 8, 4, 0),
        (0x009A, "Stream Deck Neo", 10, 4, 0),
        (0x00B8, "Stream Deck Module 6", 6, 1, 0),
        (0x00B9, "Stream Deck Module 15", 15, 4, 0),
        (0x00BA, "Stream Deck Module 32", 32, 4, 0),
        (0x0086, "Stream Deck Pedal", 3, 4, 0),
    ]

    static let streamDeckProfiles: [ControllerProfile] = streamDeckModels.map { model in
        let (pid, name, keys, offset, mirror) = model
        let first = ControllerProfile.StreamDeckFormat.firstSlot
        // The Neo's two touch points under its screen follow its 8 keys.
        let keyNames = pid == 0x0086
            ? ["Left pedal", "Middle pedal", "Right pedal"]
            : (pid == 0x009A ? (1...8).map { "Key \($0)" } + ["Left touch", "Right touch"]
                             : (1...keys).map { "Key \($0)" })
        return ControllerProfile(
            identifier: String(format: "elgato-stream-deck-%04x", pid),
            displayName: name + " (Experimental)",
            vendorID: streamDeckVendorID,
            productMatches: [.exact(pid)],
            layout: .streamDeck(.init(keys: keys, keyOffset: offset, mirrorColumns: mirror)),
            physicalButtonNames: (0..<first).map { "Button \($0)" } + keyNames
        )
    }

    /// True for a Stream Deck model this app can read.
    static func isStreamDeck(vendorID: Int32, productID: Int32) -> Bool {
        vendorID == streamDeckVendorID && streamDeckProfiles.contains { $0.matches(vendorID: vendorID, productID: productID) }
    }

    /// USB product ID of the GameCube controller adapter (WUP-028).
    static let gameCubeAdapterProductID: Int32 = 0x0337

    /// The adapter's layout for one port (1 to 4). Each port is a 9-byte
    /// block of the 36-byte payload, so port N is port 1 shifted by
    /// 9 * (N - 1) bytes. The indices match the Switch 2 GameCube
    /// controller's, so a preset moves between the two: A, B, X, Y at 0 to
    /// 3, L click at 4 and 6, Z at 5, R click at 7, Start at 9, and the
    /// D-pad as hat 0. Index 8 is held by an always-zero bit (23) only to
    /// keep Start at 9, and is left out of what the pad offers.
    static func gameCubeAdapterPort(_ port: Int) -> ControllerProfile {
        let byteShift = 9 * (max(1, min(4, port)) - 1)
        let bitShift = byteShift * 8
        var layout = ControllerProfile.GenericLayout(
                buttonBitOffsets: [8, 9, 10, 11,      // A B X Y
                                   19, 17,            // L (digital), Z
                                   19, 18,            // L, R full-press clicks
                                   23, 16]            // (none), Start
                    .map { $0 + bitShift },
                axisByteOffsets: [3, 4, 5, 6].map { $0 + byteShift },
                axisByteWidths: [1, 1, 1, 1],
                axisIsSignedFlags: [false, false, false, false],
                axisUsages: [0x30, 0x31, 0x33, 0x34],
                hatByteOffset: nil,
                triggerByteOffsets: [7, 8].map { $0 + byteShift },
                reportSize: 36,
                hasReportID: true,
                reportID: 0x21)
        // The adapter reports stick and C-stick Y with up as the high value,
        // the Nintendo way; everything else here reads up as negative (the
        // Switch 2 GameCube decoder already flips it). Without this the
        // sticks read upside down on all four ports.
        var plan = HIDExtendedLayout(legacy: layout)
        for r in plan.reports.indices {
            for a in plan.reports[r].axes.indices where [1, 3].contains(plan.reports[r].axes[a].index) {
                plan.reports[r].axes[a].inverted = true
            }
            // A GameCube stick reaches about 128 plus or minus 88, not the
            // whole byte, and a trigger rests near 30 to 40: read over the
            // whole byte, full tilt came to about 0.75 and a released
            // trigger to 0.15. SDL_hidapi_gamecube.c starts from these
            // ranges (40 to 216 for the sticks, 40 up for the triggers).
            for a in plan.reports[r].axes.indices {
                plan.reports[r].axes[a].logicalMin = 40
                plan.reports[r].axes[a].logicalMax = 216
            }
            plan.reports[r].buttons.removeAll { $0.index == 8 }
            let dpad: [(Int, HIDExtendedLayout.DpadButton.Direction)] = [(15, .up), (14, .down), (12, .left), (13, .right)]
            plan.reports[r].dpadButtons = dpad.map {
                HIDExtendedLayout.DpadButton(bitOffset: $0.0 + bitShift, direction: $0.1, hatIndex: 0)
            }
        }
        layout.extended = plan
        return ControllerProfile(
            identifier: "nintendo-gamecube-adapter-port\(port)",
            displayName: "GameCube Controller Adapter (port \(port))",
            vendorID: 0x057E,
            productMatches: [.exact(gameCubeAdapterProductID)],
            layout: .generic(layout),
            physicalButtonNames: gameCubeButtonNames,
            requiredTransport: "USB"
        )
    }

    /// Whether a GameCube adapter port block reports a controller: the
    /// status byte's type bits are 0x10 for a wired pad, 0x20 for a
    /// WaveBird. `report` includes the 0x21 report ID byte.
    static func gameCubeAdapterPortOccupied(_ report: Data, port: Int) -> Bool {
        let index = report.startIndex + 1 + 9 * (port - 1)
        guard report.count >= 37, report.first == 0x21, index < report.endIndex else { return false }
        return report[index] & 0x30 != 0
    }

    /// Look up the best profile for a (vendor, product) pair, honoring
    /// each profile's transport constraint. Returns nil when no
    /// hand-coded entry matches; the caller should fall back to runtime
    /// descriptor parsing.
    static func profile(forVendor vid: Int32, product pid: Int32, transport: String) -> ControllerProfile? {
        return all.first { profile in
            guard profile.matches(vendorID: vid, productID: pid) else { return false }
            guard let required = profile.requiredTransport else { return true }
            return transport.localizedCaseInsensitiveContains(required)
        }
    }

    /// Transport-agnostic lookup, used by diagnostics and tests.
    static func profile(forVendor vid: Int32, product pid: Int32) -> ControllerProfile? {
        return all.first { $0.matches(vendorID: vid, productID: pid) }
    }

    // MARK: - Button name catalogs

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

    /// The 2026 Steam Controller by InputConfig index: the standard slots,
    /// then the Quick Access button, the four back buttons, and the
    /// trackpad, stick and grip touch sensors.
    static let steamController2026ButtonNames: [String] = [
        "A", "B", "X", "Y",
        // As printed on the controller's shoulders.
        "L1", "R1", "L2", "R2",
        "View", "Menu", "Steam",
        "L3", "R3",
        "Quick Access", "L4", "R4", "L5", "R5",
        "Left pad click", "Right pad click", "Left pad touch", "Right pad touch",
        "Left stick touch", "Right stick touch", "Left grip touch", "Right grip touch",
    ]

    /// By InputConfig index: the four face buttons by position (B is the
    /// bottom one on a Nintendo pad), then the shoulders, menu buttons and
    /// stick presses, then the extras. 13 is the touchpad slot, unused here.
    static let switch2ProButtonNames: [String] = [
        "B", "A", "Y", "X",
        "L", "R", "ZL", "ZR",
        "Minus", "Plus", "Home",
        "L3", "R3",
        "Button 13", "Capture", "C", "GL", "GR",
    ]

    /// Same indices as the adapter's, plus the Switch 2 model's extras.
    static let switch2GameCubeButtonNames: [String] = [
        "A", "B", "X", "Y",
        "L", "Z",
        "L (full press)", "R (full press)",
        "Button 8", "Start", "Home",
        "Button 11", "Button 12",
        "Button 13", "Capture", "C", "ZL",
    ]

    static let gameCubeButtonNames: [String] = [
        "A", "B", "X", "Y",
        "L", "Z",
        "L (full press)", "R (full press)",
        "Button 8", "Start",
    ]

    static let dualShock3ButtonNames: [String] = [
        "Cross", "Circle", "Square", "Triangle",
        "L1", "R1", "L2", "R2",
        "Select", "Start", "PS",
        "L3", "R3",
    ]
}
