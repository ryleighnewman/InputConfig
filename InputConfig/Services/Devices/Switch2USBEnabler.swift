import Foundation
import IOKit
import IOUSBHost

/// Switches a Switch 2 Pro Controller (or GameCube controller for Switch 2)
/// on over USB.
///
/// macOS has no support for Nintendo's Switch 2 controllers. Over a USB-C
/// cable the Pro Controller 2 does show up as a HID gamepad, but it sends
/// nothing until the host sends it a set of start-up commands on a second,
/// vendor-specific USB interface. This sends them; from then on the pad
/// streams ordinary HID input reports, which `RawHIDGamepadService` reads
/// and `HIDReportDecoder.decodeSwitch2Pro` turns into buttons and sticks.
///
/// Only Apple's IOUSBHost framework is used, on the vendor interface alone
/// (interface 1, bulk endpoints), which no macOS driver claims, so the app
/// needs nothing beyond the sandbox's USB entitlement it already has. The
/// HID interface stays with the system's HID driver.
///
/// The command sequence and the report layout come from the community's
/// reverse engineering of the controller, as published in
/// github.com/caqlayan/procon2-mac, which credits
/// ikz87/NSW2-controller-enabler and Nohzockt/Switch2-Controllers. The
/// GameCube controller's report format and layout follow SDL's
/// SDL_hidapi_switch2.c (zlib license). procon2-mac's license:
///
/// MIT License
///
/// Copyright (c) 2026 Arda Caglayan Ercan
///
/// Permission is hereby granted, free of charge, to any person obtaining a copy
/// of this software and associated documentation files (the "Software"), to deal
/// in the Software without restriction, including without limitation the rights
/// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
/// copies of the Software, and to permit persons to whom the Software is
/// furnished to do so, subject to the following conditions:
///
/// The above copyright notice and this permission notice shall be included in all
/// copies or substantial portions of the Software.
///
/// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
/// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
/// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
/// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
/// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
/// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
/// SOFTWARE.
final class Switch2USBEnabler: @unchecked Sendable {
    static let shared = Switch2USBEnabler()

    static let vendorID = 0x057E
    /// Switch 2 Pro Controller.
    static let proControllerProductID = 0x2069
    /// Nintendo Switch Online GameCube controller for Switch 2. It takes the
    /// same USB start-up sequence on the same vendor interface, except that
    /// it is asked for input report 0x05, the only full-state report it
    /// has (report 0x09 is the Pro Controller's), as SDL's Switch 2 driver
    /// asks; `decodeSwitch2GameCube` reads it with SDL's offsets.
    static let gameCubeProductID = 0x2073
    /// Every product this enabler starts.
    static let productIDs = [proControllerProductID, gameCubeProductID]
    static let vendorInterfaceNumber = 1

