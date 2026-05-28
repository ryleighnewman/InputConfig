import Foundation

/// Built-in example presets for common games and desktop use cases.
///
/// Two construction paths live here:
///   * `parse(...)` - for simple presets whose only state is input→output
///     bindings. Uses the legacy JSON format the app already imports.
///   * `BindingModel(...)` direct - for presets that exercise advanced
///     features (deadzone, variable sensitivity, sensitivity curve, haptic,
///     spoken feedback, turbo, macros, touchpad). The legacy JSON parser
///     intentionally does NOT carry those fields, so showcase presets
///     bypass it.
///
/// GCController extended-gamepad mapping reference (axes/buttons):
///   Axes:    0=LX, 1=LY, 2=RX, 3=RY, 4=LT, 5=RT
///   Buttons: 0=A/Cross, 1=B/Circle, 2=X/Square, 3=Y/Triangle,
///            4=LB, 5=RB, 6=LT(digital), 7=RT(digital),
///            8=Options/Share, 9=Menu/Start, 10=Home/PS,
///            11=L3, 12=R3, 13=DualSense touchpad button
///   Hat 0: D-pad (U/D/L/R)
struct ExamplePresets {

    // MARK: - Group taxonomy

    /// Default group names. `PresetStore` reads these to create the seeded
    /// groups on first launch, then assigns each preset by name lookup. The
    /// raw strings are intentionally human-friendly because they appear in
    /// the sidebar - no em dashes (Apple reviewer pattern; we use a
    /// semicolon-ish hyphen instead).
    enum GroupName {
        static let desktop = "Desktop & Productivity"
        static let gamingFPS = "Gaming - First-Person"
        static let gamingGenre = "Gaming - Genre"
        static let midi = "MIDI & Creative"
        static let showcase = "Feature Showcases"
    }

    /// Preset name → group name. Presets not in this map seed ungrouped.
    static let groupAssignments: [String: String] = [
        "Desktop Navigation":            GroupName.desktop,
        "Web Browsing":                  GroupName.desktop,
        "Mouse + Scroll":                GroupName.desktop,
        "Media Controller":              GroupName.desktop,
        "Presentation Remote":           GroupName.desktop,

        "FPS (PS5 DualSense)":           GroupName.gamingFPS,
        "FPS (Xbox)":                    GroupName.gamingFPS,
        "FPS (Switch Pro)":              GroupName.gamingFPS,
        "FPS (8BitDo)":                  GroupName.gamingFPS,

        "Minecraft":                     GroupName.gamingGenre,
        "Fortnite":                      GroupName.gamingGenre,
        "Racing Game":                   GroupName.gamingGenre,

        "MIDI: DAW Performance":         GroupName.midi,
        "MIDI: Drum Pad":                GroupName.midi,
        "MIDI: Transport Control":       GroupName.midi,

        "Showcase: Variable Sensitivity":   GroupName.showcase,
        "Showcase: Deadzone Calibration":   GroupName.showcase,
        "Showcase: Haptic Feedback":        GroupName.showcase,
        "Showcase: Spoken Feedback":        GroupName.showcase,
        "Showcase: Macros & Turbo":         GroupName.showcase,
        "Showcase: Touchpad Mouse":         GroupName.showcase,
        "Showcase: Steam Controller":       GroupName.showcase,
        "Showcase: Gyro Aim":               GroupName.showcase,
        "Showcase: Motion Cursor":          GroupName.showcase,
        "Showcase: Toggle Mode":            GroupName.showcase,
        "Showcase: Stacked Outputs":        GroupName.showcase,
        "Showcase: Auto-Launch + Cursor Confine": GroupName.showcase,
        "MIDI: CC Dials":                   GroupName.midi,
    ]

    /// Ordered group names so the sidebar shows them in the curated order.
    static let groupOrder: [String] = [
        GroupName.desktop,
        GroupName.gamingFPS,
        GroupName.gamingGenre,
        GroupName.midi,
        GroupName.showcase,
    ]

    /// Default sidebar tint for each ship group. Matches the palette
    /// stored in `PresetGroup.colorOptions`. The user can override these
    /// from the folder context menu; the values here are the first-launch
    /// defaults so the sidebar comes out colorful out of the box.
    static let groupDefaultColors: [String: String] = [
        GroupName.desktop:     "orange",
        GroupName.gamingFPS:   "green",
        GroupName.gamingGenre: "green",
        GroupName.midi:        "red",
        GroupName.showcase:    "teal",
    ]

    /// Per-feature lookup so the welcome demos can jump to the matching
    /// showcase preset. Key is a stable identifier; value is the preset name.
    static let demoPresetNames: [String: String] = [
        "variable_sensitivity": "Showcase: Variable Sensitivity",
        "deadzone":             "Showcase: Deadzone Calibration",
        "haptic":               "Showcase: Haptic Feedback",
        "speech":               "Showcase: Spoken Feedback",
        "macros":               "Showcase: Macros & Turbo",
        "touchpad":             "Showcase: Touchpad Mouse",
        "midi":                 "MIDI: DAW Performance",
        "gyro":                 "Showcase: Gyro Aim",
    ]

    // MARK: - The seed list

    static var all: [Preset] {
        return [
            // Desktop & Productivity
            desktopNavigation,
            webBrowsing,
            mouseScroll,
            mediaController,
            presentationRemote,

            // Gaming - First-Person (one per controller family)
            fpsDualSense,
            fpsXbox,
            fpsSwitchPro,
            fpsEightBitDo,

            // Gaming - Genre
            minecraft,
            fortnite,
            racingGame,

            // MIDI & Creative
            midiDawPerformance,
            midiDrumPad,
            midiTransportControl,

            // Feature Showcases (programmatic, exercise advanced features)
            showcaseVariableSensitivity,
            showcaseDeadzoneCalibration,
            showcaseHapticFeedback,
            showcaseSpokenFeedback,
            showcaseMacrosTurbo,
            showcaseTouchpadMouse,
            showcaseSteamController,
            showcaseGyroAim,
            showcaseMotionCursor,
            showcaseToggleMode,
            showcaseStackedOutputs,
            showcaseAutoLaunch,
            showcaseMidiCC,
        ]
    }

    // MARK: - Desktop & Productivity (JSON)

    static var desktopNavigation: Preset {
        parse("""
        {
            "name": "Desktop Navigation",
            "tag": "Cursor, scroll, and macOS shortcuts",
            "joysticks": [{
                "tag": "Left stick = cursor, right stick = scroll, face buttons = shortcuts",
                "binds": {
                    "axi 0 -": ["mou 0 - 16"],
                    "axi 0 +": ["mou 0 + 16"],
                    "axi 1 -": ["mou 1 - 16"],
                    "axi 1 +": ["mou 1 + 16"],
                    "axi 2 +": ["whe 0 + 5"],
                    "axi 2 -": ["whe 0 - 5"],
                    "axi 3 +": ["whe 1 + 5"],
                    "axi 3 -": ["whe 1 - 5"],
                    "axi 4 +": ["mbt 1"],
                    "axi 5 +": ["mbt 0"],
                    "btn 0": ["key 227", "key 4"],
                    "btn 1": ["key 227", "key 29"],
                    "btn 2": ["key 227", "key 27"],
                    "btn 3": ["key 227", "key 25"],
                    "btn 4": ["key 227", "key 43"],
                    "btn 5": ["key 227", "key 225", "key 43"],
                    "hat 0 U": ["key 82"],
                    "hat 0 D": ["key 81"],
                    "hat 0 L": ["key 80"],
                    "hat 0 R": ["key 79"],
                    "btn 8": ["key 227", "key 44"],
                    "btn 9": ["key 40"]
                }
            }]
        }
        """)
    }

