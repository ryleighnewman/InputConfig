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
        static let gaming = "Gaming"               // top-level parent folder
        static let firstPerson = "First-Person"    // nested under Gaming
        static let genre = "Genre"                 // nested under Gaming
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

        "FPS (PS5 DualSense)":           GroupName.firstPerson,
        "FPS (Xbox)":                    GroupName.firstPerson,
        "FPS (Switch Pro)":              GroupName.firstPerson,
        "FPS (8BitDo)":                  GroupName.firstPerson,

        "Minecraft":                     GroupName.genre,
        "Fortnite":                      GroupName.genre,
        "Racing Game":                   GroupName.genre,

        "MIDI: DAW Performance":         GroupName.midi,
        "MIDI: Drum Pad":                GroupName.midi,
        "MIDI: Transport Control":       GroupName.midi,

        "Variable Sensitivity":   GroupName.showcase,
        "Deadzone Calibration":   GroupName.showcase,
        "Haptic Feedback":        GroupName.showcase,
        "Spoken Feedback":        GroupName.showcase,
        "Macros & Turbo":         GroupName.showcase,
        "Touchpad Mouse":         GroupName.showcase,
        "Steam Controller":       GroupName.showcase,
        "Gyro Aim":               GroupName.showcase,
        "Motion Cursor":          GroupName.showcase,
        "Toggle Mode":            GroupName.showcase,
        "Stacked Outputs":        GroupName.showcase,
        "MIDI: CC Dials":                   GroupName.midi,
    ]

    /// Ordered group names so the sidebar shows them in the curated order.
    /// Parents are listed before their children so seeding resolves parentIDs
    /// by name in a single pass.
    static let groupOrder: [String] = [
        GroupName.desktop,
        GroupName.gaming,
        GroupName.firstPerson,
        GroupName.genre,
        GroupName.midi,
        GroupName.showcase,
    ]

    /// Child folder name -> parent folder name for the nested ship layout.
    /// Folders not listed here are top-level. Seeding reads this to set each
    /// group's parentID, so the built-in library ships with a Gaming folder
    /// containing First-Person and Genre subfolders.
    static let groupParents: [String: String] = [
        GroupName.firstPerson: GroupName.gaming,
        GroupName.genre:       GroupName.gaming,
    ]

    /// Default sidebar tint for each ship group. Matches the palette
    /// stored in `PresetGroup.colorOptions`. The user can override these
    /// from the folder context menu; the values here are the first-launch
    /// defaults so the sidebar comes out colorful out of the box.
    static let groupDefaultColors: [String: String] = [
        GroupName.desktop:     "orange",
        GroupName.gaming:      "green",
        GroupName.firstPerson: "green",
        GroupName.genre:       "indigo",
        GroupName.midi:        "red",
        GroupName.showcase:    "teal",
    ]

    /// Per-feature lookup so the welcome demos can jump to the matching
    /// showcase preset. Key is a stable identifier; value is the preset name.
    static let demoPresetNames: [String: String] = [
        "variable_sensitivity": "Variable Sensitivity",
        "deadzone":             "Deadzone Calibration",
        "haptic":               "Haptic Feedback",
        "speech":               "Spoken Feedback",
        "macros":               "Macros & Turbo",
        "touchpad":             "Touchpad Mouse",
        "midi":                 "MIDI: DAW Performance",
        "gyro":                 "Gyro Aim",
        "toggle_mode":          "Toggle Mode",
        "stacked_outputs":      "Stacked Outputs",
        "auto_launch":          "Minecraft",
        "midi_cc":              "MIDI: CC Dials",
        "keyboard_mouse":       "Desktop Navigation",
    ]

    /// Map a connected controller's brand to the best built-in example
    /// preset to jump to from the controller info popover. Brands we don't
    /// ship a tailored layout for - generic MFi pads, unrecognized brands
    /// (e.g. Lightfire), Steam, Stadia - fall back to the DualSense FPS
    /// layout, which uses the standard extended-gamepad axis/button indices
    /// and therefore works on any controller. This guarantees every
    /// connected controller has a "Take me to an example" destination.
    static func exampleName(for brand: ControllerBrand) -> String {
        switch brand {
        case .xbox:                       return "FPS (Xbox)"
        case .switchPro, .joyConLeft,
             .joyConRight, .joyConPair:   return "FPS (Switch Pro)"
        case .eightBitDo:                 return "FPS (8BitDo)"
        case .dualSense, .dualShock4,
             .stadia, .steamController,
             .mfiGeneric, .unknown:       return "FPS (PS5 DualSense)"
        }
    }

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
            "tag": "Full Minecraft controls - works with any controller",
            "joysticks": [{
                "tag": "WASD + mouse look, triggers mine/place, bumpers cycle hotbar, D-pad hotbar 1-4. Uses standard gamepad indices so the same layout drives DualSense, Xbox, Switch Pro, 8BitDo and any other connected controller.",
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
    // Sends to InputConfig's virtual MIDI port, so any DAW listening on
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
            name: "Variable Sensitivity",
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
            name: "Deadzone Calibration",
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
            name: "Haptic Feedback",
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
            name: "Spoken Feedback",
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
            name: "Macros & Turbo",
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
            name: "Touchpad Mouse",
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
            name: "Steam Controller",
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
            name: "Gyro Aim",
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
            name: "Motion Cursor",
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
            name: "Toggle Mode",
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
            name: "Stacked Outputs",
            tag: "One press fires keystroke + mouse + MIDI + speech together",
            joystickTag: "A = parallel output stack (key + click + MIDI + speech). B = parallel keystroke pair. Different from a macro - no delays, no sequence; these fire simultaneously.",
            bindings: bindings)
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

// MARK: - Smart Preset Maker

/// A controller-agnostic mapping profile for a game, app, or workflow. The
/// Smart Preset Maker fuses one of these with the user's chosen controller
/// to generate a ready-to-use Preset. Decoded from the embedded library
/// JSON, which is researched + adversarially verified by the build workflow.
struct SmartPresetProfile: Codable, Identifiable, Hashable {
    enum Category: String, Codable, CaseIterable, Identifiable {
        case game, app, workflow
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .game: return "Game"
            case .app: return "App"
            case .workflow: return "Workflow"
            }
        }
        var pluralPrompt: String {
            switch self {
            case .game: return "Pick a game"
            case .app: return "Pick an app"
            case .workflow: return "Pick a workflow"
            }
        }
        var systemImage: String {
            switch self {
            case .game: return "gamecontroller.fill"
            case .app: return "app.badge.fill"
            case .workflow: return "rectangle.3.group.fill"
            }
        }
    }

    struct Light: Codable, Hashable { var r: Int; var g: Int; var b: Int }
    struct Binding: Codable, Hashable { var input: String; var outputs: [String]; var note: String }

    var id: String
    var category: Category
    var displayName: String
    var subtitle: String
    var appPath: String
    var launchURL: String
    var light: Light
    var confineCursor: Bool
    var autoRecenter: Bool
    var hideCursor: Bool
    var bindings: [Binding]
    var tips: [String]
}

