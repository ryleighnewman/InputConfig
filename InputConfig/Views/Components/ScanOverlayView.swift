import SwiftUI
import Combine
#if canImport(AppKit)
import AppKit
#endif

/// Overlay shown while scanning for joystick input
struct ScanOverlayView: View {
    @ObservedObject var controllerService: GameControllerService
    let onInputDetected: (InputEvent) -> Void
    let onCancel: () -> Void
    /// Touchpad family only: the press (button 13) and a tap look alike
    /// to a hand, so the overlay gathers everything the pad reported in a
    /// short window and hands the candidates over for the person to
    /// choose. When nil, the first event wins as for any other control.
    var onTouchpadChoice: (([InputEvent]) -> Void)? = nil
    @State private var touchpadCandidates: [InputEvent] = []

    @State private var timeRemaining: Int = 20
    @State private var detectedInput: InputEvent?
    @State private var timer: Timer?
    @State private var didCompleteScan = false
    /// A left click held back briefly: a Force Click begins as one, and
    /// scans as Deep Press if its second stage follows.
    @State private var pendingLeftClick: DispatchWorkItem?
    /// Local AppKit event monitor that lets the scan also pick up the Mac
    /// keyboard, trackpad, and mouse (not just the game controller). Local
    /// monitors deliver events that target this app while it is frontmost, so
    /// they need no Accessibility or Input Monitoring permission - the scan
    /// window is frontmost the whole time it is up.
    @State private var inputMonitor: Any?
    /// The Cancel button's frame in window-content coordinates. Mouse-downs
    /// inside it are NOT consumed as scan input; they reach the button, so
    /// the scan can be canceled without a keyboard. Everything else about
    /// the monitor's capture behavior is unchanged.
    @State private var cancelButtonFrame: CGRect = .zero

