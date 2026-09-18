import SwiftUI
import GameController

/// Walks the user through calibrating motion (gyro + accelerometer) for a
/// specific controller. The flow:
///
///   1. Pick which connected controller to calibrate.
///   2. Place the controller on a flat surface, face up, perfectly still.
///   3. Tap Start. We average the gyro + accel for ~2 seconds and save
///      that as the controller's "zero" so the mapping engine can subtract
///      it from every incoming sample.
///
/// Once calibrated, presets that bind motion inputs use the corrected
/// values automatically. Calibrations are per-controller-identity and
/// persisted to Application Support, so users only do this once per
/// device.
struct MotionCalibrationView: View {
    @EnvironmentObject var controllerService: GameControllerService
    @Environment(\.dismiss) private var dismiss

    @State private var selectedKey: String?
    @State private var captureInProgress: Bool = false
    @State private var captureRemaining: Double = 0
    @State private var captureSamples: [SampleVector] = []
    @State private var lastSavedKey: String?
    /// Two-step calibration flow: first click reveals instructions
    /// (scrolls them into view), second click actually starts the
    /// capture. Prevents accidental calibration with the controller
    /// in a weird orientation.
    @State private var awaitingConfirmation: Bool = false
    /// Integrated orientation in radians, ticked at 30 Hz from the
    /// controller's gyro rates. Used to drive the 3D gyro model when the
    /// controller doesn't expose absolute attitude, so the model HOLDS
    /// its orientation after motion stops instead of snapping to neutral.
    @State private var integratedRoll: Float = 0
    @State private var integratedPitch: Float = 0
    @State private var integratedYaw: Float = 0
    /// The active capture timer, retained so it can be invalidated if the view
    /// is dismissed mid-capture (otherwise it kept ticking and persisted an
    /// abandoned calibration).
    @State private var captureTimer: Timer?
    /// Re-zero section state. `rezeroButton` mirrors the persisted choice
    /// for the selected controller; while `listeningForRezeroButton` the
    /// 30 Hz tick assigns the first fresh press it sees. `observedSavedAt`
    /// is the calibration timestamp last shown, so a change (from the
    /// button, the Re-zero Now button, or a preset action) flashes a
    /// confirmation for a couple of seconds.
    @State private var rezeroButton: Int?
    @State private var listeningForRezeroButton = false
    @State private var pressedWhenListeningBegan: Set<Int> = []
    @State private var observedSavedAt: Date?
    @State private var rezeroFlashUntil: Date?
    @State private var tick = 0

    private struct SampleVector {
        var gx: Float; var gy: Float; var gz: Float
        var ax: Float; var ay: Float; var az: Float
    }

    private let captureDuration: Double = 2.5