/// The library of Smart Preset profiles, decoded once from embedded JSON.
enum SmartPresetLibrary {
    static let all: [SmartPresetProfile] = {
        guard let data = libraryJSON.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([SmartPresetProfile].self, from: data)) ?? []
    }()

    static func profiles(in category: SmartPresetProfile.Category) -> [SmartPresetProfile] {
        all.filter { $0.category == category }.sorted { $0.displayName < $1.displayName }
    }

    /// Embedded, verified profile data. Authored + adversarially checked by
    /// the `smart-preset-library` build workflow. This is the starter set;
    /// the workflow's full ~50-profile output is merged in once it returns.
    static let libraryJSON = """
    [
      {
        "id": "minecraft", "category": "game", "displayName": "Minecraft",
        "subtitle": "Move, look, mine, place, hotbar",
        "appPath": "/Applications/Minecraft.app", "launchURL": "",
        "light": {"r": 60, "g": 200, "b": 80},
        "confineCursor": true, "autoRecenter": true, "hideCursor": true,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Strafe left"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Strafe right"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Walk forward"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Walk back"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 20"], "note": "Look right"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 20"], "note": "Look left"},
          {"input": "axi 3 +", "outputs": ["mou 1 + 14"], "note": "Look down"},
          {"input": "axi 3 -", "outputs": ["mou 1 - 14"], "note": "Look up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Attack / mine"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Use / place"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Jump"},
          {"input": "btn 1", "outputs": ["key 225"], "note": "Sneak"},
          {"input": "btn 2", "outputs": ["key 8"], "note": "Inventory"},
          {"input": "btn 3", "outputs": ["key 20"], "note": "Drop item"},
          {"input": "btn 4", "outputs": ["whs 1 -"], "note": "Hotbar previous"},
          {"input": "btn 5", "outputs": ["whs 1 +"], "note": "Hotbar next"},
          {"input": "btn 11", "outputs": ["key 224"], "note": "Sprint"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Pause / menu"},
          {"input": "btn 8", "outputs": ["key 43"], "note": "Player list"}
        ],
        "tips": ["Hold sprint (left-stick click) while pushing forward to run.", "Triggers mine and place - swap them in the editor if you prefer."]
      },
      {
        "id": "microsoft-word", "category": "app", "displayName": "Microsoft Word",
        "subtitle": "Navigate, scroll, and common shortcuts",
        "appPath": "/Applications/Microsoft Word.app", "launchURL": "",
        "light": {"r": 40, "g": 90, "b": 200},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 3 +", "outputs": ["whe 1 + 5"], "note": "Scroll down"},
          {"input": "axi 3 -", "outputs": ["whe 1 - 5"], "note": "Scroll up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Click"},
          {"input": "btn 0", "outputs": ["key 227", "key 6"], "note": "Copy"},
          {"input": "btn 1", "outputs": ["key 227", "key 25"], "note": "Paste"},
          {"input": "btn 2", "outputs": ["key 227", "key 4"], "note": "Select all"},
          {"input": "btn 3", "outputs": ["key 227", "key 29"], "note": "Undo"},
          {"input": "hat 0 U", "outputs": ["key 82"], "note": "Arrow up"},
          {"input": "hat 0 D", "outputs": ["key 81"], "note": "Arrow down"},
          {"input": "hat 0 L", "outputs": ["key 80"], "note": "Arrow left"},
          {"input": "hat 0 R", "outputs": ["key 79"], "note": "Arrow right"}
        ],
        "tips": ["Left stick drives the cursor; right stick scrolls the page.", "Face buttons are Copy / Paste / Select All / Undo."]
      },
      {
        "id": "desktop-navigation", "category": "workflow", "displayName": "Desktop Navigation",
        "subtitle": "Cursor, scroll, clicks, and macOS shortcuts",
        "appPath": "", "launchURL": "",
        "light": {"r": 230, "g": 150, "b": 40},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 2 +", "outputs": ["whe 0 + 5"], "note": "Scroll right"},
          {"input": "axi 2 -", "outputs": ["whe 0 - 5"], "note": "Scroll left"},
          {"input": "axi 3 +", "outputs": ["whe 1 + 5"], "note": "Scroll down"},
          {"input": "axi 3 -", "outputs": ["whe 1 - 5"], "note": "Scroll up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Left click"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Right click"},
          {"input": "btn 0", "outputs": ["key 227", "key 4"], "note": "Select all"},
          {"input": "btn 8", "outputs": ["key 227", "key 44"], "note": "Spotlight"},
          {"input": "btn 9", "outputs": ["key 40"], "note": "Return"}
        ],
        "tips": ["Left stick moves the pointer; right stick scrolls.", "Triggers are left and right click."]
      },
      {
        "id": "roblox", "category": "game", "displayName": "Roblox",
        "subtitle": "Move, jump, and look - default third-person controls",
        "appPath": "/Applications/Roblox.app", "launchURL": "",
        "light": {"r": 225, "g": 55, "b": 55},
        "confineCursor": true, "autoRecenter": true, "hideCursor": true,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Move left"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Move right"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Move forward"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Move back"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 20"], "note": "Look right"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 20"], "note": "Look left"},
          {"input": "axi 3 +", "outputs": ["mou 1 + 14"], "note": "Look down"},
          {"input": "axi 3 -", "outputs": ["mou 1 - 14"], "note": "Look up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Primary action / click"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Secondary action"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Jump"},
          {"input": "btn 1", "outputs": ["key 225"], "note": "Sprint / shift-lock"},
          {"input": "btn 3", "outputs": ["key 41"], "note": "Menu"},
          {"input": "hat 0 U", "outputs": ["key 30"], "note": "Tool slot 1"},
          {"input": "hat 0 R", "outputs": ["key 31"], "note": "Tool slot 2"},
          {"input": "hat 0 D", "outputs": ["key 32"], "note": "Tool slot 3"},
          {"input": "hat 0 L", "outputs": ["key 33"], "note": "Tool slot 4"}
        ],
        "tips": ["Most Roblox games use WASD + mouse, so this fits the majority of experiences.", "Raise in-game camera sensitivity if the right stick feels slow."]
      },
      {
        "id": "fortnite", "category": "game", "displayName": "Fortnite",
        "subtitle": "Shoot and move (keyboard-and-mouse layout)",
        "appPath": "", "launchURL": "",
        "light": {"r": 130, "g": 80, "b": 235},
        "confineCursor": true, "autoRecenter": true, "hideCursor": true,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Strafe left"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Strafe right"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Forward"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Back"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 22"], "note": "Aim right"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 22"], "note": "Aim left"},
          {"input": "axi 3 +", "outputs": ["mou 1 + 16"], "note": "Aim down"},
          {"input": "axi 3 -", "outputs": ["mou 1 - 16"], "note": "Aim up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Shoot / confirm"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Aim down sights"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Jump"},
          {"input": "btn 1", "outputs": ["key 224"], "note": "Crouch"},
          {"input": "btn 2", "outputs": ["key 9"], "note": "Use / pick up (F)"},
          {"input": "btn 3", "outputs": ["key 20"], "note": "Switch to pickaxe (Q)"},
          {"input": "btn 4", "outputs": ["key 21"], "note": "Reload (R)"},
          {"input": "btn 5", "outputs": ["key 8"], "note": "Edit build (E)"},
          {"input": "hat 0 U", "outputs": ["key 30"], "note": "Weapon slot 1"},
          {"input": "hat 0 R", "outputs": ["key 31"], "note": "Weapon slot 2"},
          {"input": "hat 0 D", "outputs": ["key 32"], "note": "Weapon slot 3"}
        ],
        "tips": ["Building pieces vary by your binds - set wall/floor/stair/roof in the editor to match yours.", "Aim feels best with confine + hidden cursor in fullscreen."]
      },
      {
        "id": "elden-ring", "category": "game", "displayName": "Elden Ring",
        "subtitle": "Action RPG - attack, dodge, and explore",
        "appPath": "", "launchURL": "steam://run/1245620",
        "light": {"r": 200, "g": 160, "b": 40},
        "confineCursor": true, "autoRecenter": true, "hideCursor": true,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Move left"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Move right"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Move forward"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Move back"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 18"], "note": "Camera right"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 18"], "note": "Camera left"},
          {"input": "axi 3 +", "outputs": ["mou 1 + 14"], "note": "Camera down"},
          {"input": "axi 3 -", "outputs": ["mou 1 - 14"], "note": "Camera up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Right-hand attack"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Guard / block"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Roll / dodge / sprint"},
          {"input": "btn 1", "outputs": ["key 8"], "note": "Interact / confirm (E)"},
          {"input": "btn 2", "outputs": ["key 21"], "note": "Use item (R)"},
          {"input": "btn 3", "outputs": ["key 9"], "note": "Event / jump action (F)"},
          {"input": "btn 5", "outputs": ["key 20"], "note": "Skill / weapon art (Q)"},
          {"input": "btn 11", "outputs": ["key 25"], "note": "Crouch (V)"},
          {"input": "btn 12", "outputs": ["key 18"], "note": "Reset camera / lock-on (O)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Elden Ring's keyboard binds differ from this layout's assumptions - open Controls in-game and match, or rebind here with Scan.", "Lock-on is on right-stick click; change it to whatever you set in-game."]
      },
      {
        "id": "stardew-valley", "category": "game", "displayName": "Stardew Valley",
        "subtitle": "Farm, tend, and explore",
        "appPath": "/Applications/Stardew Valley.app", "launchURL": "",
        "light": {"r": 90, "g": 200, "b": 120},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Walk left"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Walk right"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Walk up"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Walk down"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 18"], "note": "Aim cursor right"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 18"], "note": "Aim cursor left"},
          {"input": "axi 3 +", "outputs": ["mou 1 + 18"], "note": "Aim cursor down"},
          {"input": "axi 3 -", "outputs": ["mou 1 - 18"], "note": "Aim cursor up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Use tool"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Check / interact"},
          {"input": "btn 0", "outputs": ["mbt 1"], "note": "Check / action"},
          {"input": "btn 3", "outputs": ["key 8"], "note": "Inventory / menu (E)"},
          {"input": "btn 8", "outputs": ["key 16"], "note": "Map (M)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"},
          {"input": "hat 0 U", "outputs": ["key 30"], "note": "Toolbar slot 1"},
          {"input": "hat 0 R", "outputs": ["key 31"], "note": "Toolbar slot 2"},
          {"input": "hat 0 D", "outputs": ["key 32"], "note": "Toolbar slot 3"},
          {"input": "hat 0 L", "outputs": ["key 33"], "note": "Toolbar slot 4"}
        ],
        "tips": ["Left stick walks; right stick aims the tool cursor.", "Right trigger uses the held tool; left trigger / A checks and interacts."]
      },
      {
        "id": "celeste", "category": "game", "displayName": "Celeste",
        "subtitle": "Precision platformer - move, jump, dash, climb",
        "appPath": "/Applications/Celeste.app", "launchURL": "steam://run/504230",
        "light": {"r": 220, "g": 45, "b": 90},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "hat 0 L", "outputs": ["key 80"], "note": "Move left (precise)"},
          {"input": "hat 0 R", "outputs": ["key 79"], "note": "Move right (precise)"},
          {"input": "hat 0 U", "outputs": ["key 82"], "note": "Aim up"},
          {"input": "hat 0 D", "outputs": ["key 81"], "note": "Crouch / aim down"},
          {"input": "axi 0 -", "outputs": ["key 80"], "note": "Move left (stick)"},
          {"input": "axi 0 +", "outputs": ["key 79"], "note": "Move right (stick)"},
          {"input": "axi 1 -", "outputs": ["key 82"], "note": "Aim up (stick)"},
          {"input": "axi 1 +", "outputs": ["key 81"], "note": "Aim down (stick)"},
          {"input": "btn 0", "outputs": ["key 6"], "note": "Jump (C)"},
          {"input": "btn 3", "outputs": ["key 6"], "note": "Jump (alt)"},
          {"input": "btn 1", "outputs": ["key 27"], "note": "Dash (X)"},
          {"input": "btn 2", "outputs": ["key 27"], "note": "Dash (alt)"},
          {"input": "axi 5 +", "outputs": ["key 29"], "note": "Climb / grab (Z)"},
          {"input": "axi 4 +", "outputs": ["key 29"], "note": "Climb / grab (either hand)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Pause (Esc)"}
        ],
        "tips": ["Defaults assume Celeste's C = jump, X = dash, Z = climb - match those in-game or rebind here.", "The D-pad is recommended for tight platforming; the left stick also works."]
      },
      {
        "id": "blender", "category": "app", "displayName": "Blender",
        "subtitle": "Navigate the viewport and core modeling shortcuts",
        "appPath": "/Applications/Blender.app", "launchURL": "",
        "light": {"r": 240, "g": 130, "b": 30},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 3 +", "outputs": ["whe 1 - 4"], "note": "Zoom out"},
          {"input": "axi 3 -", "outputs": ["whe 1 + 4"], "note": "Zoom in"},
          {"input": "btn 0", "outputs": ["mbt 0"], "note": "Select (left click)"},
          {"input": "btn 1", "outputs": ["mbt 2"], "note": "Orbit / pan (middle click)"},
          {"input": "btn 2", "outputs": ["key 10"], "note": "Grab / move (G)"},
          {"input": "btn 3", "outputs": ["key 21"], "note": "Rotate (R)"},
          {"input": "btn 4", "outputs": ["key 22"], "note": "Scale (S)"},
          {"input": "btn 5", "outputs": ["key 43"], "note": "Toggle edit mode (Tab)"},
          {"input": "axi 5 +", "outputs": ["key 27"], "note": "Delete (X)"},
          {"input": "axi 4 +", "outputs": ["key 227", "key 29"], "note": "Undo (Cmd+Z)"},
          {"input": "btn 8", "outputs": ["key 227", "key 22"], "note": "Save (Cmd+S)"}
        ],
        "tips": ["Left stick moves the cursor; right stick zooms; B (middle click) orbits.", "G/R/S are grab/rotate/scale - the heart of Blender modeling."]
      },
      {
        "id": "web-browsing", "category": "workflow", "displayName": "Web Browsing",
        "subtitle": "Cursor, scroll, tabs, and history",
        "appPath": "", "launchURL": "",
        "light": {"r": 60, "g": 140, "b": 230},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 3 +", "outputs": ["whe 1 + 6"], "note": "Scroll down"},
          {"input": "axi 3 -", "outputs": ["whe 1 - 6"], "note": "Scroll up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Click"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Right click"},
          {"input": "btn 4", "outputs": ["key 227", "key 47"], "note": "Back"},
          {"input": "btn 5", "outputs": ["key 227", "key 48"], "note": "Forward"},
          {"input": "btn 0", "outputs": ["key 227", "key 23"], "note": "New tab"},
          {"input": "btn 1", "outputs": ["key 227", "key 26"], "note": "Close tab"},
          {"input": "btn 2", "outputs": ["key 227", "key 21"], "note": "Reload"},
          {"input": "btn 3", "outputs": ["key 227", "key 15"], "note": "Address bar"},
          {"input": "hat 0 L", "outputs": ["key 227", "key 226", "key 80"], "note": "Previous tab"},
          {"input": "hat 0 R", "outputs": ["key 227", "key 226", "key 79"], "note": "Next tab"}
        ],
        "tips": ["Left stick moves the pointer; right stick scrolls.", "Bumpers are Back / Forward; face buttons handle tabs and reload."]
      },
      {
        "id": "media-playback", "category": "workflow", "displayName": "Media Playback",
        "subtitle": "Play, pause, seek, and volume",
        "appPath": "", "launchURL": "",
        "light": {"r": 230, "g": 60, "b": 150},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Click"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Play / pause (Space)"},
          {"input": "hat 0 L", "outputs": ["key 80"], "note": "Seek back"},
          {"input": "hat 0 R", "outputs": ["key 79"], "note": "Seek forward"},
          {"input": "hat 0 U", "outputs": ["key 82"], "note": "Volume up"},
          {"input": "hat 0 D", "outputs": ["key 81"], "note": "Volume down"},
          {"input": "btn 1", "outputs": ["key 9"], "note": "Fullscreen (F)"},
          {"input": "btn 2", "outputs": ["key 16"], "note": "Mute (M)"},
          {"input": "btn 4", "outputs": ["key 80"], "note": "Previous / rewind"},
          {"input": "btn 5", "outputs": ["key 79"], "note": "Next / forward"}
        ],
        "tips": ["Works with most players (YouTube, web video, QuickTime) that use Space/F/M and arrow keys.", "Left stick drives the pointer for clicking controls."]
      },
      {
        "id": "gta-v", "category": "game", "displayName": "Grand Theft Auto V",
        "subtitle": "On-foot and driving - move, aim, shoot",
        "appPath": "", "launchURL": "",
        "light": {"r": 120, "g": 180, "b": 90},
        "confineCursor": true, "autoRecenter": true, "hideCursor": true,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Move / steer left"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Move / steer right"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Forward / accelerate"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Back / brake"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 20"], "note": "Aim / look right"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 20"], "note": "Aim / look left"},
          {"input": "axi 3 +", "outputs": ["mou 1 + 14"], "note": "Aim / look down"},
          {"input": "axi 3 -", "outputs": ["mou 1 - 14"], "note": "Aim / look up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Fire"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Aim"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Jump / handbrake"},
          {"input": "btn 1", "outputs": ["key 9"], "note": "Enter / exit vehicle (F)"},
          {"input": "btn 2", "outputs": ["key 21"], "note": "Reload (R)"},
          {"input": "btn 3", "outputs": ["key 8"], "note": "Special / interact (E)"},
          {"input": "btn 8", "outputs": ["key 16"], "note": "Map (M)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Pause (Esc)"}
        ],
        "tips": ["On-foot and driving share W/S; GTA switches context automatically.", "Set in-game aiming to match the right-stick speed for comfort."]
      },
      {
        "id": "cyberpunk-2077", "category": "game", "displayName": "Cyberpunk 2077",
        "subtitle": "First-person RPG - shoot, aim, hack",
        "appPath": "", "launchURL": "steam://run/1091500",
        "light": {"r": 245, "g": 220, "b": 40},
        "confineCursor": true, "autoRecenter": true, "hideCursor": true,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Strafe left"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Strafe right"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Forward"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Back"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 20"], "note": "Look right"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 20"], "note": "Look left"},
          {"input": "axi 3 +", "outputs": ["mou 1 + 14"], "note": "Look down"},
          {"input": "axi 3 -", "outputs": ["mou 1 - 14"], "note": "Look up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Shoot / attack"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Aim / block"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Jump"},
          {"input": "btn 1", "outputs": ["key 6"], "note": "Crouch / dodge (C)"},
          {"input": "btn 2", "outputs": ["key 21"], "note": "Reload (R)"},
          {"input": "btn 3", "outputs": ["key 9"], "note": "Interact (F)"},
          {"input": "btn 4", "outputs": ["key 23"], "note": "Scanner (Tab=key 43)"},
          {"input": "btn 5", "outputs": ["key 20"], "note": "Quick hack (Q)"},
          {"input": "btn 8", "outputs": ["key 24"], "note": "Backpack (I=key 12)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Pause (Esc)"}
        ],
        "tips": ["Cyberpunk's keyboard binds are extensive - match its defaults in-game or rebind here with Scan.", "Confine + hidden cursor keeps mouse-look locked in fullscreen."]
      },
      {
        "id": "hollow-knight", "category": "game", "displayName": "Hollow Knight",
        "subtitle": "Metroidvania - move, jump, attack, dash",
        "appPath": "/Applications/Hollow Knight.app", "launchURL": "steam://run/367520",
        "light": {"r": 60, "g": 90, "b": 160},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 80"], "note": "Move left"},
          {"input": "axi 0 +", "outputs": ["key 79"], "note": "Move right"},
          {"input": "axi 1 -", "outputs": ["key 82"], "note": "Look / aim up"},
          {"input": "axi 1 +", "outputs": ["key 81"], "note": "Look / aim down"},
          {"input": "hat 0 L", "outputs": ["key 80"], "note": "Move left (d-pad)"},
          {"input": "hat 0 R", "outputs": ["key 79"], "note": "Move right (d-pad)"},
          {"input": "hat 0 U", "outputs": ["key 82"], "note": "Up (d-pad)"},
          {"input": "hat 0 D", "outputs": ["key 81"], "note": "Down (d-pad)"},
          {"input": "btn 0", "outputs": ["key 29"], "note": "Jump (Z)"},
          {"input": "btn 2", "outputs": ["key 27"], "note": "Attack / nail (X)"},
          {"input": "btn 1", "outputs": ["key 6"], "note": "Dash (C)"},
          {"input": "btn 3", "outputs": ["key 4"], "note": "Cast spell (A)"},
          {"input": "axi 5 +", "outputs": ["key 22"], "note": "Focus / heal (S, hold)"},
          {"input": "btn 4", "outputs": ["key 22"], "note": "Focus / heal (alt)"},
          {"input": "btn 5", "outputs": ["key 21"], "note": "Dream nail (R)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Pause (Esc)"}
        ],
        "tips": ["Defaults assume Hollow Knight's Z=jump, X=attack, C=dash, A=cast - match those in-game.", "Both stick and D-pad move; the D-pad is steadier for precise platforming."]
      },
      {
        "id": "terraria", "category": "game", "displayName": "Terraria",
        "subtitle": "Dig, build, fight - move and use tools",
        "appPath": "/Applications/Terraria.app", "launchURL": "steam://run/105600",
        "light": {"r": 110, "g": 180, "b": 70},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Move left"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Move right"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 18"], "note": "Aim cursor right"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 18"], "note": "Aim cursor left"},
          {"input": "axi 3 +", "outputs": ["mou 1 + 18"], "note": "Aim cursor down"},
          {"input": "axi 3 -", "outputs": ["mou 1 - 18"], "note": "Aim cursor up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Use / attack / dig"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Secondary use"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Jump"},
          {"input": "btn 1", "outputs": ["key 22"], "note": "Down / drop through (S)"},
          {"input": "btn 2", "outputs": ["key 8"], "note": "Inventory (E)"},
          {"input": "btn 3", "outputs": ["key 21"], "note": "Quick heal (R hook varies)"},
          {"input": "hat 0 U", "outputs": ["key 30"], "note": "Hotbar slot 1"},
          {"input": "hat 0 R", "outputs": ["key 31"], "note": "Hotbar slot 2"},
          {"input": "hat 0 D", "outputs": ["key 32"], "note": "Hotbar slot 3"},
          {"input": "hat 0 L", "outputs": ["key 33"], "note": "Hotbar slot 4"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Right stick aims the tool cursor; right trigger uses the held item.", "Hotbar is on the D-pad (slots 1-4) - extend with more bindings if you like."]
      },
      {
        "id": "hades", "category": "game", "displayName": "Hades",
        "subtitle": "Roguelike action - attack, dash, cast",
        "appPath": "/Applications/Hades.app", "launchURL": "steam://run/1145360",
        "light": {"r": 200, "g": 60, "b": 30},
        "confineCursor": true, "autoRecenter": true, "hideCursor": true,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Move left"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Move right"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Move up"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Move down"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 18"], "note": "Aim right"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 18"], "note": "Aim left"},
          {"input": "axi 3 +", "outputs": ["mou 1 + 14"], "note": "Aim down"},
          {"input": "axi 3 -", "outputs": ["mou 1 - 14"], "note": "Aim up"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Dash (Space)"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Attack"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Special"},
          {"input": "btn 2", "outputs": ["key 20"], "note": "Cast (Q)"},
          {"input": "btn 1", "outputs": ["key 8"], "note": "Call / summon (E)"},
          {"input": "btn 3", "outputs": ["key 9"], "note": "Interact / gift (F)"},
          {"input": "btn 5", "outputs": ["key 21"], "note": "Hammer / use (R)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Attack and Special sit on the triggers; Dash is A/Cross.", "Cast = Q, Call = E by Hades' keyboard defaults - rebind in-game if yours differ."]
      },
      {
        "id": "adobe-photoshop", "category": "app", "displayName": "Adobe Photoshop",
        "subtitle": "Pan, zoom, brush size, and core shortcuts",
        "appPath": "/Applications/Adobe Photoshop 2024/Adobe Photoshop 2024.app", "launchURL": "",
        "light": {"r": 30, "g": 110, "b": 230},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 3 +", "outputs": ["whe 1 + 4"], "note": "Scroll down"},
          {"input": "axi 3 -", "outputs": ["whe 1 - 4"], "note": "Scroll up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Paint / click"},
          {"input": "btn 4", "outputs": ["key 47"], "note": "Smaller brush ([)"},
          {"input": "btn 5", "outputs": ["key 48"], "note": "Larger brush (])"},
          {"input": "btn 0", "outputs": ["key 5"], "note": "Brush tool (B)"},
          {"input": "btn 1", "outputs": ["key 8"], "note": "Eraser (E)"},
          {"input": "btn 2", "outputs": ["key 227", "key 29"], "note": "Undo"},
          {"input": "btn 3", "outputs": ["key 227", "key 28"], "note": "Redo"},
          {"input": "axi 4 +", "outputs": ["key 226"], "note": "Hold to color-pick (Alt)"},
          {"input": "btn 8", "outputs": ["key 227", "key 22"], "note": "Save"}
        ],
        "tips": ["Left stick moves the cursor; bumpers shrink/grow the brush.", "Hold the left trigger (Alt) while painting to sample a color."]
      },
      {
        "id": "adobe-premiere-pro", "category": "app", "displayName": "Adobe Premiere Pro",
        "subtitle": "Shuttle, mark, and cut the timeline",
        "appPath": "", "launchURL": "",
        "light": {"r": 130, "g": 60, "b": 210},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Click"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Play / pause (Space)"},
          {"input": "btn 4", "outputs": ["key 13"], "note": "Shuttle left (J)"},
          {"input": "btn 5", "outputs": ["key 15"], "note": "Shuttle right (L)"},
          {"input": "btn 1", "outputs": ["key 14"], "note": "Stop (K)"},
          {"input": "btn 2", "outputs": ["key 12"], "note": "Mark in (I)"},
          {"input": "btn 3", "outputs": ["key 18"], "note": "Mark out (O)"},
          {"input": "hat 0 L", "outputs": ["key 80"], "note": "Previous frame"},
          {"input": "hat 0 R", "outputs": ["key 79"], "note": "Next frame"},
          {"input": "btn 9", "outputs": ["key 227", "key 22"], "note": "Save"}
        ],
        "tips": ["J/K/L are the classic shuttle controls; I/O set in/out points.", "D-pad steps one frame at a time for precise trims."]
      },
      {
        "id": "presentation-remote", "category": "workflow", "displayName": "Presentation Remote",
        "subtitle": "Advance slides hands-free (Keynote / PowerPoint / Slides)",
        "appPath": "", "launchURL": "",
        "light": {"r": 230, "g": 120, "b": 30},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 5 +", "outputs": ["key 79"], "note": "Next slide (right trigger)"},
          {"input": "axi 4 +", "outputs": ["key 80"], "note": "Previous slide (left trigger)"},
          {"input": "btn 0", "outputs": ["key 79"], "note": "Next slide"},
          {"input": "btn 1", "outputs": ["key 80"], "note": "Previous slide"},
          {"input": "btn 5", "outputs": ["key 79"], "note": "Next slide (bumper)"},
          {"input": "btn 4", "outputs": ["key 80"], "note": "Previous slide (bumper)"},
          {"input": "hat 0 R", "outputs": ["key 79"], "note": "Next"},
          {"input": "hat 0 L", "outputs": ["key 80"], "note": "Previous"},
          {"input": "btn 3", "outputs": ["key 41"], "note": "End slideshow (Esc)"},
          {"input": "axi 0 -", "outputs": ["mou 0 - 14"], "note": "Pointer left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 14"], "note": "Pointer right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 14"], "note": "Pointer up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 14"], "note": "Pointer down"}
        ],
        "tips": ["Either trigger, bumper, face button, or D-pad advances slides - use whatever's comfortable.", "Left stick moves a pointer for gesturing at the screen."]
      },
      {
        "id": "counter-strike-2", "category": "game", "displayName": "Counter-Strike 2",
        "subtitle": "Tactical FPS: move, aim, shoot, buy, swap weapons",
        "appPath": "/Applications/Steam.app", "launchURL": "",
        "light": {"r": 236, "g": 137, "b": 42},
        "confineCursor": true, "autoRecenter": true, "hideCursor": true,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Strafe left (A)"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Strafe right (D)"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Move forward (W)"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Move back (S)"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 20"], "note": "Look right"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 20"], "note": "Look left"},
          {"input": "axi 3 +", "outputs": ["mou 1 + 14"], "note": "Look down"},
          {"input": "axi 3 -", "outputs": ["mou 1 - 14"], "note": "Look up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Fire"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Scope / secondary fire"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Jump"},
          {"input": "btn 1", "outputs": ["key 224"], "note": "Crouch"},
          {"input": "btn 2", "outputs": ["key 21"], "note": "Reload"},
          {"input": "btn 3", "outputs": ["key 8"], "note": "Use / plant / defuse (E)"},
          {"input": "btn 4", "outputs": ["key 10"], "note": "Drop bomb (G)"},
          {"input": "btn 11", "outputs": ["key 225"], "note": "Walk quietly (hold)"},
          {"input": "hat 0 U", "outputs": ["key 30"], "note": "Primary weapon (1)"},
          {"input": "hat 0 L", "outputs": ["key 31"], "note": "Secondary weapon (2)"},
          {"input": "hat 0 D", "outputs": ["key 32"], "note": "Knife (3)"},
          {"input": "hat 0 R", "outputs": ["key 5"], "note": "Buy menu (B)"},
          {"input": "btn 8", "outputs": ["key 43"], "note": "Scoreboard (Tab)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Right trigger fires; left trigger scopes or alt-fires.", "D-pad picks weapons and opens the buy menu."]
      },
      {
        "id": "valorant", "category": "game", "displayName": "VALORANT",
        "subtitle": "Tactical FPS: move, aim, abilities, ultimate",
        "appPath": "", "launchURL": "",
        "light": {"r": 255, "g": 70, "b": 85},
        "confineCursor": true, "autoRecenter": true, "hideCursor": true,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Strafe left (A)"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Strafe right (D)"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Move forward (W)"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Move back (S)"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 20"], "note": "Look right"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 20"], "note": "Look left"},
          {"input": "axi 3 +", "outputs": ["mou 1 + 14"], "note": "Look down"},
          {"input": "axi 3 -", "outputs": ["mou 1 - 14"], "note": "Look up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Fire"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Alt fire / zoom"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Jump"},
          {"input": "btn 1", "outputs": ["key 224"], "note": "Crouch"},
          {"input": "btn 2", "outputs": ["key 21"], "note": "Reload"},
          {"input": "btn 3", "outputs": ["key 9"], "note": "Pick up / interact (F)"},
          {"input": "btn 4", "outputs": ["key 20"], "note": "Ability (Q)"},
          {"input": "btn 5", "outputs": ["key 8"], "note": "Signature ability (E)"},
          {"input": "hat 0 U", "outputs": ["key 6"], "note": "Ability (C)"},
          {"input": "hat 0 D", "outputs": ["key 27"], "note": "Ultimate (X)"},
          {"input": "hat 0 L", "outputs": ["key 30"], "note": "Primary weapon (1)"},
          {"input": "hat 0 R", "outputs": ["key 31"], "note": "Secondary weapon (2)"},
          {"input": "btn 8", "outputs": ["key 43"], "note": "Scoreboard (Tab)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Face buttons hold your abilities; D-pad up and down are C and the ultimate.", "Left trigger zooms; right trigger fires."]
      },
      {
        "id": "apex-legends", "category": "game", "displayName": "Apex Legends",
        "subtitle": "Battle-royale FPS: move, aim, tactical, ultimate",
        "appPath": "/Applications/Steam.app", "launchURL": "",
        "light": {"r": 218, "g": 55, "b": 42},
        "confineCursor": true, "autoRecenter": true, "hideCursor": true,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Strafe left (A)"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Strafe right (D)"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Move forward (W)"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Move back (S)"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 20"], "note": "Look right"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 20"], "note": "Look left"},
          {"input": "axi 3 +", "outputs": ["mou 1 + 14"], "note": "Look down"},
          {"input": "axi 3 -", "outputs": ["mou 1 - 14"], "note": "Look up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Fire"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Aim down sights"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Jump"},
          {"input": "btn 1", "outputs": ["key 6"], "note": "Crouch (C)"},
          {"input": "btn 2", "outputs": ["key 21"], "note": "Reload"},
          {"input": "btn 3", "outputs": ["key 8"], "note": "Interact / use (E)"},
          {"input": "btn 4", "outputs": ["key 20"], "note": "Tactical ability (Q)"},
          {"input": "btn 5", "outputs": ["key 29"], "note": "Ultimate ability (Z)"},
          {"input": "btn 11", "outputs": ["key 225"], "note": "Sprint (hold)"},
          {"input": "hat 0 U", "outputs": ["key 30"], "note": "Weapon 1"},
          {"input": "hat 0 L", "outputs": ["key 31"], "note": "Weapon 2"},
          {"input": "hat 0 R", "outputs": ["key 10"], "note": "Grenade (G)"},
          {"input": "hat 0 D", "outputs": ["key 25"], "note": "Melee (V)"},
          {"input": "btn 8", "outputs": ["key 43"], "note": "Inventory (Tab)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"},
          {"input": "btn 10", "outputs": ["key 16"], "note": "Map (M)"}
        ],
        "tips": ["Left-stick click sprints; bumpers are your tactical and ultimate.", "D-pad swaps weapons, throws a grenade, and melees."]
      },
      {
        "id": "overwatch-2", "category": "game", "displayName": "Overwatch 2",
        "subtitle": "Hero shooter: move, aim, abilities, ultimate",
        "appPath": "", "launchURL": "",
        "light": {"r": 244, "g": 128, "b": 33},
        "confineCursor": true, "autoRecenter": true, "hideCursor": true,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Strafe left (A)"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Strafe right (D)"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Move forward (W)"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Move back (S)"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 20"], "note": "Look right"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 20"], "note": "Look left"},
          {"input": "axi 3 +", "outputs": ["mou 1 + 14"], "note": "Look down"},
          {"input": "axi 3 -", "outputs": ["mou 1 - 14"], "note": "Look up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Primary fire"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Secondary fire"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Jump"},
          {"input": "btn 1", "outputs": ["key 224"], "note": "Crouch"},
          {"input": "btn 2", "outputs": ["key 21"], "note": "Reload"},
          {"input": "btn 3", "outputs": ["key 8"], "note": "Ability 2 (E)"},
          {"input": "btn 4", "outputs": ["key 225"], "note": "Ability 1 (Shift)"},
          {"input": "btn 5", "outputs": ["key 20"], "note": "Ultimate (Q)"},
          {"input": "hat 0 U", "outputs": ["key 6"], "note": "Comms wheel (C)"},
          {"input": "hat 0 D", "outputs": ["key 25"], "note": "Melee (V)"},
          {"input": "btn 8", "outputs": ["key 43"], "note": "Scoreboard (Tab)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Bumpers fire your two cooldown abilities; right bumper is the ultimate.", "Right trigger is primary fire, left trigger is alternate fire."]
      },
      {
        "id": "call-of-duty-warzone", "category": "game", "displayName": "Call of Duty: Warzone",
        "subtitle": "FPS battle royale: move, aim, sprint, equipment",
        "appPath": "", "launchURL": "",
        "light": {"r": 120, "g": 140, "b": 90},
        "confineCursor": true, "autoRecenter": true, "hideCursor": true,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Strafe left (A)"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Strafe right (D)"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Move forward (W)"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Move back (S)"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 20"], "note": "Look right"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 20"], "note": "Look left"},
          {"input": "axi 3 +", "outputs": ["mou 1 + 14"], "note": "Look down"},
          {"input": "axi 3 -", "outputs": ["mou 1 - 14"], "note": "Look up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Fire"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Aim down sights"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Jump / mantle"},
          {"input": "btn 1", "outputs": ["key 6"], "note": "Crouch / slide (C)"},
          {"input": "btn 2", "outputs": ["key 21"], "note": "Reload"},
          {"input": "btn 3", "outputs": ["key 9"], "note": "Use (F)"},
          {"input": "btn 4", "outputs": ["key 10"], "note": "Lethal grenade (G)"},
          {"input": "btn 5", "outputs": ["key 20"], "note": "Tactical (Q)"},
          {"input": "btn 11", "outputs": ["key 225"], "note": "Sprint (hold)"},
          {"input": "hat 0 U", "outputs": ["key 30"], "note": "Primary weapon (1)"},
          {"input": "hat 0 L", "outputs": ["key 31"], "note": "Secondary weapon (2)"},
          {"input": "hat 0 D", "outputs": ["key 25"], "note": "Melee (V)"},
          {"input": "hat 0 R", "outputs": ["key 16"], "note": "Ping / map (M)"},
          {"input": "btn 8", "outputs": ["key 43"], "note": "Map / inventory (Tab)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Left-stick click sprints; left trigger aims, right trigger fires.", "D-pad swaps weapons, melees, and opens the map."]
      },
      {
        "id": "league-of-legends", "category": "game", "displayName": "League of Legends",
        "subtitle": "MOBA: point-to-move, QWER abilities, summoners",
        "appPath": "", "launchURL": "",
        "light": {"r": 200, "g": 170, "b": 90},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 5 +", "outputs": ["mbt 1"], "note": "Move / attack (right click)"},
          {"input": "axi 4 +", "outputs": ["mbt 0"], "note": "Select (left click)"},
          {"input": "btn 0", "outputs": ["key 20"], "note": "Ability Q"},
          {"input": "btn 1", "outputs": ["key 26"], "note": "Ability W"},
          {"input": "btn 2", "outputs": ["key 8"], "note": "Ability E"},
          {"input": "btn 3", "outputs": ["key 21"], "note": "Ultimate R"},
          {"input": "btn 4", "outputs": ["key 7"], "note": "Summoner spell D"},
          {"input": "btn 5", "outputs": ["key 9"], "note": "Summoner spell F"},
          {"input": "hat 0 U", "outputs": ["key 30"], "note": "Item 1"},
          {"input": "hat 0 L", "outputs": ["key 31"], "note": "Item 2"},
          {"input": "hat 0 R", "outputs": ["key 32"], "note": "Item 3"},
          {"input": "hat 0 D", "outputs": ["key 5"], "note": "Recall (B)"},
          {"input": "btn 8", "outputs": ["key 43"], "note": "Scoreboard (Tab)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Aim with the left stick; right trigger right-clicks to move or attack.", "Face buttons are Q W E R; bumpers are your summoner spells."]
      },
      {
        "id": "dota-2", "category": "game", "displayName": "Dota 2",
        "subtitle": "MOBA: point-to-move, QWER abilities, items",
        "appPath": "/Applications/Steam.app", "launchURL": "",
        "light": {"r": 180, "g": 40, "b": 30},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 5 +", "outputs": ["mbt 1"], "note": "Move / attack (right click)"},
          {"input": "axi 4 +", "outputs": ["mbt 0"], "note": "Select (left click)"},
          {"input": "btn 0", "outputs": ["key 20"], "note": "Ability Q"},
          {"input": "btn 1", "outputs": ["key 26"], "note": "Ability W"},
          {"input": "btn 2", "outputs": ["key 8"], "note": "Ability E"},
          {"input": "btn 3", "outputs": ["key 21"], "note": "Ultimate R"},
          {"input": "btn 4", "outputs": ["key 7"], "note": "Ability D"},
          {"input": "btn 5", "outputs": ["key 9"], "note": "Ability F"},
          {"input": "hat 0 U", "outputs": ["key 30"], "note": "Item 1"},
          {"input": "hat 0 L", "outputs": ["key 31"], "note": "Item 2"},
          {"input": "hat 0 R", "outputs": ["key 32"], "note": "Item 3"},
          {"input": "hat 0 D", "outputs": ["key 10"], "note": "Glyph (G)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Aim with the left stick; right trigger right-clicks to move or attack.", "Face buttons and bumpers cover all six ability slots."]
      },
      {
        "id": "the-witcher-3", "category": "game", "displayName": "The Witcher 3",
        "subtitle": "Action RPG: move, camera, attacks, signs",
        "appPath": "/Applications/Steam.app", "launchURL": "",
        "light": {"r": 200, "g": 200, "b": 210},
        "confineCursor": true, "autoRecenter": true, "hideCursor": true,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Strafe left (A)"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Strafe right (D)"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Move forward (W)"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Move back (S)"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 18"], "note": "Camera right"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 18"], "note": "Camera left"},
          {"input": "axi 3 +", "outputs": ["mou 1 + 12"], "note": "Camera down"},
          {"input": "axi 3 -", "outputs": ["mou 1 - 12"], "note": "Camera up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Fast attack"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Strong attack"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Jump"},
          {"input": "btn 1", "outputs": ["key 226"], "note": "Dodge (Alt)"},
          {"input": "btn 2", "outputs": ["key 224"], "note": "Roll (Ctrl)"},
          {"input": "btn 3", "outputs": ["key 8"], "note": "Interact (E)"},
          {"input": "btn 4", "outputs": ["key 20"], "note": "Cast sign (Q)"},
          {"input": "btn 11", "outputs": ["key 225"], "note": "Sprint (Shift)"},
          {"input": "hat 0 U", "outputs": ["key 12"], "note": "Inventory (I)"},
          {"input": "hat 0 D", "outputs": ["key 13"], "note": "Journal (J)"},
          {"input": "hat 0 L", "outputs": ["key 16"], "note": "Map (M)"},
          {"input": "hat 0 R", "outputs": ["key 6"], "note": "Character (C)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Triggers are fast and strong attacks; hold left-stick click to sprint.", "D-pad opens inventory, journal, map, and character screens."]
      },
      {
        "id": "skyrim", "category": "game", "displayName": "Skyrim",
        "subtitle": "Open-world RPG: move, look, attack, block, menus",
        "appPath": "/Applications/Steam.app", "launchURL": "",
        "light": {"r": 150, "g": 140, "b": 110},
        "confineCursor": true, "autoRecenter": true, "hideCursor": true,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Strafe left (A)"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Strafe right (D)"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Move forward (W)"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Move back (S)"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 18"], "note": "Look right"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 18"], "note": "Look left"},
          {"input": "axi 3 +", "outputs": ["mou 1 + 12"], "note": "Look down"},
          {"input": "axi 3 -", "outputs": ["mou 1 - 12"], "note": "Look up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Right hand / attack"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Left hand / block"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Jump"},
          {"input": "btn 1", "outputs": ["key 224"], "note": "Sneak (Ctrl)"},
          {"input": "btn 2", "outputs": ["key 21"], "note": "Ready / sheathe (R)"},
          {"input": "btn 3", "outputs": ["key 8"], "note": "Activate (E)"},
          {"input": "btn 4", "outputs": ["key 20"], "note": "Favorites (Q)"},
          {"input": "btn 5", "outputs": ["key 23"], "note": "Wait (T)"},
          {"input": "btn 11", "outputs": ["key 225"], "note": "Sprint (Shift)"},
          {"input": "hat 0 U", "outputs": ["key 16"], "note": "Map (M)"},
          {"input": "hat 0 D", "outputs": ["key 13"], "note": "Journal (J)"},
          {"input": "hat 0 L", "outputs": ["key 12"], "note": "Inventory (I)"},
          {"input": "hat 0 R", "outputs": ["key 19"], "note": "Magic (P)"},
          {"input": "btn 8", "outputs": ["key 43"], "note": "Menu (Tab)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "System (Esc)"}
        ],
        "tips": ["Triggers are your right and left hands; sheathe with the Square/X face button.", "D-pad opens map, journal, inventory, and magic."]
      },
      {
        "id": "baldurs-gate-3", "category": "game", "displayName": "Baldur's Gate 3",
        "subtitle": "Party RPG: cursor, hotbar, jump, end turn",
        "appPath": "/Applications/Steam.app", "launchURL": "",
        "light": {"r": 120, "g": 60, "b": 160},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Select / confirm (left click)"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Context menu (right click)"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Jump"},
          {"input": "btn 1", "outputs": ["key 6"], "note": "Toggle sneak (C)"},
          {"input": "btn 2", "outputs": ["key 8"], "note": "Highlight items (E / Alt)"},
          {"input": "btn 3", "outputs": ["key 13"], "note": "Journal (J)"},
          {"input": "btn 4", "outputs": ["key 30"], "note": "Hotbar 1"},
          {"input": "btn 5", "outputs": ["key 31"], "note": "Hotbar 2"},
          {"input": "hat 0 U", "outputs": ["key 32"], "note": "Hotbar 3"},
          {"input": "hat 0 D", "outputs": ["key 33"], "note": "Hotbar 4"},
          {"input": "hat 0 L", "outputs": ["key 34"], "note": "Hotbar 5"},
          {"input": "hat 0 R", "outputs": ["key 35"], "note": "Hotbar 6"},
          {"input": "btn 8", "outputs": ["key 12"], "note": "Inventory (I)"},
          {"input": "btn 10", "outputs": ["key 16"], "note": "Map (M)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Aim the cursor with the left stick; triggers are left and right click.", "Face buttons and D-pad fire hotbar slots 1 through 6."]
      },
      {
        "id": "diablo-iv", "category": "game", "displayName": "Diablo IV",
        "subtitle": "Action RPG: move, skills, potion, evade",
        "appPath": "", "launchURL": "",
        "light": {"r": 160, "g": 20, "b": 20},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Move / core skill (left click)"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Secondary skill (right click)"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Evade"},
          {"input": "btn 1", "outputs": ["key 20"], "note": "Potion (Q)"},
          {"input": "btn 2", "outputs": ["key 8"], "note": "Skill 3 (E)? interact"},
          {"input": "btn 3", "outputs": ["key 21"], "note": "Skill 4 (R)"},
          {"input": "hat 0 U", "outputs": ["key 30"], "note": "Skill slot 1"},
          {"input": "hat 0 L", "outputs": ["key 31"], "note": "Skill slot 2"},
          {"input": "hat 0 R", "outputs": ["key 32"], "note": "Skill slot 3"},
          {"input": "hat 0 D", "outputs": ["key 33"], "note": "Skill slot 4"},
          {"input": "btn 4", "outputs": ["key 12"], "note": "Inventory (I)"},
          {"input": "btn 5", "outputs": ["key 6"], "note": "Character (C)"},
          {"input": "btn 8", "outputs": ["key 43"], "note": "Map (Tab)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Aim with the left stick; triggers are your left and right click skills.", "D-pad fires action-bar skill slots 1 through 4."]
      },
      {
        "id": "doom-eternal", "category": "game", "displayName": "DOOM Eternal",
        "subtitle": "Fast FPS: move, aim, dash, weapons, glory kill",
        "appPath": "/Applications/Steam.app", "launchURL": "",
        "light": {"r": 200, "g": 60, "b": 30},
        "confineCursor": true, "autoRecenter": true, "hideCursor": true,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Strafe left (A)"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Strafe right (D)"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Move forward (W)"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Move back (S)"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 22"], "note": "Look right"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 22"], "note": "Look left"},
          {"input": "axi 3 +", "outputs": ["mou 1 + 16"], "note": "Look down"},
          {"input": "axi 3 -", "outputs": ["mou 1 - 16"], "note": "Look up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Fire"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Weapon mod / alt fire"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Jump"},
          {"input": "btn 1", "outputs": ["key 224"], "note": "Crouch"},
          {"input": "btn 2", "outputs": ["key 9"], "note": "Glory kill / use (F)"},
          {"input": "btn 3", "outputs": ["key 8"], "note": "Equipment (E)"},
          {"input": "btn 4", "outputs": ["key 10"], "note": "Grenade (G)"},
          {"input": "btn 5", "outputs": ["key 25"], "note": "Flame belch (V)"},
          {"input": "btn 11", "outputs": ["key 225"], "note": "Dash (Shift)"},
          {"input": "hat 0 U", "outputs": ["key 30"], "note": "Weapon 1"},
          {"input": "hat 0 L", "outputs": ["key 31"], "note": "Weapon 2"},
          {"input": "hat 0 R", "outputs": ["key 32"], "note": "Weapon 3"},
          {"input": "hat 0 D", "outputs": ["key 33"], "note": "Weapon 4"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Left-stick click dashes; bumpers throw grenades and flame belch.", "D-pad swaps weapons; left trigger is the weapon mod."]
      },
      {
        "id": "valheim", "category": "game", "displayName": "Valheim",
        "subtitle": "Survival: move, look, attack, block, hotbar",
        "appPath": "/Applications/Steam.app", "launchURL": "",
        "light": {"r": 90, "g": 150, "b": 90},
        "confineCursor": true, "autoRecenter": true, "hideCursor": true,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Strafe left (A)"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Strafe right (D)"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Move forward (W)"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Move back (S)"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 18"], "note": "Look right"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 18"], "note": "Look left"},
          {"input": "axi 3 +", "outputs": ["mou 1 + 12"], "note": "Look down"},
          {"input": "axi 3 -", "outputs": ["mou 1 - 12"], "note": "Look up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Attack"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Block / secondary"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Jump"},
          {"input": "btn 1", "outputs": ["key 224"], "note": "Crouch / sneak (Ctrl)"},
          {"input": "btn 3", "outputs": ["key 8"], "note": "Use / interact (E)"},
          {"input": "btn 2", "outputs": ["key 21"], "note": "Repair / rotate (R)"},
          {"input": "btn 11", "outputs": ["key 225"], "note": "Run (Shift)"},
          {"input": "hat 0 U", "outputs": ["key 30"], "note": "Hotbar 1"},
          {"input": "hat 0 L", "outputs": ["key 31"], "note": "Hotbar 2"},
          {"input": "hat 0 R", "outputs": ["key 32"], "note": "Hotbar 3"},
          {"input": "hat 0 D", "outputs": ["key 33"], "note": "Hotbar 4"},
          {"input": "btn 8", "outputs": ["key 43"], "note": "Inventory (Tab)"},
          {"input": "btn 10", "outputs": ["key 16"], "note": "Map (M)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Triggers attack and block; hold left-stick click to run.", "D-pad selects hotbar items; Tab opens your inventory."]
      },
      {
        "id": "vampire-survivors", "category": "game", "displayName": "Vampire Survivors",
        "subtitle": "Auto-attack roguelite: just move and menu",
        "appPath": "/Applications/Steam.app", "launchURL": "",
        "light": {"r": 140, "g": 80, "b": 200},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Move left (A)"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Move right (D)"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Move up (W)"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Move down (S)"},
          {"input": "hat 0 U", "outputs": ["key 82"], "note": "Move up"},
          {"input": "hat 0 D", "outputs": ["key 81"], "note": "Move down"},
          {"input": "hat 0 L", "outputs": ["key 80"], "note": "Move left"},
          {"input": "hat 0 R", "outputs": ["key 79"], "note": "Move right"},
          {"input": "btn 0", "outputs": ["key 40"], "note": "Confirm (Enter)"},
          {"input": "btn 1", "outputs": ["key 41"], "note": "Back / pause (Esc)"}
        ],
        "tips": ["Weapons fire on their own, so this is movement only.", "Either stick or the D-pad moves; the A button confirms menus."]
      },
      {
        "id": "factorio", "category": "game", "displayName": "Factorio",
        "subtitle": "Top-down builder: move, cursor, mine, place, toolbar",
        "appPath": "/Applications/Steam.app", "launchURL": "",
        "light": {"r": 230, "g": 160, "b": 40},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Move left (A)"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Move right (D)"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Move up (W)"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Move down (S)"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 3 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 3 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Mine / place (left click)"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Pick up / interact (right click)"},
          {"input": "btn 0", "outputs": ["key 8"], "note": "Open / inventory (E)"},
          {"input": "btn 1", "outputs": ["key 21"], "note": "Rotate (R)"},
          {"input": "btn 2", "outputs": ["key 20"], "note": "Clear cursor / pick (Q)"},
          {"input": "btn 3", "outputs": ["key 9"], "note": "Toggle filter (F)"},
          {"input": "hat 0 U", "outputs": ["key 30"], "note": "Toolbar 1"},
          {"input": "hat 0 L", "outputs": ["key 31"], "note": "Toolbar 2"},
          {"input": "hat 0 R", "outputs": ["key 32"], "note": "Toolbar 3"},
          {"input": "hat 0 D", "outputs": ["key 33"], "note": "Toolbar 4"},
          {"input": "btn 8", "outputs": ["key 23"], "note": "Tech tree (T)"},
          {"input": "btn 10", "outputs": ["key 16"], "note": "Map (M)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Left stick walks; right stick aims the cursor for placing and mining.", "R rotates the held item; E opens the inventory."]
      },
      {
        "id": "subnautica", "category": "game", "displayName": "Subnautica",
        "subtitle": "Underwater survival: swim, look, tools, quickslots",
        "appPath": "/Applications/Steam.app", "launchURL": "",
        "light": {"r": 40, "g": 150, "b": 200},
        "confineCursor": true, "autoRecenter": true, "hideCursor": true,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Swim left (A)"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Swim right (D)"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Swim forward (W)"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Swim back (S)"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 18"], "note": "Look right"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 18"], "note": "Look left"},
          {"input": "axi 3 +", "outputs": ["mou 1 + 12"], "note": "Look down"},
          {"input": "axi 3 -", "outputs": ["mou 1 - 12"], "note": "Look up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Use tool (left click)"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Alt use (right click)"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Swim up"},
          {"input": "btn 1", "outputs": ["key 224"], "note": "Swim down (Ctrl)"},
          {"input": "btn 3", "outputs": ["key 9"], "note": "Use / pick up (F)"},
          {"input": "btn 2", "outputs": ["key 21"], "note": "Reload / deselect (R)"},
          {"input": "btn 11", "outputs": ["key 225"], "note": "Sprint swim (Shift)"},
          {"input": "hat 0 U", "outputs": ["key 30"], "note": "Quickslot 1"},
          {"input": "hat 0 L", "outputs": ["key 31"], "note": "Quickslot 2"},
          {"input": "hat 0 R", "outputs": ["key 32"], "note": "Quickslot 3"},
          {"input": "hat 0 D", "outputs": ["key 33"], "note": "Quickslot 4"},
          {"input": "btn 8", "outputs": ["key 43"], "note": "Inventory (Tab)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["A button swims up, Circle/B swims down; triggers use your tools.", "D-pad picks quickslot gear; Tab opens the inventory."]
      },
      {
        "id": "among-us", "category": "game", "displayName": "Among Us",
        "subtitle": "Move, use, report, kill, map",
        "appPath": "/Applications/Steam.app", "launchURL": "",
        "light": {"r": 200, "g": 50, "b": 60},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Move left (A)"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Move right (D)"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Move up (W)"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Move down (S)"},
          {"input": "hat 0 U", "outputs": ["key 82"], "note": "Move up"},
          {"input": "hat 0 D", "outputs": ["key 81"], "note": "Move down"},
          {"input": "hat 0 L", "outputs": ["key 80"], "note": "Move left"},
          {"input": "hat 0 R", "outputs": ["key 79"], "note": "Move right"},
          {"input": "btn 0", "outputs": ["key 8"], "note": "Use (E)"},
          {"input": "btn 1", "outputs": ["key 21"], "note": "Report (R)"},
          {"input": "btn 2", "outputs": ["key 20"], "note": "Kill (Q)"},
          {"input": "btn 3", "outputs": ["key 43"], "note": "Map (Tab)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Move with the stick or D-pad; A uses, B reports, X is the impostor kill.", "Y opens the map."]
      },
      {
        "id": "microsoft-excel", "category": "app", "displayName": "Microsoft Excel",
        "subtitle": "Move between cells, scroll, copy, paste, save",
        "appPath": "/Applications/Microsoft Excel.app", "launchURL": "",
        "light": {"r": 33, "g": 115, "b": 70},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 3 +", "outputs": ["whe 1 + 5"], "note": "Scroll down"},
          {"input": "axi 3 -", "outputs": ["whe 1 - 5"], "note": "Scroll up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Click"},
          {"input": "hat 0 U", "outputs": ["key 82"], "note": "Cell up"},
          {"input": "hat 0 D", "outputs": ["key 81"], "note": "Cell down"},
          {"input": "hat 0 L", "outputs": ["key 80"], "note": "Cell left"},
          {"input": "hat 0 R", "outputs": ["key 79"], "note": "Cell right"},
          {"input": "btn 0", "outputs": ["key 227", "key 6"], "note": "Copy"},
          {"input": "btn 1", "outputs": ["key 227", "key 25"], "note": "Paste"},
          {"input": "btn 2", "outputs": ["key 227", "key 22"], "note": "Save"},
          {"input": "btn 3", "outputs": ["key 227", "key 29"], "note": "Undo"},
          {"input": "btn 4", "outputs": ["key 43"], "note": "Next cell (Tab)"},
          {"input": "btn 5", "outputs": ["key 40"], "note": "Confirm cell (Enter)"}
        ],
        "tips": ["Left stick nudges the pointer; the D-pad steps cell by cell.", "Face buttons are Copy, Paste, Save, and Undo."]
      },
      {
        "id": "microsoft-powerpoint", "category": "app", "displayName": "Microsoft PowerPoint",
        "subtitle": "Present hands-free: advance, pointer, end show",
        "appPath": "/Applications/Microsoft PowerPoint.app", "launchURL": "",
        "light": {"r": 183, "g": 71, "b": 42},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 5 +", "outputs": ["key 79"], "note": "Next slide (right trigger)"},
          {"input": "axi 4 +", "outputs": ["key 80"], "note": "Previous slide (left trigger)"},
          {"input": "btn 0", "outputs": ["key 79"], "note": "Next slide"},
          {"input": "btn 1", "outputs": ["key 80"], "note": "Previous slide"},
          {"input": "btn 5", "outputs": ["key 79"], "note": "Next (bumper)"},
          {"input": "btn 4", "outputs": ["key 80"], "note": "Previous (bumper)"},
          {"input": "hat 0 R", "outputs": ["key 79"], "note": "Next"},
          {"input": "hat 0 L", "outputs": ["key 80"], "note": "Previous"},
          {"input": "btn 3", "outputs": ["key 41"], "note": "End show (Esc)"},
          {"input": "btn 2", "outputs": ["key 227", "key 22"], "note": "Save"},
          {"input": "axi 0 -", "outputs": ["mou 0 - 14"], "note": "Pointer left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 14"], "note": "Pointer right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 14"], "note": "Pointer up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 14"], "note": "Pointer down"}
        ],
        "tips": ["Trigger, bumper, face button, or D-pad all advance slides.", "Left stick moves a pointer to gesture at the screen."]
      },
      {
        "id": "google-chrome", "category": "app", "displayName": "Google Chrome",
        "subtitle": "Cursor, scroll, tabs, back, forward, reload",
        "appPath": "/Applications/Google Chrome.app", "launchURL": "",
        "light": {"r": 66, "g": 133, "b": 244},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 3 +", "outputs": ["whe 1 + 5"], "note": "Scroll down"},
          {"input": "axi 3 -", "outputs": ["whe 1 - 5"], "note": "Scroll up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Left click"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Right click"},
          {"input": "btn 0", "outputs": ["key 227", "key 80"], "note": "Back"},
          {"input": "btn 1", "outputs": ["key 227", "key 79"], "note": "Forward"},
          {"input": "btn 2", "outputs": ["key 227", "key 21"], "note": "Reload"},
          {"input": "btn 3", "outputs": ["key 227", "key 23"], "note": "New tab"},
          {"input": "btn 4", "outputs": ["key 227", "key 26"], "note": "Close tab"},
          {"input": "btn 5", "outputs": ["key 227", "key 15"], "note": "Address bar"},
          {"input": "hat 0 L", "outputs": ["key 227", "key 226", "key 80"], "note": "Previous tab"},
          {"input": "hat 0 R", "outputs": ["key 227", "key 226", "key 79"], "note": "Next tab"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Stop / Esc"}
        ],
        "tips": ["Left stick moves the pointer; right stick scrolls.", "Face buttons are Back, Forward, Reload, and New Tab."]
      },
      {
        "id": "safari", "category": "app", "displayName": "Safari",
        "subtitle": "Cursor, scroll, tabs, back, forward, reload",
        "appPath": "/Applications/Safari.app", "launchURL": "",
        "light": {"r": 30, "g": 140, "b": 230},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 3 +", "outputs": ["whe 1 + 5"], "note": "Scroll down"},
          {"input": "axi 3 -", "outputs": ["whe 1 - 5"], "note": "Scroll up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Left click"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Right click"},
          {"input": "btn 0", "outputs": ["key 227", "key 80"], "note": "Back"},
          {"input": "btn 1", "outputs": ["key 227", "key 79"], "note": "Forward"},
          {"input": "btn 2", "outputs": ["key 227", "key 21"], "note": "Reload"},
          {"input": "btn 3", "outputs": ["key 227", "key 23"], "note": "New tab"},
          {"input": "btn 4", "outputs": ["key 227", "key 26"], "note": "Close tab"},
          {"input": "btn 5", "outputs": ["key 227", "key 15"], "note": "Address bar"},
          {"input": "hat 0 L", "outputs": ["key 227", "key 226", "key 80"], "note": "Previous tab"},
          {"input": "hat 0 R", "outputs": ["key 227", "key 226", "key 79"], "note": "Next tab"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Stop / Esc"}
        ],
        "tips": ["Left stick moves the pointer; right stick scrolls.", "D-pad left and right step through your open tabs."]
      },
      {
        "id": "visual-studio-code", "category": "app", "displayName": "Visual Studio Code",
        "subtitle": "Cursor, scroll, save, find, palette, sidebar",
        "appPath": "/Applications/Visual Studio Code.app", "launchURL": "",
        "light": {"r": 0, "g": 122, "b": 204},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 3 +", "outputs": ["whe 1 + 5"], "note": "Scroll down"},
          {"input": "axi 3 -", "outputs": ["whe 1 - 5"], "note": "Scroll up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Click"},
          {"input": "btn 0", "outputs": ["key 227", "key 22"], "note": "Save"},
          {"input": "btn 1", "outputs": ["key 227", "key 9"], "note": "Find"},
          {"input": "btn 2", "outputs": ["key 227", "key 226", "key 19"], "note": "Command palette"},
          {"input": "btn 3", "outputs": ["key 227", "key 5"], "note": "Toggle sidebar"},
          {"input": "hat 0 L", "outputs": ["key 227", "key 226", "key 80"], "note": "Previous editor"},
          {"input": "hat 0 R", "outputs": ["key 227", "key 226", "key 79"], "note": "Next editor"},
          {"input": "hat 0 U", "outputs": ["key 82"], "note": "Line up"},
          {"input": "hat 0 D", "outputs": ["key 81"], "note": "Line down"},
          {"input": "btn 4", "outputs": ["key 227", "key 29"], "note": "Undo"},
          {"input": "btn 5", "outputs": ["key 227", "key 226", "key 29"], "note": "Redo"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Escape"}
        ],
        "tips": ["Face buttons are Save, Find, Command Palette, and Sidebar.", "D-pad left and right switch editor tabs."]
      },
      {
        "id": "xcode", "category": "app", "displayName": "Xcode",
        "subtitle": "Build, run, stop, save, find, navigate",
        "appPath": "/Applications/Xcode.app", "launchURL": "",
        "light": {"r": 40, "g": 110, "b": 210},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 3 +", "outputs": ["whe 1 + 5"], "note": "Scroll down"},
          {"input": "axi 3 -", "outputs": ["whe 1 - 5"], "note": "Scroll up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Click"},
          {"input": "btn 0", "outputs": ["key 227", "key 5"], "note": "Build (Cmd+B)"},
          {"input": "btn 1", "outputs": ["key 227", "key 21"], "note": "Run (Cmd+R)"},
          {"input": "btn 2", "outputs": ["key 227", "key 22"], "note": "Save"},
          {"input": "btn 3", "outputs": ["key 227", "key 9"], "note": "Find"},
          {"input": "btn 4", "outputs": ["key 227", "key 29"], "note": "Undo"},
          {"input": "btn 5", "outputs": ["key 227", "key 5"], "note": "Build"},
          {"input": "hat 0 U", "outputs": ["key 82"], "note": "Line up"},
          {"input": "hat 0 D", "outputs": ["key 81"], "note": "Line down"},
          {"input": "btn 9", "outputs": ["key 227", "key 55"], "note": "Stop (Cmd+.)"}
        ],
        "tips": ["Face buttons Build, Run, Save, and Find; Start/Options stops the run.", "Left stick is the pointer, right stick scrolls."]
      },
      {
        "id": "final-cut-pro", "category": "app", "displayName": "Final Cut Pro",
        "subtitle": "Transport, blade, mark in/out, undo, save",
        "appPath": "/Applications/Final Cut Pro.app", "launchURL": "",
        "light": {"r": 160, "g": 160, "b": 170},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "btn 0", "outputs": ["key 44"], "note": "Play / Pause (Space)"},
          {"input": "btn 1", "outputs": ["key 15"], "note": "Play forward (L)"},
          {"input": "btn 2", "outputs": ["key 13"], "note": "Play reverse (J)"},
          {"input": "btn 3", "outputs": ["key 14"], "note": "Pause (K)"},
          {"input": "axi 0 -", "outputs": ["key 80"], "note": "Step back one frame"},
          {"input": "axi 0 +", "outputs": ["key 79"], "note": "Step forward one frame"},
          {"input": "axi 5 +", "outputs": ["key 5"], "note": "Blade (B)"},
          {"input": "axi 4 +", "outputs": ["key 4"], "note": "Select tool (A)"},
          {"input": "hat 0 L", "outputs": ["key 12"], "note": "Mark in (I)"},
          {"input": "hat 0 R", "outputs": ["key 18"], "note": "Mark out (O)"},
          {"input": "btn 4", "outputs": ["key 227", "key 29"], "note": "Undo"},
          {"input": "btn 5", "outputs": ["key 227", "key 22"], "note": "Save"},
          {"input": "axi 3 +", "outputs": ["whe 1 + 5"], "note": "Scroll timeline down"},
          {"input": "axi 3 -", "outputs": ["whe 1 - 5"], "note": "Scroll timeline up"}
        ],
        "tips": ["Face buttons are the J K L transport plus the spacebar.", "Right trigger is the Blade; left and right on the D-pad mark in and out."]
      },
      {
        "id": "logic-pro", "category": "app", "displayName": "Logic Pro",
        "subtitle": "Transport, record, cycle, undo, save",
        "appPath": "/Applications/Logic Pro.app", "launchURL": "",
        "light": {"r": 120, "g": 140, "b": 170},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "btn 0", "outputs": ["key 44"], "note": "Play / Stop (Space)"},
          {"input": "btn 1", "outputs": ["key 21"], "note": "Record (R)"},
          {"input": "btn 2", "outputs": ["key 40"], "note": "Return to start (Enter)"},
          {"input": "btn 3", "outputs": ["key 6"], "note": "Cycle (C)"},
          {"input": "axi 0 -", "outputs": ["key 80"], "note": "Rewind (Left)"},
          {"input": "axi 0 +", "outputs": ["key 79"], "note": "Forward (Right)"},
          {"input": "axi 3 +", "outputs": ["whe 1 + 5"], "note": "Scroll down"},
          {"input": "axi 3 -", "outputs": ["whe 1 - 5"], "note": "Scroll up"},
          {"input": "btn 4", "outputs": ["key 227", "key 29"], "note": "Undo"},
          {"input": "btn 5", "outputs": ["key 227", "key 22"], "note": "Save"},
          {"input": "hat 0 U", "outputs": ["key 227", "key 46"], "note": "Zoom in"},
          {"input": "hat 0 D", "outputs": ["key 227", "key 45"], "note": "Zoom out"}
        ],
        "tips": ["A button is the spacebar transport; B records, X returns to start.", "Bumpers Undo and Save; the D-pad zooms the timeline."]
      },
      {
        "id": "figma", "category": "app", "displayName": "Figma",
        "subtitle": "Cursor, tools, zoom, undo, copy",
        "appPath": "/Applications/Figma.app", "launchURL": "",
        "light": {"r": 162, "g": 89, "b": 255},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 3 +", "outputs": ["whe 1 + 5"], "note": "Scroll down"},
          {"input": "axi 3 -", "outputs": ["whe 1 - 5"], "note": "Scroll up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Click"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Right click"},
          {"input": "btn 0", "outputs": ["key 25"], "note": "Move tool (V)"},
          {"input": "btn 1", "outputs": ["key 21"], "note": "Rectangle (R)"},
          {"input": "btn 2", "outputs": ["key 23"], "note": "Text (T)"},
          {"input": "btn 3", "outputs": ["key 18"], "note": "Ellipse (O)"},
          {"input": "btn 4", "outputs": ["key 227", "key 29"], "note": "Undo"},
          {"input": "btn 5", "outputs": ["key 227", "key 6"], "note": "Copy"},
          {"input": "hat 0 U", "outputs": ["key 227", "key 46"], "note": "Zoom in"},
          {"input": "hat 0 D", "outputs": ["key 227", "key 45"], "note": "Zoom out"}
        ],
        "tips": ["Face buttons are the Move, Rectangle, Text, and Ellipse tools.", "D-pad zooms in and out; right stick scrolls the canvas."]
      },
      {
        "id": "spotify", "category": "app", "displayName": "Spotify",
        "subtitle": "Play, skip, volume, browse",
        "appPath": "/Applications/Spotify.app", "launchURL": "",
        "light": {"r": 30, "g": 215, "b": 96},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "btn 0", "outputs": ["key 44"], "note": "Play / Pause (Space)"},
          {"input": "btn 1", "outputs": ["key 227", "key 79"], "note": "Next track"},
          {"input": "btn 2", "outputs": ["key 227", "key 80"], "note": "Previous track"},
          {"input": "btn 4", "outputs": ["key 227", "key 82"], "note": "Volume up"},
          {"input": "btn 5", "outputs": ["key 227", "key 81"], "note": "Volume down"},
          {"input": "hat 0 R", "outputs": ["key 227", "key 79"], "note": "Next track"},
          {"input": "hat 0 L", "outputs": ["key 227", "key 80"], "note": "Previous track"},
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 3 +", "outputs": ["whe 1 + 5"], "note": "Scroll down"},
          {"input": "axi 3 -", "outputs": ["whe 1 - 5"], "note": "Scroll up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Click"}
        ],
        "tips": ["A button plays and pauses; B and X skip tracks.", "Bumpers change the volume; left stick clicks through playlists."]
      },
      {
        "id": "vlc", "category": "app", "displayName": "VLC",
        "subtitle": "Play, seek, volume, fullscreen",
        "appPath": "/Applications/VLC.app", "launchURL": "",
        "light": {"r": 255, "g": 140, "b": 0},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "btn 0", "outputs": ["key 44"], "note": "Play / Pause (Space)"},
          {"input": "btn 1", "outputs": ["key 9"], "note": "Fullscreen (F)"},
          {"input": "axi 0 -", "outputs": ["key 80"], "note": "Seek back (Left)"},
          {"input": "axi 0 +", "outputs": ["key 79"], "note": "Seek forward (Right)"},
          {"input": "btn 4", "outputs": ["key 227", "key 82"], "note": "Volume up"},
          {"input": "btn 5", "outputs": ["key 227", "key 81"], "note": "Volume down"},
          {"input": "hat 0 L", "outputs": ["key 80"], "note": "Seek back"},
          {"input": "hat 0 R", "outputs": ["key 79"], "note": "Seek forward"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Click"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Exit fullscreen (Esc)"}
        ],
        "tips": ["A button plays and pauses; B toggles fullscreen.", "Left stick or D-pad seeks; bumpers change volume."]
      },
      {
        "id": "zoom-meetings", "category": "app", "displayName": "Zoom",
        "subtitle": "Mute, video, share, leave",
        "appPath": "/Applications/zoom.us.app", "launchURL": "",
        "light": {"r": 45, "g": 140, "b": 255},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "btn 0", "outputs": ["key 227", "key 226", "key 4"], "note": "Mute / unmute (Cmd+Shift+A)"},
          {"input": "btn 1", "outputs": ["key 227", "key 226", "key 25"], "note": "Start / stop video (Cmd+Shift+V)"},
          {"input": "btn 2", "outputs": ["key 227", "key 226", "key 22"], "note": "Share screen (Cmd+Shift+S)"},
          {"input": "btn 3", "outputs": ["key 227", "key 26"], "note": "Leave / end (Cmd+W)"},
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Click"}
        ],
        "tips": ["Face buttons mute, toggle video, share screen, and leave.", "Left stick moves the pointer for clicking on-screen controls."]
      },
      {
        "id": "obs-studio", "category": "app", "displayName": "OBS Studio",
        "subtitle": "Scene switch, record, stream (assign in OBS)",
        "appPath": "/Applications/OBS.app", "launchURL": "",
        "light": {"r": 80, "g": 90, "b": 110},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "btn 0", "outputs": ["key 30"], "note": "Scene 1 (set hotkey in OBS)"},
          {"input": "btn 1", "outputs": ["key 31"], "note": "Scene 2 (set hotkey in OBS)"},
          {"input": "btn 2", "outputs": ["key 32"], "note": "Scene 3 (set hotkey in OBS)"},
          {"input": "btn 3", "outputs": ["key 33"], "note": "Scene 4 (set hotkey in OBS)"},
          {"input": "hat 0 U", "outputs": ["key 34"], "note": "Scene 5 (set hotkey in OBS)"},
          {"input": "hat 0 D", "outputs": ["key 35"], "note": "Scene 6 (set hotkey in OBS)"},
          {"input": "btn 4", "outputs": ["key 36"], "note": "Start / stop recording (set in OBS)"},
          {"input": "btn 5", "outputs": ["key 37"], "note": "Start / stop streaming (set in OBS)"},
          {"input": "btn 8", "outputs": ["key 38"], "note": "Mute mic (set in OBS)"}
        ],
        "tips": ["OBS ships with no default hotkeys, so assign these keys in OBS Settings, Hotkeys.", "Face buttons switch scenes; bumpers start recording and streaming."]
      },
      {
        "id": "discord", "category": "app", "displayName": "Discord",
        "subtitle": "Mute, deafen, switch channels, navigate",
        "appPath": "/Applications/Discord.app", "launchURL": "",
        "light": {"r": 88, "g": 101, "b": 242},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "btn 0", "outputs": ["key 227", "key 226", "key 16"], "note": "Mute mic (Cmd+Shift+M)"},
          {"input": "btn 1", "outputs": ["key 227", "key 226", "key 7"], "note": "Deafen (Cmd+Shift+D)"},
          {"input": "hat 0 U", "outputs": ["key 226", "key 82"], "note": "Previous channel (Alt+Up)"},
          {"input": "hat 0 D", "outputs": ["key 226", "key 81"], "note": "Next channel (Alt+Down)"},
          {"input": "hat 0 L", "outputs": ["key 226", "key 227", "key 82"], "note": "Previous server"},
          {"input": "hat 0 R", "outputs": ["key 226", "key 227", "key 81"], "note": "Next server"},
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 3 +", "outputs": ["whe 1 + 5"], "note": "Scroll down"},
          {"input": "axi 3 -", "outputs": ["whe 1 - 5"], "note": "Scroll up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Click"}
        ],
        "tips": ["A button mutes your mic; B deafens.", "D-pad up and down change channels; left and right change servers."]
      },
      {
        "id": "accessibility-pointer", "category": "workflow", "displayName": "Accessibility Pointer",
        "subtitle": "Full pointer control: precise + fast cursor, clicks, scroll",
        "appPath": "", "launchURL": "",
        "light": {"r": 40, "g": 120, "b": 255},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["mou 0 - 10"], "note": "Cursor left (precise)"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 10"], "note": "Cursor right (precise)"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 10"], "note": "Cursor up (precise)"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 10"], "note": "Cursor down (precise)"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 26"], "note": "Cursor left (fast)"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 26"], "note": "Cursor right (fast)"},
          {"input": "axi 3 -", "outputs": ["mou 1 - 26"], "note": "Cursor up (fast)"},
          {"input": "axi 3 +", "outputs": ["mou 1 + 26"], "note": "Cursor down (fast)"},
          {"input": "btn 0", "outputs": ["mbt 0"], "note": "Left click"},
          {"input": "btn 1", "outputs": ["mbt 1"], "note": "Right click"},
          {"input": "btn 2", "outputs": ["mbt 2"], "note": "Middle click"},
          {"input": "btn 3", "outputs": ["key 40"], "note": "Return"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Left click (trigger)"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Right click (trigger)"},
          {"input": "hat 0 U", "outputs": ["whs 1 -"], "note": "Scroll up"},
          {"input": "hat 0 D", "outputs": ["whs 1 +"], "note": "Scroll down"},
          {"input": "hat 0 L", "outputs": ["whs 0 -"], "note": "Scroll left"},
          {"input": "hat 0 R", "outputs": ["whs 0 +"], "note": "Scroll right"},
          {"input": "btn 8", "outputs": ["key 227", "key 44"], "note": "Spotlight search"}
        ],
        "tips": ["Left stick is the precise pointer; right stick moves it quickly.", "Face buttons and triggers click; the D-pad scrolls in any direction."]
      },
      {
        "id": "window-management", "category": "workflow", "displayName": "Window Management",
        "subtitle": "Mission Control, Spaces, fullscreen, app switch",
        "appPath": "", "launchURL": "",
        "light": {"r": 40, "g": 170, "b": 160},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "btn 0", "outputs": ["key 224", "key 82"], "note": "Mission Control (Ctrl+Up)"},
          {"input": "btn 1", "outputs": ["key 224", "key 81"], "note": "App windows (Ctrl+Down)"},
          {"input": "btn 2", "outputs": ["key 227", "key 43"], "note": "Switch app (Cmd+Tab)"},
          {"input": "btn 3", "outputs": ["key 227", "key 11"], "note": "Hide app (Cmd+H)"},
          {"input": "hat 0 L", "outputs": ["key 224", "key 80"], "note": "Space left (Ctrl+Left)"},
          {"input": "hat 0 R", "outputs": ["key 224", "key 79"], "note": "Space right (Ctrl+Right)"},
          {"input": "btn 4", "outputs": ["key 227", "key 224", "key 9"], "note": "Toggle fullscreen"},
          {"input": "btn 5", "outputs": ["key 227", "key 16"], "note": "Minimize (Cmd+M)"},
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Click"}
        ],
        "tips": ["Face buttons open Mission Control, app windows, the app switcher, and hide.", "D-pad left and right move between Spaces."]
      },
      {
        "id": "media-scrubbing", "category": "workflow", "displayName": "Media Player Control",
        "subtitle": "Play, seek, volume, fullscreen for any player",
        "appPath": "", "launchURL": "",
        "light": {"r": 230, "g": 120, "b": 30},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "btn 0", "outputs": ["key 44"], "note": "Play / Pause (Space)"},
          {"input": "btn 1", "outputs": ["key 9"], "note": "Fullscreen (F)"},
          {"input": "btn 2", "outputs": ["key 16"], "note": "Mute (M)"},
          {"input": "axi 0 -", "outputs": ["key 80"], "note": "Seek back (Left)"},
          {"input": "axi 0 +", "outputs": ["key 79"], "note": "Seek forward (Right)"},
          {"input": "hat 0 L", "outputs": ["key 80"], "note": "Seek back"},
          {"input": "hat 0 R", "outputs": ["key 79"], "note": "Seek forward"},
          {"input": "hat 0 U", "outputs": ["key 82"], "note": "Volume up (Up)"},
          {"input": "hat 0 D", "outputs": ["key 81"], "note": "Volume down (Down)"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Click"}
        ],
        "tips": ["Works with most players that use the common Space, F, and arrow shortcuts.", "Left stick or D-pad seeks; D-pad up and down change volume."]
      },
      {
        "id": "ebook-reader", "category": "workflow", "displayName": "eBook Reader",
        "subtitle": "Turn pages, scroll, zoom for reading apps",
        "appPath": "", "launchURL": "",
        "light": {"r": 200, "g": 170, "b": 120},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 5 +", "outputs": ["key 79"], "note": "Next page (right trigger)"},
          {"input": "axi 4 +", "outputs": ["key 80"], "note": "Previous page (left trigger)"},
          {"input": "btn 0", "outputs": ["key 79"], "note": "Next page"},
          {"input": "btn 1", "outputs": ["key 80"], "note": "Previous page"},
          {"input": "btn 5", "outputs": ["key 79"], "note": "Next page (bumper)"},
          {"input": "btn 4", "outputs": ["key 80"], "note": "Previous page (bumper)"},
          {"input": "hat 0 R", "outputs": ["key 79"], "note": "Next page"},
          {"input": "hat 0 L", "outputs": ["key 80"], "note": "Previous page"},
          {"input": "axi 3 +", "outputs": ["whe 1 + 4"], "note": "Scroll down"},
          {"input": "axi 3 -", "outputs": ["whe 1 - 4"], "note": "Scroll up"},
          {"input": "btn 2", "outputs": ["key 227", "key 46"], "note": "Zoom in"},
          {"input": "btn 3", "outputs": ["key 227", "key 45"], "note": "Zoom out"}
        ],
        "tips": ["Triggers, bumpers, face buttons, or D-pad all turn pages.", "Right stick scrolls within a page; X and Y zoom."]
      },
      {
        "id": "coding-navigation", "category": "workflow", "displayName": "Code Editor Navigation",
        "subtitle": "Save, find, undo, switch tabs, scroll (any editor)",
        "appPath": "", "launchURL": "",
        "light": {"r": 0, "g": 122, "b": 204},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 3 +", "outputs": ["whe 1 + 5"], "note": "Scroll down"},
          {"input": "axi 3 -", "outputs": ["whe 1 - 5"], "note": "Scroll up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Click"},
          {"input": "btn 0", "outputs": ["key 227", "key 22"], "note": "Save"},
          {"input": "btn 1", "outputs": ["key 227", "key 9"], "note": "Find"},
          {"input": "btn 2", "outputs": ["key 227", "key 29"], "note": "Undo"},
          {"input": "btn 3", "outputs": ["key 227", "key 226", "key 29"], "note": "Redo"},
          {"input": "hat 0 L", "outputs": ["key 227", "key 226", "key 80"], "note": "Previous tab"},
          {"input": "hat 0 R", "outputs": ["key 227", "key 226", "key 79"], "note": "Next tab"},
          {"input": "hat 0 U", "outputs": ["key 82"], "note": "Line up"},
          {"input": "hat 0 D", "outputs": ["key 81"], "note": "Line down"}
        ],
        "tips": ["Editor-agnostic: uses the common Cmd shortcuts most editors share.", "Face buttons Save, Find, Undo, Redo; D-pad switches tabs."]
      },
      {
        "id": "file-management", "category": "workflow", "displayName": "Finder / Files",
        "subtitle": "Navigate folders, open, copy, paste, trash",
        "appPath": "", "launchURL": "",
        "light": {"r": 70, "g": 130, "b": 200},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Click"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Right click"},
          {"input": "hat 0 U", "outputs": ["key 82"], "note": "Select up"},
          {"input": "hat 0 D", "outputs": ["key 81"], "note": "Select down"},
          {"input": "hat 0 L", "outputs": ["key 80"], "note": "Select left"},
          {"input": "hat 0 R", "outputs": ["key 79"], "note": "Select right"},
          {"input": "btn 0", "outputs": ["key 227", "key 81"], "note": "Open (Cmd+Down)"},
          {"input": "btn 1", "outputs": ["key 227", "key 82"], "note": "Up a folder (Cmd+Up)"},
          {"input": "btn 2", "outputs": ["key 227", "key 6"], "note": "Copy"},
          {"input": "btn 3", "outputs": ["key 227", "key 25"], "note": "Paste"},
          {"input": "btn 4", "outputs": ["key 227", "key 42"], "note": "Move to Trash"},
          {"input": "btn 5", "outputs": ["key 40"], "note": "Rename / open (Return)"}
        ],
        "tips": ["D-pad moves the selection; A opens, B goes up a folder.", "Bumper sends the selected item to the Trash."]
      },
      {
        "id": "photo-review", "category": "workflow", "displayName": "Photo Review",
        "subtitle": "Flip through photos, zoom, delete (Photos / Preview)",
        "appPath": "", "launchURL": "",
        "light": {"r": 150, "g": 90, "b": 200},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 80"], "note": "Previous photo (Left)"},
          {"input": "axi 0 +", "outputs": ["key 79"], "note": "Next photo (Right)"},
          {"input": "btn 0", "outputs": ["key 79"], "note": "Next photo"},
          {"input": "btn 1", "outputs": ["key 80"], "note": "Previous photo"},
          {"input": "hat 0 R", "outputs": ["key 79"], "note": "Next photo"},
          {"input": "hat 0 L", "outputs": ["key 80"], "note": "Previous photo"},
          {"input": "btn 2", "outputs": ["key 227", "key 46"], "note": "Zoom in"},
          {"input": "btn 3", "outputs": ["key 227", "key 45"], "note": "Zoom out"},
          {"input": "btn 4", "outputs": ["key 227", "key 42"], "note": "Delete (Cmd+Delete)"},
          {"input": "btn 5", "outputs": ["key 227", "key 39"], "note": "Actual size (Cmd+0)"}
        ],
        "tips": ["Left stick, face buttons, or D-pad flip between photos.", "X and Y zoom; the left bumper deletes the current photo."]
      },
      {
        "id": "reading-scroll", "category": "workflow", "displayName": "Reading & Scroll",
        "subtitle": "Smooth scroll and zoom for long pages and dashboards",
        "appPath": "", "launchURL": "",
        "light": {"r": 120, "g": 160, "b": 200},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 1 +", "outputs": ["whe 1 + 5"], "note": "Scroll down"},
          {"input": "axi 1 -", "outputs": ["whe 1 - 5"], "note": "Scroll up"},
          {"input": "axi 3 +", "outputs": ["whe 1 + 9"], "note": "Scroll down (fast)"},
          {"input": "axi 3 -", "outputs": ["whe 1 - 9"], "note": "Scroll up (fast)"},
          {"input": "axi 0 +", "outputs": ["whe 0 + 5"], "note": "Scroll right"},
          {"input": "axi 0 -", "outputs": ["whe 0 - 5"], "note": "Scroll left"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Click"},
          {"input": "btn 0", "outputs": ["key 227", "key 46"], "note": "Zoom in"},
          {"input": "btn 1", "outputs": ["key 227", "key 45"], "note": "Zoom out"},
          {"input": "btn 2", "outputs": ["key 227", "key 39"], "note": "Reset zoom (Cmd+0)"},
          {"input": "hat 0 U", "outputs": ["key 227", "key 82"], "note": "Top of page (Cmd+Up)"},
          {"input": "hat 0 D", "outputs": ["key 227", "key 81"], "note": "Bottom of page (Cmd+Down)"}
        ],
        "tips": ["Left stick scrolls smoothly; right stick scrolls quickly.", "Face buttons zoom in, out, and reset; D-pad jumps to top or bottom."]
      },
      {
        "id": "rust", "category": "game", "displayName": "Rust",
        "subtitle": "Survival FPS: move, aim, build, hotbar, inventory",
        "appPath": "/Applications/Steam.app", "launchURL": "",
        "light": {"r": 180, "g": 80, "b": 40},
        "confineCursor": true, "autoRecenter": true, "hideCursor": true,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Strafe left (A)"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Strafe right (D)"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Move forward (W)"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Move back (S)"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 20"], "note": "Look right"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 20"], "note": "Look left"},
          {"input": "axi 3 +", "outputs": ["mou 1 + 14"], "note": "Look down"},
          {"input": "axi 3 -", "outputs": ["mou 1 - 14"], "note": "Look up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Fire / use"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Aim / alt"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Jump"},
          {"input": "btn 1", "outputs": ["key 224"], "note": "Duck (Ctrl)"},
          {"input": "btn 2", "outputs": ["key 21"], "note": "Reload"},
          {"input": "btn 3", "outputs": ["key 8"], "note": "Use (E)"},
          {"input": "btn 4", "outputs": ["key 21"], "note": "Reload"},
          {"input": "btn 5", "outputs": ["key 9"], "note": "Flashlight (F)"},
          {"input": "btn 11", "outputs": ["key 225"], "note": "Sprint (Shift)"},
          {"input": "hat 0 U", "outputs": ["key 30"], "note": "Hotbar 1"},
          {"input": "hat 0 L", "outputs": ["key 31"], "note": "Hotbar 2"},
          {"input": "hat 0 R", "outputs": ["key 32"], "note": "Hotbar 3"},
          {"input": "hat 0 D", "outputs": ["key 33"], "note": "Hotbar 4"},
          {"input": "btn 8", "outputs": ["key 43"], "note": "Inventory (Tab)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Hold left-stick click to sprint; triggers fire and aim.", "D-pad selects hotbar slots; Tab opens your inventory."]
      },
      {
        "id": "sea-of-thieves", "category": "game", "displayName": "Sea of Thieves",
        "subtitle": "Pirate FPS: move, aim, interact, equipment wheel",
        "appPath": "", "launchURL": "",
        "light": {"r": 40, "g": 160, "b": 170},
        "confineCursor": true, "autoRecenter": true, "hideCursor": true,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Strafe left (A)"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Strafe right (D)"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Move forward (W)"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Move back (S)"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 20"], "note": "Look right"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 20"], "note": "Look left"},
          {"input": "axi 3 +", "outputs": ["mou 1 + 14"], "note": "Look down"},
          {"input": "axi 3 -", "outputs": ["mou 1 - 14"], "note": "Look up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Use / fire"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Aim"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Jump"},
          {"input": "btn 1", "outputs": ["key 224"], "note": "Crouch (Ctrl)"},
          {"input": "btn 2", "outputs": ["key 21"], "note": "Reload"},
          {"input": "btn 3", "outputs": ["key 9"], "note": "Interact (F)"},
          {"input": "btn 11", "outputs": ["key 225"], "note": "Sprint (Shift)"},
          {"input": "hat 0 U", "outputs": ["key 30"], "note": "Equipment 1"},
          {"input": "hat 0 L", "outputs": ["key 31"], "note": "Equipment 2"},
          {"input": "hat 0 R", "outputs": ["key 32"], "note": "Equipment 3"},
          {"input": "hat 0 D", "outputs": ["key 33"], "note": "Equipment 4"},
          {"input": "btn 10", "outputs": ["key 16"], "note": "Map (M)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Triggers use and aim your held item; D-pad swaps equipment.", "Hold left-stick click to sprint across the deck."]
      },
      {
        "id": "destiny-2", "category": "game", "displayName": "Destiny 2",
        "subtitle": "Looter FPS: move, aim, abilities, super",
        "appPath": "/Applications/Steam.app", "launchURL": "",
        "light": {"r": 120, "g": 130, "b": 240},
        "confineCursor": true, "autoRecenter": true, "hideCursor": true,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Strafe left (A)"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Strafe right (D)"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Move forward (W)"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Move back (S)"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 20"], "note": "Look right"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 20"], "note": "Look left"},
          {"input": "axi 3 +", "outputs": ["mou 1 + 14"], "note": "Look down"},
          {"input": "axi 3 -", "outputs": ["mou 1 - 14"], "note": "Look up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Fire"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Aim down sights"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Jump"},
          {"input": "btn 1", "outputs": ["key 224"], "note": "Crouch (Ctrl)"},
          {"input": "btn 2", "outputs": ["key 21"], "note": "Reload"},
          {"input": "btn 3", "outputs": ["key 9"], "note": "Interact (F)"},
          {"input": "btn 4", "outputs": ["key 20"], "note": "Grenade (Q)"},
          {"input": "btn 5", "outputs": ["key 8"], "note": "Melee (E)"},
          {"input": "btn 11", "outputs": ["key 225"], "note": "Sprint (Shift)"},
          {"input": "hat 0 U", "outputs": ["key 30"], "note": "Kinetic weapon (1)"},
          {"input": "hat 0 L", "outputs": ["key 31"], "note": "Energy weapon (2)"},
          {"input": "hat 0 R", "outputs": ["key 32"], "note": "Power weapon (3)"},
          {"input": "hat 0 D", "outputs": ["key 5"], "note": "Super / class (B)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Bumpers throw a grenade and melee; D-pad down casts your Super.", "Triggers fire and aim; hold left-stick click to sprint."]
      },
      {
        "id": "warframe", "category": "game", "displayName": "Warframe",
        "subtitle": "Ninja FPS: move, aim, abilities, sprint",
        "appPath": "/Applications/Steam.app", "launchURL": "",
        "light": {"r": 60, "g": 180, "b": 200},
        "confineCursor": true, "autoRecenter": true, "hideCursor": true,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Strafe left (A)"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Strafe right (D)"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Move forward (W)"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Move back (S)"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 20"], "note": "Look right"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 20"], "note": "Look left"},
          {"input": "axi 3 +", "outputs": ["mou 1 + 14"], "note": "Look down"},
          {"input": "axi 3 -", "outputs": ["mou 1 - 14"], "note": "Look up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Fire"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Aim"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Jump / bullet jump"},
          {"input": "btn 1", "outputs": ["key 224"], "note": "Crouch / slide (Ctrl)"},
          {"input": "btn 2", "outputs": ["key 21"], "note": "Reload"},
          {"input": "btn 3", "outputs": ["key 9"], "note": "Use / interact (F)"},
          {"input": "btn 4", "outputs": ["key 8"], "note": "Melee (E)"},
          {"input": "btn 5", "outputs": ["key 25"], "note": "Roll (V)"},
          {"input": "btn 11", "outputs": ["key 225"], "note": "Sprint (Shift)"},
          {"input": "hat 0 U", "outputs": ["key 30"], "note": "Ability 1"},
          {"input": "hat 0 L", "outputs": ["key 31"], "note": "Ability 2"},
          {"input": "hat 0 R", "outputs": ["key 32"], "note": "Ability 3"},
          {"input": "hat 0 D", "outputs": ["key 33"], "note": "Ability 4"},
          {"input": "btn 8", "outputs": ["key 43"], "note": "Gear wheel (Tab)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["D-pad casts your four Warframe abilities; bumpers melee and roll.", "Crouch while sprinting to slide; A bullet-jumps."]
      },
      {
        "id": "fallout-4", "category": "game", "displayName": "Fallout 4",
        "subtitle": "RPG FPS: move, aim, VATS, Pip-Boy",
        "appPath": "/Applications/Steam.app", "launchURL": "",
        "light": {"r": 120, "g": 200, "b": 90},
        "confineCursor": true, "autoRecenter": true, "hideCursor": true,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Strafe left (A)"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Strafe right (D)"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Move forward (W)"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Move back (S)"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 20"], "note": "Look right"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 20"], "note": "Look left"},
          {"input": "axi 3 +", "outputs": ["mou 1 + 14"], "note": "Look down"},
          {"input": "axi 3 -", "outputs": ["mou 1 - 14"], "note": "Look up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Attack / fire"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Aim"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Jump"},
          {"input": "btn 1", "outputs": ["key 224"], "note": "Sneak (Ctrl)"},
          {"input": "btn 2", "outputs": ["key 21"], "note": "Reload"},
          {"input": "btn 3", "outputs": ["key 8"], "note": "Activate (E)"},
          {"input": "btn 4", "outputs": ["key 25"], "note": "VATS (V)"},
          {"input": "btn 5", "outputs": ["key 21"], "note": "Reload / holster (R)"},
          {"input": "btn 11", "outputs": ["key 225"], "note": "Sprint (Shift)"},
          {"input": "hat 0 U", "outputs": ["key 30"], "note": "Favorite 1"},
          {"input": "hat 0 L", "outputs": ["key 31"], "note": "Favorite 2"},
          {"input": "hat 0 R", "outputs": ["key 32"], "note": "Favorite 3"},
          {"input": "hat 0 D", "outputs": ["key 23"], "note": "Pip-Boy (Tab)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Left bumper triggers VATS; D-pad down opens the Pip-Boy.", "Triggers attack and aim; hold left-stick click to sprint."]
      },
      {
        "id": "starfield", "category": "game", "displayName": "Starfield",
        "subtitle": "Space RPG: move, aim, boost, scan, menus",
        "appPath": "/Applications/Steam.app", "launchURL": "",
        "light": {"r": 90, "g": 110, "b": 220},
        "confineCursor": true, "autoRecenter": true, "hideCursor": true,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Strafe left (A)"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Strafe right (D)"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Move forward (W)"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Move back (S)"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 20"], "note": "Look right"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 20"], "note": "Look left"},
          {"input": "axi 3 +", "outputs": ["mou 1 + 14"], "note": "Look down"},
          {"input": "axi 3 -", "outputs": ["mou 1 - 14"], "note": "Look up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Fire"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Aim"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Jump / jetpack"},
          {"input": "btn 1", "outputs": ["key 224"], "note": "Crouch (Ctrl)"},
          {"input": "btn 2", "outputs": ["key 21"], "note": "Reload"},
          {"input": "btn 3", "outputs": ["key 8"], "note": "Activate (E)"},
          {"input": "btn 4", "outputs": ["key 21"], "note": "Scanner (F)"},
          {"input": "btn 5", "outputs": ["key 21"], "note": "Reload"},
          {"input": "btn 11", "outputs": ["key 225"], "note": "Sprint (Shift)"},
          {"input": "hat 0 U", "outputs": ["key 12"], "note": "Inventory (I)"},
          {"input": "hat 0 D", "outputs": ["key 14"], "note": "Skills (K)"},
          {"input": "hat 0 L", "outputs": ["key 13"], "note": "Quests (J)"},
          {"input": "hat 0 R", "outputs": ["key 16"], "note": "Map (M)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["A button doubles as the jetpack; D-pad opens your menus.", "Triggers fire and aim; hold left-stick click to sprint."]
      },
      {
        "id": "far-cry-6", "category": "game", "displayName": "Far Cry 6",
        "subtitle": "Open-world FPS: move, aim, gadgets, weapons",
        "appPath": "", "launchURL": "",
        "light": {"r": 230, "g": 150, "b": 40},
        "confineCursor": true, "autoRecenter": true, "hideCursor": true,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Strafe left (A)"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Strafe right (D)"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Move forward (W)"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Move back (S)"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 20"], "note": "Look right"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 20"], "note": "Look left"},
          {"input": "axi 3 +", "outputs": ["mou 1 + 14"], "note": "Look down"},
          {"input": "axi 3 -", "outputs": ["mou 1 - 14"], "note": "Look up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Fire"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Aim down sights"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Jump"},
          {"input": "btn 1", "outputs": ["key 224"], "note": "Crouch (Ctrl)"},
          {"input": "btn 2", "outputs": ["key 21"], "note": "Reload"},
          {"input": "btn 3", "outputs": ["key 8"], "note": "Interact (E)"},
          {"input": "btn 4", "outputs": ["key 10"], "note": "Throwable (G)"},
          {"input": "btn 5", "outputs": ["key 21"], "note": "Supremo / gadget"},
          {"input": "btn 11", "outputs": ["key 225"], "note": "Sprint (Shift)"},
          {"input": "hat 0 U", "outputs": ["key 30"], "note": "Weapon 1"},
          {"input": "hat 0 L", "outputs": ["key 31"], "note": "Weapon 2"},
          {"input": "hat 0 R", "outputs": ["key 32"], "note": "Weapon 3"},
          {"input": "hat 0 D", "outputs": ["key 16"], "note": "Map (M)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Left bumper throws a grenade; D-pad swaps weapons and opens the map.", "Triggers fire and aim; hold left-stick click to sprint."]
      },
      {
        "id": "borderlands-3", "category": "game", "displayName": "Borderlands 3",
        "subtitle": "Looter shooter: move, aim, action skill, grenade",
        "appPath": "/Applications/Steam.app", "launchURL": "",
        "light": {"r": 230, "g": 130, "b": 30},
        "confineCursor": true, "autoRecenter": true, "hideCursor": true,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Strafe left (A)"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Strafe right (D)"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Move forward (W)"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Move back (S)"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 20"], "note": "Look right"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 20"], "note": "Look left"},
          {"input": "axi 3 +", "outputs": ["mou 1 + 14"], "note": "Look down"},
          {"input": "axi 3 -", "outputs": ["mou 1 - 14"], "note": "Look up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Fire"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Aim down sights"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Jump"},
          {"input": "btn 1", "outputs": ["key 224"], "note": "Crouch (Ctrl)"},
          {"input": "btn 2", "outputs": ["key 21"], "note": "Reload"},
          {"input": "btn 3", "outputs": ["key 8"], "note": "Use (E)"},
          {"input": "btn 4", "outputs": ["key 9"], "note": "Action skill (F)"},
          {"input": "btn 5", "outputs": ["key 10"], "note": "Grenade (G)"},
          {"input": "btn 11", "outputs": ["key 225"], "note": "Sprint (Shift)"},
          {"input": "hat 0 U", "outputs": ["key 30"], "note": "Weapon 1"},
          {"input": "hat 0 L", "outputs": ["key 31"], "note": "Weapon 2"},
          {"input": "hat 0 R", "outputs": ["key 32"], "note": "Weapon 3"},
          {"input": "hat 0 D", "outputs": ["key 33"], "note": "Weapon 4"},
          {"input": "btn 8", "outputs": ["key 12"], "note": "Inventory (I)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Bumpers fire your action skill and a grenade; D-pad swaps all four guns.", "Triggers fire and aim; hold left-stick click to sprint."]
      },
      {
        "id": "half-life-2", "category": "game", "displayName": "Half-Life 2",
        "subtitle": "Classic FPS: move, aim, gravity gun, weapons",
        "appPath": "/Applications/Steam.app", "launchURL": "steam://rungameid/220",
        "light": {"r": 235, "g": 150, "b": 30},
        "confineCursor": true, "autoRecenter": true, "hideCursor": true,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Strafe left (A)"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Strafe right (D)"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Move forward (W)"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Move back (S)"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 20"], "note": "Look right"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 20"], "note": "Look left"},
          {"input": "axi 3 +", "outputs": ["mou 1 + 14"], "note": "Look down"},
          {"input": "axi 3 -", "outputs": ["mou 1 - 14"], "note": "Look up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Fire"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Secondary fire"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Jump"},
          {"input": "btn 1", "outputs": ["key 224"], "note": "Crouch (Ctrl)"},
          {"input": "btn 2", "outputs": ["key 21"], "note": "Reload"},
          {"input": "btn 3", "outputs": ["key 8"], "note": "Use (E)"},
          {"input": "btn 11", "outputs": ["key 225"], "note": "Sprint (Shift)"},
          {"input": "hat 0 U", "outputs": ["key 30"], "note": "Weapon group 1"},
          {"input": "hat 0 L", "outputs": ["key 31"], "note": "Weapon group 2"},
          {"input": "hat 0 R", "outputs": ["key 32"], "note": "Weapon group 3"},
          {"input": "hat 0 D", "outputs": ["key 9"], "note": "Flashlight (F)"},
          {"input": "btn 8", "outputs": ["whs 1 -"], "note": "Previous weapon"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Triggers are primary and secondary fire (great for the gravity gun).", "D-pad picks weapon groups and toggles the flashlight."]
      },
      {
        "id": "portal-2", "category": "game", "displayName": "Portal 2",
        "subtitle": "Puzzle FPS: move, place portals, jump, use",
        "appPath": "/Applications/Steam.app", "launchURL": "steam://rungameid/620",
        "light": {"r": 60, "g": 150, "b": 230},
        "confineCursor": true, "autoRecenter": true, "hideCursor": true,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Strafe left (A)"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Strafe right (D)"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Move forward (W)"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Move back (S)"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 20"], "note": "Look right"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 20"], "note": "Look left"},
          {"input": "axi 3 +", "outputs": ["mou 1 + 14"], "note": "Look down"},
          {"input": "axi 3 -", "outputs": ["mou 1 - 14"], "note": "Look up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Blue portal"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Orange portal"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Jump"},
          {"input": "btn 1", "outputs": ["key 224"], "note": "Crouch (Ctrl)"},
          {"input": "btn 3", "outputs": ["key 8"], "note": "Use / pick up (E)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Right trigger fires the blue portal, left trigger the orange one.", "A jumps, B crouches, Y picks up cubes."]
      },
      {
        "id": "team-fortress-2", "category": "game", "displayName": "Team Fortress 2",
        "subtitle": "Class FPS: move, aim, weapons, taunt",
        "appPath": "/Applications/Steam.app", "launchURL": "steam://rungameid/440",
        "light": {"r": 190, "g": 70, "b": 50},
        "confineCursor": true, "autoRecenter": true, "hideCursor": true,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Strafe left (A)"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Strafe right (D)"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Move forward (W)"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Move back (S)"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 20"], "note": "Look right"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 20"], "note": "Look left"},
          {"input": "axi 3 +", "outputs": ["mou 1 + 14"], "note": "Look down"},
          {"input": "axi 3 -", "outputs": ["mou 1 - 14"], "note": "Look up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Fire"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Alt fire / zoom"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Jump"},
          {"input": "btn 1", "outputs": ["key 224"], "note": "Crouch (Ctrl)"},
          {"input": "btn 2", "outputs": ["key 21"], "note": "Reload"},
          {"input": "btn 3", "outputs": ["key 9"], "note": "Call medic (E)"},
          {"input": "btn 4", "outputs": ["key 10"], "note": "Taunt (G)"},
          {"input": "hat 0 U", "outputs": ["key 30"], "note": "Primary (1)"},
          {"input": "hat 0 L", "outputs": ["key 31"], "note": "Secondary (2)"},
          {"input": "hat 0 R", "outputs": ["key 32"], "note": "Melee (3)"},
          {"input": "btn 8", "outputs": ["key 43"], "note": "Scoreboard (Tab)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["D-pad swaps primary, secondary, and melee; Y calls for a Medic.", "Triggers fire and alt-fire or zoom."]
      },
      {
        "id": "left-4-dead-2", "category": "game", "displayName": "Left 4 Dead 2",
        "subtitle": "Co-op FPS: move, aim, heal, melee, items",
        "appPath": "/Applications/Steam.app", "launchURL": "",
        "light": {"r": 150, "g": 30, "b": 30},
        "confineCursor": true, "autoRecenter": true, "hideCursor": true,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Strafe left (A)"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Strafe right (D)"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Move forward (W)"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Move back (S)"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 20"], "note": "Look right"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 20"], "note": "Look left"},
          {"input": "axi 3 +", "outputs": ["mou 1 + 14"], "note": "Look down"},
          {"input": "axi 3 -", "outputs": ["mou 1 - 14"], "note": "Look up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Fire"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Shove / melee"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Jump"},
          {"input": "btn 1", "outputs": ["key 224"], "note": "Crouch (Ctrl)"},
          {"input": "btn 2", "outputs": ["key 21"], "note": "Reload"},
          {"input": "btn 3", "outputs": ["key 8"], "note": "Use (E)"},
          {"input": "btn 11", "outputs": ["key 225"], "note": "Run (Shift)"},
          {"input": "hat 0 U", "outputs": ["key 30"], "note": "Primary (1)"},
          {"input": "hat 0 L", "outputs": ["key 31"], "note": "Pistol (2)"},
          {"input": "hat 0 R", "outputs": ["key 34"], "note": "Health kit (5)"},
          {"input": "hat 0 D", "outputs": ["key 33"], "note": "Grenade (4)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Left trigger shoves zombies back; D-pad picks weapons, grenades, and health.", "Right trigger fires; A jumps over obstacles."]
      },
      {
        "id": "deep-rock-galactic", "category": "game", "displayName": "Deep Rock Galactic",
        "subtitle": "Co-op mining FPS: move, mine, tools, gadgets",
        "appPath": "/Applications/Steam.app", "launchURL": "",
        "light": {"r": 240, "g": 190, "b": 40},
        "confineCursor": true, "autoRecenter": true, "hideCursor": true,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Strafe left (A)"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Strafe right (D)"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Move forward (W)"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Move back (S)"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 20"], "note": "Look right"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 20"], "note": "Look left"},
          {"input": "axi 3 +", "outputs": ["mou 1 + 14"], "note": "Look down"},
          {"input": "axi 3 -", "outputs": ["mou 1 - 14"], "note": "Look up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Fire / mine"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Aim / alt"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Jump"},
          {"input": "btn 1", "outputs": ["key 224"], "note": "Crouch (Ctrl)"},
          {"input": "btn 2", "outputs": ["key 21"], "note": "Reload"},
          {"input": "btn 3", "outputs": ["key 8"], "note": "Use (E)"},
          {"input": "btn 4", "outputs": ["key 6"], "note": "Throw flare (C)"},
          {"input": "btn 5", "outputs": ["key 25"], "note": "Power attack (V)"},
          {"input": "btn 11", "outputs": ["key 225"], "note": "Sprint (Shift)"},
          {"input": "hat 0 U", "outputs": ["key 30"], "note": "Primary weapon (1)"},
          {"input": "hat 0 L", "outputs": ["key 31"], "note": "Secondary weapon (2)"},
          {"input": "hat 0 R", "outputs": ["key 32"], "note": "Traversal tool (3)"},
          {"input": "hat 0 D", "outputs": ["key 33"], "note": "Support tool (4)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Left bumper throws a flare to light the cave; D-pad swaps tools.", "Rock and Stone! Triggers mine and aim."]
      },
      {
        "id": "risk-of-rain-2", "category": "game", "displayName": "Risk of Rain 2",
        "subtitle": "Roguelite shooter: move, aim, four skills, sprint",
        "appPath": "/Applications/Steam.app", "launchURL": "",
        "light": {"r": 90, "g": 130, "b": 230},
        "confineCursor": true, "autoRecenter": true, "hideCursor": true,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Strafe left (A)"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Strafe right (D)"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Move forward (W)"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Move back (S)"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 20"], "note": "Look right"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 20"], "note": "Look left"},
          {"input": "axi 3 +", "outputs": ["mou 1 + 14"], "note": "Look down"},
          {"input": "axi 3 -", "outputs": ["mou 1 - 14"], "note": "Look up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Primary skill"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Secondary skill"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Jump"},
          {"input": "btn 1", "outputs": ["key 225"], "note": "Sprint (Shift)"},
          {"input": "btn 2", "outputs": ["key 20"], "note": "Equipment (Q)"},
          {"input": "btn 3", "outputs": ["key 8"], "note": "Interact (E)"},
          {"input": "btn 4", "outputs": ["key 25"], "note": "Utility skill (Shift / V)"},
          {"input": "btn 5", "outputs": ["key 21"], "note": "Special skill (R)"},
          {"input": "btn 8", "outputs": ["key 43"], "note": "Info / scoreboard (Tab)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Triggers and bumpers cover all four skills; B sprints.", "Y interacts with chests and the teleporter."]
      },
      {
        "id": "civilization-vi", "category": "game", "displayName": "Civilization VI",
        "subtitle": "4X strategy: cursor, pan, select, next turn",
        "appPath": "/Applications/Steam.app", "launchURL": "",
        "light": {"r": 50, "g": 110, "b": 200},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 2 -", "outputs": ["key 80"], "note": "Pan camera left"},
          {"input": "axi 2 +", "outputs": ["key 79"], "note": "Pan camera right"},
          {"input": "axi 3 -", "outputs": ["key 82"], "note": "Pan camera up"},
          {"input": "axi 3 +", "outputs": ["key 81"], "note": "Pan camera down"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Select (left click)"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Move / context (right click)"},
          {"input": "btn 0", "outputs": ["key 40"], "note": "Next turn / confirm (Enter)"},
          {"input": "btn 1", "outputs": ["key 41"], "note": "Cancel (Esc)"},
          {"input": "btn 4", "outputs": ["whs 1 -"], "note": "Zoom out"},
          {"input": "btn 5", "outputs": ["whs 1 +"], "note": "Zoom in"},
          {"input": "btn 2", "outputs": ["key 23"], "note": "Tech tree (T)"},
          {"input": "btn 10", "outputs": ["key 5"], "note": "Found / build (B)"}
        ],
        "tips": ["Left stick is the pointer; right stick pans the map.", "A ends the turn; bumpers zoom in and out."]
      },
      {
        "id": "cities-skylines", "category": "game", "displayName": "Cities: Skylines",
        "subtitle": "City builder: cursor, pan, zoom, speed",
        "appPath": "/Applications/Steam.app", "launchURL": "",
        "light": {"r": 60, "g": 170, "b": 120},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 2 -", "outputs": ["key 4"], "note": "Pan left (A)"},
          {"input": "axi 2 +", "outputs": ["key 7"], "note": "Pan right (D)"},
          {"input": "axi 3 -", "outputs": ["key 26"], "note": "Pan up (W)"},
          {"input": "axi 3 +", "outputs": ["key 22"], "note": "Pan down (S)"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Place / select (left click)"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Cancel / rotate (right click)"},
          {"input": "btn 4", "outputs": ["whs 1 -"], "note": "Zoom out"},
          {"input": "btn 5", "outputs": ["whs 1 +"], "note": "Zoom in"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Pause (Space)"},
          {"input": "btn 1", "outputs": ["key 30"], "note": "Speed 1"},
          {"input": "btn 2", "outputs": ["key 31"], "note": "Speed 2"},
          {"input": "btn 3", "outputs": ["key 32"], "note": "Speed 3"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Left stick is the pointer; right stick pans the city.", "A pauses; B, X, Y set simulation speed."]
      },
      {
        "id": "rimworld", "category": "game", "displayName": "RimWorld",
        "subtitle": "Colony sim: cursor, pause, speed, commands",
        "appPath": "/Applications/Steam.app", "launchURL": "",
        "light": {"r": 200, "g": 150, "b": 90},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 2 -", "outputs": ["key 4"], "note": "Pan left (A)"},
          {"input": "axi 2 +", "outputs": ["key 7"], "note": "Pan right (D)"},
          {"input": "axi 3 -", "outputs": ["key 26"], "note": "Pan up (W)"},
          {"input": "axi 3 +", "outputs": ["key 22"], "note": "Pan down (S)"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Select (left click)"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Command (right click)"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Pause (Space)"},
          {"input": "btn 1", "outputs": ["key 30"], "note": "Normal speed (1)"},
          {"input": "btn 2", "outputs": ["key 31"], "note": "Fast (2)"},
          {"input": "btn 3", "outputs": ["key 32"], "note": "Superfast (3)"},
          {"input": "btn 4", "outputs": ["whs 1 -"], "note": "Zoom out"},
          {"input": "btn 5", "outputs": ["whs 1 +"], "note": "Zoom in"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Left stick is the pointer; right stick scrolls the colony.", "A pauses; B, X, Y are the speed settings."]
      },
      {
        "id": "satisfactory", "category": "game", "displayName": "Satisfactory",
        "subtitle": "First-person factory: move, build, interact",
        "appPath": "/Applications/Steam.app", "launchURL": "",
        "light": {"r": 240, "g": 130, "b": 50},
        "confineCursor": true, "autoRecenter": true, "hideCursor": true,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Strafe left (A)"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Strafe right (D)"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Move forward (W)"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Move back (S)"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 18"], "note": "Look right"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 18"], "note": "Look left"},
          {"input": "axi 3 +", "outputs": ["mou 1 + 12"], "note": "Look down"},
          {"input": "axi 3 -", "outputs": ["mou 1 - 12"], "note": "Look up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Primary (build / fire)"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Secondary (dismantle)"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Jump"},
          {"input": "btn 1", "outputs": ["key 224"], "note": "Crouch (Ctrl)"},
          {"input": "btn 2", "outputs": ["key 21"], "note": "Rotate / reload (R)"},
          {"input": "btn 3", "outputs": ["key 8"], "note": "Interact (E)"},
          {"input": "btn 4", "outputs": ["key 20"], "note": "Build menu (Q)"},
          {"input": "btn 11", "outputs": ["key 225"], "note": "Sprint (Shift)"},
          {"input": "hat 0 U", "outputs": ["key 30"], "note": "Hotbar 1"},
          {"input": "hat 0 L", "outputs": ["key 31"], "note": "Hotbar 2"},
          {"input": "hat 0 R", "outputs": ["key 32"], "note": "Hotbar 3"},
          {"input": "btn 8", "outputs": ["key 23"], "note": "Inventory (Tab)"},
          {"input": "btn 10", "outputs": ["key 16"], "note": "Map (M)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Left bumper opens the build menu; R rotates the held part.", "Triggers build and dismantle; hold left-stick click to sprint."]
      },
      {
        "id": "no-mans-sky", "category": "game", "displayName": "No Man's Sky",
        "subtitle": "Space survival: move, aim, scan, tech, menus",
        "appPath": "/Applications/Steam.app", "launchURL": "",
        "light": {"r": 80, "g": 90, "b": 220},
        "confineCursor": true, "autoRecenter": true, "hideCursor": true,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Strafe left (A)"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Strafe right (D)"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Move forward (W)"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Move back (S)"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 18"], "note": "Look right"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 18"], "note": "Look left"},
          {"input": "axi 3 +", "outputs": ["mou 1 + 12"], "note": "Look down"},
          {"input": "axi 3 -", "outputs": ["mou 1 - 12"], "note": "Look up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Use / fire"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Aim / terrain tool"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Jump / jetpack"},
          {"input": "btn 1", "outputs": ["key 224"], "note": "Crouch (Ctrl)"},
          {"input": "btn 2", "outputs": ["key 21"], "note": "Reload"},
          {"input": "btn 3", "outputs": ["key 8"], "note": "Interact (E)"},
          {"input": "btn 4", "outputs": ["key 6"], "note": "Scanner (C)"},
          {"input": "btn 11", "outputs": ["key 225"], "note": "Sprint (Shift)"},
          {"input": "hat 0 U", "outputs": ["key 30"], "note": "Tech 1"},
          {"input": "hat 0 L", "outputs": ["key 31"], "note": "Tech 2"},
          {"input": "hat 0 R", "outputs": ["key 32"], "note": "Tech 3"},
          {"input": "btn 8", "outputs": ["key 12"], "note": "Inventory (I)"},
          {"input": "btn 10", "outputs": ["key 16"], "note": "Galaxy map (M)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Left bumper runs the scanner; A doubles as the jetpack.", "Triggers use and aim your multi-tool; I opens the inventory."]
      },
      {
        "id": "palworld", "category": "game", "displayName": "Palworld",
        "subtitle": "Creature survival: move, aim, throw, hotbar",
        "appPath": "/Applications/Steam.app", "launchURL": "",
        "light": {"r": 70, "g": 150, "b": 220},
        "confineCursor": true, "autoRecenter": true, "hideCursor": true,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Strafe left (A)"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Strafe right (D)"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Move forward (W)"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Move back (S)"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 18"], "note": "Look right"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 18"], "note": "Look left"},
          {"input": "axi 3 +", "outputs": ["mou 1 + 12"], "note": "Look down"},
          {"input": "axi 3 -", "outputs": ["mou 1 - 12"], "note": "Look up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Attack / throw sphere"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Aim"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Jump"},
          {"input": "btn 1", "outputs": ["key 224"], "note": "Crouch (Ctrl)"},
          {"input": "btn 2", "outputs": ["key 21"], "note": "Reload"},
          {"input": "btn 3", "outputs": ["key 9"], "note": "Interact (F)"},
          {"input": "btn 4", "outputs": ["key 20"], "note": "Pal command (Q)"},
          {"input": "btn 5", "outputs": ["key 8"], "note": "Summon / use Pal (E)"},
          {"input": "btn 11", "outputs": ["key 225"], "note": "Sprint (Shift)"},
          {"input": "hat 0 U", "outputs": ["key 30"], "note": "Slot 1"},
          {"input": "hat 0 L", "outputs": ["key 31"], "note": "Slot 2"},
          {"input": "hat 0 R", "outputs": ["key 32"], "note": "Slot 3"},
          {"input": "btn 8", "outputs": ["key 23"], "note": "Inventory (Tab)"},
          {"input": "btn 10", "outputs": ["key 16"], "note": "Map (M)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Bumpers command and summon your Pals; D-pad swaps gear.", "Right trigger throws a Pal Sphere or attacks; left trigger aims."]
      },
      {
        "id": "ark-survival-evolved", "category": "game", "displayName": "ARK: Survival Evolved",
        "subtitle": "Dino survival: move, aim, gather, hotbar",
        "appPath": "/Applications/Steam.app", "launchURL": "",
        "light": {"r": 120, "g": 170, "b": 80},
        "confineCursor": true, "autoRecenter": true, "hideCursor": true,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Strafe left (A)"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Strafe right (D)"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Move forward (W)"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Move back (S)"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 18"], "note": "Look right"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 18"], "note": "Look left"},
          {"input": "axi 3 +", "outputs": ["mou 1 + 12"], "note": "Look down"},
          {"input": "axi 3 -", "outputs": ["mou 1 - 12"], "note": "Look up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Attack / gather"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Aim / alt"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Jump"},
          {"input": "btn 1", "outputs": ["key 6"], "note": "Crouch (C)"},
          {"input": "btn 2", "outputs": ["key 21"], "note": "Reload"},
          {"input": "btn 3", "outputs": ["key 8"], "note": "Use / access (E)"},
          {"input": "btn 4", "outputs": ["key 21"], "note": "Reload"},
          {"input": "btn 5", "outputs": ["key 9"], "note": "Whistle / use (F)"},
          {"input": "btn 11", "outputs": ["key 225"], "note": "Sprint (Shift)"},
          {"input": "hat 0 U", "outputs": ["key 30"], "note": "Hotbar 1"},
          {"input": "hat 0 L", "outputs": ["key 31"], "note": "Hotbar 2"},
          {"input": "hat 0 R", "outputs": ["key 32"], "note": "Hotbar 3"},
          {"input": "btn 8", "outputs": ["key 12"], "note": "Inventory (I)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Triggers gather and aim; D-pad selects hotbar slots.", "Hold left-stick click to sprint; E accesses storage and dinos."]
      },
      {
        "id": "project-zomboid", "category": "game", "displayName": "Project Zomboid",
        "subtitle": "Isometric survival: move, aim, interact, hotbar",
        "appPath": "/Applications/Steam.app", "launchURL": "",
        "light": {"r": 130, "g": 40, "b": 40},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Move left (A)"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Move right (D)"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Move up (W)"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Move down (S)"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 16"], "note": "Aim right"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 16"], "note": "Aim left"},
          {"input": "axi 3 +", "outputs": ["mou 1 + 16"], "note": "Aim down"},
          {"input": "axi 3 -", "outputs": ["mou 1 - 16"], "note": "Aim up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Attack"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Aim weapon"},
          {"input": "btn 0", "outputs": ["key 8"], "note": "Interact (E)"},
          {"input": "btn 1", "outputs": ["key 6"], "note": "Sneak (C)"},
          {"input": "btn 2", "outputs": ["key 21"], "note": "Reload"},
          {"input": "btn 3", "outputs": ["key 22"], "note": "Open inventory (I)? "},
          {"input": "btn 11", "outputs": ["key 225"], "note": "Run (Shift)"},
          {"input": "hat 0 U", "outputs": ["key 30"], "note": "Hotbar 1"},
          {"input": "hat 0 L", "outputs": ["key 31"], "note": "Hotbar 2"},
          {"input": "hat 0 R", "outputs": ["key 32"], "note": "Hotbar 3"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Right trigger attacks, left trigger raises your weapon to aim.", "Hold left-stick click to run; A interacts with doors and items."]
      },
      {
        "id": "dont-starve-together", "category": "game", "displayName": "Don't Starve Together",
        "subtitle": "Survival: move, gather, inventory slots",
        "appPath": "/Applications/Steam.app", "launchURL": "",
        "light": {"r": 150, "g": 130, "b": 70},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Move left (A)"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Move right (D)"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Move up (W)"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Move down (S)"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 3 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 3 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Action / gather (left click)"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Inspect (right click)"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Attack (Space)"},
          {"input": "btn 1", "outputs": ["key 9"], "note": "Examine (F)"},
          {"input": "hat 0 U", "outputs": ["key 30"], "note": "Inventory 1"},
          {"input": "hat 0 L", "outputs": ["key 31"], "note": "Inventory 2"},
          {"input": "hat 0 R", "outputs": ["key 32"], "note": "Inventory 3"},
          {"input": "hat 0 D", "outputs": ["key 33"], "note": "Inventory 4"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Left stick moves; right stick aims the cursor for gathering.", "Space attacks; the D-pad uses inventory slots."]
      },
      {
        "id": "the-sims-4", "category": "game", "displayName": "The Sims 4",
        "subtitle": "Life sim: cursor, pan, speed, build",
        "appPath": "", "launchURL": "",
        "light": {"r": 60, "g": 200, "b": 90},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 2 -", "outputs": ["key 4"], "note": "Pan left (A)"},
          {"input": "axi 2 +", "outputs": ["key 7"], "note": "Pan right (D)"},
          {"input": "axi 3 -", "outputs": ["key 26"], "note": "Pan up (W)"},
          {"input": "axi 3 +", "outputs": ["key 22"], "note": "Pan down (S)"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Select (left click)"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Interact (right click)"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Pause / play (Space)"},
          {"input": "btn 1", "outputs": ["key 30"], "note": "Normal speed (1)"},
          {"input": "btn 2", "outputs": ["key 31"], "note": "Fast (2)"},
          {"input": "btn 3", "outputs": ["key 32"], "note": "Faster (3)"},
          {"input": "btn 4", "outputs": ["whs 1 -"], "note": "Zoom out"},
          {"input": "btn 5", "outputs": ["whs 1 +"], "note": "Zoom in"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Left stick is the pointer; right stick pans the lot.", "A pauses or resumes; B, X, Y set the game speed."]
      },
      {
        "id": "age-of-empires-iv", "category": "game", "displayName": "Age of Empires IV",
        "subtitle": "RTS: cursor, pan, select, command, groups",
        "appPath": "/Applications/Steam.app", "launchURL": "",
        "light": {"r": 200, "g": 160, "b": 70},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 2 -", "outputs": ["key 80"], "note": "Pan left"},
          {"input": "axi 2 +", "outputs": ["key 79"], "note": "Pan right"},
          {"input": "axi 3 -", "outputs": ["key 82"], "note": "Pan up"},
          {"input": "axi 3 +", "outputs": ["key 81"], "note": "Pan down"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Select (left click)"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Move / attack (right click)"},
          {"input": "btn 0", "outputs": ["key 30"], "note": "Control group 1"},
          {"input": "btn 1", "outputs": ["key 31"], "note": "Control group 2"},
          {"input": "btn 2", "outputs": ["key 32"], "note": "Control group 3"},
          {"input": "btn 3", "outputs": ["key 5"], "note": "Build menu (B)"},
          {"input": "btn 4", "outputs": ["whs 1 -"], "note": "Zoom out"},
          {"input": "btn 5", "outputs": ["whs 1 +"], "note": "Zoom in"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Left stick is the pointer; right stick pans the battlefield.", "Face buttons jump to control groups; bumpers zoom."]
      },
      {
        "id": "starcraft-ii", "category": "game", "displayName": "StarCraft II",
        "subtitle": "RTS: cursor, pan, select, control groups",
        "appPath": "", "launchURL": "",
        "light": {"r": 60, "g": 130, "b": 220},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["mou 0 - 18"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 18"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 18"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 18"], "note": "Cursor down"},
          {"input": "axi 2 -", "outputs": ["key 80"], "note": "Pan left"},
          {"input": "axi 2 +", "outputs": ["key 79"], "note": "Pan right"},
          {"input": "axi 3 -", "outputs": ["key 82"], "note": "Pan up"},
          {"input": "axi 3 +", "outputs": ["key 81"], "note": "Pan down"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Select (left click)"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Move / attack (right click)"},
          {"input": "btn 0", "outputs": ["key 30"], "note": "Control group 1"},
          {"input": "btn 1", "outputs": ["key 31"], "note": "Control group 2"},
          {"input": "btn 2", "outputs": ["key 32"], "note": "Control group 3"},
          {"input": "btn 3", "outputs": ["key 33"], "note": "Control group 4"},
          {"input": "btn 4", "outputs": ["key 4"], "note": "Attack-move (A)"},
          {"input": "btn 5", "outputs": ["key 5"], "note": "Build / hold (B)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Left stick is the pointer; right stick pans the map.", "Face buttons recall control groups; left bumper is attack-move."]
      },
      {
        "id": "frostpunk", "category": "game", "displayName": "Frostpunk",
        "subtitle": "Survival city sim: cursor, pan, pause, speed",
        "appPath": "/Applications/Steam.app", "launchURL": "",
        "light": {"r": 120, "g": 180, "b": 210},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 2 -", "outputs": ["key 4"], "note": "Pan left (A)"},
          {"input": "axi 2 +", "outputs": ["key 7"], "note": "Pan right (D)"},
          {"input": "axi 3 -", "outputs": ["key 26"], "note": "Pan up (W)"},
          {"input": "axi 3 +", "outputs": ["key 22"], "note": "Pan down (S)"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Select (left click)"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Cancel (right click)"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Pause (Space)"},
          {"input": "btn 1", "outputs": ["key 30"], "note": "Speed 1"},
          {"input": "btn 2", "outputs": ["key 31"], "note": "Speed 2"},
          {"input": "btn 3", "outputs": ["key 32"], "note": "Speed 3"},
          {"input": "btn 4", "outputs": ["whs 1 -"], "note": "Zoom out"},
          {"input": "btn 5", "outputs": ["whs 1 +"], "note": "Zoom in"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Left stick is the pointer; right stick pans the city.", "A pauses; B, X, Y change the speed of time."]
      },
      {
        "id": "oxygen-not-included", "category": "game", "displayName": "Oxygen Not Included",
        "subtitle": "Colony sim: cursor, pan, pause, speed",
        "appPath": "/Applications/Steam.app", "launchURL": "",
        "light": {"r": 90, "g": 200, "b": 160},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 2 -", "outputs": ["key 4"], "note": "Pan left (A)"},
          {"input": "axi 2 +", "outputs": ["key 7"], "note": "Pan right (D)"},
          {"input": "axi 3 -", "outputs": ["key 26"], "note": "Pan up (W)"},
          {"input": "axi 3 +", "outputs": ["key 22"], "note": "Pan down (S)"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Select / assign (left click)"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Cancel (right click)"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Pause (Space)"},
          {"input": "btn 1", "outputs": ["key 30"], "note": "Speed 1"},
          {"input": "btn 2", "outputs": ["key 31"], "note": "Speed 2"},
          {"input": "btn 3", "outputs": ["key 32"], "note": "Speed 3"},
          {"input": "btn 4", "outputs": ["whs 1 -"], "note": "Zoom out"},
          {"input": "btn 5", "outputs": ["whs 1 +"], "note": "Zoom in"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Left stick is the pointer; right stick pans the asteroid.", "A pauses; B, X, Y set the speed; bumpers zoom."]
      },
      {
        "id": "enter-the-gungeon", "category": "game", "displayName": "Enter the Gungeon",
        "subtitle": "Twin-stick roguelite: move, aim, dodge, reload",
        "appPath": "/Applications/Steam.app", "launchURL": "",
        "light": {"r": 140, "g": 90, "b": 200},
        "confineCursor": true, "autoRecenter": true, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Move left (A)"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Move right (D)"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Move up (W)"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Move down (S)"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 18"], "note": "Aim right"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 18"], "note": "Aim left"},
          {"input": "axi 3 +", "outputs": ["mou 1 + 18"], "note": "Aim down"},
          {"input": "axi 3 -", "outputs": ["mou 1 - 18"], "note": "Aim up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Fire"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Dodge roll (Space)"},
          {"input": "btn 1", "outputs": ["key 8"], "note": "Interact (E)"},
          {"input": "btn 2", "outputs": ["key 21"], "note": "Reload (R)"},
          {"input": "btn 3", "outputs": ["key 9"], "note": "Use blank (F)"},
          {"input": "btn 4", "outputs": ["whs 1 -"], "note": "Previous gun"},
          {"input": "btn 5", "outputs": ["whs 1 +"], "note": "Next gun"},
          {"input": "btn 11", "outputs": ["key 20"], "note": "Use active item (Q)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Left stick moves, right stick aims, right trigger fires.", "Bumpers swap guns; match the keys in-game if yours differ."]
      },
      {
        "id": "binding-of-isaac", "category": "game", "displayName": "The Binding of Isaac",
        "subtitle": "Twin-stick roguelite: move, shoot, bombs, items",
        "appPath": "/Applications/Steam.app", "launchURL": "",
        "light": {"r": 180, "g": 50, "b": 60},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Move left (A)"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Move right (D)"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Move up (W)"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Move down (S)"},
          {"input": "axi 2 -", "outputs": ["key 80"], "note": "Shoot left"},
          {"input": "axi 2 +", "outputs": ["key 79"], "note": "Shoot right"},
          {"input": "axi 3 -", "outputs": ["key 82"], "note": "Shoot up"},
          {"input": "axi 3 +", "outputs": ["key 81"], "note": "Shoot down"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Use item (Space)"},
          {"input": "btn 1", "outputs": ["key 8"], "note": "Drop bomb (E)"},
          {"input": "btn 2", "outputs": ["key 20"], "note": "Use card / pill (Q)"},
          {"input": "btn 3", "outputs": ["key 6"], "note": "Use pocket item (C)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Left stick moves; right stick fires tears in any direction.", "A uses your active item; B drops a bomb."]
      },
      {
        "id": "dead-cells", "category": "game", "displayName": "Dead Cells",
        "subtitle": "Action platformer: move, attack, roll, skills",
        "appPath": "/Applications/Steam.app", "launchURL": "",
        "light": {"r": 60, "g": 200, "b": 180},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Move left (A)"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Move right (D)"},
          {"input": "hat 0 L", "outputs": ["key 4"], "note": "Move left"},
          {"input": "hat 0 R", "outputs": ["key 7"], "note": "Move right"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Jump (Space)"},
          {"input": "btn 1", "outputs": ["key 15"], "note": "Roll (L)"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Primary weapon"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Secondary weapon"},
          {"input": "btn 2", "outputs": ["key 20"], "note": "Skill 1 (Q)"},
          {"input": "btn 3", "outputs": ["key 8"], "note": "Skill 2 (E)"},
          {"input": "btn 4", "outputs": ["key 21"], "note": "Use / interact (R)"},
          {"input": "hat 0 U", "outputs": ["key 26"], "note": "Up / enter door (W)"},
          {"input": "hat 0 D", "outputs": ["key 22"], "note": "Down / drop (S)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Triggers swing your two weapons; B rolls through enemies.", "Face buttons fire your two skills; D-pad enters doors."]
      },
      {
        "id": "cuphead", "category": "game", "displayName": "Cuphead",
        "subtitle": "Run and gun: move, shoot, dash, parry",
        "appPath": "/Applications/Steam.app", "launchURL": "",
        "light": {"r": 220, "g": 80, "b": 60},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Move left (A)"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Move right (D)"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Aim up (W)"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Duck / aim down (S)"},
          {"input": "hat 0 L", "outputs": ["key 4"], "note": "Move left"},
          {"input": "hat 0 R", "outputs": ["key 7"], "note": "Move right"},
          {"input": "btn 0", "outputs": ["key 27"], "note": "Jump / parry (X)"},
          {"input": "btn 2", "outputs": ["key 6"], "note": "Shoot (C)"},
          {"input": "btn 1", "outputs": ["key 25"], "note": "Dash (V)"},
          {"input": "btn 3", "outputs": ["key 29"], "note": "EX / super (Z)"},
          {"input": "btn 5", "outputs": ["key 27"], "note": "Lock aim (Shift)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["A jumps and parries pink objects; X shoots.", "Default keys shown - match them in Cuphead's options if yours differ."]
      },
      {
        "id": "ori-will-of-the-wisps", "category": "game", "displayName": "Ori and the Will of the Wisps",
        "subtitle": "Platformer: move, jump, dash, abilities",
        "appPath": "/Applications/Steam.app", "launchURL": "",
        "light": {"r": 110, "g": 200, "b": 220},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Move left (A)"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Move right (D)"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Aim up (W)"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Aim down (S)"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Jump (Space)"},
          {"input": "btn 1", "outputs": ["key 15"], "note": "Dash (L / Shift)"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Attack"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Bash / aim"},
          {"input": "btn 2", "outputs": ["key 8"], "note": "Ability (E)"},
          {"input": "btn 3", "outputs": ["key 20"], "note": "Ability (Q)"},
          {"input": "btn 4", "outputs": ["key 21"], "note": "Grab / interact (R)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["A jumps, B dashes; triggers attack and bash.", "Face buttons fire your equipped spirit abilities."]
      },
      {
        "id": "hades-2", "category": "game", "displayName": "Hades II",
        "subtitle": "Roguelite action: move, attack, special, dash, cast",
        "appPath": "/Applications/Steam.app", "launchURL": "",
        "light": {"r": 140, "g": 70, "b": 200},
        "confineCursor": true, "autoRecenter": true, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Move left (A)"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Move right (D)"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Move up (W)"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Move down (S)"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 18"], "note": "Aim right"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 18"], "note": "Aim left"},
          {"input": "axi 3 +", "outputs": ["mou 1 + 18"], "note": "Aim down"},
          {"input": "axi 3 -", "outputs": ["mou 1 - 18"], "note": "Aim up"},
          {"input": "btn 0", "outputs": ["mbt 0"], "note": "Attack"},
          {"input": "btn 1", "outputs": ["mbt 1"], "note": "Special"},
          {"input": "btn 2", "outputs": ["key 20"], "note": "Cast (Q)"},
          {"input": "btn 3", "outputs": ["key 8"], "note": "Interact (E)"},
          {"input": "axi 5 +", "outputs": ["key 44"], "note": "Dash (Space)"},
          {"input": "axi 4 +", "outputs": ["key 9"], "note": "Sprint / Omega (F)"},
          {"input": "btn 4", "outputs": ["key 21"], "note": "Use Hex / call (R)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["A attacks, B is your special; right trigger dashes.", "Hold left trigger for Omega moves; X casts."]
      },
      {
        "id": "hotline-miami", "category": "game", "displayName": "Hotline Miami",
        "subtitle": "Top-down action: move, aim, attack, lock-on",
        "appPath": "/Applications/Steam.app", "launchURL": "",
        "light": {"r": 230, "g": 60, "b": 140},
        "confineCursor": true, "autoRecenter": true, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Move left (A)"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Move right (D)"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Move up (W)"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Move down (S)"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 18"], "note": "Aim right"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 18"], "note": "Aim left"},
          {"input": "axi 3 +", "outputs": ["mou 1 + 18"], "note": "Aim down"},
          {"input": "axi 3 -", "outputs": ["mou 1 - 18"], "note": "Aim up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Attack / fire"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Lock aim"},
          {"input": "btn 0", "outputs": ["key 8"], "note": "Throw / pick up (E)"},
          {"input": "btn 1", "outputs": ["key 21"], "note": "Execute (R)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Left stick moves, right stick aims; right trigger attacks.", "Left trigger locks your aim; A throws or picks up weapons."]
      },
      {
        "id": "katana-zero", "category": "game", "displayName": "Katana ZERO",
        "subtitle": "Action platformer: move, attack, roll, slow-mo",
        "appPath": "/Applications/Steam.app", "launchURL": "",
        "light": {"r": 200, "g": 40, "b": 90},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Move left (A)"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Move right (D)"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Up (W)"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Down / drop (S)"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Jump (Space)"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Attack"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Throw item"},
          {"input": "btn 1", "outputs": ["key 15"], "note": "Roll / dodge (L / Shift)"},
          {"input": "btn 2", "outputs": ["key 20"], "note": "Slow-mo (Q)"},
          {"input": "btn 3", "outputs": ["key 8"], "note": "Interact (E)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Right trigger swings your katana; left trigger throws items.", "B rolls; X triggers slow motion to deflect bullets."]
      },
      {
        "id": "balatro", "category": "game", "displayName": "Balatro",
        "subtitle": "Poker roguelite: cursor, select cards, play",
        "appPath": "/Applications/Steam.app", "launchURL": "",
        "light": {"r": 220, "g": 60, "b": 60},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 28"], "note": "Cursor left (fast)"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 28"], "note": "Cursor right (fast)"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Select / play (left click)"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Inspect (right click)"},
          {"input": "btn 0", "outputs": ["mbt 0"], "note": "Click"},
          {"input": "btn 1", "outputs": ["key 41"], "note": "Back (Esc)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Left stick is precise, right stick is fast - both move the pointer.", "Right trigger or A clicks to select and play your hand."]
      },
      {
        "id": "slay-the-spire", "category": "game", "displayName": "Slay the Spire",
        "subtitle": "Deckbuilder: cursor, play cards, end turn",
        "appPath": "/Applications/Steam.app", "launchURL": "",
        "light": {"r": 230, "g": 140, "b": 40},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 28"], "note": "Cursor left (fast)"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 28"], "note": "Cursor right (fast)"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Play card / select (left click)"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Cancel (right click)"},
          {"input": "btn 0", "outputs": ["mbt 0"], "note": "Click"},
          {"input": "btn 3", "outputs": ["key 8"], "note": "End turn (E)"},
          {"input": "btn 1", "outputs": ["key 41"], "note": "Back (Esc)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Left stick is precise, right stick is fast pointer movement.", "Y ends your turn; right trigger plays the highlighted card."]
      },
      {
        "id": "darkest-dungeon", "category": "game", "displayName": "Darkest Dungeon",
        "subtitle": "Gothic RPG: cursor, select, skills, scroll",
        "appPath": "/Applications/Steam.app", "launchURL": "",
        "light": {"r": 150, "g": 40, "b": 40},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Select / confirm (left click)"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Back (right click)"},
          {"input": "btn 0", "outputs": ["key 30"], "note": "Skill 1"},
          {"input": "btn 1", "outputs": ["key 31"], "note": "Skill 2"},
          {"input": "btn 2", "outputs": ["key 32"], "note": "Skill 3"},
          {"input": "btn 3", "outputs": ["key 33"], "note": "Skill 4"},
          {"input": "btn 4", "outputs": ["key 19"], "note": "Pass turn (P)"},
          {"input": "hat 0 L", "outputs": ["key 4"], "note": "Move party left (A)"},
          {"input": "hat 0 R", "outputs": ["key 7"], "note": "Move party right (D)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Left stick aims the pointer; right trigger confirms.", "Face buttons fire combat skills 1 through 4; left bumper passes."]
      },
      {
        "id": "cult-of-the-lamb", "category": "game", "displayName": "Cult of the Lamb",
        "subtitle": "Action + management: move, attack, dodge, interact",
        "appPath": "/Applications/Steam.app", "launchURL": "",
        "light": {"r": 200, "g": 70, "b": 150},
        "confineCursor": true, "autoRecenter": true, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Move left (A)"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Move right (D)"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Move up (W)"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Move down (S)"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 16"], "note": "Aim right"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 16"], "note": "Aim left"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Attack"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Curse / ranged"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Dodge roll (Space)"},
          {"input": "btn 3", "outputs": ["key 8"], "note": "Interact (E)"},
          {"input": "btn 2", "outputs": ["key 21"], "note": "Use item (R)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Triggers melee and cast curses; A rolls out of danger.", "Y interacts with your followers and buildings."]
      },
      {
        "id": "fall-guys", "category": "game", "displayName": "Fall Guys",
        "subtitle": "Party platformer: move, jump, dive, grab",
        "appPath": "", "launchURL": "",
        "light": {"r": 255, "g": 130, "b": 200},
        "confineCursor": true, "autoRecenter": true, "hideCursor": true,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 4"], "note": "Move left (A)"},
          {"input": "axi 0 +", "outputs": ["key 7"], "note": "Move right (D)"},
          {"input": "axi 1 -", "outputs": ["key 26"], "note": "Move forward (W)"},
          {"input": "axi 1 +", "outputs": ["key 22"], "note": "Move back (S)"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 18"], "note": "Camera right"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 18"], "note": "Camera left"},
          {"input": "axi 3 +", "outputs": ["mou 1 + 12"], "note": "Camera down"},
          {"input": "axi 3 -", "outputs": ["mou 1 - 12"], "note": "Camera up"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Jump (Space)"},
          {"input": "btn 1", "outputs": ["key 224"], "note": "Dive (Ctrl)"},
          {"input": "axi 5 +", "outputs": ["key 225"], "note": "Grab (Shift)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["A jumps, B dives; hold the right trigger to grab.", "Right stick swings the camera."]
      },
      {
        "id": "disco-elysium", "category": "game", "displayName": "Disco Elysium",
        "subtitle": "Narrative RPG: cursor, interact, highlight",
        "appPath": "/Applications/Steam.app", "launchURL": "",
        "light": {"r": 180, "g": 120, "b": 60},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Move / interact (left click)"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Examine (right click)"},
          {"input": "btn 0", "outputs": ["key 44"], "note": "Highlight items (Space / Tab)"},
          {"input": "btn 1", "outputs": ["key 12"], "note": "Inventory (I)"},
          {"input": "btn 2", "outputs": ["key 13"], "note": "Journal (J)"},
          {"input": "btn 3", "outputs": ["key 6"], "note": "Character (C)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Left stick aims the pointer; right trigger walks and interacts.", "A highlights interactables; face buttons open your menus."]
      },
      {
        "id": "divinity-original-sin-2", "category": "game", "displayName": "Divinity: Original Sin 2",
        "subtitle": "Party RPG: cursor, select, hotbar, end turn",
        "appPath": "/Applications/Steam.app", "launchURL": "",
        "light": {"r": 150, "g": 90, "b": 200},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Move / select (left click)"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Context menu (right click)"},
          {"input": "btn 0", "outputs": ["key 30"], "note": "Hotbar 1"},
          {"input": "btn 1", "outputs": ["key 31"], "note": "Hotbar 2"},
          {"input": "btn 2", "outputs": ["key 32"], "note": "Hotbar 3"},
          {"input": "btn 3", "outputs": ["key 8"], "note": "End turn (E? )"},
          {"input": "btn 4", "outputs": ["key 12"], "note": "Inventory (I)"},
          {"input": "btn 5", "outputs": ["key 5"], "note": "Highlight items (Alt)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Menu (Esc)"}
        ],
        "tips": ["Left stick aims the pointer; right trigger moves and selects.", "Face buttons fire hotbar skills; left bumper opens inventory."]
      },
      {
        "id": "microsoft-outlook", "category": "app", "displayName": "Microsoft Outlook",
        "subtitle": "Read mail, reply, compose, delete, navigate",
        "appPath": "/Applications/Microsoft Outlook.app", "launchURL": "",
        "light": {"r": 0, "g": 120, "b": 200},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 3 +", "outputs": ["whe 1 + 5"], "note": "Scroll down"},
          {"input": "axi 3 -", "outputs": ["whe 1 - 5"], "note": "Scroll up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Click"},
          {"input": "hat 0 U", "outputs": ["key 82"], "note": "Previous message"},
          {"input": "hat 0 D", "outputs": ["key 81"], "note": "Next message"},
          {"input": "btn 0", "outputs": ["key 227", "key 17"], "note": "New email (Cmd+N)"},
          {"input": "btn 1", "outputs": ["key 227", "key 21"], "note": "Reply (Cmd+R)"},
          {"input": "btn 2", "outputs": ["key 227", "key 226", "key 7"], "note": "Send (Cmd+Shift+D)"},
          {"input": "btn 3", "outputs": ["key 42"], "note": "Delete (Backspace)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Close / Esc"}
        ],
        "tips": ["D-pad up and down move between messages; right stick scrolls.", "Face buttons compose, reply, send, and delete."]
      },
      {
        "id": "microsoft-teams", "category": "app", "displayName": "Microsoft Teams",
        "subtitle": "Mute, camera, navigate, click",
        "appPath": "/Applications/Microsoft Teams.app", "launchURL": "",
        "light": {"r": 90, "g": 95, "b": 200},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 3 +", "outputs": ["whe 1 + 5"], "note": "Scroll down"},
          {"input": "axi 3 -", "outputs": ["whe 1 - 5"], "note": "Scroll up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Click"},
          {"input": "btn 0", "outputs": ["key 227", "key 226", "key 16"], "note": "Mute / unmute (Cmd+Shift+M)"},
          {"input": "btn 1", "outputs": ["key 227", "key 226", "key 18"], "note": "Camera (Cmd+Shift+O)"},
          {"input": "btn 2", "outputs": ["key 227", "key 226", "key 11"], "note": "Raise hand (Cmd+Shift+K)"},
          {"input": "btn 3", "outputs": ["key 227", "key 226", "key 5"], "note": "Leave call (Cmd+Shift+B)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Close / Esc"}
        ],
        "tips": ["Face buttons mute, toggle camera, raise hand, and leave.", "Left stick moves the pointer to click chats and controls."]
      },
      {
        "id": "apple-mail", "category": "app", "displayName": "Apple Mail",
        "subtitle": "Read, reply, compose, delete, navigate",
        "appPath": "/Applications/Mail.app", "launchURL": "",
        "light": {"r": 40, "g": 140, "b": 240},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 3 +", "outputs": ["whe 1 + 5"], "note": "Scroll down"},
          {"input": "axi 3 -", "outputs": ["whe 1 - 5"], "note": "Scroll up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Click"},
          {"input": "hat 0 U", "outputs": ["key 82"], "note": "Previous message"},
          {"input": "hat 0 D", "outputs": ["key 81"], "note": "Next message"},
          {"input": "btn 0", "outputs": ["key 227", "key 17"], "note": "New message (Cmd+N)"},
          {"input": "btn 1", "outputs": ["key 227", "key 21"], "note": "Reply (Cmd+R)"},
          {"input": "btn 2", "outputs": ["key 227", "key 226", "key 7"], "note": "Send (Cmd+Shift+D)"},
          {"input": "btn 3", "outputs": ["key 42"], "note": "Delete (Backspace)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Close / Esc"}
        ],
        "tips": ["D-pad steps through messages; right stick scrolls the reading pane.", "Face buttons compose, reply, send, and delete."]
      },
      {
        "id": "apple-notes", "category": "app", "displayName": "Apple Notes",
        "subtitle": "Cursor, scroll, new note, formatting",
        "appPath": "/Applications/Notes.app", "launchURL": "",
        "light": {"r": 240, "g": 200, "b": 70},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 3 +", "outputs": ["whe 1 + 5"], "note": "Scroll down"},
          {"input": "axi 3 -", "outputs": ["whe 1 - 5"], "note": "Scroll up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Click"},
          {"input": "btn 0", "outputs": ["key 227", "key 17"], "note": "New note (Cmd+N)"},
          {"input": "btn 1", "outputs": ["key 227", "key 5"], "note": "Bold (Cmd+B)"},
          {"input": "btn 2", "outputs": ["key 227", "key 226", "key 15"], "note": "Checklist (Cmd+Shift+L)"},
          {"input": "btn 3", "outputs": ["key 227", "key 6"], "note": "Copy"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Close / Esc"}
        ],
        "tips": ["Left stick is the pointer; right stick scrolls.", "Face buttons make a new note, bold, a checklist, and copy."]
      },
      {
        "id": "keynote", "category": "app", "displayName": "Keynote",
        "subtitle": "Present, advance slides, pointer",
        "appPath": "/Applications/Keynote.app", "launchURL": "",
        "light": {"r": 40, "g": 130, "b": 230},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 5 +", "outputs": ["key 79"], "note": "Next slide (right trigger)"},
          {"input": "axi 4 +", "outputs": ["key 80"], "note": "Previous slide (left trigger)"},
          {"input": "btn 0", "outputs": ["key 79"], "note": "Next slide"},
          {"input": "btn 1", "outputs": ["key 80"], "note": "Previous slide"},
          {"input": "btn 5", "outputs": ["key 79"], "note": "Next (bumper)"},
          {"input": "btn 4", "outputs": ["key 80"], "note": "Previous (bumper)"},
          {"input": "hat 0 R", "outputs": ["key 79"], "note": "Next"},
          {"input": "hat 0 L", "outputs": ["key 80"], "note": "Previous"},
          {"input": "btn 3", "outputs": ["key 41"], "note": "End show (Esc)"},
          {"input": "btn 2", "outputs": ["key 227", "key 18", "key 19"], "note": "Play slideshow (Cmd+Opt+P)? "},
          {"input": "axi 0 -", "outputs": ["mou 0 - 14"], "note": "Pointer left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 14"], "note": "Pointer right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 14"], "note": "Pointer up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 14"], "note": "Pointer down"}
        ],
        "tips": ["Trigger, bumper, face button, or D-pad advances slides.", "Left stick moves a pointer; X ends the show."]
      },
      {
        "id": "pages", "category": "app", "displayName": "Pages",
        "subtitle": "Cursor, scroll, copy, paste, save",
        "appPath": "/Applications/Pages.app", "launchURL": "",
        "light": {"r": 240, "g": 150, "b": 40},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 3 +", "outputs": ["whe 1 + 5"], "note": "Scroll down"},
          {"input": "axi 3 -", "outputs": ["whe 1 - 5"], "note": "Scroll up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Click"},
          {"input": "btn 0", "outputs": ["key 227", "key 6"], "note": "Copy"},
          {"input": "btn 1", "outputs": ["key 227", "key 25"], "note": "Paste"},
          {"input": "btn 2", "outputs": ["key 227", "key 22"], "note": "Save"},
          {"input": "btn 3", "outputs": ["key 227", "key 29"], "note": "Undo"},
          {"input": "hat 0 U", "outputs": ["key 82"], "note": "Arrow up"},
          {"input": "hat 0 D", "outputs": ["key 81"], "note": "Arrow down"},
          {"input": "hat 0 L", "outputs": ["key 80"], "note": "Arrow left"},
          {"input": "hat 0 R", "outputs": ["key 79"], "note": "Arrow right"}
        ],
        "tips": ["Left stick is the pointer; right stick scrolls.", "Face buttons are Copy, Paste, Save, and Undo."]
      },
      {
        "id": "numbers", "category": "app", "displayName": "Numbers",
        "subtitle": "Move between cells, scroll, copy, paste",
        "appPath": "/Applications/Numbers.app", "launchURL": "",
        "light": {"r": 40, "g": 180, "b": 80},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 3 +", "outputs": ["whe 1 + 5"], "note": "Scroll down"},
          {"input": "axi 3 -", "outputs": ["whe 1 - 5"], "note": "Scroll up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Click"},
          {"input": "hat 0 U", "outputs": ["key 82"], "note": "Cell up"},
          {"input": "hat 0 D", "outputs": ["key 81"], "note": "Cell down"},
          {"input": "hat 0 L", "outputs": ["key 80"], "note": "Cell left"},
          {"input": "hat 0 R", "outputs": ["key 79"], "note": "Cell right"},
          {"input": "btn 0", "outputs": ["key 227", "key 6"], "note": "Copy"},
          {"input": "btn 1", "outputs": ["key 227", "key 25"], "note": "Paste"},
          {"input": "btn 2", "outputs": ["key 40"], "note": "Confirm cell (Enter)"},
          {"input": "btn 3", "outputs": ["key 227", "key 29"], "note": "Undo"}
        ],
        "tips": ["D-pad steps cell by cell; left stick is the pointer.", "Face buttons Copy, Paste, confirm, and Undo."]
      },
      {
        "id": "preview-pdf", "category": "app", "displayName": "Preview",
        "subtitle": "Page through PDFs, zoom, scroll, rotate",
        "appPath": "/Applications/Preview.app", "launchURL": "",
        "light": {"r": 120, "g": 170, "b": 230},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 3 +", "outputs": ["whe 1 + 5"], "note": "Scroll down"},
          {"input": "axi 3 -", "outputs": ["whe 1 - 5"], "note": "Scroll up"},
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Click"},
          {"input": "btn 0", "outputs": ["key 81"], "note": "Next page (Down)"},
          {"input": "btn 1", "outputs": ["key 82"], "note": "Previous page (Up)"},
          {"input": "btn 2", "outputs": ["key 227", "key 46"], "note": "Zoom in"},
          {"input": "btn 3", "outputs": ["key 227", "key 45"], "note": "Zoom out"},
          {"input": "btn 4", "outputs": ["key 227", "key 15"], "note": "Rotate left (Cmd+L)"},
          {"input": "btn 5", "outputs": ["key 227", "key 21"], "note": "Rotate right (Cmd+R)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Close / Esc"}
        ],
        "tips": ["A and B turn pages; right stick scrolls within a page.", "X and Y zoom; bumpers rotate the page."]
      },
      {
        "id": "adobe-illustrator", "category": "app", "displayName": "Adobe Illustrator",
        "subtitle": "Tools, cursor, zoom, undo, save",
        "appPath": "", "launchURL": "",
        "light": {"r": 255, "g": 154, "b": 0},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Click / draw"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Right click"},
          {"input": "btn 0", "outputs": ["key 25"], "note": "Selection tool (V)"},
          {"input": "btn 1", "outputs": ["key 19"], "note": "Pen tool (P)"},
          {"input": "btn 2", "outputs": ["key 23"], "note": "Type tool (T)"},
          {"input": "btn 3", "outputs": ["key 16"], "note": "Rectangle (M)"},
          {"input": "btn 4", "outputs": ["key 227", "key 29"], "note": "Undo"},
          {"input": "btn 5", "outputs": ["key 227", "key 22"], "note": "Save"},
          {"input": "hat 0 U", "outputs": ["key 227", "key 46"], "note": "Zoom in"},
          {"input": "hat 0 D", "outputs": ["key 227", "key 45"], "note": "Zoom out"}
        ],
        "tips": ["Face buttons are Selection, Pen, Type, and Rectangle tools.", "Bumpers Undo and Save; D-pad zooms."]
      },
      {
        "id": "adobe-after-effects", "category": "app", "displayName": "Adobe After Effects",
        "subtitle": "Transport, tools, undo, save",
        "appPath": "", "launchURL": "",
        "light": {"r": 153, "g": 153, "b": 255},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "btn 0", "outputs": ["key 44"], "note": "Play / Pause (Space)"},
          {"input": "axi 0 -", "outputs": ["key 80"], "note": "Step back one frame"},
          {"input": "axi 0 +", "outputs": ["key 79"], "note": "Step forward one frame"},
          {"input": "btn 1", "outputs": ["key 25"], "note": "Selection tool (V)"},
          {"input": "btn 2", "outputs": ["key 28"], "note": "Hand tool (H)? "},
          {"input": "btn 3", "outputs": ["key 11"], "note": "Hand tool (H)"},
          {"input": "btn 4", "outputs": ["key 227", "key 29"], "note": "Undo"},
          {"input": "btn 5", "outputs": ["key 227", "key 22"], "note": "Save"},
          {"input": "axi 3 +", "outputs": ["whe 1 + 5"], "note": "Scroll down"},
          {"input": "axi 3 -", "outputs": ["whe 1 - 5"], "note": "Scroll up"},
          {"input": "hat 0 L", "outputs": ["key 13"], "note": "Previous keyframe (J)"},
          {"input": "hat 0 R", "outputs": ["key 15"], "note": "Next keyframe (L)"}
        ],
        "tips": ["A plays and pauses; the left stick steps frame by frame.", "Bumpers Undo and Save; D-pad jumps between keyframes."]
      },
      {
        "id": "adobe-lightroom", "category": "app", "displayName": "Adobe Lightroom",
        "subtitle": "Flip photos, rate, flag, zoom",
        "appPath": "", "launchURL": "",
        "light": {"r": 49, "g": 168, "b": 222},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 80"], "note": "Previous photo (Left)"},
          {"input": "axi 0 +", "outputs": ["key 79"], "note": "Next photo (Right)"},
          {"input": "btn 0", "outputs": ["key 79"], "note": "Next photo"},
          {"input": "btn 1", "outputs": ["key 80"], "note": "Previous photo"},
          {"input": "hat 0 U", "outputs": ["key 34"], "note": "5 stars"},
          {"input": "hat 0 D", "outputs": ["key 30"], "note": "1 star"},
          {"input": "hat 0 L", "outputs": ["key 19"], "note": "Flag as pick (P)"},
          {"input": "hat 0 R", "outputs": ["key 27"], "note": "Flag as reject (X)"},
          {"input": "btn 2", "outputs": ["key 7"], "note": "Develop module (D)"},
          {"input": "btn 3", "outputs": ["key 10"], "note": "Library grid (G)"},
          {"input": "btn 4", "outputs": ["key 227", "key 29"], "note": "Undo"},
          {"input": "axi 3 +", "outputs": ["whe 1 + 5"], "note": "Scroll down"},
          {"input": "axi 3 -", "outputs": ["whe 1 - 5"], "note": "Scroll up"}
        ],
        "tips": ["Left stick or face buttons flip between photos.", "D-pad rates and flags; X opens Develop, Y the grid."]
      },
      {
        "id": "davinci-resolve", "category": "app", "displayName": "DaVinci Resolve",
        "subtitle": "Transport, blade, mark, undo, save",
        "appPath": "", "launchURL": "",
        "light": {"r": 50, "g": 140, "b": 160},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "btn 0", "outputs": ["key 44"], "note": "Play / Pause (Space)"},
          {"input": "btn 1", "outputs": ["key 15"], "note": "Play forward (L)"},
          {"input": "btn 2", "outputs": ["key 13"], "note": "Play reverse (J)"},
          {"input": "btn 3", "outputs": ["key 14"], "note": "Pause (K)"},
          {"input": "axi 0 -", "outputs": ["key 80"], "note": "Step back one frame"},
          {"input": "axi 0 +", "outputs": ["key 79"], "note": "Step forward one frame"},
          {"input": "axi 5 +", "outputs": ["key 5"], "note": "Blade (B)"},
          {"input": "axi 4 +", "outputs": ["key 4"], "note": "Selection (A)"},
          {"input": "hat 0 L", "outputs": ["key 12"], "note": "Mark in (I)"},
          {"input": "hat 0 R", "outputs": ["key 18"], "note": "Mark out (O)"},
          {"input": "btn 4", "outputs": ["key 227", "key 29"], "note": "Undo"},
          {"input": "btn 5", "outputs": ["key 227", "key 22"], "note": "Save"}
        ],
        "tips": ["Face buttons are the J K L transport plus the spacebar.", "Right trigger is Blade; D-pad marks in and out."]
      },
      {
        "id": "ableton-live", "category": "app", "displayName": "Ableton Live",
        "subtitle": "Transport, record, scenes, undo",
        "appPath": "", "launchURL": "",
        "light": {"r": 255, "g": 200, "b": 40},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "btn 0", "outputs": ["key 44"], "note": "Play / Stop (Space)"},
          {"input": "btn 1", "outputs": ["key 65"], "note": "Record (F9)"},
          {"input": "btn 2", "outputs": ["key 43"], "note": "Session / Arrangement (Tab)"},
          {"input": "btn 3", "outputs": ["key 40"], "note": "Launch scene (Enter)"},
          {"input": "hat 0 U", "outputs": ["key 82"], "note": "Select up"},
          {"input": "hat 0 D", "outputs": ["key 81"], "note": "Select down"},
          {"input": "hat 0 L", "outputs": ["key 80"], "note": "Select left"},
          {"input": "hat 0 R", "outputs": ["key 79"], "note": "Select right"},
          {"input": "btn 4", "outputs": ["key 227", "key 29"], "note": "Undo"},
          {"input": "btn 5", "outputs": ["key 227", "key 22"], "note": "Save"},
          {"input": "axi 3 +", "outputs": ["whe 1 + 5"], "note": "Scroll down"},
          {"input": "axi 3 -", "outputs": ["whe 1 - 5"], "note": "Scroll up"}
        ],
        "tips": ["A is the spacebar transport; B records, X swaps views.", "D-pad navigates clips; Y launches the selected scene."]
      },
      {
        "id": "notion", "category": "app", "displayName": "Notion",
        "subtitle": "Cursor, scroll, quick find, copy, paste",
        "appPath": "/Applications/Notion.app", "launchURL": "",
        "light": {"r": 120, "g": 120, "b": 120},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 3 +", "outputs": ["whe 1 + 5"], "note": "Scroll down"},
          {"input": "axi 3 -", "outputs": ["whe 1 - 5"], "note": "Scroll up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Click"},
          {"input": "btn 0", "outputs": ["key 227", "key 19"], "note": "Quick find (Cmd+P)"},
          {"input": "btn 1", "outputs": ["key 227", "key 6"], "note": "Copy"},
          {"input": "btn 2", "outputs": ["key 227", "key 25"], "note": "Paste"},
          {"input": "btn 3", "outputs": ["key 227", "key 29"], "note": "Undo"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Close / Esc"}
        ],
        "tips": ["Left stick is the pointer; right stick scrolls the page.", "A opens Quick Find; face buttons copy, paste, and undo."]
      },
      {
        "id": "obsidian", "category": "app", "displayName": "Obsidian",
        "subtitle": "Cursor, scroll, quick switcher, search",
        "appPath": "/Applications/Obsidian.app", "launchURL": "",
        "light": {"r": 130, "g": 80, "b": 220},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 3 +", "outputs": ["whe 1 + 5"], "note": "Scroll down"},
          {"input": "axi 3 -", "outputs": ["whe 1 - 5"], "note": "Scroll up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Click"},
          {"input": "btn 0", "outputs": ["key 227", "key 18"], "note": "Quick switcher (Cmd+O)"},
          {"input": "btn 1", "outputs": ["key 227", "key 17"], "note": "New note (Cmd+N)"},
          {"input": "btn 2", "outputs": ["key 227", "key 226", "key 9"], "note": "Search (Cmd+Shift+F)"},
          {"input": "btn 3", "outputs": ["key 227", "key 8"], "note": "Toggle edit / preview (Cmd+E)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Close / Esc"}
        ],
        "tips": ["A opens the Quick Switcher; B makes a new note.", "X searches the vault; Y toggles edit and preview."]
      },
      {
        "id": "slack", "category": "app", "displayName": "Slack",
        "subtitle": "Cursor, scroll, jump, unreads",
        "appPath": "/Applications/Slack.app", "launchURL": "",
        "light": {"r": 74, "g": 21, "b": 75},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 3 +", "outputs": ["whe 1 + 5"], "note": "Scroll down"},
          {"input": "axi 3 -", "outputs": ["whe 1 - 5"], "note": "Scroll up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Click"},
          {"input": "btn 0", "outputs": ["key 227", "key 14"], "note": "Jump to (Cmd+K)"},
          {"input": "hat 0 U", "outputs": ["key 226", "key 226", "key 82"], "note": "Previous unread"},
          {"input": "hat 0 D", "outputs": ["key 226", "key 226", "key 81"], "note": "Next unread"},
          {"input": "btn 1", "outputs": ["key 227", "key 6"], "note": "Copy"},
          {"input": "btn 2", "outputs": ["key 227", "key 25"], "note": "Paste"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Close / Esc"}
        ],
        "tips": ["A opens Jump To for fast channel switching; right stick scrolls.", "D-pad moves between unread messages."]
      },
      {
        "id": "firefox", "category": "app", "displayName": "Firefox",
        "subtitle": "Cursor, scroll, tabs, back, forward",
        "appPath": "/Applications/Firefox.app", "launchURL": "",
        "light": {"r": 230, "g": 120, "b": 30},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 3 +", "outputs": ["whe 1 + 5"], "note": "Scroll down"},
          {"input": "axi 3 -", "outputs": ["whe 1 - 5"], "note": "Scroll up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Left click"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Right click"},
          {"input": "btn 0", "outputs": ["key 227", "key 80"], "note": "Back"},
          {"input": "btn 1", "outputs": ["key 227", "key 79"], "note": "Forward"},
          {"input": "btn 2", "outputs": ["key 227", "key 21"], "note": "Reload"},
          {"input": "btn 3", "outputs": ["key 227", "key 23"], "note": "New tab"},
          {"input": "btn 4", "outputs": ["key 227", "key 26"], "note": "Close tab"},
          {"input": "btn 5", "outputs": ["key 227", "key 15"], "note": "Address bar"},
          {"input": "hat 0 L", "outputs": ["key 227", "key 226", "key 47"], "note": "Previous tab"},
          {"input": "hat 0 R", "outputs": ["key 227", "key 226", "key 48"], "note": "Next tab"}
        ],
        "tips": ["Left stick moves the pointer; right stick scrolls.", "Face buttons are Back, Forward, Reload, and New Tab."]
      },
      {
        "id": "apple-music", "category": "app", "displayName": "Apple Music",
        "subtitle": "Play, skip, volume, browse",
        "appPath": "/Applications/Music.app", "launchURL": "",
        "light": {"r": 250, "g": 60, "b": 90},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "btn 0", "outputs": ["key 44"], "note": "Play / Pause (Space)"},
          {"input": "btn 1", "outputs": ["key 227", "key 79"], "note": "Next track"},
          {"input": "btn 2", "outputs": ["key 227", "key 80"], "note": "Previous track"},
          {"input": "btn 4", "outputs": ["key 227", "key 82"], "note": "Volume up"},
          {"input": "btn 5", "outputs": ["key 227", "key 81"], "note": "Volume down"},
          {"input": "hat 0 R", "outputs": ["key 227", "key 79"], "note": "Next track"},
          {"input": "hat 0 L", "outputs": ["key 227", "key 80"], "note": "Previous track"},
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 3 +", "outputs": ["whe 1 + 5"], "note": "Scroll down"},
          {"input": "axi 3 -", "outputs": ["whe 1 - 5"], "note": "Scroll up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Click"}
        ],
        "tips": ["A plays and pauses; B and X skip tracks.", "Bumpers change volume; left stick clicks through your library."]
      },
      {
        "id": "terminal-navigation", "category": "workflow", "displayName": "Terminal",
        "subtitle": "Scroll, copy, paste, tabs, interrupt, clear",
        "appPath": "", "launchURL": "",
        "light": {"r": 60, "g": 90, "b": 70},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 3 +", "outputs": ["whe 1 + 5"], "note": "Scroll down"},
          {"input": "axi 3 -", "outputs": ["whe 1 - 5"], "note": "Scroll up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Click"},
          {"input": "btn 0", "outputs": ["key 227", "key 6"], "note": "Copy"},
          {"input": "btn 1", "outputs": ["key 227", "key 25"], "note": "Paste"},
          {"input": "btn 2", "outputs": ["key 227", "key 23"], "note": "New tab"},
          {"input": "btn 3", "outputs": ["key 227", "key 14"], "note": "Clear (Cmd+K)"},
          {"input": "btn 4", "outputs": ["key 224", "key 6"], "note": "Interrupt (Ctrl+C)"},
          {"input": "hat 0 L", "outputs": ["key 227", "key 226", "key 47"], "note": "Previous tab"},
          {"input": "hat 0 R", "outputs": ["key 227", "key 226", "key 48"], "note": "Next tab"}
        ],
        "tips": ["Face buttons copy, paste, new tab, and clear; left bumper sends Ctrl+C.", "Right stick scrolls back through output."]
      },
      {
        "id": "map-navigation", "category": "workflow", "displayName": "Maps Navigation",
        "subtitle": "Pan, zoom, and click in Maps",
        "appPath": "", "launchURL": "",
        "light": {"r": 70, "g": 170, "b": 110},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["key 80"], "note": "Pan left"},
          {"input": "axi 0 +", "outputs": ["key 79"], "note": "Pan right"},
          {"input": "axi 1 -", "outputs": ["key 82"], "note": "Pan up"},
          {"input": "axi 1 +", "outputs": ["key 81"], "note": "Pan down"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 3 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 3 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Click"},
          {"input": "btn 4", "outputs": ["key 227", "key 45"], "note": "Zoom out"},
          {"input": "btn 5", "outputs": ["key 227", "key 46"], "note": "Zoom in"},
          {"input": "btn 0", "outputs": ["key 227", "key 9"], "note": "Search (Cmd+F)"},
          {"input": "btn 9", "outputs": ["key 41"], "note": "Close / Esc"}
        ],
        "tips": ["Left stick pans the map; right stick moves the pointer to click pins.", "Bumpers zoom in and out; A opens search."]
      },
      {
        "id": "drawing-tablet", "category": "workflow", "displayName": "Drawing & Painting",
        "subtitle": "Cursor, draw, brush size, undo (any art app)",
        "appPath": "", "launchURL": "",
        "light": {"r": 230, "g": 100, "b": 170},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["mou 0 - 10"], "note": "Cursor left (precise)"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 10"], "note": "Cursor right (precise)"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 10"], "note": "Cursor up (precise)"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 10"], "note": "Cursor down (precise)"},
          {"input": "axi 2 -", "outputs": ["mou 0 - 26"], "note": "Cursor left (fast)"},
          {"input": "axi 2 +", "outputs": ["mou 0 + 26"], "note": "Cursor right (fast)"},
          {"input": "axi 3 -", "outputs": ["mou 1 - 26"], "note": "Cursor up (fast)"},
          {"input": "axi 3 +", "outputs": ["mou 1 + 26"], "note": "Cursor down (fast)"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Draw (hold)"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Right click"},
          {"input": "btn 0", "outputs": ["key 227", "key 29"], "note": "Undo"},
          {"input": "btn 1", "outputs": ["key 227", "key 226", "key 29"], "note": "Redo"},
          {"input": "btn 4", "outputs": ["key 47"], "note": "Brush smaller ([)"},
          {"input": "btn 5", "outputs": ["key 48"], "note": "Brush larger (])"},
          {"input": "btn 2", "outputs": ["key 8"], "note": "Eraser (E)"},
          {"input": "btn 3", "outputs": ["key 5"], "note": "Brush (B)"},
          {"input": "btn 9", "outputs": ["key 227", "key 22"], "note": "Save"}
        ],
        "tips": ["Hold the right trigger to draw; left stick is precise, right stick is fast.", "Bumpers change brush size; B and E switch brush and eraser."]
      },
      {
        "id": "video-editor-transport", "category": "workflow", "displayName": "Video Editor Transport",
        "subtitle": "Play, scrub, blade, mark in/out (any editor)",
        "appPath": "", "launchURL": "",
        "light": {"r": 150, "g": 150, "b": 170},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "btn 0", "outputs": ["key 44"], "note": "Play / Pause (Space)"},
          {"input": "btn 1", "outputs": ["key 15"], "note": "Play forward (L)"},
          {"input": "btn 2", "outputs": ["key 13"], "note": "Play reverse (J)"},
          {"input": "btn 3", "outputs": ["key 14"], "note": "Pause (K)"},
          {"input": "axi 0 -", "outputs": ["key 80"], "note": "Step back one frame"},
          {"input": "axi 0 +", "outputs": ["key 79"], "note": "Step forward one frame"},
          {"input": "axi 5 +", "outputs": ["key 5"], "note": "Blade / split (B)"},
          {"input": "axi 4 +", "outputs": ["key 25"], "note": "Selection (V)"},
          {"input": "hat 0 L", "outputs": ["key 12"], "note": "Mark in (I)"},
          {"input": "hat 0 R", "outputs": ["key 18"], "note": "Mark out (O)"},
          {"input": "btn 4", "outputs": ["key 227", "key 29"], "note": "Undo"},
          {"input": "btn 5", "outputs": ["key 227", "key 22"], "note": "Save"},
          {"input": "axi 3 +", "outputs": ["whe 1 + 5"], "note": "Scroll down"},
          {"input": "axi 3 -", "outputs": ["whe 1 - 5"], "note": "Scroll up"}
        ],
        "tips": ["Works with editors that use J K L and the I or O marks.", "Right trigger blades; D-pad marks in and out."]
      },
      {
        "id": "daw-transport", "category": "workflow", "displayName": "Music Studio Transport",
        "subtitle": "Play, record, return, undo (any DAW)",
        "appPath": "", "launchURL": "",
        "light": {"r": 200, "g": 170, "b": 60},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "btn 0", "outputs": ["key 44"], "note": "Play / Stop (Space)"},
          {"input": "btn 1", "outputs": ["key 21"], "note": "Record (R)"},
          {"input": "btn 2", "outputs": ["key 40"], "note": "Return to start (Enter)"},
          {"input": "btn 3", "outputs": ["key 6"], "note": "Cycle / loop (C)"},
          {"input": "axi 0 -", "outputs": ["key 80"], "note": "Rewind (Left)"},
          {"input": "axi 0 +", "outputs": ["key 79"], "note": "Forward (Right)"},
          {"input": "btn 4", "outputs": ["key 227", "key 29"], "note": "Undo"},
          {"input": "btn 5", "outputs": ["key 227", "key 22"], "note": "Save"},
          {"input": "axi 3 +", "outputs": ["whe 1 + 5"], "note": "Scroll down"},
          {"input": "axi 3 -", "outputs": ["whe 1 - 5"], "note": "Scroll up"},
          {"input": "hat 0 U", "outputs": ["key 227", "key 46"], "note": "Zoom in"},
          {"input": "hat 0 D", "outputs": ["key 227", "key 45"], "note": "Zoom out"}
        ],
        "tips": ["A is the spacebar transport; B records, X returns to start.", "Bumpers Undo and Save; D-pad zooms the timeline."]
      },
      {
        "id": "zoom-magnifier", "category": "workflow", "displayName": "Screen Zoom",
        "subtitle": "macOS screen magnifier: zoom in, out, toggle",
        "appPath": "", "launchURL": "",
        "light": {"r": 50, "g": 150, "b": 220},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "btn 0", "outputs": ["key 226", "key 227", "key 46"], "note": "Zoom in (Opt+Cmd+=)"},
          {"input": "btn 1", "outputs": ["key 226", "key 227", "key 45"], "note": "Zoom out (Opt+Cmd+-)"},
          {"input": "btn 2", "outputs": ["key 226", "key 227", "key 37"], "note": "Toggle zoom (Opt+Cmd+8)"},
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Click"}
        ],
        "tips": ["Enable Zoom in System Settings, Accessibility, Zoom for these to work.", "A and B zoom in and out; X toggles the magnifier."]
      },
      {
        "id": "video-watching", "category": "workflow", "displayName": "Video Watching",
        "subtitle": "Play, seek, fullscreen, volume (YouTube, etc.)",
        "appPath": "", "launchURL": "",
        "light": {"r": 220, "g": 40, "b": 40},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "btn 0", "outputs": ["key 44"], "note": "Play / Pause (Space)"},
          {"input": "btn 1", "outputs": ["key 9"], "note": "Fullscreen (F)"},
          {"input": "btn 2", "outputs": ["key 16"], "note": "Mute (M)"},
          {"input": "btn 3", "outputs": ["key 6"], "note": "Captions (C)"},
          {"input": "axi 0 -", "outputs": ["key 80"], "note": "Seek back (Left)"},
          {"input": "axi 0 +", "outputs": ["key 79"], "note": "Seek forward (Right)"},
          {"input": "btn 4", "outputs": ["key 13"], "note": "Back 10s (J)"},
          {"input": "btn 5", "outputs": ["key 15"], "note": "Forward 10s (L)"},
          {"input": "hat 0 U", "outputs": ["key 82"], "note": "Volume up"},
          {"input": "hat 0 D", "outputs": ["key 81"], "note": "Volume down"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Click"}
        ],
        "tips": ["A plays and pauses, B is fullscreen; left stick seeks.", "Bumpers jump 10 seconds; D-pad changes volume."]
      },
      {
        "id": "social-media-scroll", "category": "workflow", "displayName": "Social Feed Scroll",
        "subtitle": "Scroll feeds, click, back, refresh",
        "appPath": "", "launchURL": "",
        "light": {"r": 90, "g": 140, "b": 230},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 1 +", "outputs": ["whe 1 + 5"], "note": "Scroll down"},
          {"input": "axi 1 -", "outputs": ["whe 1 - 5"], "note": "Scroll up"},
          {"input": "axi 3 +", "outputs": ["whe 1 + 9"], "note": "Scroll down (fast)"},
          {"input": "axi 3 -", "outputs": ["whe 1 - 9"], "note": "Scroll up (fast)"},
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Click"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Right click"},
          {"input": "btn 0", "outputs": ["mbt 0"], "note": "Click"},
          {"input": "btn 1", "outputs": ["key 227", "key 80"], "note": "Back"},
          {"input": "btn 2", "outputs": ["key 227", "key 21"], "note": "Refresh"},
          {"input": "hat 0 U", "outputs": ["key 227", "key 82"], "note": "Top of page"},
          {"input": "hat 0 D", "outputs": ["key 227", "key 81"], "note": "Bottom of page"}
        ],
        "tips": ["Left stick scrolls smoothly, right stick scrolls fast.", "A or right trigger clicks; B goes back, X refreshes."]
      },
      {
        "id": "text-editing", "category": "workflow", "displayName": "Text Editing",
        "subtitle": "Cursor, arrows, select, copy, paste, word nav",
        "appPath": "", "launchURL": "",
        "light": {"r": 120, "g": 160, "b": 120},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Click"},
          {"input": "hat 0 U", "outputs": ["key 82"], "note": "Up arrow"},
          {"input": "hat 0 D", "outputs": ["key 81"], "note": "Down arrow"},
          {"input": "hat 0 L", "outputs": ["key 80"], "note": "Left arrow"},
          {"input": "hat 0 R", "outputs": ["key 79"], "note": "Right arrow"},
          {"input": "btn 0", "outputs": ["key 227", "key 6"], "note": "Copy"},
          {"input": "btn 1", "outputs": ["key 227", "key 25"], "note": "Paste"},
          {"input": "btn 2", "outputs": ["key 227", "key 29"], "note": "Undo"},
          {"input": "btn 3", "outputs": ["key 227", "key 4"], "note": "Select all"},
          {"input": "btn 4", "outputs": ["key 226", "key 80"], "note": "Word left (Opt+Left)"},
          {"input": "btn 5", "outputs": ["key 226", "key 79"], "note": "Word right (Opt+Right)"}
        ],
        "tips": ["D-pad is the arrow keys; left stick is the pointer.", "Face buttons copy, paste, undo, and select all; bumpers jump by word."]
      },
      {
        "id": "one-handed-cursor", "category": "workflow", "displayName": "One-Handed Cursor",
        "subtitle": "Full pointer, clicks, and scroll from one side",
        "appPath": "", "launchURL": "",
        "light": {"r": 40, "g": 160, "b": 200},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["mou 0 - 14"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 14"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 14"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 14"], "note": "Cursor down"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Left click"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Right click"},
          {"input": "btn 0", "outputs": ["mbt 0"], "note": "Left click"},
          {"input": "btn 1", "outputs": ["mbt 1"], "note": "Right click"},
          {"input": "btn 2", "outputs": ["mbt 2"], "note": "Middle click"},
          {"input": "btn 3", "outputs": ["key 40"], "note": "Return"},
          {"input": "hat 0 U", "outputs": ["whs 1 -"], "note": "Scroll up"},
          {"input": "hat 0 D", "outputs": ["whs 1 +"], "note": "Scroll down"},
          {"input": "hat 0 L", "outputs": ["whs 0 -"], "note": "Scroll left"},
          {"input": "hat 0 R", "outputs": ["whs 0 +"], "note": "Scroll right"},
          {"input": "btn 8", "outputs": ["key 227", "key 44"], "note": "Spotlight"}
        ],
        "tips": ["Everything you need is on the left side: stick moves, triggers click.", "D-pad scrolls in any direction; A, B, X are the three clicks."]
      },
      {
        "id": "web-research", "category": "workflow", "displayName": "Web Research",
        "subtitle": "Tabs, scroll, find, back, forward, new tab",
        "appPath": "", "launchURL": "",
        "light": {"r": 80, "g": 150, "b": 210},
        "confineCursor": false, "autoRecenter": false, "hideCursor": false,
        "bindings": [
          {"input": "axi 0 -", "outputs": ["mou 0 - 16"], "note": "Cursor left"},
          {"input": "axi 0 +", "outputs": ["mou 0 + 16"], "note": "Cursor right"},
          {"input": "axi 1 -", "outputs": ["mou 1 - 16"], "note": "Cursor up"},
          {"input": "axi 1 +", "outputs": ["mou 1 + 16"], "note": "Cursor down"},
          {"input": "axi 3 +", "outputs": ["whe 1 + 5"], "note": "Scroll down"},
          {"input": "axi 3 -", "outputs": ["whe 1 - 5"], "note": "Scroll up"},
          {"input": "axi 5 +", "outputs": ["mbt 0"], "note": "Left click"},
          {"input": "axi 4 +", "outputs": ["mbt 1"], "note": "Right click"},
          {"input": "btn 0", "outputs": ["key 227", "key 80"], "note": "Back"},
          {"input": "btn 1", "outputs": ["key 227", "key 79"], "note": "Forward"},
          {"input": "btn 2", "outputs": ["key 227", "key 9"], "note": "Find on page"},
          {"input": "btn 3", "outputs": ["key 227", "key 23"], "note": "New tab"},
          {"input": "btn 4", "outputs": ["key 227", "key 26"], "note": "Close tab"},
          {"input": "btn 5", "outputs": ["key 227", "key 15"], "note": "Address bar"},
          {"input": "hat 0 L", "outputs": ["key 227", "key 226", "key 47"], "note": "Previous tab"},
          {"input": "hat 0 R", "outputs": ["key 227", "key 226", "key 48"], "note": "Next tab"}
        ],
        "tips": ["Works in any browser; face buttons are Back, Forward, Find, New Tab.", "D-pad switches tabs; right stick scrolls the page."]
      }
    ]
    """
}

