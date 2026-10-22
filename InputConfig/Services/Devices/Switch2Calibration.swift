import Foundation

/// Stick and trigger calibration a Switch 2 controller keeps in its own
/// flash, read over the vendor interface before the start command and
/// applied to every report, as SDL_hidapi_switch2.c does (ReadFlashBlock,
/// ParseStickCalibration, MapJoystickAxis, MapTriggerAxis). Without it the
/// decoders fall back to a center of 2048 and a span of 1650 counts, the
/// numbers measured on one procon2-mac unit.
struct Switch2Calibration: Equatable {
    /// One stick: its rest point and how far it travels each way from
    /// there, in 12 bit counts (max and min are relative to neutral).
    struct Stick: Equatable {
        var neutralX: Int, neutralY: Int
        var maxX: Int, maxY: Int
        var minX: Int, minY: Int

        /// Nine bytes, three 12 bit pairs packed Nintendo style (X low byte,
        /// Y low nibble over X high nibble, Y high byte): neutral, max, min.
        init?(block c: [UInt8]) {
            guard c.count >= 9 else { return nil }
            func pair(_ i: Int) -> (Int, Int) {
                (Int(c[i]) | Int(c[i + 1] & 0x0F) << 8, Int(c[i + 1] >> 4) | Int(c[i + 2]) << 4)
            }
            let n = pair(0), mx = pair(3), mn = pair(6)
            neutralX = n.0; neutralY = n.1; maxX = mx.0; maxY = mx.1; minX = mn.0; minY = mn.1
            // A blank or erased block is not a calibration.
            guard (512...3584).contains(neutralX), (512...3584).contains(neutralY),
                  (200...2600).contains(maxX), (200...2600).contains(maxY),
                  (200...2600).contains(minX), (200...2600).contains(minY) else { return nil }
        }

        /// SDL MapJoystickAxis: distance from neutral over the travel on
        /// that side, clamped to one.
        func mapX(_ raw: Int) -> Float { Self.map(raw, neutral: neutralX, max: maxX, min: minX) }
        func mapY(_ raw: Int) -> Float { Self.map(raw, neutral: neutralY, max: maxY, min: minY) }
        private static func map(_ raw: Int, neutral: Int, max: Int, min: Int) -> Float {
            let span = raw < neutral ? min : max
            guard span > 0 else { return 0 }
            return Swift.max(-1, Swift.min(1, Float(raw - neutral) / Float(span)))
        }
    }

    var left: Stick?
    var right: Stick?
    /// GameCube controller: the analog L and R value at rest (flash
    /// 0x013140 bytes 0 and 1); SDL's MapTriggerAxis uses 232 as full.
    var triggerZeroL: Int?
    var triggerZeroR: Int?

    // MARK: - Flash reads

    static let leftStickAddress: UInt32 = 0x013080
    static let rightStickAddress: UInt32 = 0x0130C0
    static let triggerZeroAddress: UInt32 = 0x013140
    static let userLeftStickAddress: UInt32 = 0x1FC040
    static let userRightStickAddress: UInt32 = 0x1FC080
    static let addresses: [UInt32] = [leftStickAddress, rightStickAddress, triggerZeroAddress, userLeftStickAddress, userRightStickAddress]

    /// The 16 byte vendor command that reads a 0x40 byte flash block:
    /// `02 91 00 01 00 08 00 00` then the address little endian at 12 to
    /// 15 (SDL ReadFlashBlock). The reply is 0x50 bytes with the data at
    /// offset 0x10.
    static func readCommand(address: UInt32) -> [UInt8] {
        [0x02, 0x91, 0x00, 0x01, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
         UInt8(address & 0xFF), UInt8((address >> 8) & 0xFF), UInt8((address >> 16) & 0xFF), UInt8(address >> 24)]
    }
    static let replyLength = 0x50
    static let replyDataOffset = 0x10
    /// Where the nine calibration bytes sit inside the factory stick block.
    static let factoryStickOffset = 0x28
    /// A user calibration block starts with this magic, then the nine bytes.
    static let userMagic: [UInt8] = [0xB2, 0xA1]

    static func data(fromReply reply: [UInt8]) -> [UInt8]? {
        guard reply.count >= replyLength else { return nil }
        return Array(reply[replyDataOffset..<replyLength])
    }

    static func factoryStick(fromReply reply: [UInt8]) -> Stick? {
        guard let d = data(fromReply: reply), d.count >= factoryStickOffset + 9 else { return nil }
        return Stick(block: Array(d[factoryStickOffset..<(factoryStickOffset + 9)]))
    }

    static func userStick(fromReply reply: [UInt8]) -> Stick? {
        guard let d = data(fromReply: reply), d.count >= 11, Array(d[0..<2]) == userMagic else { return nil }
        return Stick(block: Array(d[2..<11]))
    }

    static func triggerZeros(fromReply reply: [UInt8]) -> (l: Int, r: Int)? {
        guard let d = data(fromReply: reply), d.count >= 2, d[0] != 0xFF, d[1] != 0xFF else { return nil }
        return (Int(d[0]), Int(d[1]))
    }

    /// Builds a calibration from the five replies, by address; a user
    /// block overrides the factory one for its stick.
    static func from(replies: [UInt32: [UInt8]]) -> Switch2Calibration {
        var cal = Switch2Calibration()
        cal.left = replies[leftStickAddress].flatMap(factoryStick(fromReply:))
        cal.right = replies[rightStickAddress].flatMap(factoryStick(fromReply:))
        if let user = replies[userLeftStickAddress].flatMap(userStick(fromReply:)) { cal.left = user }
        if let user = replies[userRightStickAddress].flatMap(userStick(fromReply:)) { cal.right = user }
        if let zeros = replies[triggerZeroAddress].flatMap(triggerZeros(fromReply:)) {
            cal.triggerZeroL = zeros.l; cal.triggerZeroR = zeros.r
        }
        return cal
    }

    // MARK: - The calibration in use, by product

    /// Fallbacks when the flash was not read: the procon2-mac numbers.
    static let fallbackCenter = 2048
    static let fallbackSpan = 1650
    static let fallbackTriggerZero = 40

    private static let lock = NSLock()
    nonisolated(unsafe) private static var byProduct: [Int32: Switch2Calibration] = [:]

    static func current(product: Int32) -> Switch2Calibration? {
        lock.lock(); defer { lock.unlock() }
        return byProduct[product]
    }

    static func store(_ cal: Switch2Calibration?, product: Int32) {
        lock.lock(); defer { lock.unlock() }
        if let cal, cal.left != nil || cal.right != nil || cal.triggerZeroL != nil { byProduct[product] = cal } else { byProduct.removeValue(forKey: product) }
    }
}