    static var webBrowsing: Preset {
        parse("""
        {
            "name": "Web Browsing",
            "tag": "Mouse, scroll, tabs, and browser shortcuts",
            "joysticks": [{
                "tag": "Browse, scroll, switch tabs, navigate history",
                "binds": {
                    "axi 0 -": ["mou 0 - 18"],
                    "axi 0 +": ["mou 0 + 18"],
                    "axi 1 -": ["mou 1 - 18"],
                    "axi 1 +": ["mou 1 + 18"],
                    "axi 2 +": ["whe 0 + 5"],
                    "axi 2 -": ["whe 0 - 5"],
                    "axi 3 +": ["whe 1 + 5"],
                    "axi 3 -": ["whe 1 - 5"],
                    "btn 0": ["mbt 0"],
                    "btn 1": ["mbt 1"],
                    "btn 2": ["key 227", "key 26"],
                    "btn 3": ["key 227", "key 23"],
                    "btn 4": ["key 227", "key 54"],
                    "btn 5": ["key 227", "key 55"],
                    "axi 4 +": ["key 227", "key 55"],
                    "axi 5 +": ["key 227", "key 225", "key 55"],
                    "btn 8": ["key 227", "key 15"],
                    "btn 9": ["key 227", "key 43"]
                }
            }]
        }
        """)
    }

    static var mouseScroll: Preset {
        parse("""
        {
            "name": "Mouse + Scroll",
            "tag": "Dual-stick mouse and scroll",
            "joysticks": [{
                "tag": "Left stick = cursor, right stick = scroll, D-pad = nudge cursor",
                "binds": {
                    "axi 0 -": ["mou 0 - 20"],
                    "axi 0 +": ["mou 0 + 20"],
                    "axi 1 -": ["mou 1 - 20"],
                    "axi 1 +": ["mou 1 + 20"],
                    "axi 2 -": ["whe 0 - 6"],
                    "axi 2 +": ["whe 0 + 6"],
                    "axi 3 -": ["whe 1 - 6"],
                    "axi 3 +": ["whe 1 + 6"],
                    "btn 0": ["mbt 0"],
                    "btn 1": ["mbt 1"],
                    "btn 2": ["mbt 2"],
                    "hat 0 L": ["mou 0 - 12"],
                    "hat 0 R": ["mou 0 + 12"],
                    "hat 0 U": ["mou 1 - 12"],
                    "hat 0 D": ["mou 1 + 12"]
                }
            }]
        }
        """)
    }

    static var mediaController: Preset {
        parse("""
        {
            "name": "Media Controller",
            "tag": "Play, pause, volume, track skip",
            "joysticks": [{
                "tag": "Face buttons control playback, D-pad controls volume",
                "binds": {
                    "btn 0": ["key 232"],
                    "btn 1": ["key 233"],
                    "btn 2": ["key 234"],
                    "btn 3": ["key 235"],
                    "btn 4": ["key 237"],
                    "btn 5": ["key 238"],
                    "hat 0 U": ["key 128"],
                    "hat 0 D": ["key 129"],
                    "hat 0 L": ["key 130"],
                    "hat 0 R": ["key 131"],
                    "axi 1 -": ["key 128"],
                    "axi 1 +": ["key 129"],
                    "axi 0 -": ["key 130"],
                    "axi 0 +": ["key 131"],
                    "btn 8": ["key 41"]
                }
            }]
        }
        """)
    }

    static var presentationRemote: Preset {
        parse("""
        {
            "name": "Presentation Remote",
            "tag": "Slide navigation, laser pointer, blank screen",
            "joysticks": [{
                "tag": "A/B advance/back, X starts slideshow, left stick aims a pointer",
                "binds": {
                    "axi 0 -": ["mou 0 - 10"],
                    "axi 0 +": ["mou 0 + 10"],
                    "axi 1 -": ["mou 1 - 10"],
                    "axi 1 +": ["mou 1 + 10"],
                    "btn 0": ["key 79"],
                    "btn 1": ["key 80"],
                    "btn 2": ["key 44"],
                    "btn 3": ["key 5"],
                    "btn 4": ["mbt 0"],
                    "btn 5": ["mbt 1"],
                    "btn 8": ["key 41"],
                    "btn 9": ["key 62"]
                }
            }]
        }
        """)
    }

    // MARK: - Gaming - First-Person (JSON)

    static var fpsDualSense: Preset {
        parse("""
        {
            "name": "FPS (PS5 DualSense)",
            "tag": "PS5 DualSense FPS layout with touchpad as map",
            "joysticks": [{
                "tag": "WASD, mouse aim, triggers fire/ADS, touchpad opens map",
                "binds": {
                    "axi 0 -": ["key 4"],
                    "axi 0 +": ["key 7"],
                    "axi 1 -": ["key 26"],
                    "axi 1 +": ["key 22"],
                    "axi 2 +": ["mou 0 + 22"],
                    "axi 2 -": ["mou 0 - 22"],
                    "axi 3 +": ["mou 1 + 14"],
                    "axi 3 -": ["mou 1 - 14"],
                    "axi 5 +": ["mbt 0"],
                    "axi 4 +": ["mbt 1"],
                    "btn 0": ["key 44"],
                    "btn 1": ["key 224"],
                    "btn 2": ["key 21"],
                    "btn 3": ["key 30"],
                    "btn 4": ["key 33"],
                    "btn 5": ["mbt 2"],
                    "btn 11": ["key 225"],
                    "btn 12": ["key 25"],
                    "hat 0 U": ["whs 1 -"],
                    "hat 0 D": ["whs 1 +"],
                    "hat 0 L": ["key 20"],
                    "hat 0 R": ["key 9"],
                    "btn 8": ["key 43"],
                    "btn 9": ["key 41"],
                    "btn 13": ["key 8"]
                }
            }]
        }
        """)
    }

    static var fpsXbox: Preset {
        parse("""
        {
            "name": "FPS (Xbox)",
            "tag": "Xbox One / Series controller FPS layout",
            "joysticks": [{
                "tag": "WASD, mouse aim, triggers fire/ADS",
                "binds": {
                    "axi 0 -": ["key 4"],
                    "axi 0 +": ["key 7"],
                    "axi 1 -": ["key 26"],
                    "axi 1 +": ["key 22"],
                    "axi 2 +": ["mou 0 + 24"],
                    "axi 2 -": ["mou 0 - 24"],
                    "axi 3 +": ["mou 1 + 16"],
                    "axi 3 -": ["mou 1 - 16"],
                    "axi 5 +": ["mbt 0"],
                    "axi 4 +": ["mbt 1"],
                    "btn 0": ["key 44"],
                    "btn 1": ["key 6"],
                    "btn 2": ["key 21"],
                    "btn 3": ["key 30"],
                    "btn 4": ["key 33"],
                    "btn 5": ["mbt 2"],
                    "btn 11": ["key 225"],
                    "btn 12": ["key 8"],
                    "hat 0 U": ["whs 1 -"],
                    "hat 0 D": ["whs 1 +"],
                    "hat 0 L": ["key 20"],
                    "hat 0 R": ["key 9"],
                    "btn 8": ["key 41"],
                    "btn 9": ["key 43"]
                }
            }]
        }
        """)
    }