/// Turns a `SmartPresetProfile` plus the user's chosen controller into a
/// ready-to-use `Preset`, with controller-aware button labels and built-in
/// setup guidance. Reuses the legacy-JSON preset path so it integrates with
/// every existing subsystem (light bar, automation, touchpad, calibration).
enum SmartPresetGenerator {
    struct Options {
        var name: String
        var groupID: UUID?
        var autoLaunchApp: Bool
        var appPathOverride: String?
        var confineCursor: Bool
        var autoRecenter: Bool
        var hideCursor: Bool
        var lightColor: SmartPresetProfile.Light?
    }

    static func makePreset(from profile: SmartPresetProfile,
                           brand: ControllerBrand,
                           options: Options) -> Preset {
        // Build the bindings directly (rather than via the legacy-JSON path)
        // so each row carries its own per-binding note from the profile. The
        // note is what shows in the editor under each input, so people see
        // what every control does without a giant info dump in the notes box.
        var bindingModels: [BindingModel] = []
        for b in profile.bindings {
            guard let input = InputEvent.parse(b.input) else { continue }
            let outputs = b.outputs.compactMap { OutputAction.parse($0) }
            guard !outputs.isEmpty else { continue }
            var bm = BindingModel(input: input, outputs: outputs)
            let trimmed = b.note.trimmingCharacters(in: .whitespacesAndNewlines)
            bm.note = trimmed.isEmpty ? nil : trimmed
            bindingModels.append(bm)
        }
        let slot = JoystickMapping(tag: slotGuide(for: profile, brand: brand),
                                   bindings: bindingModels)
        var preset = Preset(name: options.name, tag: profile.subtitle,
                            joysticks: [slot], filename: Preset.generateFilename())
        preset.sortBindings()
        preset.groupID = options.groupID

        var auto = PresetAutomation()
        if options.autoLaunchApp {
            auto.launchAppPath = options.appPathOverride ?? profile.appPath
            auto.launchURL = profile.launchURL
        }
        auto.confineCursor = options.confineCursor
        auto.confineBufferPx = 24
        auto.autoRecenterCursor = options.autoRecenter
        auto.autoRecenterIntervalMs = 250
        auto.hideCursorWhileActive = options.hideCursor
        preset.automation = auto

        // Only carry a light-bar color for controllers that actually have one
        // (Sony pads). Other controllers ignore it, so we leave it unset.
        if brand.hasLightBar {
            let light = options.lightColor ?? profile.light
            preset.lightBarColor = RGBLightColor(r: UInt8(clamping: light.r),
                                                 g: UInt8(clamping: light.g),
                                                 b: UInt8(clamping: light.b))
            preset.lightBarBrightness = 2
        }
        preset.notes = buildNotes(for: profile, brand: brand)
        return preset
    }