    /// The start-up sequence, sent in order on the bulk OUT pipe of the
    /// vendor interface. Framing: command, 0x91, 0x00, sub-command, 0x00,
    /// payload length, 0x00, 0x00, then the payload.
    static let initCommands: [[UInt8]] = [
        // Start reporting.
        [0x03, 0x91, 0x00, 0x0D, 0x00, 0x08, 0x00, 0x00, 0x01, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
        [0x07, 0x91, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00],
        [0x16, 0x91, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00],
        // Player lights off.
        [0x09, 0x91, 0x00, 0x07, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
        // Motion sensors on.
        [0x0C, 0x91, 0x00, 0x02, 0x00, 0x04, 0x00, 0x00, 0x27, 0x00, 0x00, 0x00],
        [0x11, 0x91, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00],
        [0x0A, 0x91, 0x00, 0x08, 0x00, 0x14, 0x00, 0x00, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x35, 0x00, 0x46, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
        [0x0C, 0x91, 0x00, 0x04, 0x00, 0x04, 0x00, 0x00, 0x27, 0x00, 0x00, 0x00],
        // Report format: the one `decodeSwitch2Pro` reads (input report
        // 0x09). `commands(for:)` asks the GameCube controller for 0x05.
        [0x03, 0x91, 0x00, 0x0A, 0x00, 0x04, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00],
        [0x10, 0x91, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00],
        [0x01, 0x91, 0x00, 0x0C, 0x00, 0x00, 0x00, 0x00],
        // A full 8-byte header (it was sent 7 bytes long).
        [0x03, 0x91, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00],
        [0x0A, 0x91, 0x00, 0x02, 0x00, 0x04, 0x00, 0x00, 0x03, 0x00, 0x00],
        // Player light 1 on, so the controller shows it is connected.
        [0x09, 0x91, 0x00, 0x07, 0x00, 0x08, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
    ]

    /// The start-up sequence for one product: the GameCube controller is
    /// asked for its report 0x05 instead of 0x09.
    static func commands(for product: Int) -> [[UInt8]] {
        guard product == gameCubeProductID else { return initCommands }
        return initCommands.map { command in
            guard command.count == 12, command[0] == 0x03, command[3] == 0x0A else { return command }
            var c = command
            c[8] = 0x05
            return c
        }
    }

    private let queue = DispatchQueue(label: "com.inputconfig.switch2-usb", qos: .userInitiated)
    private let lock = NSLock()
    private var inFlight = false

    private init() {}

    /// Send the start-up commands to every Switch 2 Pro Controller (and
    /// GameCube controller for Switch 2) on USB.
    /// Called when its HID interface appears. Runs off the main thread (the
    /// sequence takes about a second); tries a few times, since the vendor
    /// interface can register a moment after the HID one.
    private var rerunPending = false

    func enableConnectedControllers() {
        lock.lock()
        // A pass is running: it may have listed the controllers before this
        // one appeared, so it runs once more when it is done instead of the
        // new controller being dropped until it is plugged in again.
        if inFlight { rerunPending = true; lock.unlock(); return }
        inFlight = true
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            defer {
                self.lock.lock()
                self.inFlight = false
                let again = self.rerunPending
                self.rerunPending = false
                self.lock.unlock()
                if again { self.enableConnectedControllers() }
            }
            for attempt in 0..<4 {
                if attempt > 0 { Thread.sleep(forTimeInterval: 0.5) }
                let services = self.vendorInterfaces()
                if services.isEmpty { continue }
                var anyStarted = false
                for service in services {
                    defer { IOObjectRelease(service) }
                    do {
                        try self.sendStartSequence(to: service)
                        anyStarted = true
                    } catch {
                        ActivityLog.shared.warning("Devices", "Switch 2 controller: could not start it over USB (\(error.localizedDescription))")
                    }
                }
                if anyStarted {
                    ActivityLog.shared.info("Devices", "Switch 2 controller started over USB")
                    return
                }
            }
        }
    }

    /// The vendor interface of each connected Switch 2 controller this
    /// enabler starts. Matched on its properties with IOPropertyMatch, which
    /// is what matches from a user process (Apple's helper puts the IDs where
    /// they no longer do).
    private func vendorInterfaces() -> [io_service_t] {
        var found: [io_service_t] = []
        for productID in Self.productIDs {
            let matching = IOServiceMatching("IOUSBHostInterface") as NSMutableDictionary
            matching["IOPropertyMatch"] = [
                "idVendor": Self.vendorID,
                "idProduct": productID,
                "bInterfaceNumber": Self.vendorInterfaceNumber,
            ]
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { continue }
            while case let service = IOIteratorNext(iterator), service != 0 {
                found.append(service)
            }
            IOObjectRelease(iterator)
        }
        return found
    }

    private enum StartError: LocalizedError {
        case noBulkOut
        var errorDescription: String? { "the controller's command endpoint was not found" }
    }

    private func sendStartSequence(to service: io_service_t) throws {
        let interface = try IOUSBHostInterface(__ioService: service, options: [], queue: nil, interestHandler: nil)
        defer { interface.destroy() }
        let (outAddress, inAddress) = bulkEndpoints(of: interface)
        guard let outAddress else { throw StartError.noBulkOut }
        let outPipe = try interface.copyPipe(withAddress: Int(outAddress))
        let inPipe = inAddress.flatMap { try? interface.copyPipe(withAddress: Int($0)) }
        let product = (IORegistryEntryCreateCFProperty(service, "idProduct" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber)?.intValue ?? Self.proControllerProductID
        for command in Self.commands(for: product) {
            let data = NSMutableData(bytes: command, length: command.count)
            var sent: UInt = 0
            try outPipe.__sendIORequest(with: data, bytesTransferred: &sent, completionTimeout: 1.0)
            // Read the reply and drop it, so the next command does not
            // queue up behind it.
            if let inPipe, let reply = NSMutableData(length: 64) {
                var got: UInt = 0
                try? inPipe.__sendIORequest(with: reply, bytesTransferred: &got, completionTimeout: 0.1)
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    /// The bulk endpoints of the vendor interface, found by walking the
    /// configuration descriptor: an interface descriptor (type 4) opens a
    /// section, endpoint descriptors (type 5) follow it.
    private func bulkEndpoints(of interface: IOUSBHostInterface) -> (out: UInt8?, in: UInt8?) {
        let config = interface.configurationDescriptor
        let total = Int(config.pointee.wTotalLength)
        let bytes = UnsafeRawBufferPointer(start: UnsafeRawPointer(config), count: total)
        var out: UInt8?
        var inbound: UInt8?
        var inVendorInterface = false
        var i = 0
        while i + 2 <= total {
            let length = Int(bytes[i])
            if length < 2 { break }
            let type = bytes[i + 1]
            if type == 0x04, i + 3 <= total {
                inVendorInterface = bytes[i + 2] == UInt8(Self.vendorInterfaceNumber)
            } else if type == 0x05, inVendorInterface, i + 4 <= total {
                let address = bytes[i + 2]
                if bytes[i + 3] & 0x03 == 0x02 {
                    if address & 0x80 != 0 { inbound = address } else { out = address }
                }
            }
            i += length
        }
        return (out, inbound)
    }
}
