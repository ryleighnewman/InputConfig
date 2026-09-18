import SwiftUI
import simd
import SceneKit
import AppKit

/// Shared 3D-tilt + attitude-horizon gyro visualization. Used by:
///
/// * `VirtualControllerView` (compact, alongside other widgets)
/// * `MotionCalibrationView` (regular, while previewing live readings)
/// * `FeatureDemoView` / GyroDemo (large, animated welcome demo)
///
/// Renders a stylized controller silhouette that tilts in 3D via
/// `rotation3DEffect`, plus an attitude-indicator ring with a horizon line
/// that pitches and rolls, plus three small bars showing instantaneous
/// angular-rate magnitude on each gyro axis (color-coded: red X, green Y,
/// blue Z).
struct GyroVisualizationView: View {
    /// Instantaneous angular velocity around each axis (radians / second).
    /// Drives the rate bars at the bottom of the widget.
    let gyroX: Float
    let gyroY: Float
    let gyroZ: Float

    /// Absolute attitude in radians. When the controller exposes
    /// `hasAttitude`, callers pass through Euler-derived roll/pitch/yaw so
    /// the silhouette can hold its real-world orientation instead of
    /// drifting from integrated rates.
    var rollAngle: Float = 0
    var pitchAngle: Float = 0
    var yawAngle: Float = 0

    /// Rendering size preset. Compact strips labels and rate bars to fit
    /// inside the controller visualizer; regular shows everything; large
    /// gets extra padding for the demo cards.
    /// `model` is the 3D controller on its own, large, with no horizon
    /// ring, ticks or rate bars around it: the calibrator's view, where the
    /// controller tilting is the whole point and everything else is noise.
    enum Mode { case compact, regular, large, model }
    var mode: Mode = .regular

    /// Base size of the attitude ring. Other sub-views scale relative to
    /// this so changes here affect everything proportionally.
    private var ringSize: CGFloat {
        switch mode {
        case .compact: return 60
        case .regular: return 130
        case .large:   return 170
        case .model:   return 300
        }
    }

    private var silhouetteSize: CGFloat {
        // The model fills most of its ring now; it used to sit at under
        // half the ring's width and read as a badge in a dial.
        switch mode {
        case .compact: return 30
        case .regular: return 82
        case .large:   return 108
        case .model:   return 200
        }
    }

    private var barHeight: CGFloat { mode == .compact ? 3 : 5 }

    // MARK: - Body

    var body: some View {
        if mode == .model {
            Controller3DSceneView(
                pitchAngle: pitchAngle,
                yawAngle: yawAngle,
                rollAngle: rollAngle,
                fieldOfView: 38,
                isMoving: abs(gyroX) + abs(gyroY) + abs(gyroZ) > 0.03
            )
            .frame(width: 300, height: 140)
        } else {
            VStack(spacing: mode == .compact ? 4 : 10) {
                attitudeRing
                if mode != .compact {
                    rateBars
                        .frame(maxWidth: ringSize)
                }
            }
        }
    }

    // MARK: - Attitude ring

    /// Circular "artificial horizon" - sky tints upper half, ground tints
    /// lower half, and the horizon line tilts with roll while sliding
    /// vertically with pitch. Controller silhouette sits centered and
    /// tilts in 3D so it feels like the physical controller in your hand.
    private var attitudeRing: some View {
        ZStack {
            // Sky / ground gradient slices that shift with pitch.
            attitudeHorizon
                .clipShape(Circle())

            // Faint tick marks every 30 degrees around the ring.
            ForEach(0..<12) { i in
                Rectangle()
                    .fill(Color.primary.opacity(0.18))
                    .frame(width: 1, height: 6)
                    .offset(y: -ringSize / 2 + 4)
                    .rotationEffect(.degrees(Double(i) * 30))
            }

            // Outer ring.
            Circle()
                .stroke(Color.teal.opacity(0.55), lineWidth: 1.5)

            // True 3D controller mesh, rendered with SceneKit. Rotates in
            // real time on the actual pitch/yaw/roll values - so the model
            // mirrors how the physical controller is being held. Far more
            // convincing than a flat SF Symbol with a rotation effect on
            // top.
            Controller3DSceneView(
                pitchAngle: pitchAngle,
                yawAngle: yawAngle,
                rollAngle: rollAngle,
                // Gyro rate magnitude above a small noise deadband = tilting.
                isMoving: abs(gyroX) + abs(gyroY) + abs(gyroZ) > 0.03
            )
            .frame(width: silhouetteSize * 1.6, height: silhouetteSize * 1.2)
            .shadow(color: .teal.opacity(0.4), radius: 4)

            // Center crosshair so the eye has an "origin" even when the
            // controller silhouette is tilting away.
            Circle()
                .stroke(Color.primary.opacity(0.35), lineWidth: 0.5)
                .frame(width: 6, height: 6)
        }
        .frame(width: ringSize, height: ringSize)
    }

    /// Horizon shading: cyan sky on top, brown ground on bottom, with a
    /// thin horizon line. The whole composition rotates with roll and
    /// shifts up/down with pitch.
    private var attitudeHorizon: some View {
        // Pitch offset: pi/2 (90 deg) nose-up moves the horizon to the
        // bottom of the ring, pi/2 nose-down to the top. Clamp for safety.
        let pitchOffset = CGFloat(max(-1, min(1, pitchAngle / (.pi / 2)))) * (ringSize / 2)

        return ZStack {
            // Sky.
            Rectangle()
                .fill(LinearGradient(
                    colors: [Color(red: 0.30, green: 0.55, blue: 0.85),
                             Color(red: 0.20, green: 0.45, blue: 0.75)],
                    startPoint: .top, endPoint: .bottom))
                .frame(height: ringSize)
                .offset(y: -ringSize / 2)

            // Ground.
            Rectangle()
                .fill(LinearGradient(
                    colors: [Color(red: 0.55, green: 0.40, blue: 0.25),
                             Color(red: 0.40, green: 0.28, blue: 0.18)],
                    startPoint: .top, endPoint: .bottom))
                .frame(height: ringSize)
                .offset(y: ringSize / 2)

            // Horizon line.
            Rectangle()
                .fill(Color.white.opacity(0.85))
                .frame(width: ringSize * 1.4, height: 1.5)
        }
        .offset(y: pitchOffset)
        .rotationEffect(.radians(Double(rollAngle)))
        .animation(.easeOut(duration: 0.05), value: rollAngle)
        .animation(.easeOut(duration: 0.05), value: pitchAngle)
    }

