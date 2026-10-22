import Foundation

/// Descriptor driven decoding and readBits, moved out of HIDReportDecoder.swift.
extension HIDReportDecoder {
    // MARK: - Generic layout

    static func decodeGeneric(report: Data,
                              layout: ControllerProfile.GenericLayout,
                              into state: inout ControllerState) {
        decodeGeneric(report: report,
                      plan: HIDExtendedLayoutRegistry.extended(for: layout),
                      into: &state)
    }

    /// Decodes one input report with the parser's full plan. Only the
    /// controls this report carries are written, so a device that splits
    /// its controls across report IDs (a SpaceMouse sends translation,
    /// rotation, and buttons separately) fills the rest of the state from
    /// its other reports; `RawHIDGamepad.updateState` merges them. A
    /// report ID the plan doesn't know (battery, sensor, vendor) writes
    /// nothing, rather than phantom input.
    static func decodeGeneric(report: Data,
                              plan: HIDExtendedLayout,
                              into state: inout ControllerState) {
        let bytes = Array(report)
        var offset = 0
        let entry: HIDExtendedLayout.Report
        if plan.usesReportIDs {
            guard !bytes.isEmpty, let found = plan.report(forID: Int(bytes[0])) else { return }
            entry = found
            offset = 1
        } else {
            guard let found = plan.reports.first else { return }
            entry = found
        }
        // Fields past the end of a short report are skipped one by one
        // (readBits); only a hand-written layout needs the whole report.
        if plan.requiresFullReport {
            guard bytes.count >= offset + entry.payloadSize else { return }
        } else {
            guard bytes.count > offset else { return }
        }
        let payloadCount = bytes.count - offset

        // Buttons
        var forcedAxes: Set<Int> = []
        for button in entry.buttons {
            guard let raw = readBits(bytes, offset, payloadCount, button.bitOffset, button.bitSize) else { continue }
            let pressed = Int(raw) > button.pressAbove
            state.buttons[button.index] = pressed ? 1.0 : 0.0
            if pressed, let axis = button.forcesAxis { forcedAxes.insert(axis) }
        }

        // Axes, each scaled by its own declared logical range and read
        // through a bit window, so 10/12/14-bit packed axes, 32-bit axes,
        // and ranges like 0..1023 or -350..350 all reach full scale.
        // Y stays positive = down, the same as the GameController,
        // XInput, DualShock 3, and Switch 2 paths.
        for axis in entry.axes {
            guard axis.logicalMax > axis.logicalMin,
                  let raw = readBits(bytes, offset, payloadCount, axis.bitOffset, axis.bitSize) else { continue }
            var v = Int(raw)
            if axis.isSigned || axis.relative {
                let signBit = 1 << (axis.bitSize - 1)
                if v & signBit != 0 { v -= 1 << axis.bitSize }
            }
            if axis.wrapCounter {
                // A jog wheel's byte is a position counter that wraps at the
                // field size; the pad keeps the last one and takes the delta.
                state.relativeSteps[axis.index] = Int(raw)
                continue
            }
            if axis.relative {
                // A knob reports how far it turned since the last report, so
                // one detent is a delta of 1 out of a range of 255. Read as a
                // position it moved the axis by 0.004 and then stayed there.
                // It reads full tilt in the direction of the turn instead;
                // RawHIDGamepad.updateState(_:pulsingAxes:) lets go after a
                // moment, so each detent is a short push.
                state.axes[axis.index] = v > 0 ? 1 : (v < 0 ? -1 : 0)
                continue
            }
            let lo = axis.logicalMin, hi = axis.logicalMax
            var value: Float
            if axis.unipolar {
                value = max(0, min(1, Float(v - lo) / Float(hi - lo)))
                if axis.inverted { value = 1 - value }
            } else {
                // Center on the upper middle value (128 for 0..255, 0 for
                // signed ranges) and scale each side separately, so rest
                // reads exactly 0 and both ends reach exactly -1 and +1.
                let center = lo + (hi - lo + 1) / 2
                let span = Float(v >= center ? max(1, hi - center) : max(1, center - lo))
                value = max(-1, min(1, Float(v - center) / span))
                if axis.inverted { value = -value }
            }
            if forcedAxes.contains(axis.index) { value = max(value, 1) }
            state.axes[axis.index] = value
            if let b = axis.digitalButton {
                state.buttons[b] = value > 0.12 ? 1.0 : 0.0
            }
        }

        // Hat switches, each into its own hats[i]. Honor the declared
        // logical minimum: pads that use 1..8 with 0 as null would
        // otherwise read rotated 45 degrees with the resting value
        // decoding as a held North. A 4-way hat (0..3) steps 90 degrees
        // per value, so its direction doubles onto the 8-way table.
        for hat in entry.hats {
            // 8-bit hats keep the direction in the low nibble with
            // padding above, so only the low 4 bits are read. A hat that
            // reports an angle is read whole.
            let angular = hat.directions > 16
            guard let raw = readBits(bytes, offset, payloadCount, hat.bitOffset,
                                     angular ? hat.bitSize : min(hat.bitSize, 4)) else { continue }
            var direction = Int(raw) - hat.logicalMin
            if hat.directions == 4 {
                direction = (0...3).contains(direction) ? direction * 2 : -1
            } else if angular {
                // 0 is North, `directions` is a full turn, and a value past
                // it is the centered state; rounded to the nearest of eight.
                direction = (0..<hat.directions).contains(direction)
                    ? Int((Double(direction) * 8 / Double(hat.directions)).rounded()) % 8 : -1
            }
            // Standard 8-direction encoding after normalization
            // (0=N, 1=NE, ..., 7=NW; anything else = center).
            // Up-positive convention (N = +1), matching GC framework,
            // Steam, and the engine's hat matching.
            let i = hat.index
            switch direction {
            case 0: setHat(&state, i, x: 0, y: 1)               // N
            case 1: setHat(&state, i, x: 0.707, y: 0.707)       // NE
            case 2: setHat(&state, i, x: 1, y: 0)               // E
            case 3: setHat(&state, i, x: 0.707, y: -0.707)      // SE
            case 4: setHat(&state, i, x: 0, y: -1)              // S
            case 5: setHat(&state, i, x: -0.707, y: -0.707)     // SW
            case 6: setHat(&state, i, x: -1, y: 0)              // W
            case 7: setHat(&state, i, x: -0.707, y: 0.707)      // NW
            default: setHat(&state, i, x: 0, y: 0)
            }
        }

        // Array inputs: every button of the array is up unless an entry
        // names it.
        for array in entry.buttonArrays {
            // A report too short to carry the array says nothing about it.
            guard readBits(bytes, offset, payloadCount, array.bitOffset, array.bitSize) != nil else { continue }
            for k in 0..<array.buttons { state.buttons[array.firstIndex + k] = 0 }
            for n in 0..<array.count {
                guard let raw = readBits(bytes, offset, payloadCount, array.bitOffset + n * array.bitSize, array.bitSize)
                else { continue }
                let k = Int(raw) - array.logicalMin
                if (0..<array.buttons).contains(k) { state.buttons[array.firstIndex + k] = 1 }
            }
        }

        // A D-pad that sends each direction as a button, folded into its
        // hat with up positive like the hats above.
        if !entry.dpadButtons.isEmpty {
            var pads: [Int: (x: Float, y: Float)] = [:]
            for pad in entry.dpadButtons {
                let pressed: Bool
                if let half = pad.axisHalf {
                    // Half of an axis: pressed past the middle of that half.
                    guard var v = readBits(bytes, offset, payloadCount, pad.bitOffset, half.bitSize).map({ Int($0) })
                    else { continue }
                    if half.isSigned {
                        let signBit = 1 << (half.bitSize - 1)
                        if v & signBit != 0 { v -= 1 << half.bitSize }
                    }
                    let lo = half.logicalMin, hi = half.logicalMax
                    let center = lo + (hi - lo + 1) / 2
                    let span = Float(v >= center ? max(1, hi - center) : max(1, center - lo))
                    let value = Float(v - center) / span
                    pressed = half.positive ? value > 0.5 : value < -0.5
                } else {
                    guard let raw = readBits(bytes, offset, payloadCount, pad.bitOffset, pad.bitSize) else { continue }
                    pressed = Int(raw) > pad.pressAbove
                }
                var hat = pads[pad.hatIndex] ?? (0, 0)
                if pressed {
                    switch pad.direction {
                    case .up: hat.y += 1
                    case .down: hat.y -= 1
                    case .left: hat.x -= 1
                    case .right: hat.x += 1
                    }
                }
                pads[pad.hatIndex] = hat
            }
            for (i, hat) in pads { setHat(&state, i, x: hat.x, y: hat.y) }
        }
    }

    /// Reads `bitSize` bits (1...32) starting `bitOffset` bits into the
    /// payload, little endian. Nil when the field runs past the report.
    @inline(__always)
    private static func readBits(_ bytes: [UInt8], _ base: Int, _ payloadCount: Int,
                                 _ bitOffset: Int, _ bitSize: Int) -> UInt64? {
        guard bitSize >= 1 && bitSize <= 32, bitOffset >= 0 else { return nil }
        let first = bitOffset / 8
        let last = (bitOffset + bitSize - 1) / 8
        guard last < payloadCount else { return nil }
        var window: UInt64 = 0
        for k in 0...(last - first) {
            window |= UInt64(bytes[base + first + k]) << UInt64(8 * k)
        }
        return (window >> UInt64(bitOffset % 8)) & ((UInt64(1) << UInt64(bitSize)) - 1)
    }
}
