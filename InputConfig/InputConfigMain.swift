import SwiftUI
import AppKit
import os

@MainActor
final class AppState: ObservableObject {
    let presetStore = PresetStore()
    let controllerService = GameControllerService()
    let eightBitDoDetector = EightBitDoDetector()
    lazy var mappingEngine = MappingEngine(controllerService: controllerService)
    let crashRecovery = CrashRecoveryService.shared
    let freezeWatchdog = FreezeWatchdogService.shared
    let externalInput = ExternalInputDeviceService.shared
    let accessibility = AccessibilityPermissionService.shared
    /// Created at launch, not when the tip jar first opens: its StoreKit
    /// transaction listener has to run all the time to finish purchases
    /// approved later (Ask to Buy) and renewals.
    let tipJar = TipJarService.shared

    init() {
        // Registered (volatile) defaults, applied whenever a key is unset.
        // Polling defaults to the power-source auto-switch mode so a fresh
        // install already adapts its rate to AC vs battery; the engine reads
        // these keys directly, so registering here (not just in @AppStorage)
        // is what makes "auto" the real default before Settings is ever opened.
        // NOTE: deliberately NOT registering pollHzOnAC/pollHzOnBattery/pollHz.
        // MappingEngine falls back to the user's chosen pollHz when the
        // per-source keys are unset; registering 120 here made that fallback
        // dead and silently downgraded existing users who had picked a
        // higher rate before this update.
        UserDefaults.standard.register(defaults: [
            "InputConfig.autoPollHzByPower": true,
            "InputConfig.showDockIcon": true,
        ])
        // The app is designed dark-first; in light mode the frosted-glass
        // surfaces wash out to near-white. Force the dark appearance app-wide
        // (windows, sheets, menus, popovers) regardless of the system setting.
        // Go through NSApplication.shared, never the NSApp global. NSApp is an
        // implicitly unwrapped NSApplication! that stays nil until the shared
        // instance exists, and on macOS 14 this initializer runs while SwiftUI
        // builds the scene graph straight from main, before that happens - so
        // touching NSApp here trapped at launch for every Sonoma user.
        // NSApplication.shared is non-optional and creates the instance.
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        AppState.enforceSingleInstance()
        // Boot the freeze watchdog before any heavy work runs - this is the
        // earliest place the main actor is alive, so we get the most
        // accurate "main thread responsiveness" baseline.
        _ = freezeWatchdog
        // Boot the external HID enumeration too, so keyboards / mice are
        // already detected by the time the user opens Settings → Devices
        // or the binding editor's external-source picker.
        _ = externalInput
        // Boot the Accessibility-permission watcher so its trust state is
        // known at launch and refreshes when we return to the foreground.
        _ = accessibility
        // Register the global "toggle most recent preset" hotkey if the user
        // turned it on in Settings, so it works app-wide from launch.
        // When another app owns the chord, the setting goes off, so Settings
        // does not show a shortcut that does nothing.
        if UserDefaults.standard.bool(forKey: GlobalHotKeyService.enabledDefaultsKey),
           !GlobalHotKeyService.shared.enable() {
            UserDefaults.standard.set(false, forKey: GlobalHotKeyService.enabledDefaultsKey)
            ActivityLog.shared.warning("Shortcuts", "\(GlobalHotKeyService.shared.shortcutDescription) is taken by another app, so the preset shortcut was turned off")
        }
        // The emergency stop is on by default and registered before anything
        // can activate a preset. A kill switch you have to enable first is
        // not a kill switch.
        EmergencyStopService.registerDefaults()
        // A kill switch that silently failed to register is worse than none,
        // because you believe you have one. Carbon hot keys are exclusive per
        // process, so another app (or a second copy of this one) holding the
        // same chord makes this fail quietly.
        if !EmergencyStopService.shared.refreshRegistration() {
            AppState.warnEmergencyStopUnavailable()
        }
        // Keys a crashed run left held are let go first. If the user
        // hasn't opted out of session restore, the preset that was running
        // is offered again below, deferred to the next run-loop tick so
        // PresetStore has finished its disk load.
        if crashRecovery.previousRunEndedWithPresetRunning {
            InputSimulator.shared.releaseLeftoversFromLastRun()
        }
        // SIGTERM (kill, some installers and updaters) skipped every release;
        // let go of everything first, then exit as the signal asked.
        signal(SIGTERM, SIG_IGN)
        // Received off the main thread, so a hung main thread cannot keep
        // the app alive against kill the way it would with the handler on
        // main: SIGTERM's own default action ended a hung 1.5.
        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .userInitiated))
        termSource.setEventHandler(handler: Self.terminationHandler())
        termSource.resume()
        Self.terminationSignalSource = termSource
        // Launch wiring that must not wait for the main window. Closing the
        // window no longer quits, so a later launch can restore no window at
        // all, and all of this hung off the window's onAppear: the app ran
        // with no menu bar item, no auto-switch and no preset migrations.
        // Each call is safe to repeat when the window appears.
        DispatchQueue.main.async { [presetStore, mappingEngine, controllerService] in
            presetStore.reseedExamplePresets()
            presetStore.restoreBuiltInsIfLibraryLost()
            MenuBarController.shared.install(presetStore: presetStore,
                                             mappingEngine: mappingEngine,
                                             controllerService: controllerService)
            FrontmostAppWatcher.shared.install(presetStore: presetStore, mappingEngine: mappingEngine)
            LegacyRowCheck.shared.install(store: presetStore, service: controllerService)
            if !UserDefaults.standard.bool(forKey: "InputConfig.showDockIcon") {
                NSApplication.shared.setActivationPolicy(.accessory)
            }
        }
        // A run loop block, not a main-queue one: a modal started inside a
        // main-queue block stops the main queue for as long as it is up, so
        // for 20 s nothing else ran (the freeze watchdog reported a freeze,
        // and the controller services started only after it closed).
        RunLoop.main.perform(inModes: [.default]) { [presetStore, crashRecovery, mappingEngine] in
          MainActor.assumeIsolated {
            guard let id = crashRecovery.consumeRestoreTarget() else { return }
            if let preset = presetStore.presets.first(where: { $0.id == id }) {
                // Ask before starting it again. Starting it silently brought
                // back a runaway preset the user had just force quit to stop.
                // Start is the default button, so Return restarts it.
                // Someone who runs the Mac from a controller cannot answer an
                // alert with the preset off, so with no answer it starts again
                // by itself after 20 seconds, as 1.5 did at once.
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "InputConfig quit while \u{201C}\(preset.name)\u{201D} was running"
                alert.informativeText = "Start it again? It starts again by itself in 20 seconds unless you choose Not Now."
                alert.addButton(withTitle: "Start")
                alert.addButton(withTitle: "Not Now")
                // abortModal, not stopModal: a timer is not an event, and
                // a stop request is only noticed once an event arrives,
                // which a controller never sends. Abort ends the loop
                // straight away and counts as Start.
                let timeout = Timer(timeInterval: 20, repeats: false) { _ in
                    NSApp.abortModal()
                }
                RunLoop.main.add(timeout, forMode: .modalPanel)
                // An Emergency Stop during the countdown counts as Not Now:
                // the preset it stopped started by itself 20 seconds later.
                final class Flag { var stopped = false }
                let flag = Flag()
                let stopObserver = NotificationCenter.default.addObserver(
                    forName: EmergencyStopService.stoppedNotification, object: nil, queue: nil
                ) { _ in
                    flag.stopped = true
                    NSApp.abortModal()
                }
                let answer = alert.runModal()
                timeout.invalidate()
                NotificationCenter.default.removeObserver(stopObserver)
                if !flag.stopped, answer == .alertFirstButtonReturn || answer == .abort {
                    ActivityLog.shared.warning("Recovery", "InputConfig ended unexpectedly last time; started \(preset.name) again")
                    // In the background: no second, untimed alert about
                    // Accessibility can follow the timed one.
                    MenuBarController.activate(preset, store: presetStore, engine: mappingEngine, background: true)
                } else {
                    ActivityLog.shared.info("Recovery", "InputConfig ended unexpectedly last time; left \(preset.name) off")
                }
            }
          }
        }

        // Silence any controller left buzzing by an earlier run. A pad holds
        // its last motor level indefinitely, so if a previous session ended
        // mid-pulse the rumble is still going when this one starts.
        InProcessLightWriter.shared.stopMotors()

        // Graceful shutdown. When the user quits, NSApplication posts
        // willTerminate one main-runloop tick before exit; observing it
        // here gives us a deterministic window to release controller
        // state, stop the engine (which flushes pressed keys / mouse
        // buttons via releaseAll), close light-bar helpers, and persist
        // any pending stats. Without this, the process exits with
        // synthesized inputs still "down" in the OS event tap, so a
        // turbo'd or held key carries past the app.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.gracefulShutdown()
        }
    }

    /// Show or hide the app's Dock icon (and, with it, the top menu bar and
    /// Cmd-Tab entry). Hiding it makes InputConfig a menu bar-only agent app.
    /// The caller guarantees at least one of {Dock icon, menu bar icon} stays
    /// visible so the app is always reachable.
    static func applyDockIconVisible(_ visible: Bool) {
        NSApp.setActivationPolicy(visible ? .regular : .accessory)
        // Re-activate on BOTH paths: switching to .accessory otherwise drops
        // the app behind whatever is next, which reads as the window
        // vanishing the moment the toggle is flipped. One runloop turn lets
        // the policy change land first.
        DispatchQueue.main.async {
            NSApp.activate()
        }
    }

    /// Refuse to run beside another copy of ourselves.
    ///
    /// Two instances each run their own MappingEngine poll loop and both post
    /// to the same `.cghidEventTap`, so controls the visible preset never
    /// bound appear to fire, output becomes the union of two presets, and
    /// quitting one leaves the other running. Worse, the emergency stop uses a
    /// Carbon hot key, which is exclusive per process: the SECOND copy's kill
    /// switch silently fails to register, so the runaway instance is precisely
    /// the one that cannot be stopped. Several launchable copies exist on a
    /// developer machine (App Store build, dev build, DerivedData), which
    /// makes this easy to hit by accident.
    /// Kept alive for the app's lifetime; see the SIGTERM handler in init.
    /// The SIGTERM work, built outside the main actor: the signal arrives
    /// on a background queue, and a closure formed in the main-actor init
    /// counted as main-actor code there, so Swift's isolation check stopped
    /// the app with a crash instead of the clean exit.
    nonisolated private static func terminationHandler() -> @Sendable () -> Void {
        return {
            let mainStarted = OSAllocatedUnfairLock(initialState: false)
            DispatchQueue.main.async {
                mainStarted.withLock { $0 = true }
                InputSimulator.shared.releaseAll()
                // A deliberate quit, not a crash: the usual will-terminate
                // work runs (the crash record is marked clean) before exiting.
                MainActor.assumeIsolated {
                    NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApplication.shared)
                }
                exit(0)
            }
            // Main has not even started the shutdown within 3 seconds, so
            // it is hung: let go of what is held from here and exit anyway.
            // Once main has started, its own release and shutdown are left
            // alone (the key sets are main-thread only), with a last-resort
            // exit if it never finishes. _exit, so no exit-time work races
            // the main thread.
            Thread.sleep(forTimeInterval: 3)
            if !mainStarted.withLock({ $0 }) {
                InputSimulator.shared.releaseAll()
                _exit(0)
            }
            Thread.sleep(forTimeInterval: 7)
            _exit(0)
        }
    }

    private static var terminationSignalSource: DispatchSourceSignal?

    static func enforceSingleInstance() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleID && $0.processIdentifier != me
        }
        guard let other = others.first else { return }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "InputConfig is already running"
        alert.informativeText = "Another copy of InputConfig is already open, and two copies fight over the same keyboard and mouse: controls you never mapped can appear to fire, and the emergency stop only works in one of them.\n\nThis copy will quit. Use the one already running."
        alert.addButton(withTitle: "Quit This Copy")
        alert.addButton(withTitle: "Show the Other Copy")
        if alert.runModal() == .alertSecondButtonReturn {
            // Closing the window keeps the app running in the menu bar, so
            // the other copy may have no window to bring forward. Opening
            // it through Launch Services sends it a reopen, which shows
            // its main window.
            if let url = other.bundleURL {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                let done = DispatchSemaphore(value: 0)
                NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in done.signal() }
                _ = done.wait(timeout: .now() + 3)
            } else {
                other.activate(options: [.activateAllWindows])
            }
        }
        // exit, not terminate: this runs inside AppState's init, before the
        // app is running, where terminate can return and let this copy go
        // on to fail the shared shortcut's registration and switch it off
        // in the settings both copies share. Nothing has started yet, so
        // there is nothing to let go of.
        exit(0)
    }

    /// Say plainly when the panic chord could not be claimed, instead of only
    /// writing a line to the log nobody reads.
    static func warnEmergencyStopUnavailable() {
        let service = EmergencyStopService.shared
        let chord = service.spec.displayString
        // Once per conflicting chord, not on every launch.
        let warnedKey = "InputConfig.emergencyStopWarnedChord"
        guard UserDefaults.standard.string(forKey: warnedKey) != chord else { return }
        UserDefaults.standard.set(chord, forKey: warnedKey)
        // What actually still works, from the live settings: the controller
        // hold and the menu bar icon can each be turned off.
        var ways: [String] = []
        if service.controllerHoldEnabled {
            let name = BindingRowView.standardButtonLabels(for: nil)
                .first(where: { $0.index == service.controllerButton })?.label ?? "Button \(service.controllerButton)"
            ways.append("holding \(name) on the controller for \(String(format: "%g", service.holdSeconds)) seconds")
        }
        if (UserDefaults.standard.object(forKey: MenuBarController.defaultsKey) as? Bool) ?? true {
            ways.append("using the InputConfig menu bar icon")
        }
        let fallback = ways.isEmpty
            ? "Turn on the controller hold in Settings so there is still a way to stop a preset."
            : "You can still stop everything by " + ways.joined(separator: ", or by ") + "."
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The emergency stop shortcut is not available"
        alert.informativeText = "Another app has already claimed \(chord), so InputConfig could not register it. That keyboard shortcut will not stop a running preset.\n\n\(fallback) Choose a different shortcut in Settings to restore it."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Tear down outputs in priority order. Called on willTerminate.
    /// Each step is best-effort - a failure in one shouldn't block
    /// the others. Wraps in a fileprivate method so it's available
    /// from the observer closure above.
    fileprivate func gracefulShutdown() {
        // 0. Flush stats synchronously so the session's counters and time
        //    rollup are on disk before the process exits. The periodic flush
        //    writes asynchronously and may not complete at Cmd+Q.
        StatsService.shared.flushSynchronously()
        // 1. Stop the mapping engine. Releases held keys / mouse
        //    buttons / MIDI notes via the engine's stop() path.
        mappingEngine.stop()
        // The Mac's accelerometer too, whoever still holds it (the editor
        // or the visualizer's tap panel), so its report interval is put back.
        ChassisTapService.shared.stop()
        // 2. Deactivate the active preset record so a re-launch
        //    doesn't think a preset was already running.
        presetStore.deactivateAll()
        // Preset files are written on a background queue; wait for any
        // write still queued (a Save in the quit alert) to reach the disk.
        PresetStore.flushPendingWrites()
        // 3. Belt-and-suspenders: drop everything the InputSimulator
        //    still considers pressed. Catches any synthesized keys
        //    the engine didn't track (e.g. macro mid-flight).
        InputSimulator.shared.releaseAll()
        // 4. Close the system-wide CGEventTap + IOHIDManager. Without
        //    this the mach port + runloop source linger past process
        //    exit, blocking a re-launch from grabbing a fresh tap
        //    until the kernel garbage-collects (can take 30+ seconds
        //    on a busy session).
        externalInput.teardownForTermination()
        // 5. Force the system cursor visible. If a preset had
        //    `hideCursorWhileActive` on and the user quit mid-session,
        //    we'd otherwise leave the cursor hidden until login - which
        //    looks indistinguishable from a frozen Mac.
        CursorGuardService.shared.forceShowCursor()
        // 6. Stop every haptic pattern and shut the engines down. An engine
        //    torn down by process exit instead of by stop() can leave the
        //    controller buzzing after the app is gone.
        FeedbackService.shared.clearHapticEngines()
        // 7. Let go of the controllers with their motors at zero. A pad holds
        //    the last motor level it was sent, so quitting mid-buzz would
        //    otherwise leave it rumbling until it is unplugged.
        InProcessLightWriter.shared.shutdownSynchronously()
    }
}

