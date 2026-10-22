import Foundation

/// Golden output bytes shared across families, and the resolver that turns
/// an `OutputBuilder` case into the bytes the app's own static builder makes.
extension HIDFixtureCorpus {
    private static func out(_ id: String, _ device: String, _ builder: OutputBuilder, _ expect: [HIDFixture.Expect],
                            _ source: String, _ locator: String, status: HIDFixture.Status = .verified) -> HIDFixture {
        HIDFixture(id: id, device: device, transport: .usb, route: .outputReport(builder: builder), reportID: 0, hex: "",
                   expect: expect, status: status, citation: HIDFixture.Citation(source: source, locator: locator, date: "2026-10-20"))
    }
    private static func zeros(_ n: Int) -> [UInt8] { [UInt8](repeating: 0, count: n) }

    static let output: [HIDFixture] = [
        // DualSense adaptive trigger report: USB 0x02, flag0 0x0C, right block at 11, left at 22
        // (measured on the Edge 2026-09-17 and 18 with the light writer's framing).
        out("out.dualsense.triggerfeel.usb.firm", "DualSense", .triggerEffect(left: 3, right: 3, bluetooth: false, sequence: 0),
            [.custom("count=48"), .bytesPrefix([0x02, 0x0C]), .custom("reportID=0x02")],
            "InProcessLightWriter.triggerEffectReport; hid-playstation.c dualsense_output_report", "flags 0x0C claims both trigger blocks"),
        out("out.dualsense.triggerfeel.bt", "DualSense", .triggerEffect(left: 1, right: 1, bluetooth: true, sequence: 5),
            [.custom("count=78"), .bytesPrefix([0x31, 0x50, 0x10, 0x0C])],
            "hid-playstation.c dualsense BT output: [1] seq << 4, [2] 0x10, payload at 3, CRC seed 0xA2 at 74", "sequence 5"),
        // Logitech wheels
        out("out.logitech.g923ps.switch", "Logitech G923 PS", .logitechNativeMode(productID: 0xC267, bcdDevice: 0),
            [.bytes([0x30, 0xF8, 0x09, 0x07, 0x01, 0x01, 0x00, 0x00])],
            "new-lg4ff hid-lg4ff.c lg4ff_switch_from_ps_mode", "report 0x30, ID first; wire framing to be measured", status: .unverified),
        out("out.logitech.dfex.g29.switch", "Logitech G29 (DF EX mode)", .logitechNativeMode(productID: 0xC294, bcdDevice: 0x1350),
            [.bytes([0xF8, 0x09, 0x05, 0x01, 0x01, 0x00, 0x00])], "SDL_hidapi_lg4ff.c", "G29 mask 0x1350"),
        out("out.logitech.g29.range900", "Logitech G29", .logitechRange(productID: 0xC24F),
            [.bytes([0xF8, 0x81, 0x84, 0x03, 0x00, 0x00, 0x00])], "hid-lg4ff.c lg4ff_set_range_g25", "900 = 0x0384 little endian"),
        out("out.logitech.dfp.range", "Logitech Driving Force Pro", .logitechRange(productID: 0xC298),
            [.bytes([0xF8, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x81, 0x0B, 0x00, 0x00, 0x00, 0x00, 0x00])], "SDL_hidapi_lg4ff.c", "coarse then fine"),
        out("out.logitech.g29.startup", "Logitech G29", .rawStartup(vendorID: 0x046D, productID: 0xC24F, layout: "generic"),
            [.bytes([0xF8, 0x81, 0x84, 0x03, 0x00, 0x00, 0x00])], "RawHIDStartupCommands", "the range command is the only start-up write"),
        // Start-up writes
        out("out.ds3.startup", "DualShock 3", .rawStartup(vendorID: 0x054C, productID: 0x0268, layout: "dualShock3"),
            [.bytes([0xF5, 0x42, 0x0C, 0x00, 0x00])], "SDL_hidapi_ps3.c; hid-sony.c sixaxis_set_operational_usb",
            "output 0xF5 [F5] then feature 0xF4 [42 0C 00 00]; the two feature reads before them carry no bytes", status: .reconstructed),
        out("out.gcadapter.startup", "GameCube Controller Adapter", .rawStartup(vendorID: 0x057E, productID: 0x0337, layout: "generic"),
            [.bytes([0x13])], "SDL_hidapi_gamecube.c", "the 0x13 start command"),
        out("out.xinput.nostartup", "Xbox 360 (XUSB)", .rawStartup(vendorID: 0x045E, productID: 0x028E, layout: "xinput"),
            [.custom("count=0")], "RawHIDStartupCommands", "nothing is written to an XInput pad"),
        // Switch 2
        out("out.switch2.pro.commands", "Switch 2 Pro Controller", .switch2Commands(productID: 0x2069),
            [.bytesPrefix([0x03, 0x91, 0x00, 0x0D, 0x00, 0x08, 0x00, 0x00, 0x01, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x07, 0x91])],
            "procon2-mac; SDL_hidapi_switch2.c", "the 14 start commands, first two shown", status: .reconstructed),
        out("out.switch2.flashread.leftstick", "Switch 2 Pro Controller", .switch2Calibration(address: 0x013080),
            [.bytes([0x02, 0x91, 0x00, 0x01, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80, 0x30, 0x01, 0x00])],
            "SDL_hidapi_switch2.c ReadFlashBlock", "address little endian at 12 to 15"),
        // Sony light writers, byte for byte as writeLocked sends them.
        out("out.dualsense.light.usb.setup", "DualSense", .dualSenseLight(pid: 0x0CE6, transport: "USB", rgb: (0x12, 0x34, 0x56), brightness: 2, setup: true, motors: nil, sequence: 0),
            [.bytes({ var r = zeros(48); r[0] = 0x02; r[2] = 0x04; r[39] = 0x02; r[42] = 0x02; r[43] = 2; r[45] = 0x12; r[46] = 0x34; r[47] = 0x56; return r }())],
            "hid-playstation.c dualsense_output_report; verified live 2026-08-17", "first light write: flag1 0x04, flag2 0x02 setup, lightbar_setup 0x02"),
        out("out.dualsense.light.usb.rumble.edge", "DualSense Edge", .dualSenseLight(pid: 0x0DF2, transport: "USB", rgb: (0, 0, 0), brightness: 0, setup: false, motors: (0x40, 0x80), sequence: 0),
            [.bytes({ var r = zeros(48); r[0] = 0x02; r[1] = 0x03; r[2] = 0x04; r[3] = 0x40; r[4] = 0x80; return r }())],
            "measured 2026-09-18: the Edge takes no flag2 0x04", "flag0 0x03 claims motors with haptics select; weak at 3, strong at 4"),
        out("out.dualsense.light.usb.rumble.plain", "DualSense", .dualSenseLight(pid: 0x0CE6, transport: "USB", rgb: (0, 0, 0), brightness: 0, setup: false, motors: (0x40, 0x80), sequence: 0),
            [.bytes({ var r = zeros(48); r[0] = 0x02; r[1] = 0x03; r[2] = 0x04; r[3] = 0x40; r[4] = 0x80; r[39] = 0x04; return r }())],
            "measured 2026-09-18: a plain DualSense takes flag2 0x04 for the improved rumble", "flag2 0x04"),
        out("out.dualsense.light.bt", "DualSense", .dualSenseLight(pid: 0x0CE6, transport: "Bluetooth", rgb: (0x12, 0x34, 0x56), brightness: 2, setup: true, motors: nil, sequence: 5),
            [.bytes(HIDFixture.parse("31 50 10 00 04 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 02 00 00 02 02 00 12 34 56 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 5B A3 F7 1D"))],
            "verified live 2026-08-17 (the Edge turned blue)", "[1] seq << 4, [2] 0x10, payload at 3, CRC seed 0xA2 at 74"),
        out("out.ds4.light.usb", "DualShock 4", .dualShock4Light(transport: "USB", rgb: (0xFF, 0x00, 0x00), motors: (0xC8, 0xC8)),
            [.bytes({ var r = zeros(32); r[0] = 0x05; r[1] = 0x07; r[4] = 0xC8; r[5] = 0xC8; r[6] = 0xFF; return r }())],
            "SDL_hidapi_ps4.c DS4EffectsState_t; hid-playstation.c dualshock4_output_report_usb", "flags 0x07, motors 4 and 5, RGB 6 to 8"),
        out("out.ds4.light.bt", "DualShock 4", .dualShock4Light(transport: "Bluetooth", rgb: (0xFF, 0x00, 0x00), motors: (0xC8, 0xC8)),
            [.bytes(HIDFixture.parse("11 C4 00 03 00 00 C8 C8 FF 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 47 EA 78 AA"))],
            "hid-playstation.c dualshock4_output_report_bt (hw_control 0xC0 | 4 ms); CRC computed", "O-10: 0xC4 after the poll fix; no DS4 on the desk", status: .reconstructed),
        // Access controller lights (builders only; the first send is H1 step 6)
        out("out.access.led.red", "PlayStation Access", .accessLED(rgb: (0xFF, 0x00, 0x00), player: 0),
            [.bytes([0x02, 0x04, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00] + zeros(23))], "titania access_output_msg; dualsense-ts output section", "O1: mutator bit 2, RGB at 6 to 8", status: .unverified),
        out("out.access.led.player4.blue", "PlayStation Access", .accessLED(rgb: (0x00, 0x80, 0xFF), player: 4),
            [.bytes([0x02, 0x14, 0x00, 0x00, 0x00, 0x04, 0x00, 0x80, 0xFF] + zeros(23))], "dualsense-ts", "mutator 0x14: ring and player indicator", status: .unverified),
        // Switch 2 player LEDs (documented; not sent)
        out("out.switch2.playerled.2", "Switch 2 Pro Controller", .switch2PlayerLED(player: 2),
            [.bytes([0x09, 0x91, 0x00, 0x07, 0x00, 0x08, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])], "SDL_hidapi_switch2.c UpdateSlotLED", "player 2 is mask 0x03"),
        out("out.switch2.playerled.5", "Switch 2 Pro Controller", .switch2PlayerLED(player: 5),
            [.bytes([0x09, 0x91, 0x00, 0x07, 0x00, 0x08, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])], "SDL_hidapi_switch2.c UpdateSlotLED", "player 5 is mask 0x09"),
        // 2026 Steam Controller
        out("out.steam2026.lizardoff.setting", "Steam Controller (2026)", .steam2026Setting(setting: 9, value: 0),
            [.bytes([0x01, 0x87, 0x03, 0x09, 0x00, 0x00] + zeros(58))], "SDL_hidapi_steam.c SetSettings; verified 2026-10-19", "feature 1, 0x87, 3 bytes: setting 9 value 0"),
        out("out.steam2026.imu.on", "Steam Controller (2026)", .steam2026Setting(setting: 48, value: 0x18),
            [.bytes([0x01, 0x87, 0x03, 0x30, 0x18, 0x00] + zeros(58))], "SDL_hidapi_steam.c", "setting 48 value 0x18"),
        out("out.steam2026.rumble", "Steam Controller (2026)", .steam2026Rumble(speed: 0x1234),
            [.bytes([0x80, 0x00, 0x00, 0x00, 0x34, 0x12, 0x00, 0x34, 0x12, 0x00])], "verified 2026-10-19", "output 0x80, both motors"),
        out("out.steam2026.lizardon", "Steam Controller (2026)", .steam2026LizardOn,
            [.bytes([0x01, 0x87, 0x03, 0x09, 0x01, 0x00] + zeros(58))], "the app's own lizard on write", "setting 9 value 1; SDL sends 0x85 and 0x8E instead (gaps-valve B3), left as is", status: .unverified),
        // Steam Controller (2015) helper feature reports, shared with the helper
        out("out.steamhelper.cleardigital", "Steam Controller (2015)", .steamHelperFeature(name: "clear digital mappings"),
            [.bytes([0x81] + zeros(63))], "SDL_hidapi_steam.c ID_CLEAR_DIGITAL_MAPPINGS; SteamControllerHelper/main.swift sendDisableLizardMode", "feature 0, 64 bytes"),
        out("out.steamhelper.trackpadoff", "Steam Controller (2015)", .steamHelperFeature(name: "disable trackpad mouse"),
            [.bytes([0x87, 0x09, 0x07, 0x07, 0x00, 0x08, 0x07, 0x00, 0x30, 0x18, 0x00] + zeros(53))], "SDL_hidapi_steam.c ID_SET_SETTINGS_VALUES, SETTING_LEFT_TRACKPAD_MODE 7, SETTING_RIGHT_TRACKPAD_MODE 8, SETTING_IMU_MODE 48", "three UInt16 LE settings after the length"),
        out("out.steamhelper.imu", "Steam Controller (2015)", .steamHelperFeature(name: "raw gyro and accelerometer"),
            [.bytes([0x87, 0x03, 0x30, 0x18, 0x00] + zeros(59))], "SDL_hidapi_steam.c SETTING_GYRO_MODE_SEND_RAW_ACCEL 0x08 | SEND_RAW_GYRO 0x10", "setting 48 value 0x18"),
        out("out.steamhelper.defaultdigital", "Steam Controller (2015)", .steamHelperFeature(name: "default digital mappings"),
            [.bytes([0x85] + zeros(63))], "SDL_hidapi_steam.c ID_SET_DEFAULT_DIGITAL_MAPPINGS", "lizard mode keys back"),
        out("out.steamhelper.defaultsettings", "Steam Controller (2015)", .steamHelperFeature(name: "default settings"),
            [.bytes([0x8E] + zeros(63))], "SDL_hidapi_steam.c ID_LOAD_DEFAULT_SETTINGS", "trackpad mouse back"),
        out("out.steamhelper.wireless", "Steam Controller (2015)", .steamHelperFeature(name: "wireless state"),
            [.bytes([0xB4] + zeros(63))], "SDL_hidapi_steam.c ID_GET_WIRELESS_STATE", "asked of the dongle only"),
    ]