    // MARK: - Rate bars

    /// Three horizontal bars showing the instantaneous angular-rate
    /// magnitude on each gyro axis. Color-coded so it's easy to tell which
    /// axis is moving at a glance: red = X (pitch), green = Y (yaw),
    /// blue = Z (roll).
    private var rateBars: some View {
        VStack(spacing: 4) {
            rateRow(label: "X", value: gyroX, color: .red)
            rateRow(label: "Y", value: gyroY, color: .green)
            rateRow(label: "Z", value: gyroZ, color: .blue)
        }
    }

    /// Single rate row: label, bidirectional bar with center tick, value.
    private func rateRow(label: String, value: Float, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption2.weight(.semibold).monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 12, alignment: .leading)

            GeometryReader { geo in
                let halfWidth = geo.size.width / 2
                let clamped = max(-1, min(1, CGFloat(value) / 5.0))
                let barWidth = abs(clamped) * halfWidth

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(color.opacity(0.15))
                    Rectangle()
                        .fill(color)
                        .frame(width: barWidth, height: barHeight)
                        .offset(x: clamped >= 0 ? halfWidth : halfWidth - barWidth)
                    Rectangle()
                        .fill(Color.primary.opacity(0.4))
                        .frame(width: 1)
                        .offset(x: halfWidth)
                }
                .clipShape(Capsule())
            }
            .frame(height: barHeight)

            Text(String(format: "%+0.2f", value))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
    }
}

#Preview("Regular") {
    GyroVisualizationView(gyroX: 0.5, gyroY: -0.3, gyroZ: 0.1,
                          rollAngle: 0.25, pitchAngle: 0.15, yawAngle: -0.1,
                          mode: .regular)
        .padding()
}

#Preview("Compact") {
    GyroVisualizationView(gyroX: 0.5, gyroY: -0.3, gyroZ: 0.1,
                          rollAngle: 0.25, pitchAngle: 0.15, yawAngle: -0.1,
                          mode: .compact)
        .padding()
}

// MARK: - SceneKit 3D controller

/// Real 3D controller mesh, rendered via SceneKit so rotation looks like
/// genuine depth (parallax, lighting changes) instead of a flat icon being
/// tilted. Built from primitive geometry - a chamfered box body, two stick
/// cylinders, four colored face buttons, and two shoulder boxes - so we
/// don't need an asset file. Updates the node's Euler angles in real time
/// from the gyro view's pitch / yaw / roll inputs.
struct Controller3DSceneView: NSViewRepresentable {
    let pitchAngle: Float
    let yawAngle: Float
    let rollAngle: Float
    /// Horizontal field of view. Wider means the model sits smaller in the
    /// view: 27 fills a small ring, 38 leaves room around it in a sheet.
    var fieldOfView: CGFloat = 27
    /// True while the controller is actually tilting. Continuous rendering is
    /// only needed to present small per-frame deltas during motion; when the
    /// controller is still there is nothing to present, so we drop to
    /// on-demand rendering and let SceneKit hold the last frame. This stops the
    /// SCNView's independent 30 fps CVDisplayLink from running forever whenever
    /// a motion controller is merely connected.
    var isMoving: Bool = true

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = buildScene()
        view.backgroundColor = .clear
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 30
        // Start continuous so the very first frame is guaranteed to present;
        // updateNSView (called immediately after, and on every angle change)
        // then gates it to `isMoving`. isPlaying stays on so on-demand redraws
        // still fire when the scene graph changes.
        view.rendersContinuously = true
        view.isPlaying = true
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        // Only keep the render loop hot while the controller is moving. The
        // first frame already presented (makeNSView started continuous), and
        // any angle change re-runs this to present it; when still we hold the
        // last frame, which is pixel-identical to the current always-rendered
        // still frame.
        nsView.rendersContinuously = isMoving
        guard let node = nsView.scene?.rootNode.childNode(withName: "controller",
                                                          recursively: true) else { return }
        // GCMotion convention: X = pitch, Y = yaw, Z = roll. SceneKit uses
        // Euler angles in the same order so the mapping is direct. Slight
        // sign flip on yaw so tilting the controller right makes the model
        // visually point right. Wrap in SCNTransaction so the angle update
        // commits this frame and SceneKit interpolates smoothly between
        // ticks.
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.05
        node.eulerAngles = SCNVector3(
            CGFloat(pitchAngle),
            CGFloat(-yawAngle),
            CGFloat(rollAngle)
        )
        SCNTransaction.commit()
    }

    /// Build the controller mesh + camera + lighting once. The body is a
    /// DualSense-style silhouette (a bezier outline extruded and chamfered)
    /// with a dark face plate, two sticks, the touchpad with its light bar,
    /// face buttons, D-pad, menu buttons, and the shoulders and triggers on
    /// the back edge. Low-poly enough to stay cheap at 30 fps.
    private func buildScene() -> SCNScene {
        let scene = SCNScene()

        let controller = SCNNode()
        controller.name = "controller"

        // The model is the app's own controller glyph, the artwork in the
        // menu bar and the sidebar, extruded into one smooth satin shape.
        // Nothing is modelled on top of it: no sticks, no buttons. A
        // silhouette everyone in the app already knows, tilting in three
        // dimensions, says "this is the controller" more cleanly than a
        // built-up toy ever did.
        // The outline is a traced drawing with hundreds of tiny curve
        // segments. SceneKit's own extrusion gives every wall segment a flat
        // normal, so the sides shade as ridges, and its chamfer pinches
        // around the small cut-outs. The solid is built by hand instead:
        // two flat caps from the outline, and a wall mesh whose normals are
        // averaged along the outline so the sides are one smooth surface.
        let satin = SCNMaterial()
        satin.lightingModel = .physicallyBased
        satin.diffuse.contents = NSColor(white: 0.93, alpha: 1)
        satin.roughness.contents = 0.38
        satin.metalness.contents = 0.0
        let shellNode = GlyphSolid.node(path: ControllerGlyphPath.bezier(), depth: 0.22, material: satin)
        shellNode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        controller.addChildNode(shellNode)

        scene.rootNode.addChildNode(controller)

        // Camera a little lower and closer than before, so the shell's
        // curve and the light bar are in view rather than a flat top-down.
        let camera = SCNCamera()
        // Horizontal projection, so the model's width fills the view and
        // a wide, short view (the calibrator) is not mostly empty.
        camera.projectionDirection = .horizontal
        camera.fieldOfView = fieldOfView
        camera.zNear = 0.1
        camera.zFar = 50
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 3.0, 3.3)
        cameraNode.look(at: SCNVector3(0, 0, -0.05))
        scene.rootNode.addChildNode(cameraNode)

        // Physically based shading needs an environment to reflect; a soft
        // vertical gradient stands in for a studio, bright above and dark
        // below, so the white shell picks up a gentle sheen along its
        // curves and the black plate stays deep.
        scene.lightingEnvironment.contents = Self.studioEnvironment()
        scene.lightingEnvironment.intensity = 1.1

        // Soft studio lighting: a broad key from upper left, a cool fill
        // from the right, a faint rim from behind. Lower intensities than
        // before, since the environment now carries the base light.
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.color = NSColor(calibratedRed: 1.0, green: 0.98, blue: 0.95, alpha: 1)
        key.light?.intensity = 700
        key.position = SCNVector3(-3, 6, 4)
        key.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(key)

        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .directional
        fill.light?.color = NSColor(calibratedRed: 0.80, green: 0.88, blue: 1.0, alpha: 1)
        fill.light?.intensity = 260
        fill.position = SCNVector3(4, 3, 3)
        fill.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(fill)

        let rim = SCNNode()
        rim.light = SCNLight()
        rim.light?.type = .directional
        rim.light?.color = NSColor(calibratedRed: 0.70, green: 0.85, blue: 1.0, alpha: 1)
        rim.light?.intensity = 320
        rim.position = SCNVector3(0, 3, -5)
        rim.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(rim)

        return scene
    }

    /// A small vertical gradient used as the reflection environment.
    private static func studioEnvironment() -> NSImage {
        let size = NSSize(width: 64, height: 64)
        let image = NSImage(size: size)
        image.lockFocus()
        let gradient = NSGradient(colors: [
            NSColor(white: 0.16, alpha: 1),
            NSColor(white: 0.55, alpha: 1),
            NSColor(white: 0.95, alpha: 1),
        ], atLocations: [0, 0.55, 1], colorSpace: .deviceGray)
        gradient?.draw(in: NSRect(origin: .zero, size: size), angle: 90)
        image.unlockFocus()
        return image
    }
}