/// The app's own controller artwork (the same glyph as the menu bar icon)
/// as a tintable inline icon. Drop-in replacement for the "gamecontroller"
/// SF Symbol so the custom artwork shows everywhere the app pictures a
/// controller. `height` approximates the point size of the symbol replaced.
struct ControllerGlyph: View {
    var height: CGFloat = 13

    var body: some View {
        Image("ControllerGlyph")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(height: height)
    }
}

/// Icon-by-name renderer: game-controller SF Symbol names render the
/// custom ControllerGlyph artwork; every other name falls through to
/// Image(systemName:). `glyphHeight` sizes only the custom glyph - SF
/// Symbols keep sizing through .font at the call site as usual.
struct IconView: View {
    let name: String
    var glyphHeight: CGFloat = 13

    var body: some View {
        if name.hasPrefix("gamecontroller") {
            ControllerGlyph(height: glyphHeight)
        } else {
            Image(systemName: name)
        }
    }
}

/// Menu-safe controller icon. macOS menus (Menu / Picker `.menu`) ignore the
/// resize hint on a custom image and fall back to the asset's intrinsic size,
/// so a menu item must use a dedicated small-intrinsic asset rather than the
/// resizable `ControllerGlyph` (which would render at the full viewBox size).
/// The menu bar and every inline use keep the plain `ControllerGlyph` asset,
/// so the two never fight over one intrinsic size. Non-controller names fall
/// through to the SF Symbol.
struct MenuIcon: View {
    let name: String
    var body: some View {
        if name.hasPrefix("gamecontroller") {
            Image("ControllerGlyphMenu").renderingMode(.template)
        } else {
            Image(systemName: name)
        }
    }
}