    static var fpsSwitchPro: Preset {
        parse("""
        {
            "name": "FPS (Switch Pro)",
            "tag": "Nintendo Switch Pro Controller FPS layout",
            "joysticks": [{
                "tag": "Standard FPS layout, Nintendo face button positions",
                "binds": {
                    "axi 0 -": ["key 4"],
                    "axi 0 +": ["key 7"],
                    "axi 1 -": ["key 26"],
                    "axi 1 +": ["key 22"],
                    "axi 2 +": ["mou 0 + 24"],
                    "axi 2 -": ["mou 0 - 24"],
                    "axi 3 +": ["mou 1 + 16"],
                    "axi 3 -": ["mou 1 - 16"],
                    "axi 5 +": ["mbt 0"],
                    "axi 4 +": ["mbt 1"],
                    "btn 0": ["key 44"],
                    "btn 1": ["key 6"],
                    "btn 2": ["key 21"],
                    "btn 3": ["key 30"],
                    "btn 4": ["key 33"],
                    "btn 5": ["mbt 2"],
                    "btn 11": ["key 225"],
                    "btn 12": ["key 8"],
                    "hat 0 U": ["whs 1 -"],
                    "hat 0 D": ["whs 1 +"],
                    "hat 0 L": ["key 20"],
                    "hat 0 R": ["key 9"],
                    "btn 8": ["key 43"],
                    "btn 9": ["key 41"]
                }
            }]
        }
        """)
    }

    static var fpsEightBitDo: Preset {
        parse("""
        {
            "name": "FPS (8BitDo)",
            "tag": "8BitDo Pro 2, Ultimate, SN30 Pro+ in Apple mode",
            "joysticks": [{
                "tag": "FPS layout tuned for 8BitDo triggers",
                "binds": {
                    "axi 0 -": ["key 4"],
                    "axi 0 +": ["key 7"],
                    "axi 1 -": ["key 26"],
                    "axi 1 +": ["key 22"],
                    "axi 2 +": ["mou 0 + 22"],
                    "axi 2 -": ["mou 0 - 22"],
                    "axi 3 +": ["mou 1 + 14"],
                    "axi 3 -": ["mou 1 - 14"],
                    "axi 5 +": ["mbt 0"],
                    "axi 4 +": ["mbt 1"],
                    "btn 0": ["key 44"],
                    "btn 1": ["key 6"],
                    "btn 2": ["key 21"],
                    "btn 3": ["key 30"],
                    "btn 4": ["key 33"],
                    "btn 5": ["mbt 2"],
                    "btn 11": ["key 225"],
                    "btn 12": ["key 8"],
                    "hat 0 U": ["whs 1 -"],
                    "hat 0 D": ["whs 1 +"],
                    "hat 0 L": ["key 20"],
                    "hat 0 R": ["key 9"],
                    "btn 8": ["key 41"],
                    "btn 9": ["key 43"]
                }
            }]
        }
        """)
    }

    // MARK: - Gaming - Genre (JSON)

    static var minecraft: Preset {
        var preset = parse("""
        {
            "name": "Minecraft",
            "tag": "Movement, look, mine, place, hotbar",
            "joysticks": [{
                "tag": "WASD + mouse look, triggers attack/place, RB/LB cycle hotbar",
                "binds": {
                    "axi 0 -": ["key 4"],
                    "axi 0 +": ["key 7"],
                    "axi 1 -": ["key 26"],
                    "axi 1 +": ["key 22"],
                    "axi 2 +": ["mou 0 + 20"],
                    "axi 2 -": ["mou 0 - 20"],
                    "axi 3 +": ["mou 1 + 14"],
                    "axi 3 -": ["mou 1 - 14"],
                    "axi 5 +": ["mbt 0"],
                    "axi 4 +": ["mbt 1"],
                    "btn 0": ["key 44"],
                    "btn 1": ["key 225"],
                    "btn 2": ["key 8"],
                    "btn 3": ["key 20"],
                    "btn 4": ["whs 1 -"],
                    "btn 5": ["whs 1 +"],
                    "btn 11": ["key 224"],
                    "btn 12": ["key 62"],
                    "hat 0 U": ["key 30"],
                    "hat 0 R": ["key 31"],
                    "hat 0 D": ["key 32"],
                    "hat 0 L": ["key 33"],
                    "btn 8": ["key 41"],
                    "btn 9": ["key 43"]
                }
            }]
        }
        """)
        // The legacy JSON parser doesn't carry automation, so we inject
        // it here. Mirrors what the Minecraft walkthrough teaches: the
        // launcher app fires on activate, the cursor confines + auto-
        // recenters + hides so the camera doesn't catch on the screen
        // edge. Survival-grass green light bar.
        preset.automation = PresetAutomation(
            launchAppPath: "/Applications/Minecraft.app",
            launchURL: "",
            confineCursor: true,
            confineBufferPx: 24,
            autoRecenterCursor: true,
            autoRecenterIntervalMs: 250,
            hideCursorWhileActive: true,
            sensitivityMultiplier: 1.0
        )
        preset.lightBarColor = RGBLightColor(r: 60, g: 200, b: 80)
        return preset
    }

    static var fortnite: Preset {
        parse("""
        {
            "name": "Fortnite",
            "tag": "Build, edit, shoot, ADS",
            "joysticks": [{
                "tag": "WASD aim and shoot, face buttons build, ADS on LT",
                "binds": {
                    "axi 0 -": ["key 4"],
                    "axi 0 +": ["key 7"],
                    "axi 1 -": ["key 26"],
                    "axi 1 +": ["key 22"],
                    "axi 2 +": ["mou 0 + 24"],
                    "axi 2 -": ["mou 0 - 24"],
                    "axi 3 +": ["mou 1 + 16"],
                    "axi 3 -": ["mou 1 - 16"],
                    "axi 5 +": ["mbt 0"],
                    "axi 4 +": ["mbt 1"],
                    "btn 0": ["key 44"],
                    "btn 1": ["key 10"],
                    "btn 2": ["key 21"],
                    "btn 3": ["key 27"],
                    "btn 4": ["key 20"],
                    "btn 5": ["key 8"],
                    "btn 11": ["key 225"],
                    "hat 0 U": ["key 30"],
                    "hat 0 R": ["key 31"],
                    "hat 0 D": ["key 32"],
                    "hat 0 L": ["key 33"],
                    "btn 8": ["key 41"],
                    "btn 9": ["key 43"]
                }
            }]
        }
        """)
    }

    static var racingGame: Preset {
        parse("""
        {
            "name": "Racing Game",
            "tag": "Steer with stick, gas and brake on triggers",
            "joysticks": [{
                "tag": "Left stick steers, RT accelerate, LT brake, face buttons handbrake/shift",
                "binds": {
                    "axi 0 -": ["key 4"],
                    "axi 0 +": ["key 7"],
                    "axi 5 +": ["key 26"],
                    "axi 4 +": ["key 22"],
                    "axi 2 +": ["mou 0 + 16"],
                    "axi 2 -": ["mou 0 - 16"],
                    "axi 3 +": ["mou 1 + 12"],
                    "axi 3 -": ["mou 1 - 12"],
                    "btn 0": ["key 44"],
                    "btn 1": ["key 225"],
                    "btn 2": ["key 8"],
                    "btn 3": ["key 21"],
                    "btn 4": ["key 20"],
                    "btn 5": ["key 9"],
                    "btn 8": ["key 41"],
                    "btn 9": ["key 43"]
                }
            }]
        }
        """)
    }

