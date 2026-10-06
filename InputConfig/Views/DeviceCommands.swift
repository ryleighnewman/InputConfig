import SwiftUI
import IOKit.hid

/// InputConfig ▸ Devices: every external device on the bus, by transport,
/// with a checkmark on the ones InputConfig is reading. A device the app
/// did not pick up on its own can be connected from here; the choice is
/// remembered per device so it reconnects on its own.
struct DeviceCommands: Commands {
    let controllerService: GameControllerService

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Menu("Devices") {
                DevicesMenuContent(controllerService: controllerService)
            }
        }
    }
}

/// The Devices menu's items. Also in the menu bar item's popover, since an
/// app with its Dock icon off has no menu bar, and the Devices menu was then
/// out of reach.
struct DevicesMenuContent: View {
    @ObservedObject private var registry = HIDDeviceRegistry.shared
    @ObservedObject private var gamepads = RawHIDGamepadService.shared
    @ObservedObject private var controllers: GameControllerService

    init(controllerService: GameControllerService) {
        self.controllers = controllerService
    }

    var body: some View {
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
            MIDIInputService.shared.start(forceReconnect: true)
        }
    }

    // MARK: - HID

    @ViewBuilder
    private func transportSection(_ transport: HIDDeviceRegistry.Transport) -> some View {
        // A plain Text is a gray, unselectable heading in a menu. Section
        // would add its own separators above and below, doubling ours.
        let entries = registry.entries(on: transport)
        // USB pads that are not HID at all (Xbox 360 style XUSB, and Xbox
        // One or Series GIP before macOS 15) cannot be connected; they are
        // listed so the user learns why instead of seeing nothing.
        let unreadable = transport == .usb ? registry.unreadablePads : []
        Text(transport.rawValue)
        if entries.isEmpty && unreadable.isEmpty {
            Text("No \(transport.rawValue) devices")
        } else {
            ForEach(entries) { entry in
                deviceItem(entry)
            }
            ForEach(unreadable) { pad in
                Button("\(pad.name) (\(pad.reason))") { }
                    .disabled(true)
            }
        }
    }

    @ViewBuilder
    private func deviceItem(_ entry: HIDDeviceRegistry.Entry) -> some View {
        #if DEBUG
        if let fake = registry.debugFakeStates[entry.id] {
            switch fake {
            case .reading: Toggle(isOn: .constant(true)) { Text(entry.name) }
            case .listed: Text("\(entry.name) (\(entry.primaryKind.label))")
            case .needsInputMonitoring: Button("\(entry.name) (needs Input Monitoring)\u{2026}") { }
            }
        } else {
            realDeviceItem(entry)
        }
        #else
        realDeviceItem(entry)
        #endif
    }

    @ViewBuilder
    private func realDeviceItem(_ entry: HIDDeviceRegistry.Entry) -> some View {
        let device = registry.adoptableDevice(for: entry)
        let interfaces = registry.devices(for: entry)
        let reading = gamepads.isReading(anyOf: interfaces)
        // Reading `controllers.connectedControllers` keeps this item in step
        // with GameController attaching and detaching.
        let ownedBySystem = !reading && !controllers.connectedControllers.isEmpty
            && device.map { gamepads.isListedByGameController($0) } == true
        if entry.isSteamController {
            // Its own helper reads it as a controller; its keyboard and
            // mouse interfaces are only lizard mode.
            Text("\(entry.name) (read automatically as a Steam Controller)")
        } else if ownedBySystem {
            // GameController already reads it and it shows up as a
            // controller on its own. Connecting it here too would double
            // every input, so it is not switchable.
            Text("\(entry.name) (read by macOS GameController)")
        } else if !reading, let device, RawHIDGamepadService.blockedByInputMonitoring(device) {
            // Opening it needs Input Monitoring. InputConfig asks for it only
            // here, on this click: macOS lists an app in the Input Monitoring
            // pane only once it has asked, so the first click shows the
            // system's prompt; after that (or once it was turned down) it
            // opens the pane. The pad is read when InputConfig comes back to
            // the front.
            Button("\(entry.name) (needs Input Monitoring)\u{2026}") {
                if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeUnknown {
                    _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
                } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                    NSWorkspace.shared.open(url)
                }
            }
        } else if device != nil || reading {
            // Checkmark = InputConfig is reading this device. Toggling on
            // opens it by hand; off stops reading it and forgets it. Both
            // act on this device only, not every identical one.
            Toggle(isOn: Binding(
                get: { reading },
                set: { on in
                    if on {
                        if let device = registry.adoptableDevice(for: entry) {
                            gamepads.adopt(device)
                        }
                    } else {
                        gamepads.release(devices: registry.devices(for: entry))
                    }
                }
            )) {
                Text(entry.name)
            }
        } else {
            // Keyboards, mice, macro pads, pedals, and media remotes reach
            // presets through the keyboard and mouse input types, which need
            // no per-device connection, so they are listed but not
            // switchable. A composite mouse or keyboard lands here too: its
            // vendor channel is for configuration software, not input.
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
            MIDIInputService.shared.start(forceReconnect: true)
        }
    }
}