/// Behind-window vibrancy that gives the app's windows the classic frosted,
/// translucent macOS look, and makes the host window non-opaque so the blur
/// reaches the desktop behind it. Reused by every window in the app so they
/// all share the same treatment.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    /// Optional solid tint laid over the vibrancy. The behind-window blur can
    /// read too transparent on a busy desktop; a tint (30% of the window
    /// background color on the main window) firms the surface up without
    /// going opaque.
    /// 0 = pure vibrancy (the default for sheets/secondary windows).
    var tintOpacity: Double = 0

    private static let tintViewID = NSUserInterfaceItemIdentifier("VEBTint")

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
        if tintOpacity > 0 {
            let tint = NSView()
            tint.identifier = Self.tintViewID
            tint.wantsLayer = true
            tint.layer?.backgroundColor = NSColor.windowBackgroundColor
                .withAlphaComponent(tintOpacity).cgColor
            tint.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(tint)
            NSLayoutConstraint.activate([
                tint.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                tint.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                tint.topAnchor.constraint(equalTo: view.topAnchor),
                tint.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }
        // Once the view is in a window, drop the window's opacity so the
        // behind-window blur samples the desktop rather than a solid fill.
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
        }
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        // Re-resolve the tint against the current appearance so it tracks
        // light/dark switches (a stored CGColor would not).
        if tintOpacity > 0,
           let tint = nsView.subviews.first(where: { $0.identifier == Self.tintViewID }) {
            nsView.effectiveAppearance.performAsCurrentDrawingAppearance {
                tint.layer?.backgroundColor = NSColor.windowBackgroundColor
                    .withAlphaComponent(tintOpacity).cgColor
            }
        }
        // updateNSView runs after the view is mounted, so the window now
        // exists. makeNSView's early attempt saw a nil window, which is why
        // the translucency never took. Reassert it here.
        DispatchQueue.main.async { [weak nsView] in
            guard let window = nsView?.window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
        }
    }
}

/// App-level accessibility preferences, settable in Settings > General >
/// Accessibility. These layer ON TOP of the system settings: the system's
/// Reduce Motion / Reduce Transparency are always honored, and these let the
/// user opt in per-app without changing their whole Mac.
enum AppA11y {
    static var reduceMotion: Bool {
        UserDefaults.standard.bool(forKey: "InputConfig.a11y.reduceMotion")
    }
    static var reduceTransparency: Bool {
        UserDefaults.standard.bool(forKey: "InputConfig.a11y.reduceTransparency")
    }

    /// Map the stored text-size step to a font scale. Dynamic Type sizes do
    /// nothing on macOS (the text styles are fixed there), so Text Size is a
    /// plain multiplier applied to every font in the app; see FontScaler.
    static func scale(forStep step: Int) -> CGFloat {
        switch step {
        case -1: return 0.9
        case 1: return 1.15
        case 2: return 1.3
        case 3: return 1.5
        default: return 1
        }
    }
}

private struct AppTextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    /// Text Size from Settings, as a multiplier on every font.
    var appTextScale: CGFloat {
        get { self[AppTextScaleKey.self] }
        set { self[AppTextScaleKey.self] = newValue }
    }
}

private struct ScaledFontModifier: ViewModifier {
    let font: Font
    @Environment(\.appTextScale) private var scale
    func body(content: Content) -> some View {
        content.environment(\.font, FontScaler.scale(font, by: scale))
    }
}

extension View {
    /// Every `.font(...)` in the app resolves here rather than SwiftUI's
    /// (a non-optional parameter wins overload resolution), so Text Size
    /// in Settings reaches all of them. Same effect as SwiftUI's: it sets
    /// the font in the environment, scaled.
    nonisolated func font(_ font: Font) -> some View {
        modifier(ScaledFontModifier(font: font))
    }
}

/// Scales a SwiftUI `Font` by a factor, which is what Text Size in Settings
/// needs and what `dynamicTypeSize` does not do on macOS (text styles are
/// fixed there). Walks the font's private structure with `Mirror`: a text
/// style becomes a system font of the style's size times the factor, a
/// system font scales its size, and weight / bold / italic / monospaced
/// modifiers are re-applied around the scaled base. Anything unrecognized
/// comes back unchanged, so an OS change can only cost the scaling, never
/// the text.
enum FontScaler {
    /// Resolved fonts per scale factor. The reflection below allocates and
    /// walks private structure; done per font per body pass inside 30 and
    /// 60 Hz timelines it was a measurable cost whenever Text Size was not
    /// the default. The app uses a few dozen distinct fonts, so the cache
    /// stays tiny. Fonts are Hashable, and the main thread is the only
    /// caller.
    nonisolated(unsafe) private static var cache: [CGFloat: [Font: Font]] = [:]

    static func scale(_ font: Font, by factor: CGFloat) -> Font {
        guard factor != 1 else { return font }
        if let hit = cache[factor]?[font] { return hit }
        let result = scaled(font, factor) ?? font
        cache[factor, default: [:]][font] = result
        return result
    }

    /// macOS sizes for each text style (Human Interface Guidelines).
    private static func size(forStyle style: String) -> CGFloat? {
        switch style {
        case "largeTitle": return 26
        case "title": return 22
        case "title2": return 17
        case "title3": return 15
        case "headline": return 13
        case "body": return 13
        case "callout": return 12
        case "subheadline": return 11
        case "footnote": return 10
        case "caption": return 10
        case "caption2": return 10
        default: return nil
        }
    }

    private static func design(from any: Any?) -> Font.Design {
        guard let any else { return .default }
        switch String(describing: any) {
        case "rounded": return .rounded
        case "monospaced": return .monospaced
        case "serif": return .serif
        default: return .default
        }
    }

    private static func weight(from any: Any?) -> Font.Weight? {
        guard let any else { return nil }
        guard let v = Mirror(reflecting: any).children.first(where: { $0.label == "value" })?.value as? CGFloat else { return nil }
        let table: [(CGFloat, Font.Weight)] = [(-0.8, .ultraLight), (-0.6, .thin), (-0.4, .light), (0, .regular),
                                               (0.23, .medium), (0.3, .semibold), (0.4, .bold), (0.56, .heavy), (0.62, .black)]
        return table.min(by: { abs($0.0 - v) < abs($1.0 - v) })?.1
    }