    var body: some View {
        // The same shape as the deadzone sheets: icon and title with the
        // actions on the right, one line of guidance, the picture, a rule,
        // then the settings. The sheet hugs its content.
        VStack(alignment: .leading, spacing: 14) {
            header

            Text("Sets the resting zero for the gyroscope and accelerometer so motion presets do not drift. Rest the controller on a flat surface first.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            controllerPicker

            HStack {
                Spacer(minLength: 0)
                model
                Spacer(minLength: 0)
            }

            readout

            Divider()

            rezeroRow
            rezeroButtonRow
            captureRow
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            if selectedKey == nil, let first = motionCapableControllers.first {
                selectedKey = MotionCalibrationService.identityKey(for: first.controller)
            }
            controllerService.retainLiveInput("motion calibration")
        }
        .onDisappear {
            controllerService.releaseLiveInput("motion calibration")
            captureTimer?.invalidate()
            captureTimer = nil
            captureInProgress = false
        }
        // Tick the integrated orientation at 30 Hz from the currently
        // selected controller's gyro rates so the 3D model HOLDS its
        // pose when the controller is still. Paused during capture so
        // the model stays at flat for the duration of calibration.
        .onReceive(Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()) { _ in
            trackRezero()
            guard !captureInProgress,
                  let entry = selectedControllerEntry,
                  let motion = entry.controller.motion,
                  motion.hasRotationRate else { return }
            let dt: Float = 1.0 / 30.0
            // Use drift-corrected rates so a resting controller's gyro bias
            // doesn't ramp the model to the +/-90 degree clamp, and apply a
            // small per-tick leak toward zero so any residual bias decays
            // instead of accumulating.
            let key = MotionCalibrationService.identityKey(for: entry.controller)
            let (gx, gy, gz) = MotionCalibrationService.shared.correctedGyro(
                x: Float(motion.rotationRate.x),
                y: Float(motion.rotationRate.y),
                z: Float(motion.rotationRate.z),
                forKey: key)
            integratedPitch = (integratedPitch + gx * dt) * 0.98
            integratedYaw   = (integratedYaw + gy * dt) * 0.98
            integratedRoll  = (integratedRoll + gz * dt) * 0.98
            integratedPitch = max(-(.pi / 2), min(.pi / 2, integratedPitch))
            integratedYaw   = max(-(.pi / 2), min(.pi / 2, integratedYaw))
            integratedRoll  = max(-(.pi / 2), min(.pi / 2, integratedRoll))
        }
        // Reset the integrated orientation whenever the user picks a
        // different controller so the model starts from neutral on the
        // new device.
        .onChange(of: selectedKey) { _, key in
            integratedPitch = 0
            integratedYaw = 0
            integratedRoll = 0
            listeningForRezeroButton = false
            rezeroFlashUntil = nil
            rezeroButton = key.flatMap { MotionCalibrationService.shared.rezeroButton(forKey: $0) }
            observedSavedAt = key.flatMap { MotionCalibrationService.shared.calibration(forKey: $0)?.savedAt }
        }
    }

    // MARK: - Selected controller

    /// Tuple for the controller currently selected in the picker. Drives the
    /// live readings panel and the start-capture flow.
    private var selectedControllerEntry: (slot: Int, controller: GCController, info: ControllerInfo)? {
        guard let key = selectedKey else { return nil }
        return motionCapableControllers.first(where: {
            MotionCalibrationService.identityKey(for: $0.controller) == key
        })
    }

    // MARK: - Live readings (diagnostic)

    /// Live numeric + bar readout of the controller's gyro + accelerometer.
    /// Lets the user verify motion is actually flowing BEFORE running
    /// calibration. If a gyro never moves the values here, the controller
    /// either doesn't expose motion or macOS isn't piping it through.
    /// Marketing capture stand-in. The real panel needs a GCMotion, which a
    /// synthetic controller cannot provide, so the sheet showed an empty band
    /// where the readings belong. Compiles to nothing in Release.
    #if DEBUG
    @ViewBuilder
    private var syntheticLiveReadings: some View {
        TimelineView(.periodic(from: Date(), by: 1.0 / 30.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.path.ecg")
                        .foregroundStyle(.teal)
                    Text("Live sensor readings")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    availabilityBadge(label: "active", available: true)
                    availabilityBadge(label: "gyro", available: true)
                    availabilityBadge(label: "gravity", available: true)
                }
                GyroVisualizationView(
                    gyroX: Float(sin(t * 1.3)) * 0.8,
                    gyroY: Float(cos(t * 0.9)) * 0.8,
                    gyroZ: Float(sin(t * 0.6)) * 0.5,
                    rollAngle: Float(sin(t * 0.7)) * 0.35,
                    pitchAngle: Float(cos(t * 0.5)) * 0.30,
                    yawAngle: Float(sin(t * 0.4)) * 0.25)
                    .frame(maxWidth: .infinity)
            }
        }
    }
    #endif