    /// Compact "Label = action" summary for the slot subtitle.
    private static func slotGuide(for profile: SmartPresetProfile, brand: ControllerBrand) -> String {
        profile.bindings.prefix(6)
            .map { "\(label(for: $0.input, brand: brand)) = \($0.note)" }
            .joined(separator: ", ")
    }

    /// Short setup guidance baked into `preset.notes`. The per-control detail
    /// now lives on each binding row (each row has its own note), so this stays
    /// concise: a one-line intro, the first-run scan reminder, any hardware
    /// extras, and the profile's tips. No giant per-button dump.
    private static func buildNotes(for profile: SmartPresetProfile, brand: ControllerBrand) -> String {
        var out = "Smart preset for \(profile.displayName) on \(brand.displayName).\n"
        out += "What each control does is noted right on its row in the binding editor. "
        out += "If something doesn't respond, open the editor and use Scan to remap it (controllers vary).\n"
        if brand.hasMotion || brand.hasTouchpad {
            out += "\nYour \(brand.displayName) extras: \(brand.capabilitySummary).\n"
            if brand.hasMotion {
                out += "Motion: add a gyro fine-aim binding, then run Help, Calibrate Motion / Gyro.\n"
            }
            if brand.hasTouchpad {
                out += "Touchpad: add a Touchpad binding to use it as a trackpad.\n"
            }
        }
        if !profile.tips.isEmpty {
            out += "\nTips:\n" + profile.tips.map { "- \($0)" }.joined(separator: "\n")
        }
        return out
    }

