import Foundation

/// Pure builders for the 2026 Steam Controller's setting, rumble and lizard mode reports.
enum SteamController2026Commands {
    /// Settings go in feature report 1; rumble in output report 0x80.
    static let settingReportID: UInt8 = 0x01
    static let rumbleReportID: UInt8 = 0x80
    /// Setting 9: lizard mode (the controller's own mouse and keys).
    static let lizardSetting: UInt8 = 9
    /// Setting 48: which IMU streams (0x18 is gyro and accelerometer).
    static let imuSetting: UInt8 = 48
    static let imuOnValue: UInt16 = 0x18

    /// One settings write (feature report 1, message 0x87): the setting
    /// number, then its 16-bit value, padded to 64 bytes.
    static func setting(_ setting: UInt8, value: UInt16) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: 64)
        report[0] = settingReportID
        report[1] = 0x87                 // set settings values
        report[2] = 3                    // one setting: number, then a 16-bit value
        report[3] = setting
        report[4] = UInt8(value & 0xFF)
        report[5] = UInt8(value >> 8)
        return report
    }

    /// Output report 0x80: type, intensity, then each motor's speed and gain.
    static func rumble(speed: UInt16) -> [UInt8] {
        let lo = UInt8(speed & 0xFF), hi = UInt8(speed >> 8)
        return [rumbleReportID, 0x00, 0x00, 0x00, lo, hi, 0x00, lo, hi, 0x00]
    }

    /// The writes that turn lizard mode off (a preset runs) and back on.
    static var lizardOff: [[UInt8]] { [setting(lizardSetting, value: 0)] }
    static var lizardOn: [[UInt8]] { [setting(lizardSetting, value: 1)] }

    /// The write that starts or stops the gyro and accelerometer stream.
    static func imu(on: Bool) -> [UInt8] { setting(imuSetting, value: on ? imuOnValue : 0) }
}