    /// The 3D model, driven by the controller's attitude when it has one
    /// and by the integrated gyro otherwise, so it holds its pose at rest.
    @ViewBuilder
    private var model: some View {
        if let entry = selectedControllerEntry, let motion = entry.controller.motion {
            TimelineView(.periodic(from: Date(), by: 1.0 / 30.0)) { _ in
                let gx = motion.hasRotationRate ? Float(motion.rotationRate.x) : 0
                let gy = motion.hasRotationRate ? Float(motion.rotationRate.y) : 0
                let gz = motion.hasRotationRate ? Float(motion.rotationRate.z) : 0
                let attitude = motion.hasAttitude ? attitudeEuler(motion: motion) : nil
                GyroVisualizationView(
                    gyroX: gx, gyroY: gy, gyroZ: gz,
                    rollAngle: attitude?.roll ?? integratedRoll,
                    pitchAngle: attitude?.pitch ?? integratedPitch,
                    yawAngle: attitude?.yaw ?? integratedYaw,
                    mode: .model
                )
            }
        } else {
            #if DEBUG
            if controllerService.debugMarketingFakeActive {
                syntheticLiveReadings
            } else {
                noControllerNote
            }
            #else
            noControllerNote
            #endif
        }
    }

    private var noControllerNote: some View {
        Text("Connect a controller with motion sensors: DualSense, DualShock 4, Switch Pro or Joy-Con.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
    }

    /// One line of live numbers. The bars and the gravity and user
    /// acceleration rows are gone: three signed rates say whether the
    /// gyro is alive, which is all this line is for.
    @ViewBuilder
    private var readout: some View {
        if let entry = selectedControllerEntry, let motion = entry.controller.motion {
            TimelineView(.periodic(from: Date(), by: 1.0 / 10.0)) { _ in
                HStack(spacing: 10) {
                    if motion.hasRotationRate {
                        Text("gyro").foregroundStyle(.secondary)
                        Text(String(format: "x %+.2f   y %+.2f   z %+.2f rad/s",
                                    motion.rotationRate.x, motion.rotationRate.y, motion.rotationRate.z))
                            .monospacedDigit()
                    } else {
                        Text("The gyroscope is not reporting. Try a wired connection, or re-pair the controller.")
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    if motion.sensorsRequireManualActivation && !motion.sensorsActive {
                        Button("Activate sensors") { motion.sensorsActive = true }
                            .buttonStyle(.solidSecondaryCompact)
                    }
                }
                .font(.caption)
            }
        }
    }

    /// Convert the controller's quaternion attitude into Euler roll / pitch
    /// / yaw in radians. Same math as `GameControllerService.readControllerState`
    /// but inline here so the calibration view can drive the gyro
    /// visualization without going through the engine.
    private func attitudeEuler(motion: GCMotion) -> (roll: Float, pitch: Float, yaw: Float) {
        guard motion.hasAttitude else { return (0, 0, 0) }
        let q = motion.attitude
        let qx = Float(q.x), qy = Float(q.y), qz = Float(q.z), qw = Float(q.w)
        let roll  = atan2(2 * (qw * qx + qy * qz),
                          1 - 2 * (qx * qx + qy * qy))
        let pitchArg = 2 * (qw * qy - qz * qx)
        let pitch = asin(max(-1, min(1, pitchArg)))
        let yaw   = atan2(2 * (qw * qz + qx * qy),
                          1 - 2 * (qy * qy + qz * qz))
        return (roll, pitch, yaw)
    }

    private func availabilityBadge(label: String, available: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: available ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(available ? .green : .red.opacity(0.6))
            Text(label)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func sensorRow(label: String,
                           values: (Float, Float, Float),
                           scale: Float,
                           unit: String,
                           color: Color) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.caption.weight(.semibold))
                .frame(width: 42, alignment: .leading)
                .foregroundStyle(.secondary)
            sensorAxisCell(axis: "X", value: values.0, scale: scale, unit: unit, color: color)
            sensorAxisCell(axis: "Y", value: values.1, scale: scale, unit: unit, color: color)
            sensorAxisCell(axis: "Z", value: values.2, scale: scale, unit: unit, color: color)
        }
    }

    private func sensorAxisCell(axis: String,
                                value: Float,
                                scale: Float,
                                unit: String,
                                color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(axis)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10, alignment: .leading)
                Text(String(format: "%+0.2f", value))
                    .font(.caption.monospacedDigit())
                    .frame(width: 50, alignment: .trailing)
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            MotionBar(value: value, scale: scale, tint: color)
                .frame(height: 6)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Re-zero