    // MARK: - MIDI & Creative (programmatic)
    //
    // Sends to JoystickConfig's virtual MIDI port, so any DAW listening on
    // CoreMIDI sees the events. GarageBand is the recommended easy starting
    // point; Logic, Ableton, Reaper, and others work the same way.

    static var midiDawPerformance: Preset {
        let bindings: [BindingModel] = [
            // Right stick X = pitch bend on channel 1 (centered, full range).
            BindingModel(input: .axis(2, direction: .positive),
                         outputs: [OutputAction(type: .midiPitchBend, midiChannel: 1)],
                         deadzone: 0.10, sensitivityCurve: .exponential),
            BindingModel(input: .axis(2, direction: .negative),
                         outputs: [OutputAction(type: .midiPitchBend, midiChannel: 1)],
                         deadzone: 0.10, sensitivityCurve: .exponential),
            // Right stick Y = CC 1 (mod wheel).
            BindingModel(input: .axis(3, direction: .positive),
                         outputs: [OutputAction(type: .midiCC, midiCCNumber: 1, midiChannel: 1)],
                         deadzone: 0.10),
            // Triggers = CC 7 (volume) and CC 11 (expression).
            BindingModel(input: .axis(4, direction: .positive),
                         outputs: [OutputAction(type: .midiCC, midiCCNumber: 11, midiChannel: 1)]),
            BindingModel(input: .axis(5, direction: .positive),
                         outputs: [OutputAction(type: .midiCC, midiCCNumber: 7, midiChannel: 1)]),
            // Face buttons play a C major chord, one note per button.
            BindingModel(input: .button(0),
                         outputs: [OutputAction(type: .midiNote, midiNote: 60, midiVelocity: 100, midiChannel: 1)],
                         hapticEnabled: true, hapticIntensity: 0.4),
            BindingModel(input: .button(1),
                         outputs: [OutputAction(type: .midiNote, midiNote: 64, midiVelocity: 100, midiChannel: 1)],
                         hapticEnabled: true, hapticIntensity: 0.4),
            BindingModel(input: .button(2),
                         outputs: [OutputAction(type: .midiNote, midiNote: 67, midiVelocity: 100, midiChannel: 1)],
                         hapticEnabled: true, hapticIntensity: 0.4),
            BindingModel(input: .button(3),
                         outputs: [OutputAction(type: .midiNote, midiNote: 72, midiVelocity: 100, midiChannel: 1)],
                         hapticEnabled: true, hapticIntensity: 0.4),
            // D-pad runs transport (start/stop/continue) plus a tap-tempo CC.
            BindingModel(input: .hat(0, direction: .up),
                         outputs: [OutputAction(type: .midiTransport, midiTransport: .start)]),
            BindingModel(input: .hat(0, direction: .down),
                         outputs: [OutputAction(type: .midiTransport, midiTransport: .stop)]),
            BindingModel(input: .hat(0, direction: .right),
                         outputs: [OutputAction(type: .midiTransport, midiTransport: .continue)]),
        ]
        return makePreset(
            name: "MIDI: DAW Performance",
            tag: "Expressive performance for GarageBand and other DAWs",
            joystickTag: "Right stick = pitch + mod, triggers = volume/expression, face buttons play C major",
            bindings: bindings)
    }

    static var midiDrumPad: Preset {
        // Drum mapping uses General MIDI percussion notes on channel 10.
        let drumNotes = [(0, 36, "Kick"), (1, 38, "Snare"), (2, 42, "Closed Hat"), (3, 46, "Open Hat")]
        var bindings: [BindingModel] = drumNotes.map { btn, note, _ in
            BindingModel(input: .button(btn),
                         outputs: [OutputAction(type: .midiNote, midiNote: note, midiVelocity: 110, midiChannel: 10)],
                         turboEnabled: true, turboRate: 8,
                         hapticEnabled: true, hapticIntensity: 0.5)
        }
        // Triggers roll alternating kick/snare for fast fills.
        bindings.append(BindingModel(input: .axis(4, direction: .positive),
                                     outputs: [OutputAction(type: .midiNote, midiNote: 41, midiVelocity: 100, midiChannel: 10)]))
        bindings.append(BindingModel(input: .axis(5, direction: .positive),
                                     outputs: [OutputAction(type: .midiNote, midiNote: 49, midiVelocity: 100, midiChannel: 10)]))
        return makePreset(
            name: "MIDI: Drum Pad",
            tag: "Finger-drumming pads with turbo for rolls",
            joystickTag: "Face buttons = drum kit pieces with turbo (hold for rolls), triggers = cymbals",
            bindings: bindings)
    }

    static var midiTransportControl: Preset {
        let bindings: [BindingModel] = [
            BindingModel(input: .button(0), outputs: [OutputAction(type: .midiTransport, midiTransport: .start)]),
            BindingModel(input: .button(1), outputs: [OutputAction(type: .midiTransport, midiTransport: .stop)]),
            BindingModel(input: .button(2), outputs: [OutputAction(type: .midiTransport, midiTransport: .continue)]),
            BindingModel(input: .button(4),
                         outputs: [OutputAction(type: .midiProgramChange, midiChannel: 1, midiProgramNumber: 0)]),
            BindingModel(input: .button(5),
                         outputs: [OutputAction(type: .midiProgramChange, midiChannel: 1, midiProgramNumber: 1)]),
            BindingModel(input: .hat(0, direction: .up),
                         outputs: [OutputAction(type: .midiCC, midiCCNumber: 7, midiCCValue: 127, midiChannel: 1)]),
            BindingModel(input: .hat(0, direction: .down),
                         outputs: [OutputAction(type: .midiCC, midiCCNumber: 7, midiCCValue: 0, midiChannel: 1)]),
        ]
        return makePreset(
            name: "MIDI: Transport Control",
            tag: "DAW remote: start, stop, continue, program change",
            joystickTag: "A = Start, B = Stop, X = Continue, LB/RB = patch up/down",
            bindings: bindings)
    }

    // MARK: - Feature Showcases (programmatic)