/// The app's controller glyph as a bezier path, from the same SVG the
/// asset catalog holds. Only M, m, c and z appear in it.
enum ControllerGlyphPath {
    private static let data: [String] = [
        """
M6227 15234 c-3 -4 -68 -11 -144 -16 -232 -16 -293 -23 -513 -58 -51 -9 -80 -14 -222 -39 -59 -11 -123 -25 -183 -40 -104 -26 -132 -33 -163 -38 -18 -3 -35 -9 -38 -14 -3 -5 -16 -9 -29 -9 -13 0 -27 -4 -30 -10 -3 -5 -17 -10 -30 -10 -13 0 -27 -4 -30 -10 -3 -5 -17 -10 -30 -10 -13 0 -27 -4 -30 -10 -3 -5 -15 -10 -26 -10 -10 0 -27 -4 -37 -9 -18 -9 -63 -28 -97 -41 -73 -28 -200 -97 -255 -138 -42 -32 -140 -132 -140 -143 0 -4 -6 -14 -13 -21 -6 -7 -23 -35 -36 -63 -13 -27 -27 -58 -32 -67 -5 -10 -9 -26 -9 -36 0 -10 -4 -22 -9 -27 -5 -6 -12 -28 -15 -50 -3 -22 -10 -69 -16 -105 -13 -77 -24 -260 -16 -260 3 0 25 19 50 43 124 119 289 236 446 314 30 15 57 31 58 35 2 4 10 8 17 8 7 0 33 10 57 21 45 23 61 29 118 49 42 15 79 29 102 41 10 5 25 9 33 9 8 0 23 4 33 9 9 5 37 14 62 21 25 7 53 16 62 21 10 5 29 9 42 9 14 0 28 5 31 10 3 6 21 10 40 10 19 0 36 4 39 9 3 5 23 11 43 14 21 3 58 11 83 17 101 25 326 65 455 80 355 41 487 50 880 56 211 4 345 10 353 16 15 13 17 224 2 233 -5 3 -10 15 -10 26 0 10 -24 43 -52 73 -50 52 -107 85 -173 102 -37 9 -619 17 -628 8z
""",
        """
M13660 15230 c-8 -5 -28 -10 -43 -10 -39 0 -129 -46 -165 -84 -56 -58 -69 -95 -77 -208 -11 -163 -55 -145 373 -152 506 -8 821 -35 1132 -96 77 -15 158 -30 203 -36 20 -4 40 -10 43 -15 3 -5 18 -9 34 -9 16 0 31 -4 34 -9 3 -5 22 -12 41 -15 19 -3 51 -9 70 -12 19 -3 38 -10 41 -15 3 -5 18 -9 34 -9 16 0 32 -4 35 -10 3 -5 17 -10 30 -10 13 0 27 -4 30 -10 3 -5 16 -10 29 -10 12 0 26 -4 32 -8 5 -4 27 -14 49 -21 22 -7 49 -16 60 -20 59 -24 74 -30 120 -51 105 -48 223 -110 267 -141 14 -11 31 -19 37 -19 6 0 11 -4 11 -10 0 -5 5 -10 12 -10 22 0 217 -155 267 -212 37 -43 44 -35 38 45 -18 225 -44 360 -90 457 -41 87 -134 198 -199 238 -16 9 -28 20 -28 24 0 4 -5 8 -11 8 -6 0 -29 13 -52 29 -58 39 -134 77 -247 123 -14 6 -33 14 -42 19 -10 5 -29 9 -42 9 -14 0 -28 5 -31 10 -3 6 -17 10 -30 10 -13 0 -27 5 -30 10 -3 6 -17 10 -30 10 -13 0 -26 4 -29 9 -3 5 -20 11 -38 14 -18 3 -51 10 -73 17 -78 22 -178 45 -265 61 -30 5 -80 14 -110 20 -163 30 -407 58 -680 80 -193 15 -691 22 -710 9z
""",
        """
M6285 14559 c-156 -8 -262 -18 -395 -39 -36 -5 -94 -14 -130 -19 -85 -13 -164 -28 -220 -40 -93 -21 -146 -32 -178 -38 -18 -3 -35 -9 -38 -14 -3 -5 -18 -9 -34 -9 -16 0 -32 -4 -35 -10 -3 -5 -19 -10 -35 -10 -16 0 -31 -4 -34 -8 -3 -4 -28 -14 -56 -22 -28 -8 -53 -18 -56 -22 -3 -4 -14 -8 -25 -8 -10 0 -27 -4 -37 -9 -9 -5 -28 -13 -42 -19 -57 -23 -108 -45 -154 -68 -28 -13 -55 -24 -62 -24 -7 0 -14 -3 -16 -7 -3 -7 -72 -45 -155 -87 -13 -6 -23 -14 -23 -18 0 -5 -5 -8 -10 -8 -10 0 -159 -96 -170 -110 -3 -3 -21 -17 -40 -30 -19 -14 -46 -34 -59 -46 -13 -13 -54 -49 -91 -81 -36 -32 -85 -80 -108 -108 -23 -27 -56 -66 -72 -85 -103 -119 -235 -351 -281 -495 -7 -22 -17 -44 -21 -50 -4 -5 -8 -18 -8 -30 0 -12 -4 -25 -8 -30 -5 -6 -19 -44 -31 -85 -13 -41 -27 -83 -32 -92 -5 -10 -9 -25 -9 -33 0 -8 -4 -23 -9 -33 -5 -9 -19 -51 -31 -92 -12 -41 -26 -83 -31 -92 -5 -10 -9 -29 -9 -42 0 -14 -4 -28 -10 -31 -5 -3 -10 -19 -10 -35 0 -16 -4 -32 -10 -35 -5 -3 -10 -17 -10 -31 0 -13 -4 -32 -9 -42 -14 -29 -31 -87 -31 -110 0 -11 -4 -24 -10 -27 -5 -3 -10 -19 -10 -35 0 -16 -4 -32 -10 -35 -5 -3 -10 -19 -10 -35 0 -16 -4 -32 -10 -35 -5 -3 -10 -17 -10 -31 0 -13 -4 -32 -9 -42 -15 -31 -31 -88 -31 -115 0 -14 -4 -29 -10 -32 -5 -3 -10 -19 -10 -35 0 -16 -4 -32 -10 -35 -5 -3 -10 -16 -10 -27 0 -20 -13 -68 -31 -113 -4 -11 -10 -31 -13 -45 -2 -14 -10 -43 -16 -65 -7 -22 -14 -55 -17 -73 -3 -18 -9 -35 -14 -38 -5 -3 -9 -20 -9 -39 0 -19 -4 -36 -9 -39 -5 -3 -11 -20 -14 -38 -3 -18 -10 -51 -16 -73 -5 -22 -13 -53 -16 -70 -4 -16 -10 -39 -15 -50 -5 -11 -11 -33 -15 -50 -8 -39 -21 -90 -35 -140 -7 -22 -14 -57 -17 -78 -3 -20 -9 -40 -14 -43 -5 -3 -9 -20 -9 -39 0 -19 -4 -37 -10 -40 -5 -3 -10 -21 -10 -40 0 -19 -4 -36 -9 -39 -5 -3 -11 -20 -14 -38 -3 -18 -10 -52 -16 -75 -16 -63 -30 -117 -41 -165 -6 -24 -15 -61 -21 -83 -6 -22 -14 -58 -19 -80 -5 -22 -14 -60 -20 -85 -6 -25 -14 -58 -16 -75 -3 -16 -9 -39 -14 -50 -5 -11 -11 -33 -14 -50 -2 -16 -10 -50 -16 -75 -6 -25 -16 -65 -21 -90 -5 -25 -14 -64 -19 -87 -25 -109 -31 -140 -36 -173 -3 -19 -9 -44 -14 -55 -5 -11 -11 -36 -14 -55 -2 -19 -10 -55 -16 -80 -6 -25 -15 -67 -20 -95 -5 -27 -14 -75 -20 -105 -15 -78 -28 -145 -40 -220 -6 -36 -15 -87 -20 -115 -5 -27 -12 -72 -15 -100 -4 -27 -10 -59 -15 -70 -5 -11 -12 -49 -15 -85 -3 -36 -10 -96 -15 -135 -44 -348 -53 -489 -53 -880 0 -338 6 -455 33 -600 6 -33 13 -78 16 -100 4 -22 10 -44 15 -49 5 -6 9 -21 9 -35 0 -13 4 -38 10 -55 52 -166 51 -162 85 -241 10 -22 24 -56 32 -75 31 -72 118 -245 129 -258 7 -6 16 -21 19 -32 3 -11 11 -20 16 -20 5 0 9 -6 9 -13 0 -7 8 -22 18 -33 10 -10 28 -35 42 -54 13 -19 27 -37 30 -40 3 -3 17 -21 32 -41 34 -46 151 -163 197 -197 20 -15 38 -29 41 -33 16 -18 226 -149 240 -149 4 0 28 -10 52 -21 53 -27 72 -34 123 -50 22 -6 49 -15 60 -20 75 -29 199 -42 415 -42 204 0 276 6 380 33 25 6 57 14 73 17 15 3 30 9 33 14 3 5 14 9 25 9 10 0 27 4 37 9 9 5 58 28 107 52 86 42 245 134 255 148 3 4 21 18 40 31 19 13 42 31 50 40 8 8 40 36 70 61 81 69 168 156 230 229 30 36 57 67 60 70 3 3 35 43 70 90 36 47 68 87 71 90 9 8 149 219 149 225 0 3 5 11 10 18 16 19 110 167 110 173 0 3 18 32 40 64 22 32 40 64 40 69 0 6 4 11 9 11 5 0 11 8 14 18 6 17 37 72 47 82 3 3 15 23 26 45 12 22 40 70 63 107 22 37 41 72 41 78 0 5 4 10 9 10 5 0 11 8 14 18 6 17 37 72 47 82 10 10 41 65 47 83 3 9 9 17 14 17 5 0 9 5 9 11 0 6 8 23 19 37 10 15 28 43 38 62 11 19 43 71 70 115 27 44 56 91 64 105 8 14 16 27 19 30 5 5 18 27 44 75 6 11 14 22 17 25 3 3 24 33 47 66 94 140 264 285 419 359 43 20 86 41 95 46 10 5 29 9 42 9 14 0 27 4 30 9 3 5 20 11 38 14 18 3 60 12 93 19 48 10 633 13 2870 13 1546 0 2828 -4 2850 -8 116 -23 151 -31 159 -39 6 -4 18 -8 28 -8 10 0 26 -4 36 -9 9 -5 49 -24 87 -42 202 -96 376 -252 516 -464 104 -157 154 -235 179 -279 10 -18 24 -44 32 -57 7 -13 15 -26 18 -29 3 -3 11 -15 18 -27 6 -13 18 -33 25 -45 6 -13 14 -25 17 -28 3 -3 10 -14 16 -25 26 -48 39 -70 44 -75 3 -3 15 -23 27 -45 38 -71 59 -108 122 -213 33 -56 61 -107 61 -112 0 -6 3 -10 8 -10 4 0 12 -10 18 -23 35 -71 323 -521 344 -537 3 -3 17 -21 30 -40 13 -19 30 -41 37 -48 7 -7 13 -17 13 -20 0 -4 10 -18 23 -32 12 -14 38 -45 57 -70 87 -115 395 -398 478 -441 15 -8 29 -17 32 -20 28 -36 366 -189 417 -189 12 0 24 -4 27 -9 3 -5 23 -11 43 -14 21 -3 65 -12 98 -18 67 -15 454 -18 520 -6 60 12 181 43 230 59 79 27 285 128 285 140 0 4 6 8 13 8 18 0 170 119 245 192 115 112 240 278 313 418 19 36 36 67 39 70 7 7 23 41 76 168 9 20 20 45 25 54 5 10 9 27 9 37 0 11 5 23 10 26 6 3 10 17 10 30 0 13 4 26 9 29 5 3 11 18 14 33 3 16 11 46 17 68 54 187 95 541 92 805 -1 140 -19 454 -32 570 -5 47 -14 126 -19 175 -13 111 -29 240 -41 320 -5 33 -14 89 -19 125 -6 36 -15 89 -20 118 -22 106 -32 158 -41 207 -13 68 -27 140 -40 200 -6 28 -15 73 -20 100 -21 105 -57 271 -80 365 -6 25 -14 59 -16 75 -3 17 -9 39 -14 50 -5 11 -11 34 -14 50 -2 17 -10 50 -16 75 -15 59 -30 127 -36 165 -3 17 -9 39 -14 50 -5 11 -11 34 -15 50 -3 17 -10 47 -15 68 -25 98 -30 115 -40 157 -6 25 -14 59 -16 75 -3 17 -9 39 -14 50 -5 11 -11 36 -15 55 -3 19 -8 50 -12 68 -3 18 -9 35 -14 38 -5 3 -9 20 -9 39 0 19 -4 37 -10 40 -5 3 -10 21 -10 40 0 19 -4 36 -9 39 -5 3 -11 20 -14 38 -9 54 -18 92 -27 113 -5 11 -11 34 -15 50 -3 17 -10 46 -15 65 -5 19 -12 49 -15 65 -4 17 -10 39 -15 50 -5 11 -11 31 -14 45 -3 14 -8 39 -11 55 -4 17 -10 39 -15 50 -5 11 -11 31 -14 45 -2 14 -9 42 -15 63 -6 20 -16 54 -22 75 -6 20 -13 48 -15 62 -3 14 -9 34 -14 45 -5 11 -11 31 -14 45 -2 14 -10 43 -16 65 -7 22 -14 55 -17 73 -3 18 -9 35 -14 38 -5 3 -9 15 -9 26 0 23 -17 81 -31 110 -5 10 -9 29 -9 42 0 14 -4 28 -10 31 -5 3 -10 19 -10 35 0 16 -4 32 -10 35 -5 3 -10 17 -10 31 0 13 -4 32 -9 42 -5 9 -15 37 -21 62 -7 25 -16 56 -20 70 -4 14 -13 45 -20 70 -28 101 -33 116 -41 132 -5 10 -9 25 -9 33 0 8 -4 23 -9 33 -5 9 -14 35 -20 57 -7 22 -16 49 -20 60 -5 11 -14 38 -20 60 -7 22 -16 49 -20 60 -5 11 -18 52 -30 90 -12 39 -26 80 -32 93 -5 12 -13 32 -18 45 -45 113 -123 271 -142 287 -3 3 -24 32 -46 65 -23 33 -49 69 -60 80 -10 11 -30 36 -44 55 -38 50 -196 209 -249 250 -25 19 -47 37 -50 40 -22 23 -156 117 -211 148 -20 11 -47 26 -60 34 -13 7 -26 15 -29 19 -3 3 -63 33 -135 68 -155 75 -176 84 -255 111 -19 7 -44 16 -55 20 -11 4 -40 14 -65 21 -25 7 -49 16 -55 19 -5 4 -23 10 -40 14 -42 10 -93 23 -140 36 -109 31 -183 47 -372 80 -145 26 -373 47 -638 59 -240 11 -7566 11 -7800 0z m8600 -690 c5 -5 16 -9 25 -9 31 0 145 -67 196 -115 22 -21 94 -135 94 -149 0 -8 5 -18 10 -21 6 -3 10 -17 10 -30 0 -13 5 -27 10 -30 6 -3 10 -21 10 -39 0 -18 5 -48 12 -66 8 -25 8 -49 -1 -99 -35 -182 -102 -297 -223 -379 -26 -18 -51 -32 -57 -32 -6 0 -19 -4 -29 -9 -46 -23 -98 -31 -208 -31 -66 0 -124 4 -130 8 -5 4 -27 14 -49 21 -76 26 -176 107 -214 174 -38 68 -49 92 -70 158 -14 44 -15 265 -1 274 6 3 10 15 10 26 0 10 4 27 9 37 5 9 16 32 23 50 7 17 16 32 20 32 5 0 8 7 8 15 0 28 117 140 181 173 34 18 69 32 78 32 10 0 21 4 27 9 18 19 239 19 259 0z m-8948 -72 c186 -58 223 -136 223 -467 0 -175 -9 -258 -31 -302 -5 -10 -9 -24 -9 -31 0 -31 -246 -280 -311 -315 -43 -23 -142 -31 -154 -12 -3 6 -14 10 -23 10 -31 0 -231 179 -297 266 -45 59 -54 94 -67 278 -9 135 -9 191 2 275 7 58 16 112 20 121 4 8 14 28 21 44 18 37 68 87 105 105 16 7 37 17 46 22 10 5 28 9 40 9 13 0 30 5 38 10 8 5 85 10 170 10 134 0 165 -3 227 -23z m7850 -928 c27 -6 56 -15 65 -20 10 -5 22 -9 28 -9 42 0 240 -171 240 -207 0 -7 3 -13 8 -13 6 0 13 -14 42 -85 31 -78 37 -196 15 -290 -35 -150 -189 -308 -345 -354 -25 -7 -58 -17 -74 -22 -38 -12 -161 -11 -200 0 -17 5 -51 15 -76 22 -61 18 -146 72 -201 130 -46 48 -109 156 -109 188 0 9 -5 22 -12 29 -17 17 -17 237 1 282 34 91 74 155 135 216 55 56 156 113 231 132 56 13 196 14 252 1z m2152 0 c180 -58 284 -144 354 -292 32 -67 40 -104 40 -202 1 -122 -9 -164 -67 -270 -23 -42 -153 -161 -201 -184 -99 -47 -128 -53 -250 -54 -112 0 -164 15 -285 84 -44 25 -144 133 -166 179 -50 103 -73 230 -56 296 7 24 12 53 12 64 0 20 4 29 28 77 7 13 12 29 12 37 0 8 3 16 8 18 4 2 20 22 35 45 30 44 87 99 127 122 33 19 100 52 125 61 78 29 222 39 284 19z m-11022 -20 c27 -6 56 -15 65 -20 10 -5 23 -9 29 -9 46 0 351 -296 390 -379 23 -48 21 -64 -16 -146 -15 -34 -179 -205 -240 -250 -22 -17 -42 -32 -45 -35 -10 -10 -96 -49 -130 -58 -19 -6 -51 -15 -71 -21 -71 -22 -315 -9 -371 20 -10 5 -26 9 -36 9 -22 0 -72 22 -72 33 0 4 -6 7 -14 7 -20 0 -77 67 -102 120 -37 76 -46 144 -41 300 2 80 8 163 14 185 34 136 110 209 253 240 71 16 326 18 387 4z m1968 1 c3 -5 16 -10 28 -10 35 0 94 -24 141 -57 42 -30 86 -104 115 -194 15 -47 15 -342 0 -388 -41 -127 -78 -178 -160 -218 -125 -60 -259 -76 -453 -52 -144 18 -211 56 -360 204 -169 167 -176 178 -176 254 0 80 19 108 171 257 149 144 225 194 300 194 13 0 31 5 39 10 20 13 347 13 355 0z m-1087 -739 c9 -5 30 -15 45 -22 43 -20 272 -255 295 -302 36 -76 44 -141 39 -342 -3 -104 -8 -208 -12 -230 -14 -71 -67 -130 -155 -172 -64 -31 -115 -37 -290 -36 -158 1 -236 8 -246 24 -3 5 -12 9 -20 9 -19 0 -102 56 -129 87 -20 22 -28 47 -54 156 -23 98 -10 401 20 459 5 10 9 23 9 29 0 48 282 329 332 329 9 0 20 5 23 10 8 12 119 13 143 1z m9074 -200 c13 -5 41 -14 63 -20 123 -37 212 -116 272 -241 47 -98 55 -136 50 -230 -6 -134 -42 -227 -118 -314 -41 -46 -148 -126 -169 -126 -5 0 -18 -4 -28 -9 -63 -32 -275 -44 -351 -20 -89 28 -162 72 -214 129 -51 55 -97 133 -97 164 0 8 -4 18 -10 21 -5 3 -10 18 -10 32 0 14 -5 43 -12 65 -12 41 0 157 24 223 44 125 130 229 226 275 26 12 55 26 64 31 10 5 28 9 40 9 13 0 30 5 38 10 19 12 201 13 232 1z m-6690 -682 c9 -5 30 -9 47 -9 16 0 33 -4 36 -10 3 -5 15 -10 26 -10 10 0 27 -4 37 -9 16 -8 31 -15 100 -43 17 -7 32 -16 32 -20 0 -5 5 -8 10 -8 19 0 153 -96 205 -147 28 -26 64 -66 80 -88 17 -22 36 -46 42 -53 7 -7 27 -39 46 -70 111 -194 141 -305 139 -526 -1 -179 -21 -286 -73 -388 -5 -10 -9 -25 -9 -33 0 -8 -3 -15 -8 -15 -4 0 -13 -15 -21 -32 -26 -60 -73 -122 -155 -204 -77 -77 -163 -144 -184 -144 -6 0 -12 -4 -14 -8 -8 -21 -194 -97 -278 -114 -149 -31 -417 -25 -505 12 -11 4 -40 14 -65 21 -165 49 -365 201 -466 354 -52 79 -112 203 -133 275 -37 130 -57 294 -47 377 15 113 24 168 34 203 6 19 14 46 17 60 10 37 65 149 97 197 15 23 28 46 28 51 0 6 3 12 8 14 4 2 27 28 52 58 50 61 69 80 120 119 19 14 44 34 54 44 11 9 26 17 33 17 7 0 13 4 13 9 0 5 8 11 18 14 9 3 28 12 42 20 14 8 39 20 55 27 17 7 38 16 47 21 10 5 27 9 37 9 11 0 22 4 25 9 19 29 427 46 478 20z m4503 2 c183 -55 230 -75 335 -144 77 -51 260 -229 260 -253 0 -8 4 -14 8 -14 4 0 19 -22 33 -50 13 -27 27 -50 32 -50 4 0 7 -8 7 -18 0 -10 4 -22 8 -28 11 -11 46 -104 60 -159 22 -82 26 -123 26 -260 0 -157 -9 -221 -47 -330 -21 -61 -72 -162 -111 -220 -52 -78 -185 -211 -263 -263 -82 -56 -198 -109 -283 -132 -25 -6 -61 -16 -80 -22 -49 -15 -332 -14 -400 1 -90 21 -134 34 -145 43 -5 4 -15 8 -22 8 -25 0 -158 69 -228 118 -178 125 -302 309 -363 537 -23 84 -25 104 -29 245 -6 194 12 286 87 445 54 113 106 184 214 290 98 97 121 113 251 178 33 16 68 33 77 38 10 5 27 9 37 9 11 0 22 4 25 9 6 9 31 14 156 31 76 10 311 4 355 -9z m-1569 -1910 c63 -39 85 -141 41 -192 -12 -14 -32 -31 -44 -37 -16 -9 -248 -12 -875 -12 -834 0 -854 1 -886 20 -37 23 -72 75 -72 108 0 46 36 93 90 119 19 9 243 12 870 12 815 1 846 0 876 -18z
"""
    ]