    /// Unwraps an `Optional<Any>` seen through Mirror.
    private static func unwrap(_ any: Any) -> Any? {
        let m = Mirror(reflecting: any)
        if m.displayStyle == .optional { return m.children.first?.value }
        return any
    }

    private static func child(_ any: Any, _ label: String) -> Any? {
        Mirror(reflecting: any).children.first(where: { $0.label == label })?.value
    }

    private static func scaled(_ font: Font, _ f: CGFloat) -> Font? {
        guard let box = child(font, "provider"), let provider = child(box, "base") else { return nil }
        let name = String(describing: type(of: provider))
        if name == "TextStyleProvider" {
            guard let style = child(provider, "style"), let base = size(forStyle: String(describing: style)) else { return nil }
            let w = weight(from: child(provider, "weight").flatMap(unwrap))
                ?? (String(describing: style) == "headline" ? .semibold : .regular)
            return .system(size: (base * f).rounded(), weight: w, design: design(from: child(provider, "design").flatMap(unwrap)))
        }
        if name == "SystemProvider" {
            guard let size = child(provider, "size") as? CGFloat else { return nil }
            let w = weight(from: child(provider, "weight").flatMap(unwrap)) ?? .regular
            return .system(size: (size * f).rounded(), weight: w, design: design(from: child(provider, "design").flatMap(unwrap)))
        }
        if name.hasPrefix("ModifierProvider<WeightModifier>") {
            guard let base = child(provider, "base") as? Font, let inner = scaled(base, f),
                  let mod = child(provider, "modifier"), let w = weight(from: child(mod, "weight")) else { return nil }
            return inner.weight(w)
        }
        if name.hasPrefix("StaticModifierProvider<") {
            guard let base = child(provider, "base") as? Font, let inner = scaled(base, f) else { return nil }
            if name.contains("BoldModifier") { return inner.bold() }
            if name.contains("ItalicModifier") { return inner.italic() }
            if name.contains("MonospacedDigitModifier") { return inner.monospacedDigit() }
            if name.contains("MonospacedModifier") { return inner.monospaced() }
            if name.contains("SmallCapsModifier") { return inner.smallCaps() }
            if name.contains("LowercaseSmallCapsModifier") { return inner.lowercaseSmallCaps() }
            if name.contains("UppercaseSmallCapsModifier") { return inner.uppercaseSmallCaps() }
            return nil
        }
        return nil
    }
}

/// Applies the app-level preferences to a view tree: text size, bold
/// text, the accent color, and the no-animation transaction gate. Environment
/// values (type size, legibility) flow into sheets and popovers on their
/// own; the transaction gate is re-applied inside glassBackground so
/// sheets get it too.
/// The app's own Reduce Motion preference as an environment value, so a
/// view that pauses its animation on it updates the moment the switch is
/// flipped. Read as a static UserDefaults lookup it was invisible to
/// SwiftUI: 27 timelines kept animating after the user turned it on.
private struct AppReduceMotionKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var appReduceMotion: Bool {
        get { self[AppReduceMotionKey.self] }
        set { self[AppReduceMotionKey.self] = newValue }
    }
}

/// The app's accent color, picked in Settings. Automatic sets nothing, so
/// macOS stays in charge: the user's system accent, or the app's own blue
/// when System Settings is on Multicolor.
enum AppAccent: String, CaseIterable, Identifiable {
    case automatic, blue, cyan, purple, pink, red, orange, yellow, green, graphite, custom

    static let storageKey = "InputConfig.accentColor"
    /// The custom color as sRGB hex ("RRGGBB"), picked with the color well.
    static let customKey = "InputConfig.accentColor.custom"
    /// The swatches; Custom is the color well at the end of the row.
    static var swatches: [AppAccent] { allCases.filter { $0 != .custom } }
    var id: String { rawValue }
    var label: String { self == .automatic ? "Automatic" : rawValue.capitalized }

    /// The color for this choice. Custom needs the stored hex, so callers
    /// that must redraw when it changes pass it in from their own AppStorage.
    func color(customHex: String) -> Color? {
        self == .custom ? Self.color(hex: customHex) : color
    }

    static func color(hex: String) -> Color? {
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255)
    }

    static func hex(of color: Color) -> String? {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        func byte(_ x: CGFloat) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        return String(format: "%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }

    var color: Color? {
        switch self {
        case .automatic, .custom: return nil
        case .blue: return Color(nsColor: .systemBlue)
        case .cyan: return Color(red: 0.255, green: 0.616, blue: 0.812)   // the app icon's cyan
        case .purple: return Color(nsColor: .systemPurple)
        case .pink: return Color(nsColor: .systemPink)
        case .red: return Color(nsColor: .systemRed)
        case .orange: return Color(nsColor: .systemOrange)
        case .yellow: return Color(nsColor: .systemYellow)
        case .green: return Color(nsColor: .systemGreen)
        case .graphite: return Color(nsColor: .systemGray)
        }
    }
}

/// The faint hint and status text the app draws in the tertiary label
/// color: brightened to the secondary color when Higher contrast text is on
/// in Settings, or the Mac's Increase Contrast is. Tertiary text in the dark
/// appearance read at about 2.3 to 1.
struct HintStyle: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
        environment.appHighContrast || environment.colorSchemeContrast == .increased
            ? HierarchicalShapeStyle.secondary : HierarchicalShapeStyle.tertiary
    }
}

extension ShapeStyle where Self == HintStyle {
    static var hint: HintStyle { HintStyle() }
}

private struct AppHighContrastKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var appHighContrast: Bool {
        get { self[AppHighContrastKey.self] }
        set { self[AppHighContrastKey.self] = newValue }
    }
}

struct AccessibilityAdjustments: ViewModifier {
    @AppStorage("InputConfig.a11y.highContrast") private var highContrast = false
    @AppStorage("InputConfig.a11y.textSize") private var textSize = 0
    @AppStorage("InputConfig.a11y.boldText") private var boldText = false
    @AppStorage("InputConfig.a11y.reduceMotion") private var reduceMotionPref = false
    @AppStorage(AppAccent.storageKey) private var accentRaw = AppAccent.automatic.rawValue
    @AppStorage(AppAccent.customKey) private var customAccentHex = ""

    func body(content: Content) -> some View {
        // nil when Automatic, which leaves both untouched.
        let accent = (AppAccent(rawValue: accentRaw) ?? .automatic).color(customHex: customAccentHex)
        content
            // A base font for text that sets none, through the app's scaled
            // .font, so Text Size reaches it too. The same size macOS uses
            // anyway, so nothing moves at the default step.
            .font(.body)
            .tint(accent)
            .accentColor(accent)
            .environment(\.appTextScale, AppA11y.scale(forStep: textSize))
            .environment(\.appReduceMotion, reduceMotionPref)
            .environment(\.legibilityWeight, boldText ? .bold : nil)
            .environment(\.appHighContrast, highContrast)
            .transaction { txn in
                // disablesAnimations too, or an .animation(_:value:) below
                // added its own and the view still slid.
                if reduceMotionPref { txn.animation = nil; txn.disablesAnimations = true }
            }
    }
}

/// The main window's behind-window backdrop, honoring Reduce Transparency:
/// frosted glass normally, a solid window background when the user asks.
private struct WindowBackdrop: ViewModifier {
    @AppStorage("InputConfig.a11y.reduceTransparency") private var reduceTransparency = false
    func body(content: Content) -> some View {
        // One modifier whichever way the switch sits: branching the view
        // tree here remounted the whole window on every toggle.
        content.background {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            } else {
                // 30% of the window color over the frosted glass: at 7% a
                // bright or colorful wallpaper tinted the whole window and
                // paled the cards, and macOS 27's glass is clearer still.
                VisualEffectBackground(tintOpacity: 0.3).ignoresSafeArea()
            }
        }
    }
}

