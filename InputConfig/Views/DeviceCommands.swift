import SwiftUI
import IOKit.hid

/// InputConfig ▸ Devices: every external device on the bus, by transport,
/// with a checkmark on the ones InputConfig is reading. A device the app
/// did not pick up on its own can be connected from here; the choice is
/// remembered per vendor and product so it reconnects on its own.
struct DeviceCommands: Commands {
    @ObservedObject private var registry = HIDDeviceRegistry.shared
    @ObservedObject private var gamepads = RawHIDGamepadService.shared
    @ObservedObject private var controllers: GameControllerService

    init(controllerService: GameControllerService) {
        self.controllers = controllerService
    }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Menu("Devices") {
                transportSection(.bluetooth)
                Divider()
                transportSection(.usb)
                if !registry.entries(on: .other).isEmpty {
                    Divider()
                    transportSection(.other)
                }
                Divider()
                midiSection
                Divider()
                Button("Rescan Devices") {
                    registry.rescan()
                    controllers.refreshControllers()
                    MIDIInputService.shared.start()
                }
            }
        }
    }

    // MARK: - HID

    @ViewBuilder
    private func transportSection(_ transport: HIDDeviceRegistry.Transport) -> some View {
        // A plain Text is a grey, unselectable heading in a menu. Section
        // would add its own separators above and below, doubling ours.
        let entries = registry.entries(on: transport)
        Text(transport.rawValue)
        if entries.isEmpty {
            Text("No \(transport.rawValue) devices")
        } else {
            ForEach(entries) { entry in
                deviceItem(entry)
            }
        }
    }

    @ViewBuilder
    private func deviceItem(_ entry: HIDDeviceRegistry.Entry) -> some View {
        if entry.adoptableKind != nil {
            // Checkmark = InputConfig is reading it. Toggling on opens the
            // device by hand; off stops reading it and forgets it.
            Toggle(isOn: Binding(
                get: { gamepads.isReading(vendorID: entry.vendorID, productID: entry.productID) },
                set: { on in
                    if on {
                        if let device = registry.adoptableDevice(for: entry) {
                            gamepads.adopt(device)
                        }
                    } else {
                        gamepads.release(vendorID: entry.vendorID, productID: entry.productID)
                    }
                }
            )) {
                Text(entry.name)
            }
        } else {
            // Keyboards, mice, and media remotes reach presets through the
            // keyboard and mouse input types, which need no per-device
            // connection, so they are listed but not switchable.
            Text("\(entry.name) (\(entry.primaryKind.label))")
        }
    }

    // MARK: - MIDI

    @ViewBuilder
    private var midiSection: some View {
        let sources = MIDIInputService.shared.connectedDevices()
        Text("MIDI")
        if sources.isEmpty {
            Text("No MIDI sources")
        } else {
            // Every source is connected as soon as it appears; the list
            // shows what the app can hear.
            ForEach(sources) { source in
                Toggle(isOn: .constant(true)) { Text(source.name) }
            }
        }
        Button("Reconnect MIDI Sources") {
            MIDIInputService.shared.start()
        }
    }
}