    static var showcaseVariableSensitivity: Preset {
        // Right stick uses a smooth (exponential) curve so small deflections
        // give precise control; large deflections accelerate. Left stick uses
        // an aggressive (sqrt) curve so even small deflections move fast.
        let bindings: [BindingModel] = [
            // Right stick = smooth mouse motion (precise aiming feel).
            BindingModel(input: .axis(2, direction: .positive),
                         outputs: [OutputAction(type: .mouseMotion, mouseAxis: .horizontal, mouseDirection: .positive, speed: 28)],
                         deadzone: 0.10, sensitivityCurve: .exponential, variableSensitivity: true),
            BindingModel(input: .axis(2, direction: .negative),
                         outputs: [OutputAction(type: .mouseMotion, mouseAxis: .horizontal, mouseDirection: .negative, speed: 28)],
                         deadzone: 0.10, sensitivityCurve: .exponential, variableSensitivity: true),
            BindingModel(input: .axis(3, direction: .positive),
                         outputs: [OutputAction(type: .mouseMotion, mouseAxis: .vertical, mouseDirection: .positive, speed: 22)],
                         deadzone: 0.10, sensitivityCurve: .exponential, variableSensitivity: true),
            BindingModel(input: .axis(3, direction: .negative),
                         outputs: [OutputAction(type: .mouseMotion, mouseAxis: .vertical, mouseDirection: .negative, speed: 22)],
                         deadzone: 0.10, sensitivityCurve: .exponential, variableSensitivity: true),
            // Left stick = aggressive mouse motion (snappy navigation feel).
            BindingModel(input: .axis(0, direction: .positive),
                         outputs: [OutputAction(type: .mouseMotion, mouseAxis: .horizontal, mouseDirection: .positive, speed: 14)],
                         deadzone: 0.10, sensitivityCurve: .aggressive, variableSensitivity: true),
            BindingModel(input: .axis(0, direction: .negative),
                         outputs: [OutputAction(type: .mouseMotion, mouseAxis: .horizontal, mouseDirection: .negative, speed: 14)],
                         deadzone: 0.10, sensitivityCurve: .aggressive, variableSensitivity: true),
            BindingModel(input: .axis(1, direction: .positive),
                         outputs: [OutputAction(type: .mouseMotion, mouseAxis: .vertical, mouseDirection: .positive, speed: 14)],
                         deadzone: 0.10, sensitivityCurve: .aggressive, variableSensitivity: true),
            BindingModel(input: .axis(1, direction: .negative),
                         outputs: [OutputAction(type: .mouseMotion, mouseAxis: .vertical, mouseDirection: .negative, speed: 14)],
                         deadzone: 0.10, sensitivityCurve: .aggressive, variableSensitivity: true),
            BindingModel(input: .button(0), outputs: [OutputAction(type: .mouseButton, mouseButtonIndex: 0)]),
        ]
        return makePreset(
            name: "Showcase: Variable Sensitivity",
            tag: "Right stick smooth curve, left stick aggressive curve",
            joystickTag: "Compare the two response curves by moving each stick at the same depth",
            bindings: bindings)
    }

    static var showcaseDeadzoneCalibration: Preset {
        // Right stick has a wide deadzone profile: inner 0.18 ignores noise,
        // outer 0.85 means the user reaches full speed without bottoming out
        // the stick. Left stick has a narrow profile to compare.
        let bindings: [BindingModel] = [
            // Right stick: generous deadzone profile.
            BindingModel(input: .axis(2, direction: .positive),
                         outputs: [OutputAction(type: .mouseMotion, mouseAxis: .horizontal, mouseDirection: .positive, speed: 24)],
                         deadzone: 0.18, outerDeadzone: 0.85, variableSensitivity: true),
            BindingModel(input: .axis(2, direction: .negative),
                         outputs: [OutputAction(type: .mouseMotion, mouseAxis: .horizontal, mouseDirection: .negative, speed: 24)],
                         deadzone: 0.18, outerDeadzone: 0.85, variableSensitivity: true),
            BindingModel(input: .axis(3, direction: .positive),
                         outputs: [OutputAction(type: .mouseMotion, mouseAxis: .vertical, mouseDirection: .positive, speed: 20)],
                         deadzone: 0.18, outerDeadzone: 0.85, variableSensitivity: true),
            BindingModel(input: .axis(3, direction: .negative),
                         outputs: [OutputAction(type: .mouseMotion, mouseAxis: .vertical, mouseDirection: .negative, speed: 20)],
                         deadzone: 0.18, outerDeadzone: 0.85, variableSensitivity: true),
            // Left stick: very tight deadzone, no outer saturation.
            BindingModel(input: .axis(0, direction: .positive),
                         outputs: [OutputAction(type: .mouseMotion, mouseAxis: .horizontal, mouseDirection: .positive, speed: 24)],
                         deadzone: 0.05, variableSensitivity: true),
            BindingModel(input: .axis(0, direction: .negative),
                         outputs: [OutputAction(type: .mouseMotion, mouseAxis: .horizontal, mouseDirection: .negative, speed: 24)],
                         deadzone: 0.05, variableSensitivity: true),
            BindingModel(input: .axis(1, direction: .positive),
                         outputs: [OutputAction(type: .mouseMotion, mouseAxis: .vertical, mouseDirection: .positive, speed: 20)],
                         deadzone: 0.05, variableSensitivity: true),
            BindingModel(input: .axis(1, direction: .negative),
                         outputs: [OutputAction(type: .mouseMotion, mouseAxis: .vertical, mouseDirection: .negative, speed: 20)],
                         deadzone: 0.05, variableSensitivity: true),
            BindingModel(input: .button(0), outputs: [OutputAction(type: .mouseButton, mouseButtonIndex: 0)]),
        ]
        return makePreset(
            name: "Showcase: Deadzone Calibration",
            tag: "Right stick wide deadzone + outer saturation, left stick tight",
            joystickTag: "Open Advanced > Calibrate on any axis row to see the live ring visualizer",
            bindings: bindings)
    }

    static var showcaseHapticFeedback: Preset {
        // Each face button maps to a letter and rumbles at a different
        // intensity so the user feels the gradient. DualSense / DualSense
        // Edge required; other controllers fall back silently.
        let bindings: [BindingModel] = [
            BindingModel(input: .button(0),
                         outputs: [OutputAction(type: .key, keyCode: 4)],   // "A"
                         hapticEnabled: true, hapticIntensity: 0.3),
            BindingModel(input: .button(1),
                         outputs: [OutputAction(type: .key, keyCode: 5)],   // "B"
                         hapticEnabled: true, hapticIntensity: 0.6),
            BindingModel(input: .button(2),
                         outputs: [OutputAction(type: .key, keyCode: 6)],   // "C"
                         hapticEnabled: true, hapticIntensity: 0.85),
            BindingModel(input: .button(3),
                         outputs: [OutputAction(type: .key, keyCode: 7)],   // "D"
                         hapticEnabled: true, hapticIntensity: 1.0),
        ]
        return makePreset(
            name: "Showcase: Haptic Feedback",
            tag: "Face buttons rumble at four intensities, A through D",
            joystickTag: "Press A/B/X/Y to type the letter and feel the haptic step up",
            bindings: bindings)
    }

    static var showcaseSpokenFeedback: Preset {
        let bindings: [BindingModel] = [
            BindingModel(input: .button(0),
                         outputs: [OutputAction(type: .key, keyCode: 4)],
                         speechEnabled: true, speechText: "Action one", speechDestination: .mac),
            BindingModel(input: .button(1),
                         outputs: [OutputAction(type: .key, keyCode: 5)],
                         speechEnabled: true, speechText: "Reload", speechDestination: .mac),
            BindingModel(input: .button(2),
                         outputs: [OutputAction(type: .key, keyCode: 6)],
                         speechEnabled: true, speechText: "Ready", speechDestination: .controller),
            BindingModel(input: .button(3),
                         outputs: [OutputAction(type: .key, keyCode: 7)],
                         speechEnabled: true, speechText: "Push forward", speechDestination: .controller),
        ]
        return makePreset(
            name: "Showcase: Spoken Feedback",
            tag: "Each face button speaks a phrase aloud",
            joystickTag: "A/B through Mac speakers, X/Y through controller speaker if available",
            bindings: bindings)
    }