/// Sheet backdrop half of the same rule.
private struct SheetBackdrop: ViewModifier {
    /// How much window color is laid over the frosted glass. A sheet made of
    /// glass cards of its own (Statistics) can let more of the window show.
    var windowTint: Double = 0.62
    @AppStorage("InputConfig.a11y.reduceTransparency") private var reduceTransparency = false
    func body(content: Content) -> some View {
        // Same shape either way, so flipping Reduce Transparency from
        // inside a sheet (Settings) restyles it instead of closing it.
        content.presentationBackground {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            } else {
                // Frosted, but tinted with the window color so what is
                // behind the sheet (the home page's cards, a busy editor)
                // never competes with the sheet's own text.
                VisualEffectBackground()
                    .overlay(Color(nsColor: .windowBackgroundColor).opacity(windowTint))
                    .ignoresSafeArea()
            }
        }
    }
}

extension View {
    /// App-level accessibility (text size, bold text, reduced motion) and
    /// the accent color picked in Settings. Apply once at each window root;
    /// sheets inherit the environment halves automatically.
    func appAccessibility() -> some View {
        modifier(AccessibilityAdjustments())
    }

    /// Presents this sheet over the same behind-window frosted glass as the
    /// main window, so every sheet shares one consistent translucency. Apply
    /// to the content inside a `.sheet { }` closure. Also carries the
    /// Reduce Motion gate so every sheet honors it without per-sheet wiring,
    /// and swaps to a solid backdrop under Reduce Transparency.
    func glassBackground(windowTint: Double = 0.62) -> some View {
        modifier(SheetBackdrop(windowTint: windowTint))
            .reduceMotionFriendly()
            .appAccessibility()
    }

    /// Main-window backdrop honoring Reduce Transparency.
    func windowBackdrop() -> some View {
        modifier(WindowBackdrop())
    }

    /// System accessibility: when the user enables Reduce Motion, strip the
    /// animation out of every transaction that flows through this subtree, so
    /// state changes apply instantly instead of sliding/scaling/springing.
    /// Apply once at each root (window content, sheets, the menu bar popover).
    /// TimelineView-driven loops don't go through transactions and are gated
    /// individually at their call sites.
    func reduceMotionFriendly() -> some View {
        modifier(ReduceMotionGate())
    }
}

private struct ReduceMotionGate: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transaction { t in
            if reduceMotion { t.animation = nil; t.disablesAnimations = true }
        }
    }
}

// MARK: - Shared design language (see ~/Desktop/Apps/DesignSync)
//
// InputConfig converges on the same visual language as Aura and YapToText:
// real Liquid Glass cards, one spacing/radius scale, hierarchical SF Symbols,
// and colored icons that always carry a little transparency (never a flat
// solid block). Reference implementations were ported from YapToText's
// DesignSystem.swift rather than reinvented.

extension Color {
    /// The muted record/stop red shared with YapToText's menu bar (its
    /// `yapRecord`), so the Stop pill reads the same, not a harsh system red.
    static let icStop = Color(red: 0.80, green: 0.31, blue: 0.33)
}

/// One spacing scale for the whole app.
enum Space {
    static let xs: CGFloat = 4
    static let s: CGFloat = 6
    static let m: CGFloat = 10
    static let l: CGFloat = 14
}

/// One radius / padding scale. Replaces the old grab-bag of 3/4/5/6/7/8/10/12
/// literals scattered through the views.
enum Metrics {
    static let cardRadius: CGFloat = 18
    static let sectionRadius: CGFloat = 18
    /// Floating panels (the menu-bar popover) sit one notch tighter than cards.
    static let panelRadius: CGFloat = 14
    static let innerRadius: CGFloat = 10
    static let badgeRadius: CGFloat = 9
    static let cardPad: CGFloat = 14
    static let gap: CGFloat = 14
}

extension View {
    /// THE colored-icon treatment. A tinted SF Symbol is NEVER a flat 100%
    /// solid block of color: every colored icon carries a little transparency
    /// so it reads as a layered, glassy mark. Pairs with the global
    /// `.symbolRenderingMode(.hierarchical)`. Transparency only, never a
    /// gradient. Use in place of `.foregroundStyle(color)` on any colored icon.
    func iconTint(_ color: Color, opacity: Double = 0.85) -> some View {
        foregroundStyle(color.opacity(opacity))
    }

    /// The app's ONE glass surface treatment. Every glass surface in the app
    /// (cards, pills, CTAs, toasts, overlays) routes through this helper, so
    /// there is exactly one glass language and never a mixture.
    ///
    /// On macOS 26+ this is Apple's REAL Liquid Glass engine
    /// (`.glassEffect`), tinted and interactive as requested. On macOS 14-25
    /// (the App Store deployment floor) it falls back to a tinted material +
    /// hairline stroke with identical layout.
    ///
    /// Accessibility: when the user enables Reduce Transparency, every glass
    /// surface renders as an OPAQUE window-background fill instead (system
    /// materials partially self-adapt, but the tint washes and the macOS 26
    /// glass path are guaranteed here). When Increase Contrast is on, the
    /// hairline stroke doubles in weight and opacity.
    func liquidGlass<S: Shape>(in shape: S,
                               tint: Color? = nil,
                               interactive: Bool = false) -> some View {
        modifier(LiquidGlassModifier(shape: shape, tint: tint, interactive: interactive))
    }

    /// THE single flat inner-surface style: a quiet recess (NOT glass) for
    /// anything nested inside a glass card - icon badges, wells, tiles, rows.
    /// Glass-inside-glass double-frosts and reads darker; the card is the
    /// glass, everything nested is a recess so every box reads the same.
    func innerWell(radius: CGFloat = Metrics.innerRadius) -> some View {
        modifier(InnerWellModifier(radius: radius))
    }

    /// Shared hover affordance for custom `.plain` controls: a soft fill that
    /// fades in on hover, replacing the hand-rolled per-view hover backgrounds.
    func hoverFill(_ hovering: Bool, radius: CGFloat = Metrics.innerRadius) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.06 : 0))
        )
    }
}

/// Environment-aware body for `liquidGlass(in:tint:interactive:)`.
/// Honors Reduce Transparency (opaque fill, no glass) and Increase
/// Contrast (heavier stroke) system accessibility settings.
private struct LiquidGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?
    let interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    /// The app's own Reduce Transparency switch counts too; this read only
    /// the system setting, so the Settings toggle never reached glass.
    @AppStorage("InputConfig.a11y.reduceTransparency") private var appReduceTransparency = false
    private var reduceTransparency: Bool { systemReduceTransparency || appReduceTransparency }
    @Environment(\.colorSchemeContrast) private var contrast

    private var strokeOpacity: Double { contrast == .increased ? 0.5 : 0.12 }
    private var strokeWidth: CGFloat { contrast == .increased ? 1.0 : 0.5 }

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(
                    shape.fill(Color(nsColor: .windowBackgroundColor))
                        .overlay(shape.fill((tint ?? Color.clear).opacity(0.25)))
                )
                .overlay(shape.stroke((tint ?? .primary).opacity(strokeOpacity),
                                      lineWidth: strokeWidth))
        } else if #available(macOS 26.0, *) {
            // Built in an inline closure so these imperative statements aren't
            // parsed as view content by the @ViewBuilder body (a bare var/if
            // here crashes swift-frontend in Release batch mode).
            let glass: Glass = {
                var g: Glass = .regular
                if let tint { g = g.tint(tint) }
                if interactive { g = g.interactive() }
                return g
            }()
            content.glassEffect(glass, in: shape)
        } else {
            content
                .background(
                    shape.fill(.thinMaterial)
                        // Tint wash so a tinted pill (Stop, hero CTA) keeps
                        // its color; untinted passes Color.clear -> no-op.
                        .overlay(shape.fill((tint ?? Color.clear).opacity(0.35)))
                )
                .overlay(shape.stroke((tint ?? .primary).opacity(strokeOpacity),
                                      lineWidth: strokeWidth))
        }
    }
}

/// Environment-aware body for `innerWell(radius:)`. Solid fills already
/// survive Reduce Transparency; Increase Contrast doubles the border.
private struct InnerWellModifier: ViewModifier {
    let radius: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(Color.secondary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(Color.secondary.opacity(contrast == .increased ? 0.4 : 0.12),
                        lineWidth: contrast == .increased ? 1.0 : 0.5))
    }
}

extension View {