    static func bezier() -> NSBezierPath {
        let path = NSBezierPath()
        // SVG transforms in the file: scale(0.5), then translate(0, 2048)
        // scale(0.1, -0.1). Then the view box (85 222 855 573) is centred
        // and sized so the glyph is about two units wide, with Y flipped so
        // the path's +Y is the far edge once the shape is laid flat.
        let centre = NSPoint(x: 85 + 855 / 2, y: 222 + 573 / 2)
        let k: CGFloat = 855 / 2.1
        func map(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            let tx = 0.5 * (0.1 * x)
            let ty = 0.5 * (2048 - 0.1 * y)
            return NSPoint(x: (tx - centre.x) / k, y: -(ty - centre.y) / k)
        }
        let number = try! NSRegularExpression(pattern: "[MmCcZz]|-?\\d*\\.?\\d+")
        for d in data {
            let tokens = number.matches(in: d, range: NSRange(d.startIndex..., in: d))
                .map { String(d[Range($0.range, in: d)!]) }
            var i = 0
            var cur = NSPoint.zero
            var start = NSPoint.zero
            var cmd = "M"
            func next() -> CGFloat { defer { i += 1 }; return CGFloat(Double(tokens[i]) ?? 0) }
            while i < tokens.count {
                let t = tokens[i]
                if "MmCcZz".contains(t) { cmd = t; i += 1; if cmd == "z" || cmd == "Z" { path.close(); cur = start; continue } }
                switch cmd {
                case "M":
                    cur = NSPoint(x: next(), y: next()); start = cur; path.move(to: map(cur.x, cur.y)); cmd = "L"
                case "m":
                    cur = NSPoint(x: cur.x + next(), y: cur.y + next()); start = cur; path.move(to: map(cur.x, cur.y)); cmd = "l"
                case "L":
                    cur = NSPoint(x: next(), y: next()); path.line(to: map(cur.x, cur.y))
                case "l":
                    cur = NSPoint(x: cur.x + next(), y: cur.y + next()); path.line(to: map(cur.x, cur.y))
                case "C":
                    let c1 = NSPoint(x: next(), y: next()), c2 = NSPoint(x: next(), y: next())
                    cur = NSPoint(x: next(), y: next())
                    path.curve(to: map(cur.x, cur.y), controlPoint1: map(c1.x, c1.y), controlPoint2: map(c2.x, c2.y))
                case "c":
                    let c1 = NSPoint(x: cur.x + next(), y: cur.y + next())
                    let c2 = NSPoint(x: cur.x + next(), y: cur.y + next())
                    cur = NSPoint(x: cur.x + next(), y: cur.y + next())
                    path.curve(to: map(cur.x, cur.y), controlPoint1: map(c1.x, c1.y), controlPoint2: map(c2.x, c2.y))
                default:
                    i += 1
                }
            }
        }
        path.windingRule = .evenOdd
        path.flatness = 0.004
        return path
    }
}