    /// Translate a serialized input ("btn 0", "axi 2 +", "hat 0 U") into the
    /// physical control label for the chosen controller brand.
    static func label(for input: String, brand: ControllerBrand) -> String {
        let parts = input.split(separator: " ").map(String.init)
        guard let kind = parts.first else { return input }
        switch kind {
        case "btn":
            return buttonLabel(Int(parts.count > 1 ? parts[1] : "") ?? -1, brand: brand)
        case "axi":
            return axisLabel(Int(parts.count > 1 ? parts[1] : "") ?? -1, brand: brand)
        case "hat":
            return "D-pad " + dpadDir(parts.count > 2 ? parts[2] : "")
        default:
            return input
        }
    }

    private static func buttonLabel(_ index: Int, brand: ControllerBrand) -> String {
        let nintendo = brand.usesNintendoLayout
        let ps = (brand == .dualSense || brand == .dualShock4)
        switch index {
        case 0:  return nintendo ? "B" : (ps ? "Cross" : "A")
        case 1:  return nintendo ? "A" : (ps ? "Circle" : "B")
        case 2:  return nintendo ? "Y" : (ps ? "Square" : "X")
        case 3:  return nintendo ? "X" : (ps ? "Triangle" : "Y")
        case 4:  return ps ? "L1" : (nintendo ? "L" : "LB")
        case 5:  return ps ? "R1" : (nintendo ? "R" : "RB")
        case 6:  return ps ? "L2" : (nintendo ? "ZL" : "LT")
        case 7:  return ps ? "R2" : (nintendo ? "ZR" : "RT")
        case 8:  return ps ? "Share" : (nintendo ? "Minus" : "View")
        case 9:  return ps ? "Options" : (nintendo ? "Plus" : "Menu")
        case 10: return ps ? "PS" : (nintendo ? "Home" : "Guide")
        case 11: return "Left stick click (L3)"
        case 12: return "Right stick click (R3)"
        case 13: return "Touchpad"
        default: return "Button \(index)"
        }
    }

    private static func axisLabel(_ index: Int, brand: ControllerBrand) -> String {
        switch index {
        case 0, 1: return "Left stick"
        case 2, 3: return "Right stick"
        case 4:    return buttonLabel(6, brand: brand)
        case 5:    return buttonLabel(7, brand: brand)
        default:   return "Axis \(index)"
        }
    }

    private static func dpadDir(_ d: String) -> String {
        switch d {
        case "U": return "Up"
        case "D": return "Down"
        case "L": return "Left"
        case "R": return "Right"
        default:  return d
        }
    }
}
