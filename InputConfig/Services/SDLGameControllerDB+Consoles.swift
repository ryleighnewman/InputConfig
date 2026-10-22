import Foundation

/// PlayStation class mappings and the completed table, moved out of SDLGameControllerDB.swift.
extension SDLGameControllerDB {
    /// A decode plan that puts every control the row names on its
    /// InputConfig slot. nil when the row points at controls the
    /// descriptor does not have, which means the row is for a different
    /// firmware and the plain descriptor layout is the safer reading.
    /// A row with the standard targets it leaves out filled in, where the
    /// device's button order says where they are:
    /// - A PlayStation-licensed pad or stick in the DualShock order (Square
    ///   b0, Cross b1, Circle b2, Triangle b3, L1 b4, R1 b5, Share b8,
    ///   Options b9) has L3 on b10, R3 on b11 and, past PS on b12, a PS4 or
    ///   PS5 model's touchpad click on b13 (a PS3 model reports 13 buttons,
    ///   so it has no b13 to fill). Rows for the Victrix Pro FS and
    ///   the PDP Versus Fighting leave L3 and R3 out, the Qanba Drone's the
    ///   touchpad, so those presses landed on the extra slots and the drawn
    ///   buttons stayed dark.
    /// - The 8BitDo Pro 2 (2DC8:6003 and 6006) has its back buttons on b2
    ///   (PR, right) and b5 (PL, left), as SDL's own 8BitDo driver reads
    ///   them (SDL_hidapi_8bitdo.c); its rows name neither.
    /// Only buttons the device has and the row does not already use.
    static func completed(_ mapping: Mapping, buttonCount: Int) -> Mapping {
        var entries = mapping.entries
        let used = Set(entries.values.compactMap { v -> Int? in
            var s = Substring(v)
            if let f = s.first, f == "+" || f == "-" { s = s.dropFirst() }
            if s.hasSuffix("~") { s = s.dropLast() }
            guard s.first == "b" else { return nil }
            return Int(s.dropFirst())
        })
        func add(_ target: String, _ button: Int) {
            guard entries[target] == nil, button < buttonCount, !used.contains(button) else { return }
            entries[target] = "b\(button)"
        }
        let dualShockOrder = ["x": "b0", "a": "b1", "b": "b2", "y": "b3", "leftshoulder": "b4", "rightshoulder": "b5",
                              "back": "b8", "start": "b9"]
        if dualShockOrder.allSatisfy({ entries[$0.key] == $0.value }) {
            add("leftstick", 10)
            add("rightstick", 11)
            // A PS3 model has 13 buttons and no touchpad; one with a b13 and
            // no PS3 in its name is a PS4 or PS5 class device.
            if entries["guide"] == "b12", !mapping.name.uppercased().contains("PS3") {
                add("touchpad", 13)
            }
        }
        // A pad in the Switch bit order (Y B A X L R ZL ZR minus plus, then
        // L3 R3 Home Capture: GP2040-CE SwitchDescriptors.h, the Pro
        // Controller's USB order) whose row stops at plus, as the Hori
        // Pokken row does for 0F0D:0092: the next four bits are L3, R3,
        // Home and Capture on every such device that has them.
        let switchOrder = ["x": "b0", "a": "b1", "b": "b2", "y": "b3", "leftshoulder": "b4", "rightshoulder": "b5",
                           "lefttrigger": "b6", "righttrigger": "b7", "back": "b8", "start": "b9"]
        if switchOrder.allSatisfy({ entries[$0.key] == $0.value }) {
            add("leftstick", 10)
            add("rightstick", 11)
            add("guide", 12)
            add("misc1", 13)
        }
        if mapping.vendorID == 0x2DC8, mapping.productID == 0x6003 || mapping.productID == 0x6006 {
            add("paddle1", 2)
            add("paddle2", 5)
        }
        // An Xbox pad on the unified BLE descriptor (15 bit Button field,
        // then Consumer Record): Share is the sixteenth button on every
        // firmware, though only the 0B13 version 0x0509 row names it
        // (xpadneo xbxs.md byte 16 bit 0; SDL HandleButtons data[16] & 0x01).
        if mapping.vendorID == 0x045E, entries["x"] == "b3", entries["guide"] == "b12", buttonCount >= 16 {
            add("misc1", 15)
        }
        guard entries != mapping.entries else { return mapping }
        return Mapping(vendorID: mapping.vendorID, productID: mapping.productID, version: mapping.version,
                       name: mapping.name, entries: entries)
    }