/// An extruded solid from a bezier outline: flat caps, and walls with
/// normals averaged along the outline so a traced path's many tiny
/// segments shade as one continuous surface.
enum GlyphSolid {
    static func node(path: NSBezierPath, depth: CGFloat, material: SCNMaterial) -> SCNNode {
        let root = SCNNode()
        let half = depth / 2

        // Caps: the outline as a flat shape, one facing +Z and one -Z.
        for sign: CGFloat in [1, -1] {
            let cap = SCNShape(path: path, extrusionDepth: 0)
            cap.materials = [material]
            let n = SCNNode(geometry: cap)
            n.position = SCNVector3(0, 0, sign * half)
            if sign < 0 { n.eulerAngles = SCNVector3(Float.pi, 0, 0) }
            root.addChildNode(n)
        }

        // Walls: each closed contour becomes a strip of quads.
        let contours = Self.contours(of: path)
        var vertices: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [Int32] = []
        for (ci, poly) in contours.enumerated() where poly.count >= 3 {
            let inward = Self.isHole(ci, in: contours)
            let ccw = Self.signedArea(poly) > 0
            // Outward from the solid: for the outer contour that is away
            // from its interior; for a hole it is into the hole.
            let flip: Float = (ccw != inward) ? 1 : -1
            let n = poly.count
            var edgeNormals: [SIMD2<Float>] = []
            for k in 0..<n {
                let a = poly[k], b = poly[(k + 1) % n]
                let d = b - a
                let len = max(1e-6, (d * d).sum().squareRoot())
                edgeNormals.append(SIMD2(d.y, -d.x) / len * flip)
            }
            let base = Int32(vertices.count)
            for k in 0..<n {
                let prev = edgeNormals[(k + n - 1) % n], next = edgeNormals[k]
                var vn = prev + next
                let len = (vn * vn).sum().squareRoot()
                vn = len > 1e-6 ? vn / len : next
                let p = poly[k]
                vertices.append(SIMD3(p.x, p.y, Float(half)))
                vertices.append(SIMD3(p.x, p.y, Float(-half)))
                normals.append(SIMD3(vn.x, vn.y, 0))
                normals.append(SIMD3(vn.x, vn.y, 0))
            }
            for k in 0..<n {
                let t0 = base + Int32(k * 2), b0 = t0 + 1
                let t1 = base + Int32(((k + 1) % n) * 2), b1 = t1 + 1
                // Winding chosen so the face normal agrees with `flip`.
                if flip > 0 {
                    indices += [t0, b0, t1, t1, b0, b1]
                } else {
                    indices += [t0, t1, b0, t1, b1, b0]
                }
            }
        }
        guard !vertices.isEmpty else { return root }
        let vSrc = SCNGeometrySource(vertices: vertices.map { SCNVector3($0.x, $0.y, $0.z) })
        let nSrc = SCNGeometrySource(normals: normals.map { SCNVector3($0.x, $0.y, $0.z) })
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let walls = SCNGeometry(sources: [vSrc, nSrc], elements: [element])
        walls.materials = [material]
        root.addChildNode(SCNNode(geometry: walls))
        return root
    }

