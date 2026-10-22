import Foundation

/// CRC-32 over Sony Bluetooth HID reports. The controller feeds one seed
/// byte before the report: 0xA1 for input, 0xA2 for output, 0xA3 for
/// feature reports (hid-playstation.c PS_INPUT_CRC32_SEED and friends;
/// SDL_hidapi_ps5.c VerifyCRC). The polynomial is the zlib one.
enum SonyBluetoothCRC {
    static let inputSeed: UInt8 = 0xA1
    static let outputSeed: UInt8 = 0xA2
    static let featureSeed: UInt8 = 0xA3

    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(seed: UInt8, _ bytes: UnsafeBufferPointer<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        func add(_ byte: UInt8) { crc = (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 0xFF)] }
        add(seed)
        for b in bytes { add(b) }
        return crc ^ 0xFFFF_FFFF
    }

    static func crc32(seed: UInt8, _ bytes: [UInt8]) -> UInt32 {
        bytes.withUnsafeBufferPointer { crc32(seed: seed, $0) }
    }

    /// A 78 byte input report whose last four bytes are the CRC of the
    /// first 74, little endian, seeded with 0xA1.
    static func inputReportIsWhole(_ r: UnsafePointer<UInt8>, length: Int) -> Bool {
        guard length == 78 else { return false }
        let crc = crc32(seed: inputSeed, UnsafeBufferPointer(start: r, count: 74))
        let sent = UInt32(r[74]) | UInt32(r[75]) << 8 | UInt32(r[76]) << 16 | UInt32(r[77]) << 24
        return crc == sent
    }

    static func inputReportIsWhole(_ bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBufferPointer { p in
            guard let base = p.baseAddress else { return false }
            return inputReportIsWhole(base, length: p.count)
        }
    }

    /// The CRC bytes for a 78 byte output report (seed 0xA2).
    static func sealOutputReport(_ bytes: inout [UInt8]) {
        guard bytes.count == 78 else { return }
        let crc = bytes.withUnsafeBufferPointer { crc32(seed: outputSeed, UnsafeBufferPointer(rebasing: $0[0..<74])) }
        for k in 0..<4 { bytes[74 + k] = UInt8((crc >> (8 * UInt32(k))) & 0xFF) }
    }

    /// The CRC bytes for a 78 byte input report built by hand (fixtures).
    static func sealInputReport(_ bytes: inout [UInt8]) {
        guard bytes.count == 78 else { return }
        let crc = bytes.withUnsafeBufferPointer { crc32(seed: inputSeed, UnsafeBufferPointer(rebasing: $0[0..<74])) }
        for k in 0..<4 { bytes[74 + k] = UInt8((crc >> (8 * UInt32(k))) & 0xFF) }
    }
}