    /// Third-party pads that speak the PlayStation 4 or 5 protocol (Razer,
    /// Nacon, Hori, PDP, Mad Catz, Qanba and others), as SDL's
    /// controller_list.h lists them (zlib license; Sony's own pads and the
    /// Logitech G29's PS4 mode left out). SDL reads them with its own
    /// PS4/PS5 drivers, so the database has no Mac rows for most; read in
    /// descriptor order, Square, Cross, L3, R3, PS and Mute fired the wrong
    /// rows. They take Sony's own row instead (Cross 0, Circle 1, Square 2,
    /// Triangle 3, PS 10, L3 11, R3 12).
    static let playStation4Class: Set<Int> = [
        0x0079_181B, 0x044F_D00E, 0x0738_8250, 0x0738_8384, 0x0738_8480, 0x0738_8481,
        0x0C12_0E10, 0x0C12_0E13, 0x0C12_0E15, 0x0C12_0E20, 0x0C12_0EF6, 0x0C12_1CF6,
        0x0C12_1E10, 0x0C12_2E18, 0x0E6F_0203, 0x0E6F_0207, 0x0E6F_020A, 0x0F0D_0055,
        0x0F0D_005E, 0x0F0D_0066, 0x0F0D_0084, 0x0F0D_0087, 0x0F0D_008A, 0x0F0D_009C,
        0x0F0D_00A0, 0x0F0D_00EE, 0x0F0D_011C, 0x0F0D_0123, 0x0F0D_0162, 0x11C0_4001,
        0x146B_0D01, 0x146B_0D02, 0x146B_0D06, 0x146B_0D08, 0x146B_0D09, 0x146B_0D10,
        0x146B_0D13, 0x146B_1103, 0x1532_1000, 0x1532_1004, 0x1532_1007, 0x1532_1008,
        0x1532_1009, 0x1532_100A, 0x1532_1100, 0x20D6_792A, 0x2C22_2000, 0x2C22_2300,
        0x2C22_2500, 0x3285_0D16, 0x3285_0D17, 0x7545_0104, 0x9886_0025, 0x7545_1122,
        // Razer Panthera (GP2040-CE's PS4 identity) and the Qanba Drone 2.
        0x1532_0401, 0x2C22_2012,
    ]
    static let playStation5Class: Set<Int> = [
        0x0E6F_0209, 0x0F0D_0163, 0x0F0D_0184, 0x1532_100B, 0x1532_100C, 0x1532_1012,
        0x1532_1024, 0x1532_1026, 0x3285_0D18, 0x3285_0D19, 0x358A_0104, 0x358A_0304,
        // GP2040-CE PS5 mode and the Qanba Drone 2 in PS5 mode.
        0x2B81_0101, 0x2C22_2010,
    ]

    /// Sony's own row, for a PlayStation-class pad with no row of its own,
    /// when its descriptor has every control that row names.
    static func playStationClassMapping(vendorID: Int32, productID: Int32,
                                        elements: HIDDescriptorParser.SDLElements) -> Mapping? {
        let id = Int(vendorID) << 16 | Int(productID)
        let sony: Int32
        if playStation5Class.contains(id) { sony = 0x0CE6 }
        else if playStation4Class.contains(id) { sony = 0x05C4 }
        else { return nil }
        guard let row = mappings.first(where: { $0.vendorID == 0x054C && $0.productID == sony }) else { return nil }
        let borrowed = Mapping(vendorID: vendorID, productID: productID, version: 0, name: row.name, entries: row.entries)
        return fits(borrowed, elements) ? borrowed : nil
    }
}