    /// The same solid as an ASCII STL, for checking in a 3D tool. The caps
    /// are triangulated by ear clipping after each hole is bridged into
    /// the outer contour, which is enough for a check file; SceneKit does
    /// its own triangulation for the on-screen caps.
    static func writeSTL(path: NSBezierPath, depth: CGFloat, to url: URL) -> Bool {
        let contours = Self.contours(of: path)
        guard !contours.isEmpty else { return false }
        let half = Float(depth / 2)
        var tris: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = []

        // Walls, identical to the on-screen mesh.
        for (ci, poly) in contours.enumerated() where poly.count >= 3 {
            let inward = isHole(ci, in: contours)
            let ccw = signedArea(poly) > 0
            let flip = (ccw != inward)
            let n = poly.count
            for k in 0..<n {
                let a = poly[k], b = poly[(k + 1) % n]
                let t0 = SIMD3(a.x, a.y, half), b0 = SIMD3(a.x, a.y, -half)
                let t1 = SIMD3(b.x, b.y, half), b1 = SIMD3(b.x, b.y, -half)
                if flip {
                    tris.append((t0, b0, t1)); tris.append((t1, b0, b1))
                } else {
                    tris.append((t0, t1, b0)); tris.append((t1, b1, b0))
                }
            }
        }

        // Caps: outer contours with their holes bridged, then ear clipped.
        let outers = contours.indices.filter { !isHole($0, in: contours) }
        for oi in outers {
            var outer = contours[oi]
            if signedArea(outer) < 0 { outer.reverse() }
            let holes = contours.indices.filter { $0 != oi && isHole($0, in: contours) && contains(contours[oi], contours[$0][0]) }
                .map { h -> [SIMD2<Float>] in
                    var p = contours[h]
                    if signedArea(p) > 0 { p.reverse() }   // holes clockwise
                    return p
                }
            let merged = bridge(outer: outer, holes: holes)
            let capTris = earClip(merged)
            for t in capTris {
                let a = SIMD3(t.0.x, t.0.y, half), b = SIMD3(t.1.x, t.1.y, half), c = SIMD3(t.2.x, t.2.y, half)
                tris.append((a, b, c))
                let a2 = SIMD3(t.0.x, t.0.y, -half), b2 = SIMD3(t.1.x, t.1.y, -half), c2 = SIMD3(t.2.x, t.2.y, -half)
                tris.append((a2, c2, b2))
            }
        }

        var out = "solid controller\n"
        for (a, b, c) in tris {
            let n = simd_normalize(simd_cross(b - a, c - a))
            let nn = n.x.isFinite ? n : SIMD3<Float>(0, 0, 1)
            out += String(format: "facet normal %g %g %g\n outer loop\n", nn.x, nn.y, nn.z)
            for v in [a, b, c] { out += String(format: "  vertex %g %g %g\n", v.x, v.y, v.z) }
            out += " endloop\nendfacet\n"
        }
        out += "endsolid controller\n"
        return (try? out.write(to: url, atomically: true, encoding: .utf8)) != nil
    }