    var body: some View {
        ZStack {
            // Dimmed background. Mouse clicks land on the input monitor
            // (which consumes them as scan input), so no tap-catcher here.
            Color.black.opacity(0.5)
                .ignoresSafeArea()

            // Content card
            VStack(spacing: 20) {
                // Timer
                Text(ScanTiming.seconds > 0 ? "\(timeRemaining)" : "Waiting")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text("Press a control to map it")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text("Hold a button or move an axis on your controller, press a key, click, or scroll on your Mac, or play a note or twist a knob on a MIDI device. Taps on the Mac are picked from the input type menu, not scanned.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360)

                if let input = detectedInput {
                    Text("Detected: \(input.displayName)")
                        .font(.title3)
                        .bold()
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                }

                // A real Cancel button: the input monitor exempts clicks
                // inside its frame (tracked below in window coordinates), so
                // canceling never needs a keyboard. Esc still works too.
                HStack(spacing: 14) {
                    Button {
                        cleanup()
                        onCancel()
                    } label: {
                        Text("Cancel")
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 22)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(.white.opacity(0.18)))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .background(GeometryReader { geo in
                        Color.clear
                            .onAppear { cancelButtonFrame = geo.frame(in: .global) }
                            .onChange(of: geo.frame(in: .global)) { _, f in cancelButtonFrame = f }
                    })
                    .accessibilityLabel("Cancel scan")

                    HStack(spacing: 6) {
                        Text("esc")
                            .font(.caption.monospaced().weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(.white.opacity(0.18))
                            )
                        Text("also cancels")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(40)
            // Floating scan panel: real Liquid Glass at the card radius, with a
            // drop shadow (shadows are allowed on floating HUDs).
            .liquidGlass(in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
            .shadow(radius: 20)
            // Contain, not ignore: ignore removed the Cancel button from
            // VoiceOver, Voice Control and Switch Control, leaving no way
            // out without a keyboard.
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Scan for input. Press a control on your controller, a key, click, or scroll on your Mac, or a note or knob on a MIDI device, to map it.")
            .accessibilityHint("Use the Cancel scan button or press Escape to cancel.")
            .accessibilityAction(.escape) { cleanup(); onCancel() }
        }
        .onAppear {
            startTimer()
            controllerService.startScanning { event in
                completeScan(with: event)
            }
            // Taps on the Mac are deliberately NOT scanned: pressing a
            // controller button or a key jolts the MacBook enough to count
            // as a tap, which then won the scan over the control the user
            // meant. Tap the Mac is chosen from the input type menu instead
            // (with its tap-count picker), never by scanning.
            installInputMonitor()
            announce("Scanning for input. Press a control on your controller, a key, click, or scroll on your Mac, or a note or knob on a MIDI device, to map it. Press Escape to cancel.")
        }
        .onDisappear {
            cleanup()
        }
    }

    /// Watch for Mac keyboard / trackpad / mouse input during the scan, in
    /// addition to the game controller. Returns nil from the monitor to
    /// swallow the event (so a captured key does not also type into the app),
    /// except for Escape, which we let through so the Cancel shortcut works.
    private func installInputMonitor() {
        #if canImport(AppKit)
        guard inputMonitor == nil else { return }
        inputMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown,
                       // Modifier keys pressed on their own arrive as
                       // flagsChanged, never keyDown. Without this the scan
                       // could not see Shift, Control, Option, Command or
                       // Caps Lock at all, even though they are bindable.
                       .flagsChanged,
                       .leftMouseDown, .rightMouseDown,
                       .otherMouseDown, .scrollWheel, .pressure,
                       // Media / brightness keys are NSSystemDefined, not
                       // keyDown, so without this the scan could never see
                       // volume, mute, play, or brightness.
                       .systemDefined]
        ) { event in
            handleScanNSEvent(event) ? nil : event
        }
        #endif
    }

    #if canImport(AppKit)
    /// Map a captured AppKit event to an `InputEvent` and finish the scan.
    /// Returns true if the event was consumed.
    private func handleScanNSEvent(_ event: NSEvent) -> Bool {
        guard !didCompleteScan else { return false }
        if event.type == .flagsChanged {
            let vk = Int(event.keyCode)
            let f = event.modifierFlags
            // Fire on the PRESS edge only, so releasing a modifier does not
            // also complete the scan.
            let pressed: Bool
            switch vk {
            case 54, 55: pressed = f.contains(.command)
            case 56, 60: pressed = f.contains(.shift)
            case 58, 61: pressed = f.contains(.option)
            case 59, 62: pressed = f.contains(.control)
            // One flagsChanged per physical press; with Caps Lock on, the
            // press turns it off, which read as a release.
            case 57:     pressed = true
            case 63:     pressed = f.contains(.function)
            default:     return false
            }
            // With VoiceOver on, Control and Option are its own keys: moving
            // to Cancel scan bound Control to the row.
            // Caps Lock too, which VoiceOver can use as its modifier.
        if NSWorkspace.shared.isVoiceOverEnabled, [57, 58, 61, 59, 62].contains(vk) { return false }
            guard pressed,
                  let hid = ExternalInputDeviceService.hidUsage(forVirtualKeyCode: vk)
            else { return false }
            completeScan(with: InputEvent(
                type: .extKey, index: hid,
                extDeviceID: ExternalInputDeviceService.builtInKeyboardID))
            return true
        }
        if event.type == .systemDefined {
            guard let media = ExternalInputDeviceService.mediaKey(from: event),
                  media.isDown else { return false }
            completeScan(with: InputEvent(
                type: .extKey, index: media.hid,
                extDeviceID: ExternalInputDeviceService.builtInKeyboardID))
            return true
        }
        switch event.type {
        case .keyDown:
            if event.keyCode == 53 { // Escape cancels the scan
                cleanup()
                onCancel()
                return true
            }
            if event.isARepeat { return true }
            // A key with no name scans too, as "Key code N", so an unusual
            // keyboard's extra keys can be bound.
            let hid = ExternalInputDeviceService.inputCode(forVirtualKeyCode: Int(event.keyCode))
            completeScan(with: InputEvent(
                type: .extKey, index: hid,
                extDeviceID: ExternalInputDeviceService.builtInKeyboardID))
            return true
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // A click on the Cancel button is a click, not a scan input:
            // convert the event to content-view coordinates (NSHostingView
            // is flipped, matching SwiftUI's .global space) and let it
            // through to the button.
            if event.type == .leftMouseDown,
               let content = event.window?.contentView {
                let point = content.convert(event.locationInWindow, from: nil)
                if cancelButtonFrame.insetBy(dx: -6, dy: -6).contains(point) {
                    return false
                }
            }
            let button = event.type == .leftMouseDown ? 0
                : (event.type == .rightMouseDown ? 1 : event.buttonNumber)
            if event.type == .leftMouseDown {
                // Held for a moment so a Force Click can become Deep Press;
                // the click's own down event used to win every time.
                pendingLeftClick?.cancel()
                let work = DispatchWorkItem {
                    guard !didCompleteScan else { return }
                    completeScan(with: InputEvent(
                        type: .extMouse, index: 0,
                        extDeviceID: ExternalInputDeviceService.builtInMouseID,
                        extMouseKind: .button))
                }
                pendingLeftClick = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
                return true
            }
            completeScan(with: InputEvent(
                type: .extMouse, index: button,
                extDeviceID: ExternalInputDeviceService.builtInMouseID,
                extMouseKind: .button))
            return true
        case .scrollWheel:
            // A tilt wheel or thumb wheel scrolls sideways; record that as
            // Scroll X so it does not collide with the vertical wheel.
            // A trackpad gesture starts with a touch-down event that has no
            // movement, and ends with momentum; wait for the first real
            // movement so the direction is right.
            if (event.scrollingDeltaX == 0 && event.scrollingDeltaY == 0) || !event.momentumPhase.isEmpty {
                return true
            }
            let horizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            let delta = horizontal ? event.scrollingDeltaX : event.scrollingDeltaY
            let dir: AxisDirection = delta >= 0 ? .positive : .negative
            completeScan(with: InputEvent(
                type: .extMouse, index: 0, axisDirection: dir,
                extDeviceID: ExternalInputDeviceService.builtInMouseID,
                extMouseKind: horizontal ? .scrollX : .scrollY))
            return true
        case .pressure:
            // A deliberate Force Click (stage 2) scans as a Deep Press
            // input; the continuous pressure stream is ignored here so an
            // ordinary click does not get captured as pressure.
            if event.stage >= 2 {
                pendingLeftClick?.cancel()
                pendingLeftClick = nil
                completeScan(with: InputEvent(
                    type: .extMouse, index: 0,
                    extDeviceID: ExternalInputDeviceService.builtInMouseID,
                    extMouseKind: .deepPress))
            }
            return true
        default:
            return false
        }
    }
    #endif

    /// Single completion path for controller scan results.
    /// A touchpad gesture, or button 13 from a controller that has a
    /// touchpad. On a Steam Controller button 13 is the Steam button, and
    /// on a wheel or flight stick it is just the fourteenth button.
    private func isTouchpadFamily(_ e: InputEvent) -> Bool {
        // A Steam pad's tap is taken as scanned: the choice offers a
        // PlayStation touchpad's press and a two-finger tap it cannot make.
        if e.type == .touchpadGesture {
            if e.touchpadSurface == 1 { return false }
            if let slot = controllerService.lastScanSlot, controllerService.isSteamSlot(slot) { return false }
            if CACurrentMediaTime() - controllerService.steamGestureAt < 1 { return false }
            return true
        }
        guard e.type == .button, e.index == 13 else { return false }
        guard let slot = controllerService.lastScanSlot else { return false }
        // On the 2026 Steam Controller button 13 is Quick Access; its
        // trackpad clicks are their own buttons.
        if controllerService.rawHIDGamepadSlots[slot]?.profile?.layout == .steamController2026 { return false }
        // On the 2015 model it is the Steam button.
        if slot == controllerService.steamControllerSlot { return false }
        return controllerService.controllerDetails[slot]?.hasTouchpad == true
    }

    private func completeScan(with event: InputEvent) {
        if let choose = onTouchpadChoice, isTouchpadFamily(event) {
            // Collect for half a second: a click reports the press at once
            // and the finger lift a little later, so both can be shown.
            if didCompleteScan {
                if !touchpadCandidates.contains(where: { $0.serialized == event.serialized }) {
                    touchpadCandidates.append(event)
                }
                return
            }
            didCompleteScan = true
            touchpadCandidates = [event]
            detectedInput = event
            announce("Touchpad detected.")
            // A one-finger tap may be the first half of a double tap, which
            // is only known when the second finger lifts, up to ~650 ms on;
            // give it time. A press or two-finger tap needs only the lift.
            let window: Double = (event.type == .touchpadGesture && event.touchpadGestureKind == .oneFingerTap) ? 0.9 : 0.5
            DispatchQueue.main.asyncAfter(deadline: .now() + window) {
                cleanup()
                choose(touchpadCandidates)
            }
            return
        }
        guard !didCompleteScan else { return }
        didCompleteScan = true
        detectedInput = event
        announce("Detected \(event.displayName).")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            cleanup()
            onInputDetected(event)
        }
    }

    private func startTimer() {
        // How long Scan waits is a setting (Settings, General, Scan): a
        // fixed 20 seconds was too short for some hands. Zero waits until
        // the scan is canceled.
        let seconds = ScanTiming.seconds
        timeRemaining = seconds
        guard seconds > 0 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            if timeRemaining > 0 {
                timeRemaining -= 1
            } else {
                announce("Scan timed out. Nothing was set.")
                cleanup()
                onCancel()
            }
        }
    }