    /// The quick path. A full calibration averages a still controller for a
    /// few seconds; re-zero takes the reading this instant. The controller
    /// button makes it reachable mid-game without touching the Mac, and it
    /// belongs to the controller, not a preset, so it works with any preset
    /// running or none.
    /// Label, control, status: the row shape every setting uses.
    private var rezeroRow: some View {
        HStack(spacing: 12) {
            Text("Re-zero")
                .frame(minWidth: 120, alignment: .leading)
            Button("Re-zero now") { rezeroNow() }
                .buttonStyle(.solidSecondaryCompact)
                .disabled(selectedControllerEntry == nil || captureInProgress)
            if let until = rezeroFlashUntil, until > Date() {
                Label("Zeroed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .transition(.opacity)
            } else if let at = observedSavedAt {
                Text("last zeroed \(at.formatted(.relative(presentation: .named)))")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.subheadline)
        .animation(.easeOut(duration: 0.18), value: rezeroFlashUntil)
    }

    private var rezeroButtonRow: some View {
        HStack(spacing: 12) {
            Text("Re-zero button")
                .frame(minWidth: 120, alignment: .leading)
            Menu {
                Button("None") { setRezeroButton(nil) }
                Divider()
                ForEach(rezeroButtonChoices, id: \.index) { choice in
                    Button {
                        setRezeroButton(choice.index)
                    } label: {
                        if choice.index == rezeroButton {
                            Label(choice.label, systemImage: "checkmark")
                        } else {
                            Text(choice.label)
                        }
                    }
                }
            } label: {
                Text(rezeroButton.map(rezeroButtonLabel) ?? "None")
            }
            .fixedSize()
            .disabled(selectedControllerEntry == nil)

            Button {
                if listeningForRezeroButton {
                    listeningForRezeroButton = false
                } else if let slot = selectedControllerEntry?.slot {
                    pressedWhenListeningBegan = Set(
                        (controllerService.currentStates[slot]?.buttons ?? [:])
                            .filter { $0.value > 0.5 }.keys)
                    listeningForRezeroButton = true
                }
            } label: {
                if listeningForRezeroButton {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.6)
                        Text("Press a button\u{2026}")
                    }
                } else {
                    Text("Press to assign")
                }
            }
            .buttonStyle(.solidSecondaryCompact)
            .disabled(selectedControllerEntry == nil)
            Spacer()
        }
        .font(.subheadline)
    }