    /// Join each hole to the outer contour with a zero-width bridge so
    /// the whole cap is one simple polygon for ear clipping.
    private static func bridge(outer: [SIMD2<Float>], holes: [[SIMD2<Float>]]) -> [SIMD2<Float>] {
        var poly = outer
        // Holes with the largest x first, the standard order for bridging.
        let ordered = holes.sorted { ($0.map(\.x).max() ?? 0) > ($1.map(\.x).max() ?? 0) }
        for hole in ordered {
            guard let hi = hole.indices.max(by: { hole[$0].x < hole[$1].x }) else { continue }
            let hp = hole[hi]
            // Nearest polygon vertex to the right of the hole's rightmost point.
            var best = -1; var bestD = Float.greatestFiniteMagnitude
            for (i, p) in poly.enumerated() where p.x >= hp.x {
                let d = simd_length_squared(p - hp)
                if d < bestD { bestD = d; best = i }
            }
            if best < 0 { best = poly.indices.min(by: { simd_length_squared(poly[$0] - hp) < simd_length_squared(poly[$1] - hp) }) ?? 0 }
            var rotated = Array(hole[hi...]) + Array(hole[..<hi])
            rotated.append(hp)               // back to the hole's start
            rotated.append(poly[best])       // and back onto the outer
            poly.insert(contentsOf: rotated, at: best + 1)
        }
        return poly
    }