    static var showcaseMacrosTurbo: Preset {
        // RB fires the spacebar 12 times per second while held (turbo).
        // A runs a macro that copies, switches windows, then pastes.
        // LB repeats the J key three times with a short delay.
        let copyPasteMacro: [MacroStep] = [
            MacroStep(action: OutputAction(type: .key, keyCode: 227),  // hold Command
                      delayMs: 0, holdMs: 250),
            MacroStep(action: OutputAction(type: .key, keyCode: 6),    // C while holding
                      delayMs: 30, holdMs: 60),
            MacroStep(action: OutputAction(type: .key, keyCode: 43),   // Tab to switch app
                      delayMs: 200, holdMs: 60),
            MacroStep(action: OutputAction(type: .key, keyCode: 227),  // hold Command again
                      delayMs: 250, holdMs: 250),
            MacroStep(action: OutputAction(type: .key, keyCode: 25),   // V to paste
                      delayMs: 30, holdMs: 60),
        ]
        let bindings: [BindingModel] = [
            BindingModel(input: .button(5),
                         outputs: [OutputAction(type: .key, keyCode: 44)],   // spacebar
                         turboEnabled: true, turboRate: 12,
                         hapticEnabled: true, hapticIntensity: 0.4),
            BindingModel(input: .button(0),
                         outputs: [],
                         macroSteps: copyPasteMacro),
            BindingModel(input: .button(4),
                         outputs: [OutputAction(type: .key, keyCode: 13)],   // J
                         repeatCount: 3, repeatDelayMs: 80),
        ]
        return makePreset(
            name: "Showcase: Macros & Turbo",
            tag: "RB = rapid space, A = copy/switch/paste macro, LB = triple J",
            joystickTag: "Hold RB for turbo, tap A for the macro chain, tap LB for repeat",
            bindings: bindings)
    }

    /// Functional touchpad preset. Requires DualSense / DualSense Edge / DS4.
    /// The touchpad surface drives the system mouse cursor; the touchpad
    /// press (button 13) still acts as a left click so the preset is usable
    /// stand-alone without other inputs.
    static var showcaseTouchpadMouse: Preset {
        let bindings: [BindingModel] = [
            // Finger 1 drives the cursor.
            BindingModel(input: .touchpad(finger: 0, axis: .x, direction: .positive),
                         outputs: [OutputAction(type: .mouseMotion, mouseAxis: .horizontal, mouseDirection: .positive, speed: 12)]),
            BindingModel(input: .touchpad(finger: 0, axis: .x, direction: .negative),
                         outputs: [OutputAction(type: .mouseMotion, mouseAxis: .horizontal, mouseDirection: .negative, speed: 12)]),
            BindingModel(input: .touchpad(finger: 0, axis: .y, direction: .positive),
                         outputs: [OutputAction(type: .mouseMotion, mouseAxis: .vertical, mouseDirection: .positive, speed: 12)]),
            BindingModel(input: .touchpad(finger: 0, axis: .y, direction: .negative),
                         outputs: [OutputAction(type: .mouseMotion, mouseAxis: .vertical, mouseDirection: .negative, speed: 12)]),
            // Finger 2 drives the scroll wheel.
            BindingModel(input: .touchpad(finger: 1, axis: .y, direction: .positive),
                         outputs: [OutputAction(type: .mouseWheel, mouseAxis: .vertical, mouseDirection: .positive, speed: 6)]),
            BindingModel(input: .touchpad(finger: 1, axis: .y, direction: .negative),
                         outputs: [OutputAction(type: .mouseWheel, mouseAxis: .vertical, mouseDirection: .negative, speed: 6)]),
            // Touchpad button = left click. Standard face buttons still work.
            BindingModel(input: .button(13),
                         outputs: [OutputAction(type: .mouseButton, mouseButtonIndex: 0)]),
            BindingModel(input: .button(0),
                         outputs: [OutputAction(type: .mouseButton, mouseButtonIndex: 0)]),
            BindingModel(input: .button(1),
                         outputs: [OutputAction(type: .mouseButton, mouseButtonIndex: 1)]),
        ]
        return makePreset(
            name: "Showcase: Touchpad Mouse",
            tag: "DualSense / DualShock touchpad drives the mouse cursor",
            joystickTag: "Finger 1 slides cursor, finger 2 scrolls, click presses left button",
            bindings: bindings)
    }

    /// Steam Controller demo preset. Steam Controller is read by our raw-HID
    /// helper (it doesn't speak MFi), so it occupies a virtual slot just
    /// past the last MFi gamepad. The button numbers match
    /// `SteamControllerButton`: A=7, B=5, X=6, Y=4, etc. Two trackpads and
    /// a stick share the same axis indices 0-3 (left axis is the stick when
    /// the stickActive bit is set, the left trackpad otherwise).
    static var showcaseSteamController: Preset {
        let bindings: [BindingModel] = [
            // Face buttons -> WASD-ish keys
            BindingModel(input: .button(7), outputs: [OutputAction(type: .key, keyCode: 40)]),  // A -> Return
            BindingModel(input: .button(5), outputs: [OutputAction(type: .key, keyCode: 41)]),  // B -> Escape
            BindingModel(input: .button(6), outputs: [OutputAction(type: .key, keyCode: 43)]),  // X -> Tab
            BindingModel(input: .button(4), outputs: [OutputAction(type: .key, keyCode: 44)]),  // Y -> Space
            // Bumpers -> Cmd+[ / Cmd+]
            BindingModel(input: .button(3),
                         outputs: [OutputAction(type: .key, keyCode: 227),
                                   OutputAction(type: .key, keyCode: 47)]),
            BindingModel(input: .button(2),
                         outputs: [OutputAction(type: .key, keyCode: 227),
                                   OutputAction(type: .key, keyCode: 48)]),
            // Steam button -> Cmd+Space (Spotlight)
            BindingModel(input: .button(13),
                         outputs: [OutputAction(type: .key, keyCode: 227),
                                   OutputAction(type: .key, keyCode: 44)]),
            // Right trackpad -> mouse motion with smooth curve + deadzone
            BindingModel(input: .axis(2, direction: .positive),
                         outputs: [OutputAction(type: .mouseMotion, mouseAxis: .horizontal, mouseDirection: .positive, speed: 22)],
                         deadzone: 0.12, sensitivityCurve: .exponential, variableSensitivity: true),
            BindingModel(input: .axis(2, direction: .negative),
                         outputs: [OutputAction(type: .mouseMotion, mouseAxis: .horizontal, mouseDirection: .negative, speed: 22)],
                         deadzone: 0.12, sensitivityCurve: .exponential, variableSensitivity: true),
            BindingModel(input: .axis(3, direction: .positive),
                         outputs: [OutputAction(type: .mouseMotion, mouseAxis: .vertical, mouseDirection: .positive, speed: 18)],
                         deadzone: 0.12, sensitivityCurve: .exponential, variableSensitivity: true),
            BindingModel(input: .axis(3, direction: .negative),
                         outputs: [OutputAction(type: .mouseMotion, mouseAxis: .vertical, mouseDirection: .negative, speed: 18)],
                         deadzone: 0.12, sensitivityCurve: .exponential, variableSensitivity: true),
            // Triggers -> mouse buttons
            BindingModel(input: .axis(5, direction: .positive),
                         outputs: [OutputAction(type: .mouseButton, mouseButtonIndex: 0)]),
            BindingModel(input: .axis(4, direction: .positive),
                         outputs: [OutputAction(type: .mouseButton, mouseButtonIndex: 1)]),
            // Trackpad click on right -> mouse left click
            BindingModel(input: .button(18), outputs: [OutputAction(type: .mouseButton, mouseButtonIndex: 0)]),
            // Grip paddles -> shift and option modifiers
            BindingModel(input: .button(15), outputs: [OutputAction(type: .key, keyCode: 225)]),
            BindingModel(input: .button(16), outputs: [OutputAction(type: .key, keyCode: 226)]),
        ]
        return makePreset(
            name: "Showcase: Steam Controller",
            tag: "Right trackpad drives the mouse, face buttons + grips type keys",
            joystickTag: "Plug in a Steam Controller (wired or wireless dongle); it appears as a virtual slot just past your MFi controllers",
            bindings: bindings)
    }