    /// The canonical scroll-edge treatment: fades content to transparent under
    /// the title band so it dissolves into the window vibrancy instead of
    /// colliding with the toolbar. Shared across Aura / InputConfig / YapToText
    /// with the tuned finals (height 76, mid-stop 0.35 @ 0.45). Apply once at
    /// the detail-pane level.
    func headerFade() -> some View {
        mask(
            VStack(spacing: 0) {
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.35), location: 0.45),
                    .init(color: .black, location: 1),
                ], startPoint: .top, endPoint: .bottom)
                .frame(height: 76)
                Rectangle().fill(.black)
            }
            .ignoresSafeArea()
        )
    }
}

/// A tinted SF Symbol on a glass squircle - translucent layered ink, never a
/// solid block of color. Ported from YapToText's IconBadge.
struct IconBadge: View {
    let symbol: String
    var tint: Color = .accentColor
    var size: CGFloat = 32
    /// True when `symbol` is the app's custom controller glyph rather than an
    /// SF Symbol, so the badge draws the artwork instead.
    var isGlyph: Bool = false

    var body: some View {
        Group {
            if isGlyph {
                ControllerGlyph(height: size * 0.5)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.46, weight: .semibold))
            }
        }
        .iconTint(tint)
        .frame(width: size, height: size)
        .innerWell(radius: Metrics.badgeRadius)
        .accessibilityHidden(true)
    }
}

/// The workhorse container: a floating Liquid Glass card with a semibold
/// section-head title. Ported from YapToText's CardSection (using InputConfig's
/// availability-gated `liquidGlass` so it still builds on macOS 14).
struct CardSection<Content: View>: View {
    let title: String?
    var subtitle: String?
    @ViewBuilder var content: () -> Content

    init(_ title: String? = nil, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            if let title {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.hint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.cardPad)
        .liquidGlass(in: RoundedRectangle(cornerRadius: Metrics.sectionRadius, style: .continuous))
    }
}

extension Color {
    /// Black or white, whichever reads better on this color as a fill,
    /// from its relative luminance (WCAG).
    var readableLabel: Color {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return .white }
        return Self.readableLabel(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent)
    }

    /// The same, for sRGB components already worked out.
    static func readableLabel(red: CGFloat, green: CGFloat, blue: CGFloat) -> Color {
        func linear(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let l = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        // White stays (the app's look on its blue, green, and red buttons)
        // until it falls under 2.5:1, which only light fills do.
        return 1.05 / (l + 0.05) >= 2.5 ? .white : .black
    }
}

/// One flat button look across the app: a SOLID fill, no gradient or glass
/// sheen. Prominent = solid accent with white text; secondary = subtle neutral
/// fill. Ported from YapToText's SolidButton.
struct SolidButton: ButtonStyle {
    /// Three capsule sizes, one look: regular for sheet/hero rows, compact for
    /// dense utility rows, mini for the editor's per-binding micro buttons.
    enum Size { case regular, compact, mini }

    var tint: Color = .accentColor
    var prominent: Bool = true
    var size: Size = .regular
    @Environment(\.isEnabled) private var isEnabled
    /// For the fill as drawn: the accent picked in Settings lives in the
    /// environment, which NSColor(Color.accentColor) cannot see, so a yellow
    /// accent measured as the system blue and kept white text.
    @Environment(\.self) private var environment

    private var labelColor: Color {
        var fill = tint
        if tint == .accentColor {
            let d = UserDefaults.standard
            let choice = AppAccent(rawValue: d.string(forKey: AppAccent.storageKey) ?? "") ?? .automatic
            // The app's own look on the system blue stays white.
            if choice == .automatic || choice == .blue { return .white }
            if let picked = choice.color(customHex: d.string(forKey: AppAccent.customKey) ?? "") { fill = picked }
            // Any other accent gets whichever of white and black reads
            // better: white stayed on graphite and cyan at under 3:1.
            let c = fill.resolve(in: environment)
            func linear(_ v: Float) -> Float { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            let l = 0.2126 * linear(c.red) + 0.7152 * linear(c.green) + 0.0722 * linear(c.blue)
            return 1.05 / (l + 0.05) >= (l + 0.05) / 0.05 ? .white : .black
        }
        let c = fill.resolve(in: environment)
        return Color.readableLabel(red: CGFloat(c.red), green: CGFloat(c.green), blue: CGFloat(c.blue))
    }

    /// Back-compat with the earlier `compact:` spelling.
    init(tint: Color = .accentColor, prominent: Bool = true, compact: Bool) {
        self.init(tint: tint, prominent: prominent, size: compact ? .compact : .regular)
    }

    init(tint: Color = .accentColor, prominent: Bool = true, size: Size = .regular) {
        self.tint = tint
        self.prominent = prominent
        self.size = size
    }

    private var font: Font {
        switch size {
        case .regular: return .body.weight(.medium)
        case .compact: return .callout.weight(.medium)
        case .mini:    return .caption2.weight(.medium)
        }
    }
    private var hPad: CGFloat { size == .regular ? 14 : (size == .compact ? 10 : 7) }
    private var vPad: CGFloat { size == .regular ? 6 : (size == .compact ? 4 : 2) }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            // Button text is inviolable: one line, never wrapped or squashed
            // vertically. Horizontal stays flexible so full-width labels
            // (maxWidth: .infinity) still stretch across their row.
            .lineLimit(1)
            .fixedSize(horizontal: false, vertical: true)
            // White on dark fills, black on light ones: a light custom accent
            // (yellow, mint) put white text at about 1.6:1.
            .foregroundStyle(prominent ? AnyShapeStyle(labelColor) : AnyShapeStyle(.primary))
            .padding(.horizontal, hPad)
            .padding(.vertical, vPad)
            .background(prominent ? AnyShapeStyle(tint) : AnyShapeStyle(Color.secondary.opacity(0.16)),
                        in: Capsule())
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1.0) : 0.4)
    }
}

extension ButtonStyle where Self == SolidButton {
    static var solid: SolidButton { SolidButton(prominent: true) }
    static var solidSecondary: SolidButton { SolidButton(prominent: false) }
    static var solidCompact: SolidButton { SolidButton(prominent: true, size: .compact) }
    static var solidSecondaryCompact: SolidButton { SolidButton(prominent: false, size: .compact) }
    static var solidMini: SolidButton { SolidButton(prominent: true, size: .mini) }
    static var solidSecondaryMini: SolidButton { SolidButton(prominent: false, size: .mini) }
}

/// Hero call-to-action: an interactive tinted Liquid Glass capsule (spec
/// section 5 "Hero CTA"). For welcome pages, onboarding, and promotional
/// buttons - not ordinary form controls. Falls back to a tinted material
/// capsule under macOS 26 via `liquidGlass`.
struct GlassCTAButton: ButtonStyle {
    var tint: Color = .accentColor
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        // Same metrics as the regular SolidButton, so a glass CTA sits in a
        // row beside Close at the same height; only the glass and the weight
        // set it apart. No fixed width: it hugs its label.
        configuration.label
            .font(.body.weight(.semibold))
            // Same inviolable-label rule as SolidButton: one line, no vertical
            // squash; horizontal stays flexible for full-width labels.
            .lineLimit(1)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .liquidGlass(in: Capsule(), tint: tint, interactive: true)
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1.0) : 0.4)
    }
}

extension ButtonStyle where Self == GlassCTAButton {
    static var glassCTA: GlassCTAButton { GlassCTAButton() }
}

/// Quit while the binding editor is open. macOS refuses to quit an app whose
/// window has a sheet up, and says nothing, so the app looked hung. Every quit
/// (the Quit menu item, Command Q, a quit Apple Event from the Dock, a script,
/// logout or shutdown) now comes here first: with no unsaved changes the
/// editor closes and the app quits; with unsaved changes it asks first.
@MainActor
final class QuitCoordinator: NSObject, NSApplicationDelegate {
    static weak var shared: QuitCoordinator?
    private var quitting = false