    private static func earClip(_ input: [SIMD2<Float>]) -> [(SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)] {
        var v = input
        var out: [(SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)] = []
        func cross(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Float {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        func inside(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Bool {
            cross(a, b, p) >= 0 && cross(b, c, p) >= 0 && cross(c, a, p) >= 0
        }
        var guardCount = 0
        while v.count > 3 && guardCount < 200_000 {
            guardCount += 1
            var clipped = false
            for i in 0..<v.count {
                let a = v[(i + v.count - 1) % v.count], b = v[i], c = v[(i + 1) % v.count]
                if cross(a, b, c) <= 1e-9 { continue }
                var ear = true
                for (j, p) in v.enumerated() where j != i && j != (i + v.count - 1) % v.count && j != (i + 1) % v.count {
                    if p == a || p == b || p == c { continue }
                    if inside(p, a, b, c) { ear = false; break }
                }
                if ear {
                    out.append((a, b, c)); v.remove(at: i); clipped = true; break
                }
            }
            if !clipped { break }
        }
        if v.count == 3 { out.append((v[0], v[1], v[2])) }
        return out
    }

    /// Closed polygons from the path, flattened.
    private static func contours(of path: NSBezierPath) -> [[SIMD2<Float>]] {
        let flat = path.flattened
        var out: [[SIMD2<Float>]] = []
        var cur: [SIMD2<Float>] = []
        var pts = [NSPoint](repeating: .zero, count: 3)
        for i in 0..<flat.elementCount {
            switch flat.element(at: i, associatedPoints: &pts) {
            case .moveTo:
                if cur.count >= 3 { out.append(cur) }
                cur = [SIMD2(Float(pts[0].x), Float(pts[0].y))]
            case .lineTo:
                let p = SIMD2(Float(pts[0].x), Float(pts[0].y))
                if let last = cur.last, (last - p).max() == 0, (last - p).min() == 0 { continue }
                cur.append(p)
            case .closePath:
                if let first = cur.first, let last = cur.last, first == last { cur.removeLast() }
                if cur.count >= 3 { out.append(cur) }
                cur = []
            default:
                break
            }
        }
        if cur.count >= 3 { out.append(cur) }
        return out
    }

    private static func signedArea(_ poly: [SIMD2<Float>]) -> Float {
        var a: Float = 0
        for k in 0..<poly.count {
            let p = poly[k], q = poly[(k + 1) % poly.count]
            a += p.x * q.y - q.x * p.y
        }
        return a / 2
    }

    /// A contour is a hole when its first point lies inside an odd number
    /// of the other contours.
    private static func isHole(_ index: Int, in contours: [[SIMD2<Float>]]) -> Bool {
        let p = contours[index][0]
        var depth = 0
        for (i, c) in contours.enumerated() where i != index && contains(c, p) { depth += 1 }
        return depth % 2 == 1
    }

    private static func contains(_ poly: [SIMD2<Float>], _ p: SIMD2<Float>) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y),
               p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}