    static let outputSequences: [HIDSequenceFixture] = []
}

enum OutputBuilders {
    /// The report a builder case produces, or nil while no pure static
    /// builder exists for it yet; the bench fails such a fixture by name.
    static func bytes(for builder: OutputBuilder) -> [UInt8]? {
        switch builder {
        case .triggerEffect(let left, let right, let bluetooth, let sequence):
            return InProcessLightWriter.triggerEffectReport(left: left, right: right, bluetooth: bluetooth, sequence: sequence)
        case .logitechRange(let pid):
            // Every range command of the wheel, one after another; nil for a
            // wheel whose range is fixed.
            return LogitechWheel.rangeCommands(product: pid).map { $0.flatMap { $0 } }
        case .logitechNativeMode(let pid, let bcd):
            // Report ID first when the command goes on a numbered report.
            guard let c = LogitechWheel.nativeModeCommand(product: pid, bcdDevice: bcd) else { return nil }
            return c.reportID == 0 ? c.bytes : [c.reportID] + c.bytes
        case .switch2Commands(let pid):
            return Switch2USBEnabler.commands(for: Int(pid)).flatMap { $0 }
        case .switch2Calibration(let address):
            return Switch2Calibration.readCommand(address: address)
        case .rawStartup(let vid, let pid, _):
            // Every report written at start-up, one after another; feature
            // reads are not bytes and are left out.
            let profile = ControllerProfileDatabase.profile(forVendor: vid, product: pid)
            return RawHIDStartupCommands.reports(for: profile, vendorID: vid, productID: pid).flatMap { $0.bytes }
        case .steam2026Setting(let setting, let value):
            return SteamController2026Commands.setting(setting, value: value)
        case .steam2026Rumble(let speed):
            return SteamController2026Commands.rumble(speed: speed)
        case .steam2026LizardOn:
            return SteamController2026Commands.lizardOn.flatMap { $0 }
        case .xboxBluetoothRumble(let strong, let weak, let lt, let rt):
            return XboxBluetoothLayout.rumbleReport(strong: Int(strong), weak: Int(weak), leftTrigger: Int(lt), rightTrigger: Int(rt))
        case .dualSenseLight(let pid, let transport, let rgb, let brightness, let setup, let motors, let sequence):
            return InProcessLightWriter.dualSenseLightReport(bluetooth: transport.localizedCaseInsensitiveContains("Bluetooth"), sequence: sequence,
                                                             touchLight: true, rgb: rgb, brightness: brightness, setup: setup,
                                                             touchMotors: motors != nil, weak: motors?.0 ?? 0, strong: motors?.1 ?? 0,
                                                             hapticsSelect: true, motorMask: 0, improvedRumble: pid != 0x0DF2)
        case .dualShock4Light(let transport, let rgb, let motors):
            return InProcessLightWriter.dualShock4LightReport(bluetooth: transport.localizedCaseInsensitiveContains("Bluetooth"), touchLight: true, rgb: rgb,
                                                              touchMotors: motors != nil, weak: motors?.0 ?? 0, strong: motors?.1 ?? 0)
        case .accessLED(let rgb, let player):
            return AccessControllerPortService.ledReport(rgb: rgb, player: player)
        case .switch2PlayerLED(let player):
            return Switch2USBEnabler.playerLEDCommand(player: player)
        case .accessRead(let number):
            return AccessControllerPortService.readCommand(number: number)
        case .accessWrite(let number, let blob, let packet):
            let packets = AccessControllerPortService.writePackets(number: number, bytes: blob)
            return packets.indices.contains(packet) ? packets[packet] : []
        case .accessSetActive(let number):
            return AccessControllerPortService.setActiveCommand(number)
        case .steamHelperFeature(let name):
            return SteamController2015Commands.command(named: name)
        case .accessLED, .xboxBluetoothRumble:
            return nil
        }
    }
}