    /// Gyroscope showcase. Gyro Y (yaw rate) drives mouse left/right, gyro X
    /// (pitch rate) drives mouse up/down - the standard "motion aim" feel
    /// used by every Nintendo and PlayStation shooter. Triggers click,
    /// face buttons type. Works on any controller whose GCController.motion
    /// is non-nil (DualSense, DualShock 4, Switch Pro, Joy-Con).
    static var showcaseGyroAim: Preset {
        let bindings: [BindingModel] = [
            BindingModel(input: .motion(.gyroY, direction: .positive),
                         outputs: [OutputAction(type: .mouseMotion, mouseAxis: .horizontal, mouseDirection: .positive, speed: 10)],
                         deadzone: 0.05, variableSensitivity: true),
            BindingModel(input: .motion(.gyroY, direction: .negative),
                         outputs: [OutputAction(type: .mouseMotion, mouseAxis: .horizontal, mouseDirection: .negative, speed: 10)],
                         deadzone: 0.05, variableSensitivity: true),
            BindingModel(input: .motion(.gyroX, direction: .positive),
                         outputs: [OutputAction(type: .mouseMotion, mouseAxis: .vertical, mouseDirection: .positive, speed: 10)],
                         deadzone: 0.05, variableSensitivity: true),
            BindingModel(input: .motion(.gyroX, direction: .negative),
                         outputs: [OutputAction(type: .mouseMotion, mouseAxis: .vertical, mouseDirection: .negative, speed: 10)],
                         deadzone: 0.05, variableSensitivity: true),
            // Triggers click. Right trigger = left mouse click (primary fire),
            // left trigger = right mouse click (aim down sights).
            BindingModel(input: .axis(5, direction: .positive),
                         outputs: [OutputAction(type: .mouseButton, mouseButtonIndex: 0)]),
            BindingModel(input: .axis(4, direction: .positive),
                         outputs: [OutputAction(type: .mouseButton, mouseButtonIndex: 1)]),
            BindingModel(input: .button(0), outputs: [OutputAction(type: .key, keyCode: 44)]),  // space
            BindingModel(input: .button(1), outputs: [OutputAction(type: .key, keyCode: 224)]), // ctrl
        ]
        return makePreset(
            name: "Showcase: Gyro Aim",
            tag: "Tilt the controller to aim; triggers fire and ADS",
            joystickTag: "Gyro Y → mouse X, Gyro X → mouse Y. Hold the controller level and yaw / pitch to look around",
            bindings: bindings)
    }

    /// Motion-driven desktop cursor. Same idea as Gyro Aim but tuned for
    /// everyday Mac use: a wider deadzone so the cursor doesn't drift when
    /// the controller is set down, a slower gain so a small tilt doesn't
    /// shoot the cursor across the screen, and face buttons that act like
    /// trackpad clicks. Useful on the couch with a Switch Pro or
    /// Joy-Con as a "wave-the-controller" pointer.
    static var showcaseMotionCursor: Preset {
        let bindings: [BindingModel] = [
            // Yaw → X, Pitch → Y, with conservative defaults.
            BindingModel(input: .motion(.gyroY, direction: .positive),
                         outputs: [OutputAction(type: .mouseMotion, mouseAxis: .horizontal, mouseDirection: .positive, speed: 6)],
                         deadzone: 0.15, sensitivityCurve: .exponential, variableSensitivity: true),
            BindingModel(input: .motion(.gyroY, direction: .negative),
                         outputs: [OutputAction(type: .mouseMotion, mouseAxis: .horizontal, mouseDirection: .negative, speed: 6)],
                         deadzone: 0.15, sensitivityCurve: .exponential, variableSensitivity: true),
            BindingModel(input: .motion(.gyroX, direction: .positive),
                         outputs: [OutputAction(type: .mouseMotion, mouseAxis: .vertical, mouseDirection: .positive, speed: 6)],
                         deadzone: 0.15, sensitivityCurve: .exponential, variableSensitivity: true),
            BindingModel(input: .motion(.gyroX, direction: .negative),
                         outputs: [OutputAction(type: .mouseMotion, mouseAxis: .vertical, mouseDirection: .negative, speed: 6)],
                         deadzone: 0.15, sensitivityCurve: .exponential, variableSensitivity: true),
            // A = left click, B = right click, Y = double-tap (Return)
            BindingModel(input: .button(0), outputs: [OutputAction(type: .mouseButton, mouseButtonIndex: 0)]),
            BindingModel(input: .button(1), outputs: [OutputAction(type: .mouseButton, mouseButtonIndex: 1)]),
            BindingModel(input: .button(3), outputs: [OutputAction(type: .key, keyCode: 40)]),
            // Right stick still scrolls so you can read long pages without tilting.
            BindingModel(input: .axis(3, direction: .positive),
                         outputs: [OutputAction(type: .mouseWheel, mouseAxis: .vertical, mouseDirection: .negative, speed: 4)],
                         deadzone: 0.18, variableSensitivity: true),
            BindingModel(input: .axis(3, direction: .negative),
                         outputs: [OutputAction(type: .mouseWheel, mouseAxis: .vertical, mouseDirection: .positive, speed: 4)],
                         deadzone: 0.18, variableSensitivity: true),
        ]
        return makePreset(
            name: "Showcase: Motion Cursor",
            tag: "Wave the controller to move the cursor; face buttons click",
            joystickTag: "Wider gyro deadzone and slower speed than Gyro Aim; perfect for couch desktop use on Switch Pro / DualSense",
            bindings: bindings)
    }

    /// Showcase: Toggle Mode. Demonstrates the per-binding "toggle"
    /// flag - press once to latch on, press again to latch off.
    /// Perfect for sticky-keys patterns (caps lock-style modifier
    /// without a real caps lock), push-to-talk that you can park, or
    /// any "hold" output you'd rather flip.
    static var showcaseToggleMode: Preset {
        let bindings: [BindingModel] = [
            // A (button 0) toggles L-Shift: press once = Shift latched
            // until you press A again. Useful as a sticky modifier.
            BindingModel(input: .button(0),
                         outputs: [OutputAction(type: .key, keyCode: 225)],
                         toggleMode: true,
                         hapticEnabled: true, hapticIntensity: 0.4),
            // B (button 1) toggles L-Cmd same way.
            BindingModel(input: .button(1),
                         outputs: [OutputAction(type: .key, keyCode: 227)],
                         toggleMode: true,
                         hapticEnabled: true, hapticIntensity: 0.4),
            // X (button 2) toggles mute via F10 (depends on macOS
            // shortcut config; many keyboards map this to mute).
            BindingModel(input: .button(2),
                         outputs: [OutputAction(type: .key, keyCode: 67)],
                         toggleMode: true),
            // Y (button 3) toggles caps-lock style autohold of W key
            // (good for "auto-run" in games that need W held).
            BindingModel(input: .button(3),
                         outputs: [OutputAction(type: .key, keyCode: 26)],
                         toggleMode: true,
                         hapticEnabled: true, hapticIntensity: 0.6),
        ]
        return makePreset(
            name: "Showcase: Toggle Mode",
            tag: "Press once to latch on, press again to release",
            joystickTag: "Each face button toggles a key instead of holding while pressed. A = sticky Shift, B = sticky Cmd, X = mute toggle, Y = auto-run W",
            bindings: bindings)
    }

