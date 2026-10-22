import Foundation

/// Applies one decoded raw HID report to a RawHIDGamepad; the body of decodeReport shared by the live dispatcher and the bench.
enum RawHIDReportApplier {
    /// Apply one report to the pad it belongs to (or the player pad its ID
    /// names). `replay`: a saved report decoded again when decoding starts,
    /// not something the user just did. `steam2026` takes the 2026 Steam
    /// Controller's reports, which carry more than state (the service's
    /// handler; the bench passes nil and such reports are dropped).
    /// Returns true when the report was the pad's own input report and was
    /// applied to it; false when it went elsewhere or was not one.
    @discardableResult
    nonisolated static func apply(data: Data, to pad: RawHIDGamepad, profile: ControllerProfile,
                                  players: [Int: RawHIDGamepad]?, replay: Bool,
                                  steam2026: ((Data) -> Void)?) -> Bool {
        if profile.layout == .steamController2026 {
            steam2026?(data)
            return false
        }
        // Another player's report: its own pad decodes it.
        if let players, let id = data.first, let player = players[Int(id)], let playerProfile = player.profile {
            applyDecoded(HIDReportDecoder.decode(report: data, profile: playerProfile), to: player, profile: playerProfile)
            return false
        }
        // An Xbox pad's battery report carries no input.
        if case .xboxBluetooth = profile.layout, data.first == 0x04 {
            if let battery = XboxBluetoothLayout.battery(report: data) { pad.setBattery(level: battery.level, state: battery.state) }
            return false
        }
        // A Switch 2 controller also sends replies and other report kinds;
        // only its input report is a controller state.
        if profile.layout == .switch2Pro, !HIDReportDecoder.isSwitch2ProInputReport(data) { return false }
        if profile.layout == .switch2GameCube, !HIDReportDecoder.isSwitch2GameCubeInputReport(data) { return false }
        if profile.layout == .switch2JoyConLeft || profile.layout == .switch2JoyConRight,
           !HIDReportDecoder.isSwitch2GameCubeInputReport(data) { return false }
        // The adapter's own slot is port 1, there whether or not a pad is
        // plugged into it. An empty port reads as zero bytes, which decoded
        // as both sticks pegged down-left; it reads as a pad at rest
        // instead, like ports 2 to 4, which are only read when occupied.
        if isGameCubeAdapter(pad), data.first == 0x21,
           !ControllerProfileDatabase.gameCubeAdapterPortOccupied(data, port: 1) {
            // Reset, not merge: an empty state merged into the last one
            // left a button held when the pad was unplugged held for good.
            pad.resetState()
        } else if RawHIDGamepadService.isSwitch2Layout(profile.layout) {
            var decoded = HIDReportDecoder.decode(report: data, profile: profile)
            // The pad's flash calibration already centers the sticks; the
            // learned rest point is the fallback for a pad whose flash was
            // not read.
            if Switch2Calibration.current(product: pad.productID) == nil { pad.removeStickRest(&decoded) }
            processMotion(&decoded, pad: pad)
            pad.updateState(decoded)
        } else if case .streamDeck(let format) = profile.layout, !format.oneShotSlots.isEmpty {
            // A Stream Deck + turn or touch strip gesture is one report with
            // no release. Held until the next report, a single turn stayed
            // pressed while the Plus sent nothing more, and turns in a row
            // read as one long press; each is a short press of its own.
            if replay {
                // The saved report may be the last dial turn or swipe; played
                // again it would be a press nobody made.
                var decoded = HIDReportDecoder.decode(report: data, profile: profile)
                for slot in format.oneShotSlots { decoded.buttons.removeValue(forKey: slot) }
                pad.updateState(decoded)
            } else {
                pad.updateState(HIDReportDecoder.decode(report: data, profile: profile), pulsing: format.oneShotSlots)
            }
        } else {
            var decoded = HIDReportDecoder.decode(report: data, profile: profile)
            processMotion(&decoded, pad: pad)
            applyDecoded(decoded, to: pad, profile: profile)
        }
        return true
    }

    /// A raw pad's IMU sample through the shared IMU code (gravity and the
    /// gyro's rest taken out, the turn kept for the engine), as the 2026
    /// Steam Controller's goes in RawHIDGamepadService. A sample with no
    /// acceleration at all is the IMU not yet on, not a reading: it is
    /// dropped, so gravity is not learned as zero and the last motion
    /// stands. A report with no motion fields is left alone.
    nonisolated static func processMotion(_ decoded: inout ControllerState, pad: RawHIDGamepad) {
        guard !decoded.motion.isEmpty else { return }
        let a = (decoded.motion[.accelX] ?? 0, decoded.motion[.accelY] ?? 0, decoded.motion[.accelZ] ?? 0)
        if a.0 != 0 || a.1 != 0 || a.2 != 0 {
            decoded.motion = pad.processMotion(decoded.motion)
        } else {
            decoded.motion = [:]
        }
    }

    /// Merge a decoded report. A descriptor pad's relative axes (a knob's
    /// turns) are short pushes that let go on their own; the rest is a merge.
    nonisolated static func applyDecoded(_ decoded: ControllerState, to pad: RawHIDGamepad, profile: ControllerProfile) {
        if case .generic(let generic) = profile.layout {
            let relative = HIDExtendedLayoutRegistry.extended(for: generic).relativeAxisSlots
            if !relative.isEmpty {
                pad.updateState(decoded, pulsingAxes: relative)
                return
            }
        }
        pad.updateState(decoded)
    }

    /// The GameCube controller adapter (WUP-028), whose one report carries
    /// all four ports.
    nonisolated static func isGameCubeAdapter(_ pad: RawHIDGamepad) -> Bool {
        pad.vendorID == 0x057E && pad.productID == ControllerProfileDatabase.gameCubeAdapterProductID
    }
}