    /// Speak a message to VoiceOver. The scan overlay is otherwise silent, so a
    /// VoiceOver user gets no feedback that scanning started or that an input
    /// was detected; these announcements provide it.
    private func announce(_ message: String) {
        #if canImport(AppKit)
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        NSAccessibility.post(
            element: window,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
        #endif
    }

    private func cleanup() {
        timer?.invalidate()
        timer = nil
        controllerService.stopScanning()
        #if canImport(AppKit)
        if let m = inputMonitor { NSEvent.removeMonitor(m); inputMonitor = nil }
        #endif
    }
}

/// How long a Scan waits for an input, from Settings (20 seconds unless
/// changed; 0 waits until it is canceled). The Mac key and mouse button
/// scan keeps its short 5 seconds unless the setting was changed, since
/// keys and clicks in that window go to the scan.
enum ScanTiming {
    static let key = "InputConfig.scanSeconds"
    static var seconds: Int {
        let stored = UserDefaults.standard.object(forKey: key) as? Int ?? 20
        return max(0, min(600, stored))
    }
    /// Never unlimited: Escape is a key this scan can bind, so it cannot
    /// cancel it; "until canceled" waits a minute here.
    static var macInputSeconds: Int {
        UserDefaults.standard.object(forKey: key) == nil ? 5 : (seconds == 0 ? 60 : seconds)
    }
}