    override init() {
        super.init()
        QuitCoordinator.shared = self
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleQuitEvent(_:withReply:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication))
    }

    @objc private func handleQuitEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        requestQuit()
    }

    /// A preset file chosen with Open With, or dropped on the Dock icon. It
    /// goes to the same review sheet as Import Preset File, in the main
    /// window, which comes back first if it was closed.
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        MenuBarController.shared.showMainWindow()
        OpenedPresetFiles.receive(files)
    }

    /// Close an open editor (saving or discarding as the person chooses),
    /// then quit once the sheet is gone.
    func requestQuit() {
        guard let editor = OpenEditor.current else { NSApplication.shared.terminate(nil); return }
        if editor.isDirty() {
            let alert = NSAlert()
            alert.messageText = "Save your changes to \u{201C}\(editor.name())\u{201D} before quitting?"
            alert.informativeText = "The binding editor is still open. If you do not save, the changes are lost."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Don\u{2019}t Save")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: editor.save()
            case .alertSecondButtonReturn: editor.discard()
            default: return
            }
        } else {
            editor.discard()
        }
        quitting = true
        editor.close()
        // Give SwiftUI a moment to take the sheet down, then quit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApplication.shared.terminate(nil)
        }
    }

    /// Closing the main window never quits. With one `Window` scene, SwiftUI
    /// otherwise terminates when it closes, which stopped the running preset
    /// and took the menu bar item, auto-switch and the hotkeys with it. The
    /// window comes back from the menu bar, the Dock, or Open InputConfig.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// A launch shows the library window, as it always did. macOS restores
    /// no window when it was closed at the last quit, which left a launch
    /// with nothing on screen.
    func applicationDidFinishLaunching(_ notification: Notification) {
        CursorSetThrottle.install()
        #if DEBUG
        LayoutSnapshots.installHook()
        #endif
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard MenuBarController.mainWindow == nil else { return }
            MenuBarController.shared.showMainWindow()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if OpenEditor.current != nil && !quitting {
            // From a run loop block, not the main queue: its modal alert
            // held the queue, so the Emergency Stop chord could not fire
            // and the freeze watchdog recorded a freeze.
            RunLoop.main.perform(inModes: [.default]) {
                MainActor.assumeIsolated { self.requestQuit() }
            }
            return .terminateCancel
        }
        return .terminateNow
    }
}

/// The binding editor that is open right now, registered by PresetEditorView
/// so a quit can save, discard and close it. nil when no editor is open.
/// Preset files handed to the app from outside (Open With, a drop on the
/// Dock icon, a file URL), on their way to the import review sheet. Files
/// that arrive before the window is up wait here until it sets `handler`.
/// The same file can arrive twice (the delegate and SwiftUI's open-URL path
/// both see it), so a repeat within two seconds is dropped.
@MainActor
enum OpenedPresetFiles {
    static var handler: (([URL]) -> Void)? { didSet { flush() } }
    private static var pending: [URL] = []
    private static var recent: [URL: Date] = [:]

    static func receive(_ urls: [URL]) {
        let now = Date()
        recent = recent.filter { now.timeIntervalSince($0.value) < 2 }
        for url in urls where url.isFileURL {
            let key = url.standardizedFileURL
            guard recent[key] == nil else { continue }
            recent[key] = now
            pending.append(url)
        }
        flush()
    }

    /// Held while the binding editor is open: its sheet is up, and the
    /// review is a second sheet on the same window that would not show.
    /// The editor calls this again when it closes.
    /// Set by the main window while another sheet (Settings, What's New,
    /// an intro, Statistics) is up; the review waits for it too, and opens
    /// when it closes.
    static var otherSheetIsUp = false { didSet { if !otherSheetIsUp { flush() } } }

    /// Whether files are waiting, so the launch intros can step aside.
    static var hasPending: Bool { !pending.isEmpty }

    static func flush() {
        guard let handler, !pending.isEmpty else { return }
        if OpenEditor.current != nil {
            ActivityLog.shared.info("Presets", "A preset file is waiting to be reviewed; it opens when the binding editor closes")
            return
        }
        if otherSheetIsUp { return }
        let urls = pending
        pending.removeAll()
        handler(urls)
    }
}

/// Window > InputConfig. Menu items exist from launch, before any window,
/// so this is also how the app opens the library window when a launch
/// restored none (see `MenuBarController.openMainFromWindowMenu`).
struct OpenMainWindowCommand: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("InputConfig") {
            openWindow(id: "main")
            NSApp.activate()
        }
    }
}

@MainActor
struct OpenEditor {
    static var current: OpenEditor?
    let name: () -> String
    let isDirty: () -> Bool
    let save: () -> Void
    let discard: () -> Void
    let close: () -> Void
    /// The draft being edited, and a way to change it. The touchpad
    /// sheet binds regions through these while the editor is open, so the
    /// new rows land in the draft and are saved with it.
    let presetID: UUID
    let draft: () -> Preset
    let edit: ((inout Preset) -> Void) -> Void
}