    /// Showcase: Stacked Outputs. One physical input fires multiple
    /// independent outputs at the same time. Different from a macro -
    /// these aren't a sequence with delays; they're parallel events
    /// per press.
    static var showcaseStackedOutputs: Preset {
        let bindings: [BindingModel] = [
            // A button fires four things at once: a keystroke (Space),
            // a mouse click, a MIDI note, and speech. Speech rides
            // alongside the outputs as a per-binding flag, not its
            // own OutputAction.
            BindingModel(input: .button(0),
                         outputs: [
                            OutputAction(type: .key, keyCode: 44),
                            OutputAction(type: .mouseButton, mouseButtonIndex: 1),
                            OutputAction(type: .midiNote, midiNote: 60, midiVelocity: 100)
                         ],
                         hapticEnabled: true, hapticIntensity: 0.7,
                         speechEnabled: true,
                         speechText: "Hello"),
            // B fires two parallel keystrokes: Cmd+Shift+4 (screenshot)
            // approximated by Cmd then 4 (real chord recording uses
            // a different path).
            BindingModel(input: .button(1),
                         outputs: [
                            OutputAction(type: .key, keyCode: 227),
                            OutputAction(type: .key, keyCode: 33),
                         ]),
        ]
        return makePreset(
            name: "Showcase: Stacked Outputs",
            tag: "One press fires keystroke + mouse + MIDI + speech together",
            joystickTag: "A = parallel output stack (key + click + MIDI + speech). B = parallel keystroke pair. Different from a macro - no delays, no sequence; these fire simultaneously.",
            bindings: bindings)
    }

    /// Showcase: Per-Preset Automation. Demonstrates the editor's
    /// Automation panel - auto-launch an app on activation, plus
    /// scoped cursor utilities (confine / auto-recenter / hide).
    /// The preset itself only has a handful of bindings so the
    /// automation panel is the star of the show.
    static var showcaseAutoLaunch: Preset {
        let bindings: [BindingModel] = [
            BindingModel(input: .button(0),
                         outputs: [OutputAction(type: .key, keyCode: 44)]),  // A → Space
            BindingModel(input: .button(9),
                         outputs: [OutputAction(type: .key, keyCode: 41)]),  // Menu → Esc
        ]
        var preset = makePreset(
            name: "Showcase: Auto-Launch + Cursor Confine",
            tag: "Activate this preset to launch TextEdit and confine the cursor",
            joystickTag: "Two bindings (A = Space, Menu = Esc). The interesting bit is the Automation panel - activating this preset opens TextEdit AND turns on cursor confine + auto-recenter so you can see the per-preset side effects without a real game.",
            bindings: bindings)
        preset.automation = PresetAutomation(
            launchAppPath: "/System/Applications/TextEdit.app",
            launchURL: "",
            confineCursor: true,
            confineBufferPx: 40,
            autoRecenterCursor: false,
            autoRecenterIntervalMs: 500,
            hideCursorWhileActive: false,
            sensitivityMultiplier: 1.0
        )
        return preset
    }

    /// Showcase: MIDI CC Dials. Bind axes (sticks, triggers) to
    /// continuous MIDI CC values so the controller becomes a soft
    /// modulation surface for any DAW. Different from MIDI Notes -
    /// CC sends a 0-127 value every poll, perfect for filter cutoff,
    /// expression, channel volume, pan.
    static var showcaseMidiCC: Preset {
        let bindings: [BindingModel] = [
            // Left stick X → CC 1 (Modulation).
            BindingModel(input: .axis(0, direction: .positive),
                         outputs: [OutputAction(type: .midiCC,
                                                midiCCNumber: 1,
                                                midiChannel: 1)],
                         deadzone: 0.05, variableSensitivity: true),
            BindingModel(input: .axis(0, direction: .negative),
                         outputs: [OutputAction(type: .midiCC,
                                                midiCCNumber: 1,
                                                midiChannel: 1)],
                         deadzone: 0.05, variableSensitivity: true),
            // Left stick Y → CC 11 (Expression).
            BindingModel(input: .axis(1, direction: .positive),
                         outputs: [OutputAction(type: .midiCC,
                                                midiCCNumber: 11,
                                                midiChannel: 1)],
                         deadzone: 0.05, variableSensitivity: true),
            // Right stick X → CC 74 (Filter cutoff).
            BindingModel(input: .axis(2, direction: .positive),
                         outputs: [OutputAction(type: .midiCC,
                                                midiCCNumber: 74,
                                                midiChannel: 1)],
                         deadzone: 0.05, variableSensitivity: true),
            // Right stick Y → CC 71 (Resonance).
            BindingModel(input: .axis(3, direction: .positive),
                         outputs: [OutputAction(type: .midiCC,
                                                midiCCNumber: 71,
                                                midiChannel: 1)],
                         deadzone: 0.05, variableSensitivity: true),
            // R2 → CC 7 (Channel volume) - press harder for louder.
            BindingModel(input: .axis(5, direction: .positive),
                         outputs: [OutputAction(type: .midiCC,
                                                midiCCNumber: 7,
                                                midiChannel: 1)],
                         deadzone: 0.05, variableSensitivity: true),
            // L2 → CC 10 (Pan).
            BindingModel(input: .axis(4, direction: .positive),
                         outputs: [OutputAction(type: .midiCC,
                                                midiCCNumber: 10,
                                                midiChannel: 1)],
                         deadzone: 0.05, variableSensitivity: true),
        ]
        return makePreset(
            name: "MIDI: CC Dials",
            tag: "Sticks + triggers become soft MIDI controllers",
            joystickTag: "Left stick X/Y = CC 1 / CC 11. Right stick X/Y = CC 74 / CC 71. Triggers = CC 7 / CC 10. Channel 1. Plug into any DAW's MIDI Learn for instant macro control.",
            bindings: bindings)
    }

    // MARK: - Builder Helpers

    /// Construct a single-joystick preset programmatically (used by all
    /// showcase + MIDI presets, since the legacy JSON parser does not carry
    /// advanced fields like haptic, deadzone, curve, macros).
    private static func makePreset(name: String, tag: String, joystickTag: String,
                                   bindings: [BindingModel]) -> Preset {
        let joystick = JoystickMapping(tag: joystickTag, bindings: bindings)
        return Preset(name: name, tag: tag, joysticks: [joystick],
                      filename: Preset.generateFilename())
    }

    /// Parse a legacy-format preset JSON string into a Preset.
    private static func parse(_ json: String) -> Preset {
        guard let data = json.data(using: .utf8),
              let preset = Preset.fromLegacyJSON(data, filename: Preset.generateFilename()) else {
            return Preset(name: "Error", tag: "Failed to parse")
        }
        return preset
    }
}