    /// Start, with what to do beside it; the progress takes the same
    /// space while it runs, and the result the moment it is saved.
    private var captureRow: some View {
        HStack(spacing: 12) {
            Text("Full calibration")
                .frame(minWidth: 120, alignment: .leading)
            Button("Start") { startCapture() }
                .buttonStyle(.solidCompact)
                .disabled(selectedKey == nil || captureInProgress)
            if captureInProgress {
                ProgressView(value: 1 - (captureRemaining / captureDuration))
                    .frame(maxWidth: 160)
                Text("hold still, \(Int(ceil(captureRemaining))) s")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else if let key = lastSavedKey, key == selectedKey {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Text(String(format: "rest it flat and untouched for %.1f seconds", captureDuration))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.subheadline)
    }

    private var rezeroButtonChoices: [(index: Int, label: String)] {
        var choices = BindingRowView.standardButtonLabels.filter { $0.index <= 12 }
        if let slot = selectedControllerEntry?.slot {
            for extra in controllerService.extraButtonsSnapshot(for: slot)
            where !choices.contains(where: { $0.index == extra.index }) {
                choices.append((extra.index, extra.label))
            }
        }
        return choices
    }

    private func rezeroButtonLabel(_ index: Int) -> String {
        rezeroButtonChoices.first(where: { $0.index == index })?.label ?? "Button \(index)"
    }

    private func setRezeroButton(_ index: Int?) {
        guard let key = selectedKey else { return }
        rezeroButton = index
        listeningForRezeroButton = false
        MotionCalibrationService.shared.setRezeroButton(index, forKey: key)
    }

    private func rezeroNow() {
        guard let entry = selectedControllerEntry else { return }
        if controllerService.rezeroMotion(slot: entry.slot) {
            AccessibilityNotification.Announcement("Motion re-zeroed").post()
        }
    }

    /// 30 Hz bookkeeping for the re-zero section: assign the button while
    /// listening, and flash a confirmation whenever the stored zero changes.
    private func trackRezero() {
        tick &+= 1
        guard let key = selectedKey else { return }
        if listeningForRezeroButton, let slot = selectedControllerEntry?.slot {
            let pressed = (controllerService.currentStates[slot]?.buttons ?? [:])
                .filter { $0.value > 0.5 }.keys
            if let fresh = pressed.first(where: { !pressedWhenListeningBegan.contains($0) }) {
                setRezeroButton(fresh)
            } else {
                pressedWhenListeningBegan = Set(pressed)
            }
        }
        let savedAt = MotionCalibrationService.shared.calibration(forKey: key)?.savedAt
        if savedAt != observedSavedAt {
            observedSavedAt = savedAt
            if savedAt != nil, !captureInProgress {
                rezeroFlashUntil = Date().addingTimeInterval(2)
            }
        } else if let until = rezeroFlashUntil, until <= Date() {
            rezeroFlashUntil = nil
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "gyroscope")
                .foregroundStyle(.tint)
            Text("Motion Calibration")
                .font(.headline)
            Spacer()
            if let key = selectedKey, MotionCalibrationService.shared.isCalibrated(forKey: key) {
                Button("Clear") {
                    MotionCalibrationService.shared.clear(forKey: key)
                    lastSavedKey = nil
                }
                .buttonStyle(.solidSecondaryCompact)
                .disabled(captureInProgress)
                .help("Forget this controller's stored zero")
            }
            Button {
                showingHelp.toggle()
            } label: {
                Image(systemName: "questionmark.circle")
            }
            .buttonStyle(.solidSecondaryCompact)
            .help("How calibration works")
            .popover(isPresented: $showingHelp, arrowEdge: .bottom) { help }
            Button("Done") { dismiss() }
                .buttonStyle(.solidCompact)
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Controller picker

    private var motionCapableControllers: [(slot: Int, controller: GCController, info: ControllerInfo)] {
        var result: [(Int, GCController, ControllerInfo)] = []
        for (slot, controller) in controllerService.connectedControllers.enumerated() {
            if let info = controllerService.controllerDetails[slot], info.supportsMotion {
                result.append((slot, controller, info))
            }
        }
        return result
    }

    /// The controller being calibrated, on the heading line: a name when
    /// there is one, a menu when there are several, and whether it has a
    /// stored zero.
    @ViewBuilder
    private var controllerPicker: some View {
        let list = motionCapableControllers
        if let entry = selectedControllerEntry ?? list.first {
            let key = MotionCalibrationService.identityKey(for: entry.controller)
            let calibrated = MotionCalibrationService.shared.isCalibrated(forKey: key)
            HStack(spacing: 6) {
                if list.count > 1 {
                    Menu {
                        ForEach(list, id: \.slot) { e in
                            Button(e.controller.vendorName ?? "Controller") {
                                selectedKey = MotionCalibrationService.identityKey(for: e.controller)
                            }
                        }
                    } label: {
                        Text(entry.controller.vendorName ?? "Controller")
                    }
                    .fixedSize()
                } else {
                    Text(entry.controller.vendorName ?? "Controller")
                        .foregroundStyle(.secondary)
                }
                Circle().fill(calibrated ? Color.green : Color.orange).frame(width: 7, height: 7)
                Text(calibrated ? "calibrated" : "not calibrated")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if controllerService.debugMarketingFakeActive {
            HStack(spacing: 6) {
                Text(controllerService.controllerNames[0] ?? "Controller").foregroundStyle(.secondary)
                Circle().fill(Color.green).frame(width: 7, height: 7)
                Text("calibrated").foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }

    @State private var showingHelp = false

    private var help: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Calibrating motion")
                .font(.headline)
            Text("Re-zero takes the controller's reading right now as its resting zero: quick, and enough whenever motion starts to drift. A button on the controller can do the same; rest the controller, press it, and a short pulse confirms it. A paddle or a button you never use is the usual home for it.")
            Text(String(format: "Full calibration records the resting gyro and accelerometer for %.1f seconds.", captureDuration) + " Put the controller on a flat, level surface, turn off rumble, and do not touch it until it finishes. The zero is saved for this controller and used by every motion preset.")
            Text("The readout should move when you turn the controller and settle near zero when it rests. If it reads exactly zero whatever you do, motion is not reaching the app: try a wired connection or re-pair over Bluetooth.")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
        .frame(width: 380)
    }

    // MARK: - Footer

    // MARK: - Capture logic

    private func startCapture() {
        guard let key = selectedKey,
              let entry = motionCapableControllers.first(where: { MotionCalibrationService.identityKey(for: $0.controller) == key }),
              let motion = entry.controller.motion else { return }

        captureInProgress = true
        captureRemaining = captureDuration
        captureSamples.removeAll(keepingCapacity: true)
        lastSavedKey = nil
        // Snap the 3D model to absolute flat at the start of calibration
        // so the user has a clear visual reference for what "flat" means.
        // The integrator loop (further down) keeps these at zero while
        // captureInProgress is true.
        integratedRoll = 0
        integratedPitch = 0
        integratedYaw = 0

        let start = Date()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { t in
            // Sample motion on each tick.
            let s = SampleVector(
                gx: motion.hasRotationRate ? Float(motion.rotationRate.x) : 0,
                gy: motion.hasRotationRate ? Float(motion.rotationRate.y) : 0,
                gz: motion.hasRotationRate ? Float(motion.rotationRate.z) : 0,
                ax: Float(motion.userAcceleration.x),
                ay: Float(motion.userAcceleration.y),
                az: Float(motion.userAcceleration.z)
            )
            captureSamples.append(s)
            captureRemaining = max(0, captureDuration - Date().timeIntervalSince(start))
            if captureRemaining <= 0 {
                t.invalidate()
                captureTimer = nil
                finishCapture(key: key)
            }
        }
        captureTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func finishCapture(key: String) {
        defer {
            captureInProgress = false
            captureRemaining = 0
        }
        guard !captureSamples.isEmpty else { return }
        let n = Float(captureSamples.count)
        let gx = captureSamples.map(\.gx).reduce(0, +) / n
        let gy = captureSamples.map(\.gy).reduce(0, +) / n
        let gz = captureSamples.map(\.gz).reduce(0, +) / n
        let ax = captureSamples.map(\.ax).reduce(0, +) / n
        let ay = captureSamples.map(\.ay).reduce(0, +) / n
        let az = captureSamples.map(\.az).reduce(0, +) / n
        let cal = MotionCalibration(
            controllerKey: key,
            gyroDriftX: gx, gyroDriftY: gy, gyroDriftZ: gz,
            accelDriftX: ax, accelDriftY: ay, accelDriftZ: az,
            savedAt: Date()
        )
        MotionCalibrationService.shared.save(cal)
        lastSavedKey = key
        observedSavedAt = cal.savedAt
        AccessibilityNotification.Announcement("Motion calibration saved").post()
    }
}

/// Tiny bidirectional bar used by the live sensor readout. Center is zero,
/// the bar fills right for positive values and left for negative, clamped
/// to ±`scale` so a vigorous shake still stays inside the bar.
private struct MotionBar: View {
    let value: Float
    let scale: Float
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let halfWidth = width / 2
            let clamped = max(-1, min(1, value / max(scale, 0.0001)))
            let barWidth = abs(CGFloat(clamped)) * halfWidth

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(tint.opacity(0.15))

                Rectangle()
                    .fill(tint)
                    .frame(width: barWidth, height: geo.size.height)
                    .offset(x: clamped >= 0 ? halfWidth : halfWidth - barWidth)

                Rectangle()
                    .fill(Color.primary.opacity(0.35))
                    .frame(width: 1)
                    .offset(x: halfWidth)
            }
            .clipShape(RoundedRectangle(cornerRadius: 2))
        }
    }
}
