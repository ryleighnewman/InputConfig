import Foundation

/// Pure builders for the feature reports the Steam Controller helper sends
/// to a 2015 Steam Controller (SDL_hidapi_steam.c, Valve's constants). Each
/// is a 64 byte feature report 0: the command byte, its length, its payload,
/// zero padded. Compiled into the app for the test bench and into the helper
/// (SteamControllerHelper/main.swift) for the device.
enum SteamController2015Commands {
    static let reportSize = 64

    /// A command padded to the 64 byte feature report.
    static func padded(_ command: [UInt8]) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: reportSize)
        for (i, b) in command.prefix(reportSize).enumerated() { report[i] = b }
        return report
    }

    /// 0x81 ID_CLEAR_DIGITAL_MAPPINGS: no esc, enter or cursor keys.
    static let clearDigitalMappings = padded([0x81])
    /// 0x87 ID_SET_SETTINGS_VALUES, length 9: left trackpad mode (7) and
    /// right trackpad mode (8) to TRACKPAD_NONE (7), IMU mode (48) to raw
    /// gyro and accelerometer (0x18). Values are UInt16 little endian.
    static let disableTrackpadMouse = padded([0x87, 0x09,
                                              0x07, 0x07, 0x00,
                                              0x08, 0x07, 0x00,
                                              0x30, 0x18, 0x00])
    /// 0x87 length 3: IMU mode (48) = raw accelerometer (0x08) | raw gyro (0x10).
    static let enableIMU = padded([0x87, 0x03, 0x30, 0x18, 0x00])
    /// 0x85 ID_SET_DEFAULT_DIGITAL_MAPPINGS: lizard mode's keys back.
    static let defaultDigitalMappings = padded([0x85])
    /// 0x8E ID_LOAD_DEFAULT_SETTINGS: the trackpad mouse back.
    static let defaultSettings = padded([0x8E])
    /// 0xB4 ID_GET_WIRELESS_STATE, asked of the dongle.
    static let wirelessState = padded([0xB4])

    /// The command the helper logs under `name`, for fixtures.
    static func command(named name: String) -> [UInt8]? {
        switch name {
        case "clear digital mappings": return clearDigitalMappings
        case "disable trackpad mouse": return disableTrackpadMouse
        case "raw gyro and accelerometer": return enableIMU
        case "default digital mappings": return defaultDigitalMappings
        case "default settings": return defaultSettings
        case "wireless state": return wirelessState
        default: return nil
        }
    }
}