@main
struct InputConfig: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(QuitCoordinator.self) private var quitCoordinator

    var body: some Scene {
        // One main window. As a WindowGroup, File > New Window (Cmd-N) made
        // a second library window, every broadcast then ran twice (the
        // global shortcut switched a preset on and straight back off), and
        // a closed window could not be brought back from the menu bar.
        Window("InputConfig", id: "main") {
            ContentView()
                .environmentObject(appState.presetStore)
                .environmentObject(appState.controllerService)
                .environmentObject(appState.mappingEngine)
                .environmentObject(appState.eightBitDoDetector)
                // The narrowest the window goes: the home screen's four
                // showcase columns still read cleanly at this width.
                .frame(minWidth: 1080, minHeight: 700)
                .windowBackdrop()
                .reduceMotionFriendly()
                .appAccessibility()
                // A preset file opened from outside lands in this window's
                // import review rather than a second window.
                .handlesExternalEvents(preferring: Set(["*"]), allowing: Set(["*"]))
                .onOpenURL { url in OpenedPresetFiles.receive([url]) }
                .onAppear {
                    #if DEBUG
                    _ = DebugMarketing.shared   // register marketing capture hooks
                    #endif
                    OpenedPresetFiles.handler = { [presetStore = appState.presetStore] urls in
                        presetStore.previewImports(from: urls)
                    }
                    MenuBarController.shared.install(
                        presetStore: appState.presetStore,
                        mappingEngine: appState.mappingEngine,
                        controllerService: appState.controllerService
                    )
                    FrontmostAppWatcher.shared.install(
                        presetStore: appState.presetStore,
                        mappingEngine: appState.mappingEngine
                    )
                    // Apply the saved Dock-icon preference now that the window
                    // is up. Defaults to visible (registered in AppState.init).
                    AppState.applyDockIconVisible(
                        UserDefaults.standard.bool(forKey: "InputConfig.showDockIcon")
                    )
                }
        }
        .defaultSize(width: 1300, height: 750)
        .commands {
            // Quit goes through QuitCoordinator so an open editor closes first.
            CommandGroup(replacing: .appTermination) {
                Button("Quit InputConfig") { QuitCoordinator.shared?.requestQuit() }
                    .keyboardShortcut("q")
            }
            // MARK: InputConfig menu - Devices: connect hardware by hand
            DeviceCommands(controllerService: appState.controllerService)

            // MARK: File menu - preset creation + quick file actions
            CommandGroup(replacing: .newItem) {
                Button("New Preset") {
                    MenuBarController.shared.newPresetFromMenu()
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("Duplicate Active Preset") {
                    if let active = appState.presetStore.presets.first(where: { $0.isActive }) {
                        _ = appState.presetStore.duplicatePreset(active)
                    }
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Divider()

                Button("Reveal Data Folder in Finder") {
                    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                    let dataDir = appSupport.appendingPathComponent("InputConfig", isDirectory: true)
                    NSWorkspace.shared.activateFileViewerSelecting([dataDir])
                }
            }

            // Window menu: bring back the library window once it is closed.
            CommandGroup(before: .windowList) {
                OpenMainWindowCommand()
            }

            // MARK: View menu - sidebar + statistics + welcome
            CommandGroup(before: .sidebar) {
                Button("Toggle Sidebar") {
                    NSApp.keyWindow?.firstResponder?.tryToPerform(
                        #selector(NSSplitViewController.toggleSidebar(_:)), with: nil
                    )
                }
                .keyboardShortcut("s", modifiers: [.command, .control])

                Button("Show Statistics") {
                    NotificationCenter.default.post(name: .inputConfigShowStats, object: nil)
                }
                .keyboardShortcut("0", modifiers: .command)
            }

            // MARK: Controller menu - new top-level menu for controller stuff
            CommandMenu("Controller") {
                Button("Refresh Connected Controllers") {
                    appState.controllerService.refreshControllers()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Divider()

                Button("Activate / Deactivate Selected Preset") {
                    NotificationCenter.default.post(name: .inputConfigToggleActivePreset, object: nil)
                }
                .keyboardShortcut("p", modifiers: [.command, .option])

                Button("Stop All Activity") {
                    appState.mappingEngine.stop()
                    appState.presetStore.deactivateAll()
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])

                Divider()

                Button("Calibrate Touchpad…") {
                    NotificationCenter.default.post(name: .inputConfigOpenTouchpadCalibration, object: nil)
                }

                Button("Calibrate Motion / Gyro…") {
                    NotificationCenter.default.post(name: .inputConfigOpenMotionCalibration, object: nil)
                }
            }

            // MARK: Help menu - guides + diagnostics
            CommandGroup(replacing: .help) {
                Button("InputConfig Help") {
                    HelpGuideWindowController.shared.show()
                }
                .keyboardShortcut("?", modifiers: .command)

                Button("Quick Start Tour") {
                    NotificationCenter.default.post(name: .inputConfigStartTutorial, object: nil)
                }

                Divider()

                Button("Donate to InputConfig…") {
                    TipJarWindowController.shared.show()
                }

                Button("Rate InputConfig on the App Store") {
                    NSWorkspace.shared.open(ReviewPromptService.writeReviewURL)
                }

                Divider()

                Button("Test Bench (Diagnostics)…") {
                    TestBenchWindowController.shared.show()
                }
                .keyboardShortcut("t", modifiers: [.command, .option, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appState.presetStore)
                .environmentObject(appState.controllerService)
                .environmentObject(appState.mappingEngine)
                .appAccessibility()
        }
    }
}

/// Switches presets automatically when the frontmost app changes. A preset
/// opts in by listing bundle identifiers in
/// `automation.autoActivateBundleIDs` (the "Auto-activate for apps" list in
/// the editor's Advanced Options), and the whole feature is gated by a
/// global Settings toggle so nothing moves without the user asking.
///
/// Sandbox-safe: NSWorkspace.didActivateApplicationNotification delivers the
/// activated app's bundle identifier with no extra entitlement; the same
/// observer pattern already drives the light-bar re-assert in
/// GameControllerService.
///
/// Restore behavior: the preset that was active before the first auto
/// switch is remembered, and switching to an app that matches no preset
/// brings it back (or deactivates, if nothing was active). A manual
/// activation in between clears the memory, so the watcher never fights
/// an explicit user choice.
@MainActor
final class FrontmostAppWatcher {
    static let shared = FrontmostAppWatcher()

    static let enabledDefaultsKey = "InputConfig.autoSwitch.enabled"

    private weak var presetStore: PresetStore?
    private weak var mappingEngine: MappingEngine?
    private var observer: NSObjectProtocol?
    /// What was active before the first auto switch, restored on leaving.
    private var autoSwitchedFromPresetID: UUID?
    /// The preset the watcher itself activated last; if the active preset
    /// differs, the user switched manually and the watcher backs off.
    private var lastAutoActivatedPresetID: UUID?
    /// Set by the emergency stop; cleared when a preset is started by hand.
    private var holdAfterEmergencyStop = false
    private var activatingFromWatcher = false
    private var emergencyObserver: NSObjectProtocol?
    private var startObserver: NSObjectProtocol?

    private init() {}

    func install(presetStore: PresetStore, mappingEngine: MappingEngine) {
        guard observer == nil else { return }
        self.presetStore = presetStore
        self.mappingEngine = mappingEngine
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey]
                            as? NSRunningApplication)?.bundleIdentifier
            Task { @MainActor in
                self?.handleFrontmost(bundleID: bundleID)
            }
        }
        emergencyObserver = NotificationCenter.default.addObserver(
            forName: EmergencyStopService.stoppedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.holdAfterEmergencyStop = true
                self.lastAutoActivatedPresetID = nil
                self.autoSwitchedFromPresetID = nil
                if UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey) {
                    ActivityLog.shared.info("Presets", "Auto-switch is on hold after the emergency stop until you start a preset")
                }
            }
        }
        startObserver = NotificationCenter.default.addObserver(
            forName: MappingEngine.didStartNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.activatingFromWatcher else { return }
                self.holdAfterEmergencyStop = false
            }
        }
    }

    /// Stands for "stepped aside for an app whose preset binds nothing" in
    /// lastAutoActivatedPresetID, while no preset is active.
    private static let standDownID = UUID(uuidString: "00000000-0000-0000-0000-00000000A5D0")!
    /// The lock screen, the screen saver and system prompts come to the
    /// front without being an app the user switched to.
    private static let systemOverlays: Set<String> = [
        "com.apple.loginwindow", "com.apple.ScreenSaver.Engine",
        "com.apple.SecurityAgent", "com.apple.UserNotificationCenter",
    ]

    private func handleFrontmost(bundleID: String?) {
        guard UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey),
              let bundleID,
              bundleID != Bundle.main.bundleIdentifier,
              !Self.systemOverlays.contains(bundleID),
              let store = presetStore,
              let engine = mappingEngine else { return }

        // After an emergency stop nothing starts on its own until a preset
        // is started by hand, as Help promises: bringing the game back to
        // the front used to restart the very preset that was stopped.
        guard !holdAfterEmergencyStop else { return }
        // In sidebar order, so the preset higher in the sidebar wins when two
        // list the same app.
        if let match = store.presetsInSidebarOrder.first(where: { preset in
            (preset.automation.autoActivateBundleIDs ?? []).contains(bundleID)
        }) {
            // A preset with nothing bound means "step aside here" (a game
            // that reads the controller itself, as Help suggests): whatever
            // runs stops, and comes back when the app leaves the front.
            // Activating it instead marked an empty preset active.
            if !match.isRunnable {
                guard store.activePresetId != nil else {
                    if lastAutoActivatedPresetID == nil { lastAutoActivatedPresetID = Self.standDownID }
                    return
                }
                if lastAutoActivatedPresetID == nil || store.activePresetId != lastAutoActivatedPresetID {
                    autoSwitchedFromPresetID = store.activePresetId
                }
                engine.stop()
                store.deactivateAll()
                lastAutoActivatedPresetID = Self.standDownID
                ActivityLog.shared.info("Presets", "Stepped aside because an app listed for \"\(match.name)\" came to the front and it binds nothing")
                return
            }
            guard store.activePresetId != match.id else { return }
            // Remember what to come back to, but only when this is the
            // FIRST auto switch of a run; hopping between two matched apps
            // keeps the original restore point.
            // After a stand-down, a preset started by hand meanwhile is the
            // one to come back to, not the one that stood down.
            if lastAutoActivatedPresetID == nil
                || (store.activePresetId != lastAutoActivatedPresetID && lastAutoActivatedPresetID != Self.standDownID)
                || (lastAutoActivatedPresetID == Self.standDownID && store.activePresetId != nil) {
                autoSwitchedFromPresetID = store.activePresetId
            }
            activatingFromWatcher = true
            MenuBarController.activate(match, store: store, engine: engine, background: true)
            activatingFromWatcher = false
            lastAutoActivatedPresetID = match.id
            ActivityLog.shared.info("Presets", "Auto-switched to \"\(match.name)\" because one of its apps came to the front")
        } else if let lastAuto = lastAutoActivatedPresetID {
            // Only unwind an ACTIVE auto switch; if the user changed presets
            // manually since, leave their choice alone.
            let standingDown = lastAuto == Self.standDownID && store.activePresetId == nil
            guard store.activePresetId == lastAuto || standingDown else {
                lastAutoActivatedPresetID = nil
                autoSwitchedFromPresetID = nil
                return
            }
            if let backID = autoSwitchedFromPresetID,
               let back = store.presets.first(where: { $0.id == backID }), back.isRunnable {
                activatingFromWatcher = true
                MenuBarController.activate(back, store: store, engine: engine, background: true)
                activatingFromWatcher = false
            } else if !standingDown {
                engine.stop()
                store.deactivateAll()
            }
            lastAutoActivatedPresetID = nil
            autoSwitchedFromPresetID = nil
        }
    }
}
