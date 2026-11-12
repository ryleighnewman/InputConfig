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
        "Easy Browse":                   GroupName.desktop,
        "Easy Edit":                     GroupName.desktop,
        "Desktop Navigation":            GroupName.desktop,
        "Web Browsing":                  GroupName.desktop,
        "Mouse + Scroll":                GroupName.desktop,
        "Media Controller":              GroupName.desktop,
        "Presentation Remote":           GroupName.desktop,
        "Anki":                          GroupName.desktop,
        "Access Controller":             GroupName.desktop,
        "Trackpad & Mouse":              GroupName.desktop,
        "Modifier Holds":                GroupName.desktop,
        "Double Click Deck":             GroupName.desktop,
        "Auto Clicker":                  GroupName.desktop,

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
        "MIDI: Knob Deck":               GroupName.midi,
        "MIDI: Media Deck":              GroupName.midi,

        "Variable Sensitivity":   GroupName.showcase,
        "Deadzone Calibration":   GroupName.showcase,
        "Haptic Feedback":        GroupName.showcase,
        "Spoken Feedback":        GroupName.showcase,
        "Macros & Turbo":         GroupName.showcase,
        "Touchpad Mouse":         GroupName.showcase,
        "Steam Controller":       GroupName.showcase,
        "Steam Controller (2026)": GroupName.showcase,
        "Gyro Aim":               GroupName.showcase,
        "Motion Cursor":          GroupName.showcase,
        "Toggle Mode":            GroupName.showcase,
        "One-Stick Driving":      GroupName.showcase,
        "Stacked Outputs":        GroupName.showcase,
        "Tap the Mac":            GroupName.showcase,
        "Voice Commands":         GroupName.showcase,
        "Touchpad Zones":         GroupName.showcase,
        "Cursor Regions":         GroupName.showcase,
        "Stick Zones & Gestures": GroupName.showcase,
        "Hold & Double-Tap":      GroupName.showcase,
        "Keyboard & Mouse Input": GroupName.showcase,
        "Shortcuts & Apps":       GroupName.showcase,
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

    // MARK: - Notes for the shipped presets

    /// The Notes text for each shipped preset, by name: what the layout does,
    /// button by button, and any Mac setting it depends on. Applied when a
    /// preset is seeded and, once, to installs whose copy has empty notes.
    static let presetNotes: [String: String] = [
        "Easy Browse": "A calm, ready-made way to use the whole Mac from a controller: browse, read, and write without the keyboard. The left stick moves the pointer and starts slow, so small targets are easy to land on; the right stick scrolls. A clicks, B goes back a page, X closes menus and pop-ups, Y confirms or opens.\n\nPress the left stick to grab (a window, a file, or text to select) and again to drop it; press the right stick for a double click. Both give a short buzz so you know the press counted. LB starts Dictation and stops it, RB reads the selected text aloud, Start or the touchpad opens Spotlight, Back shows Mission Control. On the D-pad, left and right go back and forward a web page, down and up switch tabs; it counts one direction at a time, so a quick press cannot fire the one next to it. Other apps may use those keys for something else.\n\nThe face buttons say their names out loud while you learn them; switch that off in each row's Options. Dictation needs to be on in System Settings > Keyboard, and reading aloud needs Speak selection on in System Settings > Accessibility > Spoken Content.",
        "Easy Edit": "A calm layout for writing and editing, made for a controller in one hand and a mouse or trackpad in the other. Every button does one thing, and the ones used most stay under the thumb.\n\nThe D-pad holds the four editing shortcuts together, the way they sit together on a keyboard: up Undo, down Copy, left Cut, right Paste. It counts one direction at a time, so a quick press cannot fire the one next to it. A deletes, B saves, X types a space, Y is Return. Push the left stick down to hear the selected text read aloud, or up, firmly, to start Dictation; push up again to stop. The right stick scrolls.\n\nLT and LB go back and forward a web page, RT and RB switch to the previous and next tab. Back jumps to the browser's address bar, Start opens Spotlight, and a press on the left stick or the touchpad shows Mission Control. The left stick press gives a firm buzz so you know it counted.\n\nThe face buttons and the D-pad say their names out loud while you learn them; switch that off in each row's Options. Dictation needs to be on in System Settings > Keyboard, and reading aloud needs Speak selection on in System Settings > Accessibility > Spoken Content.",
        "Anki": "A flashcard session from the pad. Cross shows the answer and rates Good, Square is Again, Circle is Hard, Triangle is Easy, so one thumb runs a whole review. L1 undoes a mis-rating, R1 replays the audio, Share opens the deck list, Options starts studying, the stick clicks mark and bury a card, and the touchpad press edits it.\n\nThe left stick is the pointer, the right stick scrolls, the triggers click, and the D-pad sends the arrow keys for long cards and lists. Anki's shortcuts are its defaults; if you have changed them in Anki, change the matching row here.",
        "Modifier Holds": "The right-hand modifier keys, held on their own, run the Mac: hold Right Command for Spotlight (double tap it for Launchpad), hold Right Option to start Dictation, hold Right Shift for Mission Control.\n\nNo row fires on a plain press, so Command, Option, and Shift keep working as modifiers in every shortcut. The hold is 450 ms and the double tap window 300 ms; open a row's Options to change either.",
        "Auto Clicker": "An auto clicker for the Mac, from a controller, the keyboard, or a mouse. Pull the right trigger once and the left button clicks 10 times a second where the pointer is, until you pull it again; the left trigger does the same with right clicks, 5 a second. Hold the right bumper for 20 clicks a second only while held. Y clicks 100 times and stops by itself, and X clicks at an uneven, human pace (150 ms, give or take 40). The left stick moves the pointer and A clicks once, so you can aim without a mouse.\n\nNo controller needed: fn F6 starts and stops left clicks, fn F7 right clicks, and holding a mouse's side button 4 clicks 15 times a second.\n\nChange the speed in a row's Options, under How it fires: Every, Vary by up to, and Stop after. To stop everything at once, use the emergency stop.",
        "Double Click Deck": "Double clicks as inputs. Double click a mouse's side button 4 for Mission Control, side button 5 for Launchpad, or the middle button for Spotlight. A single click on each keeps doing what it always did, because a double click is only counted on the second click.\n\nOn a trackpad with tap to click on, a double tap is a double click too.",
        "Trackpad & Mouse": "The Mac's trackpad or mouse as an input. The two side buttons on a mouse go back and forward, the middle click opens Mission Control, and a force click on the trackpad opens Launchpad.\n\nForce Touch is read only while InputConfig is the front window, because macOS gives trackpad force to the front app alone; the buttons work from any app. Watch the Live Visualizer's Mouse and Trackpad template to see each click, scroll, and press as it happens.",
        "Deadzone Calibration": "A showcase for deadzones. Both sticks move the pointer; the right stick has a wide inner deadzone and an outer limit, the left stick a tight one. Move each and feel the difference, then open a stick row's Options and use Adjust live to set your own while you watch the stick. A clicks.",
        "Desktop Navigation": "A pointer and the everyday shortcuts, for using the Mac without touching the keyboard. Left stick moves the pointer, right stick scrolls, right trigger clicks, left trigger right-clicks, the D-pad sends the arrow keys.\n\nFace buttons: A clicks (so does the right trigger), B undoes, X cuts, Y pastes. Press the right stick to select all. Bumpers switch apps, Back opens Spotlight, Start is Return. For copy, add a row for Cmd C or change B.\n\nNo Mac settings needed beyond the Accessibility permission the app asks for.",
        "FPS (8BitDo)": "The first-person layout tuned for 8BitDo pads in the mode 8BitDo lists for Apple devices (D on models with a mode switch). Left stick moves, right stick looks, right trigger fires, left trigger aims. The bottom face button jumps, the right one is C for crouch, the left one reloads, the top one is slot 1 (8BitDo prints these letters either way, so Face button names in Settings decides what they are called). L1 is slot 4, R1 middle-clicks. D-pad up and down scroll weapons, left is Q, right is F. Left stick click sprints, right stick click sends E. Select is Tab, Start is Escape.\n\nSet the mode switch on the back to D before pairing; the SN30 Pro family has no switch, so hold B and Start to turn it on.",
        "FPS (PS5 DualSense)": "A first-person layout for games with no controller support. Left stick moves, right stick looks, R2 fires, L2 aims. Cross jumps, Circle crouches with Control, Square reloads, Triangle is slot 1. L1 is slot 4, R1 middle-clicks. D-pad up and down scroll weapons, left is Q, right is F. L3 sprints with Shift, R3 uses with E. The touchpad press opens the map with M. Share is Tab, Options is Escape.\n\nThe touchpad can also be a trackpad; see the Touchpad Mouse preset.",
        "FPS (Switch Pro)": "The same first-person layout with Nintendo button positions: B (bottom) jumps, A (right) is C for crouch, Y (left) reloads, X (top) is slot 1. Left stick moves, right stick looks, ZR fires, ZL aims. L is slot 4, R middle-clicks. D-pad up and down scroll weapons, left is Q, right is F. Left stick click sprints, right stick click sends E. Minus is Tab, Plus is Escape.",
        "FPS (Xbox)": "A first-person layout for games with no controller support. Left stick moves, right stick looks, right trigger fires, left trigger aims. A jumps, B is C for crouch, X reloads, Y is slot 1. LB is slot 4, RB middle-clicks. D-pad up and down scroll weapons, left is Q, right is F. Left stick click sprints with Shift, right stick click sends E. View is Tab, Menu is Escape.",
        "Fortnite": "For cloud streams (Xbox Cloud Gaming, GeForce NOW) that do not see the pad. Left stick moves, right stick looks, right trigger fires, left trigger aims. A jumps, B crouches, X reloads, Y uses. Bumpers place a wall and a floor, D-pad places stairs and a roof, sets a trap, and opens the map. Left stick click sprints, right stick click edits. Back is the inventory, Start is Escape.",
        "Haptic Feedback": "A showcase for Vibrate. Each face button types its letter (A, B, C, D) and rumbles, stronger from A to D. Vibrate is an option on every row, with an intensity and a duration, on controllers with rumble.",
        "MIDI: CC Dials": "The sticks and triggers as soft MIDI controllers on channel 1: the left stick pushed left or right sends CC 1 and pushed down sends CC 11, the right stick pushed right sends CC 74 and pushed down sends CC 71, and the triggers send CC 7 and CC 10. Use MIDI Learn in any synth or DAW to grab one.",
        "MIDI: DAW Performance": "A MIDI instrument from the controller, through InputConfig's virtual MIDI port. Face buttons play a C major chord (C, E, G, C), right stick bends pitch, and pushed down adds modulation, right trigger is volume (CC 7), left trigger is expression (CC 11). D-pad up starts, down stops, right continues the transport.\n\nIn GarageBand or Logic, pick InputConfig as the MIDI input on a software instrument track.",
        "MIDI: Drum Pad": "Finger drumming from the face buttons on channel 10: kick, snare, closed hat, open hat, with turbo for rolls while held; the triggers hit a low tom and a crash. Each pad vibrates. Point a drum instrument in your DAW at InputConfig's MIDI port.",
        "MIDI: Knob Deck": "A MIDI controller runs the Mac. CC 7 (a fader) is the Mac's volume, a center-detent pan knob (CC 10) scrolls, CC 71 turned sends the arrow keys, the sustain pedal clicks, pads 36 and 37 send Return and Escape. Rows listen to any MIDI device; to tie a row to one device, pick it from the row's input menu.",
        "MIDI: Media Deck": "A MIDI controller as a media remote. CC 7 is the Mac's volume fader, CC 71 steps volume, CC 74 steps brightness, pads 36 to 41 are play, next, previous, mute, Mission Control, and an app. Rows listen to any MIDI device; to tie a row to one device, pick it from the row's input menu.",
        "MIDI: Transport Control": "A DAW remote over MIDI. A starts, B stops, X continues (MIDI transport messages), the bumpers select patch 1 and patch 2 with program changes, D-pad up and down send CC 20 and CC 21 to learn as volume up and down. Map them in your DAW's control surface or MIDI Learn settings.",
        "Macros & Turbo": "A showcase for macros and turbo. RB repeats Space rapidly while held (turbo). A runs a macro: copy, switch app, paste. Y runs a macro: down three items, then Return. X runs a recorded style macro at double speed: types gg, Return, waits, then Command V. Down, Down, B pressed in order is a button sequence that sends Space. LB sends J three times (Repeat). Turbo, macros, Record steps, Play once and Repeat are options on every row.",
        "Media Controller": "A remote for Music, Spotify, VLC, the TV app, and YouTube in a browser: it sends the Mac's own media keys, so it works whichever app is playing.\n\nA plays and pauses, B skips forward, X skips back, Y mutes. The bumpers, and up and down on the D-pad and the left stick, change the volume; left and right on them skip tracks. Back is Escape for leaving full screen.",
        "Minecraft": "Java Edition, which has no controller support of its own. Left stick walks (WASD), right stick looks (mouse), right trigger mines and attacks, left trigger places and uses. A jumps, B sneaks, X opens the inventory, Y drops. Bumpers scroll the hotbar, D-pad picks hotbar slots 1 to 4, left stick click sprints, right stick click swaps hands.\n\nIf the camera creeps, raise the deadzone on the right stick rows. Look speed is the Speed value on those rows.",
        "Motion Cursor": "Point the controller like a laser pointer: tilt it and the pointer follows the tilt, so tilting back to level puts the pointer back where it started. Works on the DualSense, DualSense Edge, DualShock 4, and the 2026 Steam Controller (experimental). Cross clicks, Circle right-clicks, Triangle is Return, right stick scrolls (on the Steam Controller: A, B, and Y).\n\nR1 makes the controller's current tilt the new neutral and puts the pointer in the middle of the screen. Hold L1 to move the controller without moving the pointer, the way you lift a mouse off the desk. The gyro zero looks after itself while the controller rests; Calibrate Motion in a row's Options is there if you want to set it by hand.",
        "Mouse + Scroll": "The plain pointer preset. Left stick moves the pointer, right stick scrolls, D-pad nudges the pointer slowly for small targets. A clicks, B right-clicks, X middle-clicks.\n\nIf the pointer drifts on its own, raise the Deadzone in the stick row's Options (Adjust live shows the stick as you set it). If it feels too fast or too slow, change Speed on the stick rows.",
        "Presentation Remote": "Keynote, PowerPoint, and Google Slides. A goes to the next slide, B to the previous one, X starts or advances with Space, Y blanks the screen (B in Keynote and PowerPoint). Left stick moves the pointer for a laser-pointer effect, bumpers click. Back is Escape to leave the show, Start sends F5 to start a PowerPoint show.",
        "One-Stick Driving": "The whole car from one joystick, for the PlayStation Access Controller, the Xbox Adaptive Controller, or any single stick. The stick is not bound to rows here: the One-Stick Driving section at the bottom of this editor owns it. Push forward to accelerate, pull back to brake, left and right to steer, and snap the stick back twice to shift into Reverse (push forward to shift back to Drive). Let go and the car slows on its own, the way a power chair stops when you release the stick.\n\nEverything about the driving lives in that section: which stick and controller slot, the deadzone, the steering and throttle curves, keys or mouse steering, the coast brake, and the reverse gesture. Use the Test Drive arena to feel a change before you race. The rows cover the buttons: handbrake, horn, boost, reset, gears, camera, and rewind. On an Access Controller's base profile only Cross (the center button), Circle (socket 5) and Options (socket 7) send; give the other sockets buttons in a profile made on a PS5. Change the letters on each row to match the game's own key list.",
        "Racing Game": "Any racing game that takes keyboard input. Left stick steers with A and D, right trigger is the throttle (W), left trigger the brake (S). A is the handbrake, B shifts up with Shift, X sends E, Y sends R for reset, bumpers send Q and F. Right stick looks around. Back is Tab, Start is Escape.\n\nChange the letters on each row to match the game's own key list; most racers let you rebind.",
        "Spoken Feedback": "A showcase for Speak. Each face button types its letter and says a phrase out loud. Speak is an option on every row; the voice is chosen in Settings, General, Spoken feedback voice (System voice follows the Mac's Spoken Content setting).",
        "Stacked Outputs": "A showcase for several outputs on one row, fired together. A presses Space, right-clicks, plays a MIDI note, speaks, and vibrates, all at once. B presses Command and 4 together, which is a stacked shortcut. Add outputs to any row with the plus button; for a sequence with delays, use a macro instead.",
        "Steam Controller": "The original Steam Controller from 2015, wired or with its dongle (the 2026 model has its own preset). The app reads it directly and turns off its own keyboard emulation while a preset runs. Right trackpad moves the pointer, right trigger clicks, left trigger right-clicks, pressing the right trackpad clicks too. A is Return, B is Escape, X is Tab, Y is Space. Bumpers send Command [ and Command ], the Steam button opens Spotlight. The grips hold Shift and Option.",
        "Steam Controller (2026)": "Valve's 2026 Steam Controller, on a cable, over Bluetooth, or through its Puck (experimental). The right trackpad moves the pointer like a Mac trackpad, and a tap or a press on it clicks. The right trigger clicks, the left trigger right-clicks. The left trackpad and the right stick scroll. A is Return, B is Escape, X is Tab, Y is Space. The bumpers send Command [ and Command ], the Steam button opens Spotlight, and the back buttons L4 and R4 hold Shift and Option. Quit Steam first, since it takes the controller over while it runs.",
        "Access Controller": "Built for the PlayStation Access Controller. Out of the box its base profile sends Cross from the center button, Circle from socket 5, Options from socket 7, and the stick: the stick is the pointer, the center button clicks, socket 5 right-clicks, and socket 7 opens Spotlight. The other rows wait for Square, Triangle, L1, R1, L2, R2 and Create, which reach the Mac once a profile made on a PS5 gives them to sockets: double click, Return, scroll up and down, hold Command for shortcuts, Space, and Mission Control. The PS button reaches the app as its own input, PS button, through the controller's own report, so a row can use it. If your profile puts buttons elsewhere, Scan a row and press the socket you mean.\n\nTo stop everything at once, hold socket 7 (Options) for the emergency stop's hold time; the usual Create hold cannot reach the Mac from the base profile. Settings, General, Emergency stop sets the time.\n\nIf the pointer drifts, raise the Deadzone in the stick rows' Options (Adjust live shows the stick as you set it). Change Speed on those rows if it feels too fast or slow.",
        "Touchpad Zones": "The DualSense or DualShock 4 touchpad divided into four regions, each a soft button: touch the top-left corner to undo, top-right to redo, bottom-left to copy, bottom-right to paste. Each region gives a short pulse so you can feel that it landed. The press is still a left click and a two-finger tap is a right click.\n\nThe four regions belong to this preset. Pick Touchpad in the editor's Regions card to resize them, rename them, or draw your own; a new region becomes a Touchpad Region input on any row, and every preset has regions of its own.",
        "Cursor Regions": "Three corners of the screen are the inputs: put the pointer in the top-left corner for Mission Control, the top-right for Spotlight, the bottom-right for Launchpad. No controller is involved, though a controller moving the pointer fires them just the same.\n\nThe regions belong to this preset. Resize them, move them, or add more in the preset's own region editor, and the same corner can mean something different in another preset.",
        "Stick Zones & Gestures": "The left stick walks with W, A, S and D, and pushed all the way up it also holds Shift to sprint: that ring shares the stick with the walking rows. The right stick is a four-way menu of rings, one arrow key each; it has no direction rows, so each ring fires on its own. The left trigger has two bands, a half pull for 1 and a full pull for 2. Pull the left stick straight back twice for Escape, and flick it right twice for Tab (each flick also takes a step).\n\nThe regions belong to this preset. Choose Edit regions in a stick row's direction menu to resize them or draw your own; a region can take over its stick, so only it fires there, or share it with the direction rows.",
        "Hold & Double-Tap": "One control, three outputs. A / Cross clicks, held it right-clicks, tapped twice it presses Return. B / Circle is Space, held it is Escape. LB is Tab, tapped twice it is Shift Tab.\n\nThe thresholds are in each row's Options: the hold time and the double-tap window. Longer windows suit a hand that moves slowly; shorter ones feel snappier.",
        "Keyboard & Mouse Input": "The Mac's own keyboard and mouse as inputs, not just as outputs. F13, F14, and F15 run Mission Control, Spotlight, and play / pause; the two side buttons on a mouse go back and forward.\n\nThose keys were chosen because nothing else needs them, so running this preset never takes a key away from you. Scan any row and press the key or button you would rather use.",
        "Shortcuts & Apps": "Outputs that run something instead of pressing a key: Cross opens Safari, Circle opens inputconfig.com, Square and Triangle are Mission Control and Spotlight, and LB is set to Run Shortcut.\n\nOpen that row's menu to pick one of your own Shortcuts; the list is read from the Shortcuts app. Open App takes an app name, a bundle id, or a path, and Open URL takes anything the Mac has a handler for.",
        "Gyro Aim": "Aim by tilting: the pointer follows the controller's tilt, up and down and side to side, and the triggers click. Tilting back to level brings the pointer back to where it started.\n\nHold the left bumper (L1 or LB) to pause the motion while you swing the controller back to a comfortable angle, the way you lift a mouse off the desk, then let go and carry on. Press the right bumper (R1 or RB) to make the current tilt the new neutral and center the pointer. Both are App Action outputs, so you can move them to any control. Speed on the motion rows sets how far the pointer travels per degree of tilt.",
        "Voice Commands": "No controller needed: say the words and it happens. The first start asks for the microphone and Speech Recognition. It listens only while this preset runs, and nothing is recorded or kept. To change the words, click Edit and open Voice Phrases.",
        "Tap the Mac": "No controller needed: knock on the MacBook. A double tap opens Mission Control, a triple tap starts or stops Dictation. Works only on some MacBooks: tested on M4 MacBooks; it did not work on an M1 Pro in our testing. The calibrator shows whether your MacBook's sensor is listening.\n\nMac settings: for the triple tap, Dictation must be on in System Settings, Keyboard, Dictation. Open Calibrate Taps in the editor to set how firm a tap has to be.",
        "Toggle Mode": "A showcase for Toggle: press once to hold a key, press again to release it. A holds Shift, B holds Command, X holds F10 (mute in many apps), Y holds W for auto-run in games. A, B and Y vibrate when they latch. Toggle is an option on every row.",
        "Touchpad Mouse": "The DualSense or DualShock 4 touchpad as a trackpad. One finger moves the pointer, a second finger scrolls, pressing the touchpad clicks. Cross clicks too, Circle right-clicks.\n\nTouchpad rows have their own sensitivity; open Calibrate on a touchpad row to see your finger live and set the speed. Regions and swipe gestures can be added from the touchpad row's options.",
        "Variable Sensitivity": "A showcase for response curves. Both sticks move the pointer; the right stick uses a smooth curve (slow near center, fast at the edge) and the left an aggressive one. Push each the same amount and compare. The curve is on every stick row under its options. A clicks.",
        "Web Browsing": "Safari, Chrome, Firefox: pointer on the left stick, scroll on the right, A clicks. B right-clicks. X closes the tab, Y opens a new one, the bumpers go back and forward, the triggers switch tabs, Back jumps to the address bar. Start switches apps.\n\nWith the address bar focused, Dictation (System Settings, Keyboard) is the easiest way to type a search from the sofa; add a Dictation row to a spare button.",
    ]

    /// The per-row note for each shipped preset, by preset name and the
    /// row's serialized input ("btn 0", "axi 2 +", "hat 0 U", "mtn gyroY +",
    /// "tpd 0 x +"). Only rows with no note get one.
    static let rowNotes: [String: [String: String]] = [
        "Deadzone Calibration": [
            "axi 0 +": "Pointer right, tight deadzone",
            "axi 0 -": "Pointer left, tight deadzone",
            "axi 1 +": "Pointer down, tight deadzone",
            "axi 1 -": "Pointer up, tight deadzone",
            "axi 2 +": "Pointer right, wide deadzone and outer limit",
            "axi 2 -": "Pointer left, wide deadzone and outer limit",
            "axi 3 +": "Pointer down, wide deadzone and outer limit",
            "axi 3 -": "Pointer up, wide deadzone and outer limit",
            "btn 0": "Left click",
        ],
        "Desktop Navigation": [
            "axi 0 +": "Pointer right",
            "axi 0 -": "Pointer left",
            "axi 1 +": "Pointer down",
            "axi 1 -": "Pointer up",
            "axi 2 +": "Scroll right",
            "axi 2 -": "Scroll left",
            "axi 3 +": "Scroll down",
            "axi 3 -": "Scroll up",
            "axi 4 +": "Right click",
            "axi 5 +": "Left click",
            "btn 0": "Left click",
            "btn 1": "Undo (Cmd Z)",
            "btn 2": "Cut (Cmd X)",
            "btn 3": "Paste (Cmd V)",
            "btn 4": "Next app (Cmd Tab)",
            "btn 5": "Previous app (Cmd Shift Tab)",
            "btn 8": "Spotlight (Cmd Space)",
            "btn 9": "Return",
            "btn 12": "Select all (Cmd A)",
            "hat 0 D": "Down arrow",
            "hat 0 L": "Left arrow",
            "hat 0 R": "Right arrow",
            "hat 0 U": "Up arrow",
        ],
        "FPS (8BitDo)": [
            "axi 0 +": "Strafe right (D)",
            "axi 0 -": "Strafe left (A)",
            "axi 1 +": "Walk back (S)",
            "axi 1 -": "Walk forward (W)",
            "axi 2 +": "Look right",
            "axi 2 -": "Look left",
            "axi 3 +": "Look down",
            "axi 3 -": "Look up",
            "axi 4 +": "Aim down sights (right click)",
            "axi 5 +": "Fire (left click)",
            "btn 0": "Jump (Space)",
            "btn 1": "Crouch (C)",
            "btn 11": "Sprint (Shift, held)",
            "btn 12": "Use (E)",
            "btn 2": "Reload (R)",
            "btn 3": "Weapon slot 1",
            "btn 4": "Weapon slot 4",
            "btn 5": "Middle click (ping or melee in many games)",
            "btn 8": "Scoreboard (Tab)",
            "btn 9": "Menu (Escape)",
            "hat 0 D": "Previous weapon (scroll down)",
            "hat 0 L": "Ability or lean (Q)",
            "hat 0 R": "Use (F)",
            "hat 0 U": "Next weapon (scroll up)",
        ],
        "FPS (PS5 DualSense)": [
            "axi 0 +": "Strafe right (D)",
            "axi 0 -": "Strafe left (A)",
            "axi 1 +": "Walk back (S)",
            "axi 1 -": "Walk forward (W)",
            "axi 2 +": "Look right",
            "axi 2 -": "Look left",
            "axi 3 +": "Look down",
            "axi 3 -": "Look up",
            "axi 4 +": "Aim down sights (right click)",
            "axi 5 +": "Fire (left click)",
            "btn 0": "Jump (Space)",
            "btn 1": "Crouch (Control)",
            "btn 11": "Sprint (Shift, held)",
            "btn 12": "Use (E)",
            "btn 13": "Map (M)",
            "btn 2": "Reload (R)",
            "btn 3": "Weapon slot 1",
            "btn 4": "Weapon slot 4",
            "btn 5": "Middle click (ping or melee in many games)",
            "btn 8": "Scoreboard (Tab)",
            "btn 9": "Menu (Escape)",
            "hat 0 D": "Previous weapon (scroll down)",
            "hat 0 L": "Ability or lean (Q)",
            "hat 0 R": "Use (F)",
            "hat 0 U": "Next weapon (scroll up)",
        ],
        "FPS (Switch Pro)": [
            "axi 0 +": "Strafe right (D)",
            "axi 0 -": "Strafe left (A)",
            "axi 1 +": "Walk back (S)",
            "axi 1 -": "Walk forward (W)",
            "axi 2 +": "Look right",
            "axi 2 -": "Look left",
            "axi 3 +": "Look down",
            "axi 3 -": "Look up",
            "axi 4 +": "Aim down sights (right click)",
            "axi 5 +": "Fire (left click)",
            "btn 0": "Jump (Space)",
            "btn 1": "Crouch (C)",
            "btn 11": "Sprint (Shift, held)",
            "btn 12": "Use (E)",
            "btn 2": "Reload (R)",
            "btn 3": "Weapon slot 1",
            "btn 4": "Weapon slot 4",
            "btn 5": "Middle click (ping or melee in many games)",
            "btn 8": "Scoreboard (Tab)",
            "btn 9": "Menu (Escape)",
            "hat 0 D": "Previous weapon (scroll down)",
            "hat 0 L": "Ability or lean (Q)",
            "hat 0 R": "Use (F)",
            "hat 0 U": "Next weapon (scroll up)",
        ],
        "FPS (Xbox)": [
            "axi 0 +": "Strafe right (D)",
            "axi 0 -": "Strafe left (A)",
            "axi 1 +": "Walk back (S)",
            "axi 1 -": "Walk forward (W)",
            "axi 2 +": "Look right",
            "axi 2 -": "Look left",
            "axi 3 +": "Look down",
            "axi 3 -": "Look up",
            "axi 4 +": "Aim down sights (right click)",
            "axi 5 +": "Fire (left click)",
            "btn 0": "Jump (Space)",
            "btn 1": "Crouch (C)",
            "btn 11": "Sprint (Shift, held)",
            "btn 12": "Use (E)",
            "btn 2": "Reload (R)",
            "btn 3": "Weapon slot 1",
            "btn 4": "Weapon slot 4",
            "btn 5": "Middle click (ping or melee in many games)",
            "btn 8": "Scoreboard (Tab)",
            "btn 9": "Menu (Escape)",
            "hat 0 D": "Previous weapon (scroll down)",
            "hat 0 L": "Ability or lean (Q)",
            "hat 0 R": "Use (F)",
            "hat 0 U": "Next weapon (scroll up)",
        ],
        "Fortnite": [
            "axi 0 +": "Strafe right (D)",
            "axi 0 -": "Strafe left (A)",
            "axi 1 +": "Walk back (S)",
            "axi 1 -": "Walk forward (W)",
            "axi 2 +": "Look right",
            "axi 2 -": "Look left",
            "axi 3 +": "Look down",
            "axi 3 -": "Look up",
            "axi 4 +": "Aim (right click)",
            "axi 5 +": "Fire (left click)",
            "btn 0": "Jump (Space)",
            "btn 1": "Crouch (Control)",
            "btn 11": "Sprint (Shift, held)",
            "btn 12": "Edit (G)",
            "btn 2": "Reload (R)",
            "btn 3": "Use (E)",
            "btn 4": "Wall (Z)",
            "btn 5": "Floor (X)",
            "btn 8": "Inventory (Tab)",
            "btn 9": "Menu (Escape)",
            "hat 0 D": "Trap (V)",
            "hat 0 L": "Roof (1)",
            "hat 0 R": "Map (M)",
            "hat 0 U": "Stairs (C)",
        ],
        "Gyro Aim": [
            "axi 4 +": "Aim (right click)",
            "axi 5 +": "Fire (left click)",
            "btn 0": "Jump (Space)",
            "btn 1": "Crouch (Control)",
            "btn 4": "Hold to pause motion, to reposition the controller",
            "btn 5": "Re-zero motion and center the pointer",
            "mtn gyroX +": "Tilt up: look up",
            "mtn gyroX -": "Tilt down: look down",
            "mtn gyroY +": "Tilt right: look right",
            "mtn gyroY -": "Tilt left: look left",
        ],
        "Haptic Feedback": [
            "btn 0": "Type A, light rumble",
            "btn 1": "Type B, medium rumble",
            "btn 2": "Type C, strong rumble",
            "btn 3": "Type D, strongest rumble",
        ],
        "MIDI: CC Dials": [
            "axi 0 +": "CC 1, modulation",
            "axi 0 -": "CC 1, modulation",
            "axi 1 +": "CC 11, expression",
            "axi 2 +": "CC 74, filter cutoff",
            "axi 3 +": "CC 71, resonance",
            "axi 4 +": "CC 10, pan",
            "axi 5 +": "CC 7, volume",
        ],
        "MIDI: DAW Performance": [
            "axi 2 +": "Pitch bend up",
            "axi 2 -": "Pitch bend down",
            "axi 3 +": "Modulation (CC 1)",
            "axi 4 +": "Expression (CC 11)",
            "axi 5 +": "Volume (CC 7)",
            "btn 0": "Note C",
            "btn 1": "Note E",
            "btn 2": "Note G",
            "btn 3": "Note C (octave up)",
            "hat 0 D": "Transport stop",
            "hat 0 R": "Transport continue",
            "hat 0 U": "Transport start",
        ],
        "MIDI: Drum Pad": [
            "axi 4 +": "Low tom (note 41)",
            "axi 5 +": "Crash cymbal (note 49)",
            "btn 0": "Kick (note 36), turbo for rolls",
            "btn 1": "Snare (note 38), turbo for rolls",
            "btn 2": "Closed hi-hat (note 42), turbo for rolls",
            "btn 3": "Open hi-hat (note 46), turbo for rolls",
        ],
        "MIDI: Transport Control": [
            "btn 0": "Transport start",
            "btn 1": "Transport stop",
            "btn 2": "Transport continue",
            "btn 4": "Patch 1 (program change 0)",
            "btn 5": "Patch 2 (program change 1)",
            "hat 0 D": "Volume down trigger (CC 21)",
            "hat 0 U": "Volume up trigger (CC 20)",
        ],
        "Auto Clicker": [
            "btn 0": "Click once",
            "btn 2": "Auto click at a human pace (150 ms, give or take 40), on and off",
            "btn 3": "Auto click 100 times, then stop",
            "btn 5": "Auto click 20 a second while held",
            "btn 6": "Auto right click 5 a second, on and off",
            "btn 7": "Auto click 10 a second, on and off",
            "ekb 63 any": "fn F6: auto click 10 a second, on and off",
            "ekb 64 any": "fn F7: auto right click 5 a second, on and off",
            "ems button 3 + any": "Mouse button 4: auto click 15 a second while held",
        ],
        "Macros & Turbo": [
            "btn 0": "Macro: copy, switch app, paste",
            "btn 2": "Macro at double speed: types gg, Return, waits, Command V",
            "btn 3": "Macro: down three items, then Return",
            "btn 4": "J, three times (Repeat)",
            "btn 5": "Space, repeated while held (turbo)",
            "bsq 253.253.1": "Button sequence Down, Down, B: Space",
        ],
        "Media Controller": [
            "axi 0 +": "Next track",
            "axi 0 -": "Previous track",
            "axi 1 +": "Volume down",
            "axi 1 -": "Volume up",
            "btn 0": "Play or pause",
            "btn 1": "Next track",
            "btn 2": "Previous track",
            "btn 3": "Mute",
            "btn 4": "Volume down",
            "btn 5": "Volume up",
            "btn 8": "Escape (leave full screen)",
            "hat 0 D": "Volume down",
            "hat 0 L": "Previous track",
            "hat 0 R": "Next track",
            "hat 0 U": "Volume up",
        ],
        "Minecraft": [
            "axi 0 +": "Strafe right (D)",
            "axi 0 -": "Strafe left (A)",
            "axi 1 +": "Walk back (S)",
            "axi 1 -": "Walk forward (W)",
            "axi 2 +": "Look right",
            "axi 2 -": "Look left",
            "axi 3 +": "Look down",
            "axi 3 -": "Look up",
            "axi 4 +": "Place or use (right click)",
            "axi 5 +": "Mine or attack (left click)",
            "btn 0": "Jump (Space)",
            "btn 1": "Sneak (Shift, held)",
            "btn 11": "Sprint (Control, held)",
            "btn 12": "Swap hands (F)",
            "btn 2": "Inventory (E)",
            "btn 3": "Drop item (Q)",
            "btn 4": "Previous hotbar slot (scroll)",
            "btn 5": "Next hotbar slot (scroll)",
            "btn 8": "Player list (Tab)",
            "btn 9": "Menu (Escape)",
            "hat 0 D": "Hotbar slot 3",
            "hat 0 L": "Hotbar slot 4",
            "hat 0 R": "Hotbar slot 2",
            "hat 0 U": "Hotbar slot 1",
        ],
        "Motion Cursor": [
            "axi 3 +": "Scroll down",
            "axi 3 -": "Scroll up",
            "btn 0": "Left click",
            "btn 1": "Right click",
            "btn 3": "Return",
            "btn 4": "Hold to pause motion",
            "btn 5": "Re-zero gyro, center pointer",
            "mtn gyroX +": "Tilt up: pointer up",
            "mtn gyroX -": "Tilt down: pointer down",
            "mtn gyroY +": "Tilt right: pointer right",
            "mtn gyroY -": "Tilt left: pointer left",
        ],
        "Mouse + Scroll": [
            "axi 0 +": "Pointer right",
            "axi 0 -": "Pointer left",
            "axi 1 +": "Pointer down",
            "axi 1 -": "Pointer up",
            "axi 2 +": "Scroll right",
            "axi 2 -": "Scroll left",
            "axi 3 +": "Scroll down",
            "axi 3 -": "Scroll up",
            "btn 0": "Left click",
            "btn 1": "Right click",
            "btn 2": "Middle click",
            "hat 0 D": "Nudge pointer down (slow)",
            "hat 0 L": "Nudge pointer left (slow)",
            "hat 0 R": "Nudge pointer right (slow)",
            "hat 0 U": "Nudge pointer up (slow)",
        ],
        "Presentation Remote": [
            "axi 0 +": "Pointer right",
            "axi 0 -": "Pointer left",
            "axi 1 +": "Pointer down",
            "axi 1 -": "Pointer up",
            "btn 0": "Next slide (Right arrow)",
            "btn 1": "Previous slide (Left arrow)",
            "btn 2": "Start or advance (Space)",
            "btn 3": "Blank the screen (B)",
            "btn 4": "Left click",
            "btn 5": "Right click",
            "btn 8": "Leave the show (Escape)",
            "btn 9": "Start PowerPoint show (F5)",
        ],
        "Racing Game": [
            "axi 0 +": "Steer right (D)",
            "axi 0 -": "Steer left (A)",
            "axi 2 +": "Look right",
            "axi 2 -": "Look left",
            "axi 3 +": "Look down",
            "axi 3 -": "Look up",
            "axi 4 +": "Brake (S)",
            "axi 5 +": "Throttle (W)",
            "btn 0": "Handbrake (Space)",
            "btn 1": "Shift up (Shift)",
            "btn 2": "Camera or look back (E, varies by game)",
            "btn 3": "Reset car (R)",
            "btn 4": "Q (varies by game)",
            "btn 5": "F (varies by game)",
            "btn 8": "Standings or map (Tab, varies by game)",
            "btn 9": "Menu (Escape)",
        ],
        "Spoken Feedback": [
            "btn 0": "Type A and speak",
            "btn 1": "Type B and speak",
            "btn 2": "Type C and speak",
            "btn 3": "Type D and speak",
        ],
        "Stacked Outputs": [
            "btn 0": "Space, right click, a MIDI note, speech, and a rumble, together",
            "btn 1": "Command 4 (two keys at once)",
        ],
        "Steam Controller": [
            "axi 2 +": "Right trackpad: pointer right",
            "axi 2 -": "Right trackpad: pointer left",
            "axi 3 +": "Right trackpad: pointer down",
            "axi 3 -": "Right trackpad: pointer up",
            "axi 4 +": "Left trigger: right click",
            "axi 5 +": "Right trigger: left click",
            "btn 13": "Steam button: Spotlight (Cmd Space)",
            "btn 15": "Left grip: Shift (held)",
            "btn 16": "Right grip: Option (held)",
            "btn 18": "Right trackpad press: left click",
            "btn 2": "Right bumper: Cmd ] (forward)",
            "btn 3": "Left bumper: Cmd [ (back)",
            "btn 4": "Y: Space",
            "btn 5": "B: Escape",
            "btn 6": "X: Tab",
            "btn 7": "A: Return",
        ],
        "Steam Controller (2026)": [
            "tpd 0 x +": "Right trackpad: pointer right",
            "tpd 0 x -": "Right trackpad: pointer left",
            "tpd 0 y +": "Right trackpad: pointer down",
            "tpd 0 y -": "Right trackpad: pointer up",
            "tpg oneFingerTap": "Right trackpad tap: left click",
            "tpd 0 y + s1": "Left trackpad down: scroll down",
            "tpd 0 y - s1": "Left trackpad up: scroll up",
            "axi 3 +": "Right stick down: scroll down",
            "axi 3 -": "Right stick up: scroll up",
            "axi 4 +": "Left trigger: right click",
            "axi 5 +": "Right trigger: left click",
            "btn 0": "A: Return",
            "btn 1": "B: Escape",
            "btn 2": "X: Tab",
            "btn 3": "Y: Space",
            "btn 4": "Left bumper: Cmd [ (back)",
            "btn 5": "Right bumper: Cmd ] (forward)",
            "btn 10": "Steam button: Spotlight (Cmd Space)",
            "btn 14": "L4 (left back button): Shift (held)",
            "btn 15": "R4 (right back button): Option (held)",
            "btn 19": "Right trackpad press: left click",
        ],
        "Toggle Mode": [
            "btn 0": "Toggle Shift held",
            "btn 1": "Toggle Command held",
            "btn 2": "Toggle F10 (mute in many apps)",
            "btn 3": "Toggle W held (auto-run)",
        ],
        "Touchpad Mouse": [
            "btn 0": "Left click",
            "btn 1": "Right click",
            "btn 13": "Touchpad press: left click",
            "tpg oneFingerTap": "Touchpad tap: left click",
            "tpg twoFingerTap": "Two-finger tap: right click",
            "tpd 0 x +": "Finger 1 right: pointer right",
            "tpd 0 x -": "Finger 1 left: pointer left",
            "tpd 0 y +": "Finger 1 down: pointer down",
            "tpd 0 y -": "Finger 1 up: pointer up",
            "tpd 1 y +": "Finger 2 down: scroll down",
            "tpd 1 y -": "Finger 2 up: scroll up",
        ],
        "Variable Sensitivity": [
            "axi 0 +": "Pointer right, aggressive curve",
            "axi 0 -": "Pointer left, aggressive curve",
            "axi 1 +": "Pointer down, aggressive curve",
            "axi 1 -": "Pointer up, aggressive curve",
            "axi 2 +": "Pointer right, smooth curve",
            "axi 2 -": "Pointer left, smooth curve",
            "axi 3 +": "Pointer down, smooth curve",
            "axi 3 -": "Pointer up, smooth curve",
            "btn 0": "Left click",
        ],
        "Web Browsing": [
            "axi 0 +": "Pointer right",
            "axi 0 -": "Pointer left",
            "axi 1 +": "Pointer down",
            "axi 1 -": "Pointer up",
            "axi 2 +": "Scroll right",
            "axi 2 -": "Scroll left",
            "axi 3 +": "Scroll down",
            "axi 3 -": "Scroll up",
            "axi 4 +": "Previous tab (Cmd Shift [)",
            "axi 5 +": "Next tab (Cmd Shift ])",
            "btn 0": "Left click",
            "btn 1": "Right click",
            "btn 2": "Close tab (Cmd W)",
            "btn 3": "New tab (Cmd T)",
            "btn 4": "Back (Cmd [)",
            "btn 5": "Forward (Cmd ])",
            "btn 8": "Address bar (Cmd L)",
            "btn 9": "Switch app (Cmd Tab)",
        ],
    ]

    /// Notes an earlier version wrote itself that the full shipped notes
    /// replace. The Anki builder filled in a one-line note, so the full
    /// notes below never appeared; a copy still holding that line exactly
    /// is treated as empty.
    private static let supersededNotes: [String: String] = [
        // 1.8, before the rows that vibrate were named (X does not).
        "Toggle Mode": "A showcase for Toggle: press once to hold a key, press again to release it. A holds Shift, B holds Command, X holds F10 (mute in many apps), Y holds W for auto-run in games. The row vibrates when it latches. Toggle is an option on every row.",
        // 1.6 and 1.7, from before the PS button was read as its own input.
        "Access Controller": "Built for the PlayStation Access Controller. Out of the box its base profile sends Cross from the center button, Circle from socket 5, Options from socket 7, and the stick: the stick is the pointer, the center button clicks, socket 5 right-clicks, and socket 7 opens Spotlight. The other rows wait for Square, Triangle, L1, R1, L2, R2 and Create, which reach the Mac once a profile made on a PS5 gives them to sockets: double click, Return, scroll up and down, hold Command for shortcuts, Space, and Mission Control. The PS button is kept by macOS and never reaches an app, so nothing is bound to it. If your profile puts buttons elsewhere, Scan a row and press the socket you mean.\n\nTo stop everything at once, hold socket 7 (Options) for the emergency stop's hold time; the usual Create hold cannot reach the Mac from the base profile. Settings, General, Emergency stop sets the time.\n\nIf the pointer drifts, raise the Deadzone in the stick rows' Options (Adjust live shows the stick as you set it). Change Speed on those rows if it feels too fast or slow.",
        // 1.6 called them zones and sent people to Calibrate Touchpad, which 1.7 removes.
        "Touchpad Zones": "The DualSense or DualShock 4 touchpad divided into four zones, each a soft button: touch the top-left corner to undo, top-right to redo, bottom-left to copy, bottom-right to paste. Each zone gives a short pulse so you can feel that it landed. The press is still a left click and a two-finger tap is a right click.\n\nThe four zones belong to this preset. Open Calibrate Touchpad in any touchpad row's Options to resize them, rename them, or draw your own; a new zone becomes a Touchpad Region input on any row, and every preset has zones of its own.",
        "Stick Zones & Gestures": "The left stick walks with W, A, S and D, and pushed all the way up it also holds Shift to sprint: that ring shares the stick with the walking rows. The right stick is a four-way menu of rings, one arrow key each; it has no direction rows, so each ring fires on its own. The left trigger has two bands, a half pull for 1 and a full pull for 2. Pull the left stick straight back twice for Escape, and flick it right twice for Tab (each flick also takes a step).\n\nThe zones belong to this preset. Choose Edit zones in a stick row's direction menu to resize them or draw your own; a zone can take over its stick, so only it fires there, or share it with the direction rows.",
        // 1.6 sent people to a Settings tab named Accessibility, which does not exist.
        "Spoken Feedback": "A showcase for Speak. Each face button types its letter and says a phrase out loud. Speak is an option on every row; the voice is chosen in Settings, Accessibility (System voice follows the Mac's Spoken Content setting).",
        "One-Stick Driving": "The whole car from one joystick, for the PlayStation Access Controller, the Xbox Adaptive Controller, or any single stick. The stick is not bound to rows here: the One-Stick Driving section at the bottom of this editor owns it. Push forward to accelerate, pull back to brake, left and right to steer, and snap the stick back twice to shift into Reverse (push forward to shift back to Drive). Let go and the car slows on its own, the way a power chair stops when you release the stick.\n\nEverything about the driving lives in that section: which stick and controller slot, the deadzone, the steering and throttle curves, keys or mouse steering, the coast brake, and the reverse gesture. Use the Test Drive arena to feel a change before you race. The rows above only cover the eight sockets: handbrake, horn, boost, reset, gears, camera, and rewind. Change the letters on each row to match the game's own key list.",
        // 1.5 shipped this Media Deck note, pointing to a menu with no device list.
        "MIDI: Media Deck": "A MIDI controller as a media remote. CC 7 is the Mac's volume fader, CC 71 steps volume, CC 74 steps brightness, pads 36 to 41 are play, next, previous, mute, Mission Control, and an app. Pick your MIDI device in the slot's input kind menu.",
        "Anki": "Anki's default shortcuts. If you changed them in Anki's Preferences, Scan the row and press the new key.",
        // 1.7 builds before the MacBook note.
        "Tap the Mac": "No controller needed: knock on the MacBook. A double tap opens Mission Control, a triple tap starts or stops Dictation. Tested on M4 MacBooks; the calibrator shows whether your MacBook's sensor is listening.\n\nMac settings: for the triple tap, Dictation must be on in System Settings, Keyboard, Dictation. Open Calibrate Taps in the editor to set how firm a tap has to be.",
        // 1.8, before the X row and the button sequence.
        "Macros & Turbo": "A showcase for macros and turbo. RB repeats Space rapidly while held (turbo). A runs a macro: copy, switch app, paste. Y runs a macro: down three items, then Return. LB sends J three times (Repeat). Turbo, macros, and Repeat are options on every row.",
        "Steam Controller": "Valve's Steam Controller, wired or with its dongle. The app reads it directly and turns off its own keyboard emulation while a preset runs. Right trackpad moves the pointer, right trigger clicks, left trigger right-clicks, pressing the right trackpad clicks too. A is Return, B is Escape, X is Tab, Y is Space. Bumpers send Command [ and Command ], the Steam button opens Spotlight. The grips hold Shift and Option.",
    ]

    /// The preset and group descriptions 1.5 shipped where 1.6 reworded
    /// them, so a backup's copy still holding them counts as untouched.
    static let tags15: [String: (preset: String, groups: [String])] = [
        // 1.6's wording, before zones were called regions.
        "Touchpad Zones": (preset: "The DualSense touchpad as four soft buttons", groups: ["Four zones on the pad send Undo, Redo, Copy, and Paste with a pulse; the press clicks and a two-finger tap right-clicks"]),
        "Access Controller": (preset: "One stick and eight buttons for the whole desktop", groups: ["Stick = pointer; sockets click, scroll, Return, Space, and hold Command; Options and PS open Mission Control and Spotlight"]),
        // 1.7: the tag said Apple mode while the notes, Help and the
        // drawing all say to set the switch to D.
        "FPS (8BitDo)": (preset: "8BitDo Pro 2, Ultimate, SN30 Pro+ in Apple mode", groups: ["FPS layout tuned for 8BitDo triggers"]),
        "Deadzone Calibration": (preset: "Right stick wide deadzone + outer saturation, left stick tight", groups: ["Open Advanced > Calibrate on any axis row to see the live ring visualizer"]),
        "Gyro Aim": (preset: "Tilt the controller to aim; triggers fire and ADS", groups: ["Tilt to aim: sideways tilt → mouse X, forward tilt → mouse Y. LB pauses motion while held, RB re-zeros and centers the pointer"]),
        "MIDI: Drum Pad": (preset: "Finger-drumming pads with turbo for rolls", groups: ["Face buttons = drum kit pieces with turbo (hold for rolls), triggers = cymbals"]),
        "MIDI: Knob Deck": (preset: "MIDI input drives the Mac: volume fader, Dial scroll, Turn nudges", groups: ["CC 7 = volume fader, mod wheel = scroll, CC 71 = arrows, pedal = click"]),
        "MIDI: Transport Control": (preset: "DAW remote: start, stop, continue, program change", groups: ["A = Start, B = Stop, X = Continue, LB/RB = patch up/down"]),
        "Minecraft": (preset: "Full Minecraft controls - works with any controller", groups: ["WASD + mouse look, triggers mine/place, bumpers cycle hotbar, D-pad hotbar 1-4. Uses standard gamepad indices so the same layout drives DualSense, Xbox, Switch Pro, 8BitDo and any other connected controller."]),
        "Motion Cursor": (preset: "Wave the controller to move the cursor; face buttons click", groups: ["Slower than Gyro Aim, with clicks and scrolling on the buttons; perfect for couch desktop use on Switch Pro / DualSense"]),
        "Spoken Feedback": (preset: "Each face button speaks a phrase aloud", groups: ["Each face button says its phrase through the Mac's sound output"]),
        // 1.8, before the X row and the button sequence.
        "Macros & Turbo": (preset: "RB = rapid space, A = copy/switch/paste macro, Y = list navigation, LB = triple J", groups: ["Hold RB for turbo, tap A for the chord macro, tap Y to walk a list, tap LB for repeat"]),
        "Stacked Outputs": (preset: "One press fires keystroke + mouse + MIDI + speech together", groups: ["A = parallel output stack (key + click + MIDI + speech). B = parallel keystroke pair. Different from a macro - no delays, no sequence; these fire simultaneously."]),
    ]

    /// Row notes 1.5 wrote that 1.6 reworded, so a row still holding the
    /// 1.5 text counts as untouched when a backup is restored.
    static let rowNotes15: [String: [String: String]] = [
        // 1.6's wording, before zones were called regions.
        "Touchpad Zones": [
            "tpr 5a1e0001000040008000000000000001": "Top-left zone: Undo (Cmd Z)",
            "tpr 5a1e0001000040008000000000000002": "Top-right zone: Redo (Cmd Shift Z)",
            "tpr 5a1e0001000040008000000000000003": "Bottom-left zone: Copy (Cmd C)",
            "tpr 5a1e0001000040008000000000000004": "Bottom-right zone: Paste (Cmd V)",
        ],
        "Access Controller": [
            "btn 0": "Center button (Cross): left click",
            "btn 1": "Socket 5 (Circle): right click",
            "btn 2": "Square (in a PS5 profile): double click",
            "btn 3": "Triangle (in a PS5 profile): Return",
            "btn 4": "L1 (in a PS5 profile): scroll up while held",
            "btn 5": "R1 (in a PS5 profile): scroll down while held",
            "btn 6": "L2 (in a PS5 profile): hold Command, for Command-click and shortcuts",
            "btn 7": "R2 (in a PS5 profile): Space",
            "btn 8": "Create (in a PS5 profile): Mission Control",
            "btn 9": "Socket 7 (Options): Spotlight",
        ],
        "One-Stick Driving": [
            "btn 0": "Socket 1 (Cross): handbrake (Space)",
            "btn 1": "Socket 2 (Circle): horn (H)",
            "btn 2": "Socket 3 (Square): boost (Shift)",
            "btn 3": "Socket 4 (Triangle): reset the car (R)",
            "btn 4": "Socket 5 (L1): shift down (Q)",
            "btn 5": "Socket 6 (R1): shift up (E)",
            "btn 6": "Socket 7 (L2): change camera (C)",
            "btn 7": "Socket 8 (R2): rewind / flashback (Tab)",
            "btn 8": "Options: pause (Escape)",
            "btn 9": "Menu socket: confirm (Return)",
        ],
        "Desktop Navigation": [
            "btn 0": "Select all (Cmd A)",
        ],
        "FPS (8BitDo)": [
            "btn 5": "Middle click",
            "btn 8": "Menu (Escape)",
            "btn 9": "Scoreboard (Tab)",
            "hat 0 L": "Q",
        ],
        "FPS (PS5 DualSense)": [
            "btn 12": "V",
            "btn 5": "Middle click",
            "hat 0 L": "Q",
        ],
        "FPS (Switch Pro)": [
            "btn 5": "Middle click",
            "hat 0 L": "Q",
        ],
        "FPS (Xbox)": [
            "btn 5": "Middle click",
            "btn 8": "Menu (Escape)",
            "btn 9": "Scoreboard (Tab)",
            "hat 0 L": "Q",
        ],
        "Gyro Aim": [
            "mtn gyroY +": "Turn right: look right",
            "mtn gyroY -": "Turn left: look left",
        ],
        "MIDI: Transport Control": [
            "hat 0 D": "Volume down (CC 7)",
            "hat 0 U": "Volume up (CC 7)",
        ],
        "Macros & Turbo": [
            "btn 4": "J",
        ],
        "Minecraft": [
            "btn 8": "Escape (menu)",
            "btn 9": "Player list (Tab)",
        ],
        "Motion Cursor": [
            "axi 3 +": "Scroll up",
            "axi 3 -": "Scroll down",
            "mtn gyroY +": "Turn right: pointer right",
            "mtn gyroY -": "Turn left: pointer left",
        ],
        "Racing Game": [
            "btn 2": "E",
            "btn 4": "Q",
            "btn 5": "F",
            "btn 8": "Menu (Escape)",
            "btn 9": "Tab",
        ],
    ]

    /// The Notes text 1.5 shipped for the built-ins whose text 1.6 rewrote.
    /// A copy still holding it was never edited: it takes the 1.6 text, and
    /// a backup holding it is restored as the untouched built-in.
    private static let presetNotes15: [String: String] = [
        "Media Controller": "A remote for Music, Spotify, VLC, the TV app, and YouTube in a browser: it sends the Mac's own media keys, so it works whichever app is playing.\n\nA plays and pauses, B skips forward, X skips back, Y mutes. Bumpers, the D-pad, and the left stick change the volume. Back is Escape for leaving full screen.",
        "MIDI: CC Dials": "The sticks and triggers as soft MIDI controllers on channel 1: left stick X and Y send CC 1 and CC 11, right stick X and Y send CC 74 and CC 71, triggers send CC 7 and CC 10. Use MIDI Learn in any synth or DAW to grab one.",
        "MIDI: DAW Performance": "A MIDI instrument from the controller, through InputConfig's virtual MIDI port. Face buttons play a C major chord (C, E, G, C), right stick bends pitch and adds modulation, right trigger is volume (CC 7), left trigger is expression (CC 11). D-pad up starts, down stops, right continues the transport.\n\nIn GarageBand or Logic, pick InputConfig as the MIDI input on a software instrument track.",
        "Access Controller": "Built for the PlayStation Access Controller. Its base profile sends Cross from the center button, Circle from socket 5 and Options from socket 7; a profile made on a PS5 can put Square, Triangle, L1, R1, L2, R2 and Create on the other sockets. Every socket, the center button, the stick press, the PS button and the Profile button also reach the app by their own names, Socket 1 to Socket 8, PS button and so on, whatever the profile maps. The stick is the pointer; the sockets click, double click, scroll, and send Return and Space; L2 holds Command so a press with another socket is a shortcut. If you changed the profile in the PlayStation app, Scan each row and press the socket you mean.\n\nIf the pointer drifts, raise the deadzone on the stick rows (Calibrate opens a live plot). Change Speed on those rows if it feels too fast or slow.",
        "Deadzone Calibration": "A showcase for deadzones. Both sticks move the pointer; the right stick has a wide inner deadzone and an outer limit, the left stick a tight one. Move each and feel the difference, then open Calibrate on a stick row to set your own with the live plot. A clicks.",
        "Desktop Navigation": "A pointer and the everyday shortcuts, for using the Mac without touching the keyboard. Left stick moves the pointer, right stick scrolls, right trigger clicks, left trigger right-clicks, the D-pad sends the arrow keys.\n\nFace buttons: A selects all, B undoes, X cuts, Y pastes. Bumpers switch apps, Back opens Spotlight, Start is Return. For copy, add a row for Cmd C or change B.\n\nNo Mac settings needed beyond the Accessibility permission the app asks for.",
        "FPS (8BitDo)": "The first-person layout tuned for 8BitDo pads in A (Apple) mode. Left stick moves, right stick looks, right trigger fires, left trigger aims. A jumps, B is C for crouch, X reloads, Y is slot 1. L1 is slot 4, R1 middle-clicks. D-pad up and down scroll weapons, left is Q, right is F. Left stick click sprints, right stick click sends E. Select is Escape, Start is Tab.\n\nSet the mode switch on the back to A before pairing.",
        "FPS (PS5 DualSense)": "A first-person layout for games with no controller support. Left stick moves, right stick looks, R2 fires, L2 aims. Cross jumps, Circle crouches with Control, Square reloads, Triangle is slot 1. L1 is slot 4, R1 middle-clicks. D-pad up and down scroll weapons, left is Q, right is F. L3 sprints with Shift, R3 sends V. The touchpad press opens the map with M. Share is Tab, Options is Escape.\n\nThe touchpad can also be a trackpad; see the Touchpad Mouse preset.",
        "FPS (Xbox)": "A first-person layout for games with no controller support. Left stick moves, right stick looks, right trigger fires, left trigger aims. A jumps, B is C for crouch, X reloads, Y is slot 1. LB is slot 4, RB middle-clicks. D-pad up and down scroll weapons, left is Q, right is F. Left stick click sprints with Shift, right stick click sends E. View is Escape, Menu is Tab.",
        "Gyro Aim": "Aim by tilting: the pointer follows the controller's tilt, up and down and side to side, and the triggers click. Tilting back to level brings the pointer back to where it started.\n\nHold LB to pause the motion while you swing the controller back to a comfortable angle, the way you lift a mouse off the desk, then let go and carry on. Press RB to make the current tilt the new neutral and center the pointer. Both are App Action outputs, so you can move them to any control. Speed on the motion rows sets how far the pointer travels per degree of tilt.",
        "MIDI: Knob Deck": "A MIDI controller runs the Mac. CC 7 (a fader) is the Mac's volume, the mod wheel scrolls, CC 71 turned sends the arrow keys, the sustain pedal clicks, pads 36 and 37 send Return and Escape. Pick your MIDI device in the slot's input kind menu.",
        "MIDI: Transport Control": "A DAW remote over MIDI. A starts, B stops, X continues (MIDI transport messages), the bumpers select patch 1 and patch 2 with program changes, the D-pad nudges CC 7 volume. Map them in your DAW's control surface or MIDI Learn settings.",
        "Macros & Turbo": "A showcase for macros and turbo. RB repeats Space rapidly while held (turbo). A runs a macro: copy, switch app, paste. Y runs a macro: down three items, then Return. LB sends J. Turbo and macros are options on every row.",
        "Motion Cursor": "Point the controller like a laser pointer: tilt it and the pointer follows the tilt, so tilting back to level puts the pointer back where it started. Works on the DualSense, DualShock 4, Switch Pro Controller, and Joy-Cons. A clicks, B right-clicks, Y is Return, right stick scrolls.\n\nRB makes the controller's current tilt the new neutral and puts the pointer in the middle of the screen. Hold LB to move the controller without moving the pointer, the way you lift a mouse off the desk. The gyro zero looks after itself while the controller rests; Calibrate Motion in a row's Options is there if you want to set it by hand.",
        "Mouse + Scroll": "The plain pointer preset. Left stick moves the pointer, right stick scrolls, D-pad nudges the pointer slowly for small targets. A clicks, B right-clicks, X middle-clicks.\n\nIf the pointer drifts on its own, raise the stick's deadzone on its row (Calibrate opens a live plot). If it feels too fast or too slow, change Speed on the stick rows.",
        "Racing Game": "Any racing game that takes keyboard input. Left stick steers with A and D, right trigger is the throttle (W), left trigger the brake (S). A is the handbrake, B shifts up with Shift, X sends E, Y sends R for reset, bumpers send Q and F. Right stick looks around. Back is Escape, Start is Tab.\n\nChange the letters on each row to match the game's own key list; most racers let you rebind.",
        "Tap the Mac": "No controller needed: knock on the MacBook. A double tap opens Mission Control, a triple tap starts or stops Dictation. Works on M2 and later, and on M1 Pro, Max, and Ultra.\n\nMac settings: for the triple tap, Dictation must be on in System Settings, Keyboard, Dictation. Open Calibrate Taps in the editor to set how firm a tap has to be.",
        "Variable Sensitivity": "A showcase for response curves. Both sticks move the pointer; the right stick uses a smooth curve (slow near center, fast at the edge) and the left an aggressive one. Push each the same amount and compare. The curve is on every stick row under its options. A clicks.",
        "Web Browsing": "Safari, Chrome, Firefox: pointer on the left stick, scroll on the right, click on the right trigger. B right-clicks. X closes the tab, Y opens a new one, the bumpers go back and forward, the triggers switch tabs, Back jumps to the address bar. Start switches apps.\n\nWith the address bar focused, Dictation (System Settings, Keyboard) is the easiest way to type a search from the sofa; add a Dictation row to a spare button.",
    ]

    /// Whether `text` is notes this app wrote for the preset, in this
    /// version or an earlier one.
    /// Whether the notes are exactly a text a later version replaced (not
    /// 1.5's, which described rows a copy the person changed may still have).
    /// Older texts still, where one name has had more than the tables
    /// above hold: 1.5's Access Controller note, which 1.8 replaced in
    /// presetNotes15, so a 1.5 backup's untouched copy matches again.
    private static let earlierNotes: [String: [String]] = [
        "Access Controller": ["The PlayStation Access Controller's PS button is kept by macOS and never reaches an app, so nothing is bound to it; everything here runs from the stick and the sockets. Built for the PlayStation Access Controller with its default button profile: Cross, Circle, Square, Triangle, L1, R1, L2, and R2 on the eight sockets, which the Mac sees as buttons 1 to 8. The stick is the pointer; the sockets click, double click, scroll, and send Return and Space; L2 holds Command so a press with another socket is a shortcut. If you changed the profile in the PlayStation app, Scan each row and press the socket you mean.\n\nIf the pointer drifts, raise the deadzone on the stick rows (Calibrate opens a live plot). Change Speed on those rows if it feels too fast or slow."],
    ]

    static func isSupersededNotes(_ text: String, for name: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let older = [supersededNotes[name]].compactMap { $0 } + (earlierNotes[name] ?? [])
        return older.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == t }
    }

    static func isShippedNotes(_ text: String, for name: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        func norm(_ s: String?) -> String? {
            s?.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "centre", with: "center")
        }
        let n = norm(t)
        return n == norm(presetNotes[name]) || n == norm(presetNotes15[name]) || n == norm(supersededNotes[name])
            || (earlierNotes[name] ?? []).contains { norm($0) == n }
    }

    /// Fill in the shipped notes wherever the preset has none: the Notes
    /// field, and every row whose note is empty. Text the user has written
    /// is never replaced. Returns whether anything changed.
    @discardableResult
    static func fillShippedNotes(_ preset: inout Preset) -> Bool {
        var changed = false
        let current = preset.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if current.isEmpty || (isShippedNotes(current, for: preset.name) && current != presetNotes[preset.name]),
           let text = presetNotes[preset.name] {
            preset.notes = text
            changed = true
        }
        if let rows = rowNotes[preset.name] {
            for j in preset.joysticks.indices {
                for b in preset.joysticks[j].bindings.indices
                where (preset.joysticks[j].bindings[b].note ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let key = preset.joysticks[j].bindings[b].input.serialized
                    if let note = rows[key] {
                        preset.joysticks[j].bindings[b].note = note
                        changed = true
                    }
                }
            }
        }
        return changed
    }

    /// Puts a shipped preset's rows under section headings (Left stick,
    /// Buttons, D-pad...) when none of them has a section yet, so the editor
    /// shows it organized. A preset whose rows all belong to one section is
    /// left flat: one heading over everything says nothing. Returns true when
    /// anything changed.
    /// The built-in presets written for one controller family, drawn and
    /// named that way whatever pad is connected (see Preset.buttonFamily).
    static let buttonFamilies: [String: FaceLetters] = [
        "FPS (PS5 DualSense)": .playstation,
        "FPS (Xbox)": .xbox,
        "FPS (Switch Pro)": .nintendo,
        "Steam Controller": .steamController,
        "Steam Controller (2026)": .steamController2026,
        "Touchpad Mouse": .playstation,
        "Touchpad Zones": .playstation,
        "Access Controller": .playstation,
    ]

    /// Built-ins made for one model with no Buttons family of its own, by
    /// the drawing the Live Visualizer shows for them.
    static let drawnModels: [String: ControllerModelID] = [
        "FPS (8BitDo)": .eightBitDoPro2,
    ]

    /// The built-ins that got a family in the third 1.6 pass.
    static let familiedIn16v3: Set<String> = ["Touchpad Mouse", "Touchpad Zones", "Access Controller"]

    /// Gives a Steam Controller preset still on the standard section
    /// headings (1.5 filed its trackpads under Right stick) its own.
    /// Returns true when changed.
    @discardableResult
    static func refreshSteamSections(_ preset: inout Preset) -> Bool {
        guard let family = buttonFamilies[preset.name], family.isSteam else { return false }
        var changed = false
        for j in preset.joysticks.indices {
            let rows = preset.joysticks[j].bindings
            guard !rows.isEmpty, rows.allSatisfy({ ($0.section ?? "") == ControllerScaffold.section(for: $0.input) }) else { continue }
            let regrouped = ControllerScaffold.grouped(rows, family: family)
            guard regrouped.map(\.section) != rows.map(\.section) else { continue }
            preset.joysticks[j].bindings = regrouped
            changed = true
        }
        return changed
    }

    /// Points a shipped Steam Controller preset's group at its controller
    /// when it is still on Auto-detect. Returns true when set.
    @discardableResult
    static func fillSteamTarget(_ preset: inout Preset) -> Bool {
        let target: String
        switch preset.name {
        case "Steam Controller": target = steamTarget2015
        case "Steam Controller (2026)": target = steamTarget2026
        default: return false
        }
        guard preset.joysticks.count == 1, preset.joysticks[0].customName == nil,
              preset.joysticks[0].inputKind == .auto else { return false }
        preset.joysticks[0].customName = target
        preset.joysticks[0].inputKind = .controller
        return true
    }

    /// Gives a shipped copy its family if it has none. Returns true when set.
    @discardableResult
    static func fillButtonFamily(_ preset: inout Preset) -> Bool {
        guard preset.buttonFamily == nil, let family = buttonFamilies[preset.name] else { return false }
        preset.buttonFamily = family
        return true
    }

    static func fillShippedSections(_ preset: inout Preset) -> Bool {
        var changed = false
        for j in preset.joysticks.indices {
            let rows = preset.joysticks[j].bindings
            guard !rows.isEmpty, rows.allSatisfy({ ($0.section ?? "").isEmpty }) else { continue }
            let grouped = ControllerScaffold.grouped(rows, family: preset.buttonFamily ?? buttonFamilies[preset.name])
            let sections = Set(grouped.compactMap(\.section))
            guard sections.count > 1 else { continue }
            preset.joysticks[j].bindings = grouped
            changed = true
        }
        return changed
    }

    /// Per-feature lookup so the welcome demos can jump to the matching
    /// showcase preset. Key is a stable identifier; value is the preset name.
    static let demoPresetNames: [String: String] = [
        "voice_commands":       "Voice Commands",
        "touchpad_regions":     "Touchpad Zones",
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
        "midi_input":           "MIDI: Knob Deck",
        "system_control":       "Media Controller",
        "siri_shortcuts":       "Shortcuts & Apps",
        "input_remap":          "Keyboard & Mouse Input",
        "mac_trackpad":         "Trackpad & Mouse",
        "modifier_holds":       "Modifier Holds",
        "hold_double_tap":      "Hold & Double-Tap",
        "app_auto_switch":      "Anki",
        "cursor_regions":       "Cursor Regions",
        "stick_zones":          "Stick Zones & Gestures",
        "light_bar":            "FPS (PS5 DualSense)",
        "keyboard_mouse":       "Desktop Navigation",
    ]

    /// Map a connected controller's brand to the best built-in example
    /// preset to jump to from the controller info popover. Brands we don't
    /// ship a tailored layout for (generic MFi pads, unrecognized brands such
    /// as Lightfire, and Stadia) fall back to the Xbox FPS layout, which uses
    /// the standard extended-gamepad indices, A/B/X/Y names, and no touchpad
    /// row, so it works on any controller. This guarantees every
    /// connected controller has a "Take me to an example" destination.
    /// The 2026 Steam Controller shares the 2015 model's brand but has its
    /// own preset, so the slot's family decides between them.
    static func exampleName(for brand: ControllerBrand, family: FaceLetters?) -> String {
        family == .steamController2026 ? "Steam Controller (2026)" : exampleName(for: brand)
    }

    static func exampleName(for brand: ControllerBrand) -> String {
        switch brand {
        case .xbox:                       return "FPS (Xbox)"
        case .switchPro, .joyConLeft,
             .joyConRight, .joyConPair:   return "FPS (Switch Pro)"
        case .eightBitDo:                 return "FPS (8BitDo)"
        case .accessController:           return "Access Controller"
        case .dualSense, .dualShock4:    return "FPS (PS5 DualSense)"
        // A/B/X/Y names, no touchpad row, the same standard numbering.
        case .stadia, .mfiGeneric, .unknown: return "FPS (Xbox)"
        case .steamController:            return "Steam Controller"
        }
    }

    // MARK: - The seed list

    static var all: [Preset] {
        // A JSON preset that failed to parse (nil) is left out.
        let seeds: [Preset?] = [
            // Desktop & Productivity
            easyBrowse,
            easyEdit,
            desktopNavigation,
            webBrowsing,
            mouseScroll,
            mediaController,
            presentationRemote,
            anki,
            accessController,
            trackpadAndMouse,
            modifierHolds,
            doubleClickDeck,
            autoClicker,

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
            midiKnobDeck,
            midiMediaDeck,

            // Feature Showcases (programmatic, exercise advanced features)
            showcaseVariableSensitivity,
            showcaseDeadzoneCalibration,
            showcaseHapticFeedback,
            showcaseSpokenFeedback,
            showcaseMacrosTurbo,
            showcaseTouchpadMouse,
            showcaseSteamController,
            showcaseSteamController2026,
            showcaseGyroAim,
            showcaseMotionCursor,
            showcaseToggleMode,
            showcaseStackedOutputs,
            showcaseMidiCC,
            showcaseVoiceCommands,
            showcaseTouchpadZones,
            showcaseCursorRegions,
            showcaseStickZones,
            showcaseHoldDoubleTap,
            showcaseKeyboardMouseInput,
            showcaseShortcutsAndApps,
            oneStickDriving,
        ]
        return seeds.compactMap { $0 }
    }

    /// The built-ins by name, made once: `all` builds every preset again
    /// on each call, and the one-shot upgrades looked one up per preset.
    /// For comparing against and copying rows from, not for seeding, which
    /// takes a fresh copy with its own ids.
    static let byName: [String: Preset] = {
        var out: [String: Preset] = [:]
        for example in all where out[example.name] == nil { out[example.name] = example }
        return out
    }()

    // MARK: - Desktop & Productivity (JSON)

    static var desktopNavigation: Preset? {
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
                    "btn 0": ["mbt 0"],
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
                    "btn 9": ["key 40"],
                    "btn 12": ["key 227", "key 4"]
                }
            }]
        }
        """)
    }

    static var webBrowsing: Preset? {
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
                    "btn 4": ["key 227", "key 47"],
                    "btn 5": ["key 227", "key 48"],
                    "axi 4 +": ["key 227", "key 225", "key 47"],
                    "axi 5 +": ["key 227", "key 225", "key 48"],
                    "btn 8": ["key 227", "key 15"],
                    "btn 9": ["key 227", "key 43"]
                }
            }]
        }
        """)
    }

    static var mouseScroll: Preset? {
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

    static let easyBrowseName = "Easy Browse"

    /// The ready-made layout the welcome screen offers first: a calm way to
    /// use the whole Mac from a controller, named for what it does rather
    /// than for who might want it (it was Easy Mac until a tester pointed out
    /// that name belongs to a boxed macaroni, and Mac to Apple). The same
    /// layout as the guide
    /// preset on inputconfig.com (a tester's own, the jobs used most on the
    /// bumpers and the D-pad), plus the pointer ramp-up and a short buzz on
    /// the two stick presses.
    static var easyBrowse: Preset {
        func pointer(_ axis: Int, _ dir: AxisDirection, _ mouseAxis: MouseAxis, _ mouseDir: MouseDirection, _ note: String) -> BindingModel {
            BindingModel(input: .axis(axis, direction: dir),
                         outputs: [OutputAction(type: .mouseMotion, mouseAxis: mouseAxis, mouseDirection: mouseDir, speed: 9)],
                         deadzone: 0.28, sensitivityCurve: .exponential, variableSensitivity: true,
                         rampMs: 400, note: note)
        }
        func scroll(_ dir: AxisDirection, _ wheelDir: MouseDirection, _ note: String) -> BindingModel {
            BindingModel(input: .axis(3, direction: dir),
                         outputs: [OutputAction(type: .mouseWheel, mouseAxis: .vertical, mouseDirection: wheelDir, speed: 4)],
                         deadzone: 0.25, variableSensitivity: true, note: note)
        }
        func key(_ codes: [Int]) -> [OutputAction] { codes.map { OutputAction(type: .key, keyCode: $0) } }
        func system(_ kind: SystemActionKind) -> [OutputAction] { [OutputAction(type: .systemAction, systemActionKind: kind)] }
        let bindings: [BindingModel] = [
            pointer(0, .negative, .horizontal, .negative, "Pointer left"),
            pointer(0, .positive, .horizontal, .positive, "Pointer right"),
            pointer(1, .negative, .vertical, .negative, "Pointer up"),
            pointer(1, .positive, .vertical, .positive, "Pointer down"),
            scroll(.negative, .negative, "Scroll up"),
            scroll(.positive, .positive, "Scroll down"),
            BindingModel(input: .button(0), outputs: [OutputAction(type: .mouseButton, mouseButtonIndex: 0)],
                         hapticEnabled: true, hapticIntensity: 0.3,
                         speechEnabled: true, speechText: "click", speechDestination: .controller, note: "Click"),
            BindingModel(input: .button(1), outputs: key([227, 47]),
                         speechEnabled: true, speechText: "back", speechDestination: .controller, note: "Go back"),
            BindingModel(input: .button(2), outputs: key([41]),
                         speechEnabled: true, speechText: "close", speechDestination: .controller, note: "Close menus and pop-ups"),
            BindingModel(input: .button(3), outputs: key([40]),
                         speechEnabled: true, speechText: "open", speechDestination: .controller, note: "Confirm, open, send"),
            BindingModel(input: .button(11), outputs: [OutputAction(type: .mouseButton, mouseButtonIndex: 0)],
                         toggleMode: true, hapticEnabled: true, hapticIntensity: 0.8,
                         note: "Left stick press: grab and drop (press once to hold the click, again to let go)"),
            BindingModel(input: .button(12), outputs: [OutputAction(type: .mouseButton, mouseButtonIndex: 0)],
                         repeatCount: 2, repeatDelayMs: 80, hapticEnabled: true, hapticIntensity: 0.8,
                         note: "Right stick press: double click"),
            BindingModel(input: .button(4), outputs: system(.startDictation), note: "Start Dictation, press again to stop"),
            BindingModel(input: .button(5), outputs: system(.speakSelection), note: "Read Selection: reads the selected text aloud"),
            BindingModel(input: .button(9), outputs: system(.spotlight), note: "Spotlight: type the first letters of anything"),
            BindingModel(input: .button(8), outputs: system(.missionControl), note: "Mission Control: every open window at once"),
            BindingModel(input: .button(13), outputs: system(.spotlight), note: "Spotlight: type the first letters of anything"),
            BindingModel(input: .hat(0, direction: .left), outputs: key([227, 47]), note: "Back one web page"),
            BindingModel(input: .hat(0, direction: .right), outputs: key([227, 48]), note: "Forward one web page"),
            BindingModel(input: .hat(0, direction: .down), outputs: key([227, 225, 47]), note: "Previous tab"),
            BindingModel(input: .hat(0, direction: .up), outputs: key([227, 225, 48]), note: "Next tab"),
        ]
        var preset = makePreset(
            name: easyBrowseName,
            tag: "A calm layout for using the whole Mac from a controller",
            joystickTag: "Left stick = pointer (starts slow), right stick = scroll, A click, B back, X close, Y open, L3 grab and drop, R3 double click, LB dictation, RB read aloud, Start or touchpad = Spotlight, Back = Mission Control, D-pad = web pages and tabs",
            bindings: bindings,
            light: RGBLightColor(r: 90, g: 200, b: 120))
        preset.automation.dpadOneDirection = true
        return preset
    }

    static let easyEditName = "Easy Edit"

    /// The companion to Easy Browse for someone who keeps a mouse or trackpad in
    /// the other hand: a tester's own layout, one job per button, the four
    /// editing shortcuts together on the D-pad the way they sit together on
    /// a keyboard, and the D-pad counting one direction at a time so a quick
    /// press never fires Cut in place of Copy.
    static var easyEdit: Preset {
        func key(_ codes: [Int]) -> [OutputAction] { codes.map { OutputAction(type: .key, keyCode: $0) } }
        func system(_ kind: SystemActionKind) -> [OutputAction] { [OutputAction(type: .systemAction, systemActionKind: kind)] }
        func spoken(_ input: InputEvent, _ outputs: [OutputAction], _ word: String, _ note: String) -> BindingModel {
            BindingModel(input: input, outputs: outputs,
                         speechEnabled: true, speechText: word, speechDestination: .controller, note: note)
        }
        func scroll(_ dir: AxisDirection, _ wheelDir: MouseDirection, _ note: String) -> BindingModel {
            BindingModel(input: .axis(3, direction: dir),
                         outputs: [OutputAction(type: .mouseWheel, mouseAxis: .vertical, mouseDirection: wheelDir, speed: 4)],
                         deadzone: 0.25, variableSensitivity: true, note: note)
        }
        let bindings: [BindingModel] = [
            BindingModel(input: .axis(1, direction: .positive), outputs: system(.speakSelection),
                         deadzone: 0.28, note: "Left stick down: read the selected text aloud"),
            BindingModel(input: .axis(1, direction: .negative), outputs: system(.startDictation),
                         deadzone: 0.49, note: "Left stick up, pushed firmly: start Dictation, again to stop"),
            scroll(.negative, .negative, "Scroll up"),
            scroll(.positive, .positive, "Scroll down"),
            spoken(.button(0), key([42]), "delete", "Delete: erases the letter before the cursor, or the selection"),
            spoken(.button(1), key([227, 22]), "save", "Save (Command S)"),
            spoken(.button(2), key([44]), "space", "Space"),
            spoken(.button(3), key([40]), "return", "Return: confirm, open, send"),
            BindingModel(input: .button(11), outputs: system(.missionControl),
                         hapticEnabled: true, hapticIntensity: 0.8,
                         note: "Left stick press: Mission Control, every open window at once"),
            BindingModel(input: .button(13), outputs: system(.missionControl),
                         note: "Touchpad press: Mission Control, the same as the left stick press"),
            BindingModel(input: .button(6), outputs: key([227, 47]), note: "Back one web page"),
            BindingModel(input: .button(4), outputs: key([227, 48]), note: "Forward one web page"),
            BindingModel(input: .button(7), outputs: key([227, 225, 47]), note: "Previous tab"),
            BindingModel(input: .button(5), outputs: key([227, 225, 48]), note: "Next tab"),
            BindingModel(input: .button(8), outputs: key([227, 15]), note: "Browser address bar (Command L): type a search or an address"),
            BindingModel(input: .button(9), outputs: system(.spotlight), note: "Spotlight: type the first letters of anything"),
            spoken(.hat(0, direction: .up), key([227, 29]), "undo", "Undo (Command Z)"),
            spoken(.hat(0, direction: .down), key([227, 6]), "copy", "Copy (Command C)"),
            spoken(.hat(0, direction: .left), key([227, 27]), "cut", "Cut (Command X)"),
            spoken(.hat(0, direction: .right), key([227, 25]), "paste", "Paste (Command V)"),
        ]
        var preset = makePreset(
            name: easyEditName,
            tag: "A calm editing layout for one hand, with a mouse in the other",
            joystickTag: "D-pad = undo, copy, cut, paste; A delete, B save, X space, Y return; left stick down = read aloud, up = dictation; right stick = scroll; LT and LB = back and forward a page, RT and RB = previous and next tab; Back = address bar, Start = Spotlight, L3 or touchpad = Mission Control",
            bindings: bindings,
            light: RGBLightColor(r: 90, g: 150, b: 230))
        preset.automation.dpadOneDirection = true
        return preset
    }

    static var mediaController: Preset? {
        parse("""
        {
            "name": "Media Controller",
            "tag": "Play, pause, volume, track skip",
            "joysticks": [{
                "tag": "Face buttons control playback, D-pad controls volume",
                "binds": {
                    "btn 0": ["sys ply"],
                    "btn 1": ["sys nxt"],
                    "btn 2": ["sys prv"],
                    "btn 3": ["sys mut"],
                    "btn 4": ["sys vdn"],
                    "btn 5": ["sys vup"],
                    "hat 0 U": ["sys vup"],
                    "hat 0 D": ["sys vdn"],
                    "hat 0 L": ["sys prv"],
                    "hat 0 R": ["sys nxt"],
                    "axi 1 -": ["sys vup"],
                    "axi 1 +": ["sys vdn"],
                    "axi 0 -": ["sys prv"],
                    "axi 0 +": ["sys nxt"],
                    "btn 8": ["key 41"]
                }
            }]
        }
        """)
    }

    static var presentationRemote: Preset? {
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

    /// Anki flashcard review from any controller. Built with BindingModel
    /// rather than the JSON path so every row carries a note naming its
    /// Anki action, the way Smart Presets do. Shortcuts checked against the
    /// Anki 26.8 reviewer: Space shows the answer and then rates Good (the
    /// "Spacebar (or enter) also answers card" default), 1 / 2 / 4 are
    /// Again / Hard / Easy, R replays audio, * marks, - buries the card,
    /// E edits, Cmd+Z undoes, D and S jump to the deck list and study.
    static var anki: Preset {
        let bindings: [BindingModel] = [
            // Face buttons rate the card. Bottom shows the answer, then
            // rates Good, so one thumb can run a whole session.
            bind("btn 0",   ["key 44"],            "Show answer / Good (Space)"),
            bind("btn 2",   ["key 30"],            "Again (1)"),
            bind("btn 1",   ["key 31"],            "Hard (2)"),
            bind("btn 3",   ["key 33"],            "Easy (4)"),
            // Bumpers: take back a mis-rating, hear the audio again.
            bind("btn 4",   ["key 227", "key 29"], "Undo (Cmd+Z)"),
            bind("btn 5",   ["key 21"],            "Replay audio (R)"),
            // Share / Menu: hop between the deck list and studying.
            bind("btn 8",   ["key 7"],             "Deck list (D)"),
            bind("btn 9",   ["key 22"],            "Study deck (S)"),
            // Stick clicks mark and bury. DualSense touchpad click edits.
            bind("btn 11",  ["key 225", "key 37"], "Mark / unmark (*)"),
            bind("btn 12",  ["key 45"],            "Bury card (-)"),
            bind("btn 13",  ["key 8"],             "Edit card (E)"),
            // Left stick = pointer, right stick = scroll, triggers = click,
            // the same hands as the other desktop presets.
            bind("axi 0 -", ["mou 0 - 16"],        "Pointer left"),
            bind("axi 0 +", ["mou 0 + 16"],        "Pointer right"),
            bind("axi 1 -", ["mou 1 - 16"],        "Pointer up"),
            bind("axi 1 +", ["mou 1 + 16"],        "Pointer down"),
            bind("axi 3 -", ["whe 1 - 5"],         "Scroll up"),
            bind("axi 3 +", ["whe 1 + 5"],         "Scroll down"),
            bind("axi 4 +", ["mbt 1"],             "Right click"),
            bind("axi 5 +", ["mbt 0"],             "Left click"),
            // D-pad = arrow keys: scroll a long card, move through lists.
            bind("hat 0 U", ["key 82"],            "Scroll card up (Up arrow)"),
            bind("hat 0 D", ["key 81"],            "Scroll card down (Down arrow)"),
            bind("hat 0 L", ["key 80"],            "Left arrow"),
            bind("hat 0 R", ["key 79"],            "Right arrow"),
        ].compactMap { $0 }
        var preset = makePreset(
            name: "Anki",
            tag: "Flashcard review: rate, undo, replay audio",
            joystickTag: "Face buttons rate the card, bumpers undo and replay, sticks drive the pointer",
            bindings: bindings)
        var automation = PresetAutomation()
        automation.launchAppPath = "/Applications/Anki.app"
        // Current Anki builds identify as net.ankiweb.anki; older releases
        // used net.ankiweb.dtop. Listing both keeps auto-switch working
        // whichever one is installed.
        automation.autoActivateBundleIDs = ["net.ankiweb.anki", "net.ankiweb.dtop"]
        preset.automation = automation
        // Anki blue light bar.
        preset.lightBarColor = RGBLightColor(r: 30, g: 130, b: 235)
        return preset
    }

    /// PlayStation Access Controller: one stick and eight button sockets,
    /// with the PS and Options buttons in the middle. Its default profile
    /// puts Cross, Circle, Square, Triangle, L1, R1, L2, and R2 on the eight
    /// sockets, which the Mac sees as buttons 0 to 7. The whole desktop from
    /// one hand: the stick is the pointer, the sockets click, scroll, and hit
    /// the keys that matter most.
    static var accessController: Preset {
        var bindings: [BindingModel] = [
            bind("axi 0 -", ["mou 0 - 18"],  "Stick left: pointer left"),
            bind("axi 0 +", ["mou 0 + 18"],  "Stick right: pointer right"),
            bind("axi 1 -", ["mou 1 - 18"],  "Stick up: pointer up"),
            bind("axi 1 +", ["mou 1 + 18"],  "Stick down: pointer down"),
            // Sony's base profile reports Cross on the center button, Circle
            // on socket 5, Options on socket 7, and the stick. The other
            // buttons reach the Mac once a profile made on a PS5 gives them
            // to sockets. The PS button reaches the app as button 50 through
            // the controller's own report (AccessControllerPortService).
            bind("btn 0",   ["mbt 0"],       "Center button (Cross): left click"),
            bind("btn 1",   ["mbt 1"],       "Socket 5 (Circle): right click"),
            bind("btn 2",   ["mbt 0"],       "Square (in a PS5 profile): double click"),
            bind("btn 3",   ["key 40"],      "Triangle (in a PS5 profile): Return"),
            bind("btn 4",   ["whe 1 - 5"],   "L1 (in a PS5 profile): scroll up while held"),
            bind("btn 5",   ["whe 1 + 5"],   "R1 (in a PS5 profile): scroll down while held"),
            bind("btn 6",   ["key 227"],     "L2 (in a PS5 profile): hold Command, for Command-click and shortcuts"),
            bind("btn 7",   ["key 44"],      "R2 (in a PS5 profile): Space"),
            bind("btn 8",   ["sys mct"],     "Create (in a PS5 profile): Mission Control"),
            bind("btn 9",   ["sys spt"],     "Socket 7 (Options): Spotlight"),
        ].compactMap { $0 }
        // Square is a double click: one press, two clicks.
        if let i = bindings.firstIndex(where: { $0.input.serialized == "btn 2" }) {
            bindings[i].repeatCount = 2
            bindings[i].repeatDelayMs = 60
        }
        // Its one stick is just "Stick", not a left one.
        for i in bindings.indices {
            switch bindings[i].input.type {
            case .axis: bindings[i].section = "Stick"
            case .button: bindings[i].section = bindings[i].input.index >= 8 ? "Menu buttons" : "Buttons"
            default: break
            }
        }
        return makePreset(
            name: "Access Controller",
            tag: "One stick and eight buttons for the whole desktop",
            joystickTag: "Stick = pointer; center button clicks, socket 5 right-clicks, socket 7 opens Spotlight; more with a PS5 profile",
            bindings: bindings)
    }

    /// One-Stick Driving: the whole car from a single joystick. The stick is
    /// owned by the preset's Drive block (the One-Stick Driving section in
    /// the editor), which steers, accelerates, brakes, and shifts from it,
    /// so no rows are bound to the stick axes. The eight sockets of a
    /// PlayStation Access Controller (or any eight buttons) take the rest.
    static var oneStickDriving: Preset {
        var bindings: [BindingModel] = [
            // Named by the button each socket sends, not the socket: on an
            // Access controller's base profile only Cross (the center
            // button), Circle (socket 5) and Options (socket 7) send.
            bind("btn 0", ["key 44"],  "Cross: handbrake (Space)"),
            bind("btn 1", ["key 11"],  "Circle: horn (H)"),
            bind("btn 2", ["key 225"], "Square: boost (Shift)"),
            bind("btn 3", ["key 21"],  "Triangle: reset the car (R)"),
            bind("btn 4", ["key 20"],  "L1: shift down (Q)"),
            bind("btn 5", ["key 8"],   "R1: shift up (E)"),
            bind("btn 6", ["key 6"],   "L2: change camera (C)"),
            bind("btn 7", ["key 43"],  "R2: rewind / flashback (Tab)"),
            bind("btn 8", ["key 41"],  "Create: pause (Escape)"),
            bind("btn 9", ["key 40"],  "Options: confirm (Return)"),
        ].compactMap { $0 }
        for i in bindings.indices {
            bindings[i].section = bindings[i].input.index >= 8 ? "Menu buttons" : "Sockets"
        }
        var preset = makePreset(
            name: "One-Stick Driving",
            tag: "Steer, gas, brake, and reverse from one joystick",
            joystickTag: "The stick drives (see the One-Stick Driving section); sockets are handbrake, horn, boost, reset, gears, camera, rewind",
            bindings: bindings)
        var drive = DriveConfig()
        drive.enabled = true
        drive.slot = 0
        drive.steerAxis = 0
        drive.throttleAxis = 1
        // Keys, not mouse: every racer that can be driven from a keyboard
        // takes A / D for steering, and few take mouse steering.
        drive.steerMode = .keys
        drive.steerLeftKey = 4      // A
        drive.steerRightKey = 7     // D
        drive.accelKey = 26         // W
        drive.brakeKey = 22         // S
        drive.reverseKey = 22       // S again once stopped, as most games treat it
        drive.deadzone = 0.15
        drive.steerCurve = 1.4      // gentle near center, full lock at the edge
        drive.throttleCurve = 1.3   // fine low-speed control
        // Let go of the stick and the car slows like a power chair does.
        drive.coastBrake = true
        drive.coastBrakeStrength = 0.35
        drive.reverseGestureEnabled = true
        drive.reverseTapCount = 2
        drive.reverseWindowMs = 700
        preset.driveConfig = drive
        return preset
    }

    // MARK: - Gaming - First-Person (JSON)

    static var fpsDualSense: Preset? {
        guard var preset = parse("""
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
                    "btn 12": ["key 8"],
                    "hat 0 U": ["whs 1 -"],
                    "hat 0 D": ["whs 1 +"],
                    "hat 0 L": ["key 20"],
                    "hat 0 R": ["key 9"],
                    "btn 8": ["key 43"],
                    "btn 9": ["key 41"],
                    "btn 13": ["key 16"]
                }
            }]
        }
        """) else { return nil }
        // PlayStation blue on the light bar whenever this preset is active.
        preset.lightBarColor = RGBLightColor(r: 0, g: 112, b: 209)
        return preset
    }

    static var fpsXbox: Preset? {
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
                    "btn 8": ["key 43"],
                    "btn 9": ["key 41"]
                }
            }]
        }
        """)
    }

    static var fpsSwitchPro: Preset? {
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

    static var fpsEightBitDo: Preset? {
        parse("""
        {
            "name": "FPS (8BitDo)",
            "tag": "8BitDo Pro 2, Ultimate, SN30 Pro+ in D mode",
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
                    "btn 8": ["key 43"],
                    "btn 9": ["key 41"]
                }
            }]
        }
        """)
    }

    // MARK: - Gaming - Genre (JSON)

    static var minecraft: Preset? {
        guard var preset = parse("""
        {
            "name": "Minecraft",
            "tag": "Full Minecraft controls, works with any controller",
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
                    "btn 12": ["key 9"],
                    "hat 0 U": ["key 30"],
                    "hat 0 R": ["key 31"],
                    "hat 0 D": ["key 32"],
                    "hat 0 L": ["key 33"],
                    "btn 8": ["key 43"],
                    "btn 9": ["key 41"]
                }
            }]
        }
        """) else { return nil }
        // The legacy JSON parser doesn't carry automation, so we inject
        // it here: the launcher app fires on activate, and the cursor is
        // kept off the screen edges, so a full-screen game never brings up
        // the Dock or the menu bar. Not recentered or hidden (1.7):
        // Minecraft locks and hides the mouse itself while playing and reads
        // the movement InputConfig sends, so both did nothing in play, and
        // in the inventory and menus recentering pulled the pointer back to
        // the middle four times a second and hiding took it away. Survival-
        // grass green light bar.
        preset.automation = PresetAutomation(
            launchAppPath: "/Applications/Minecraft.app",
            launchURL: "",
            confineCursor: true,
            confineBufferPx: 24,
            autoRecenterCursor: false,
            autoRecenterIntervalMs: 250,
            hideCursorWhileActive: false,
            sensitivityMultiplier: 1.0
        )
        preset.lightBarColor = RGBLightColor(r: 60, g: 200, b: 80)
        let (ring, row) = minecraftSprintRing
        preset.joysticks[0].bindings.append(row)
        preset.stickRegions["0"] = [ring]
        return preset
    }

    /// Pushed all the way forward the left stick sprints, as Minecraft on a
    /// console does at full push (Control, Java's sprint key), while W keeps
    /// walking under it. Flicking forward twice sprints too, as Java's double
    /// tap of W. Added in 1.7; a library from before is offered it
    /// (BuiltInUpdate.minecraftSprint).
    static let minecraftSprintID = UUID(uuidString: "5A1E0004-0000-4000-8000-000000000001")!
    static var minecraftSprintRing: (TouchpadRegion, BindingModel) {
        var ring = TouchpadRegion.ring(name: "Sprint", SmartPresetGenerator.sprintRing, colorIndex: 3)
        ring.id = minecraftSprintID
        var row = BindingModel(input: .stickRegion(stickIndex: 0, id: minecraftSprintID),
                               outputs: [OutputAction(type: .key, keyCode: 224)],
                               note: "All the way up: Control to sprint, as well as W (this ring shares the stick)")
        row.zoneSharesStick = true
        return (ring, row)
    }

    static var fortnite: Preset? {
        parse("""
        {
            "name": "Fortnite",
            "tag": "Move, shoot, ADS, and full building",
            "joysticks": [{
                "tag": "WASD + mouse-look; bumpers/d-pad place Wall/Floor/Stairs/Roof, R3 edit, LT aim",
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
                    "btn 1": ["key 224"],
                    "btn 2": ["key 21"],
                    "btn 3": ["key 8"],
                    "btn 4": ["key 29"],
                    "btn 5": ["key 27"],
                    "btn 11": ["key 225"],
                    "btn 12": ["key 10"],
                    "hat 0 U": ["key 6"],
                    "hat 0 D": ["key 25"],
                    "hat 0 L": ["key 30"],
                    "hat 0 R": ["key 16"],
                    "btn 8": ["key 43"],
                    "btn 9": ["key 41"]
                }
            }]
        }
        """)
    }

    static var racingGame: Preset? {
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
                    "btn 8": ["key 43"],
                    "btn 9": ["key 41"]
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
            // D-pad runs transport: start, stop, continue.
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
        // Triggers hit a low tom and a crash cymbal.
        bindings.append(BindingModel(input: .axis(4, direction: .positive),
                                     outputs: [OutputAction(type: .midiNote, midiNote: 41, midiVelocity: 100, midiChannel: 10)]))
        bindings.append(BindingModel(input: .axis(5, direction: .positive),
                                     outputs: [OutputAction(type: .midiNote, midiNote: 49, midiVelocity: 100, midiChannel: 10)]))
        return makePreset(
            name: "MIDI: Drum Pad",
            tag: "Finger-drumming pads with turbo for rolls",
            joystickTag: "Face buttons = drum kit pieces with turbo (hold for rolls), triggers = low tom and crash",
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
            // A button CC sends its value on press and 0 on release, so
            // CC 7 itself dropped the volume to 0 on every release. Two
            // trigger CCs, learned in the DAW as volume up and down, work.
            BindingModel(input: .hat(0, direction: .up),
                         outputs: [OutputAction(type: .midiCC, midiCCNumber: 20, midiCCValue: 127, midiChannel: 1)]),
            BindingModel(input: .hat(0, direction: .down),
                         outputs: [OutputAction(type: .midiCC, midiCCNumber: 21, midiCCValue: 127, midiChannel: 1)]),
        ]
        return makePreset(
            name: "MIDI: Transport Control",
            tag: "DAW remote: start, stop, continue, program change",
            joystickTag: "A = Start, B = Stop, X = Continue, LB/RB = patch 1/2",
            bindings: bindings)
    }


    /// Showcase for MIDI as an *input*: a small knob deck that drives the
    /// Mac with no game controller connected. Exercises all three knob
    /// modes plus the System Volume fader, so it doubles as living
    /// documentation for the knob-mode feature set.
    static var midiKnobDeck: Preset {
        let bindings: [BindingModel] = [
            // CC 7 is MIDI's own channel-volume controller, so this reads
            // exactly as labeled on most keyboards and knob boxes.
            BindingModel(input: .midi(.cc, number: 7),
                         outputs: [OutputAction(type: .absoluteVolume)],
                         note: "Volume knob (CC 7): Mac volume follows it, engages once you move it"),
            // Dial mode wants a control that rests at its center: a pan
            // knob (CC 10) with a center detent. The mod wheel it used
            // before stays wherever it is left, usually at the bottom,
            // which read as "below center" and scrolled forever.
            BindingModel(input: .midi(.cc, number: 10, direction: .positive, ccMode: .centered),
                         outputs: [OutputAction(type: .mouseWheel, mouseAxis: .vertical, mouseDirection: .positive, speed: 6)],
                         note: "Pan knob (CC 10) right of center: scroll down, faster the further you turn"),
            BindingModel(input: .midi(.cc, number: 10, direction: .negative, ccMode: .centered),
                         outputs: [OutputAction(type: .mouseWheel, mouseAxis: .vertical, mouseDirection: .negative, speed: 6)],
                         note: "Pan knob (CC 10) left of center: scroll up"),
            BindingModel(input: .midi(.cc, number: 71, direction: .positive, ccMode: .relative),
                         outputs: [OutputAction(type: .key, keyCode: 79)],
                         note: "Knob (CC 71) clockwise: Right Arrow per step"),
            BindingModel(input: .midi(.cc, number: 71, direction: .negative, ccMode: .relative),
                         outputs: [OutputAction(type: .key, keyCode: 80)],
                         note: "Knob (CC 71) counterclockwise: Left Arrow per step"),
            BindingModel(input: .midi(.cc, number: 64),
                         outputs: [OutputAction(type: .mouseButton, mouseButtonIndex: 0)],
                         note: "Sustain pedal: hold left click, press and sweep to drag"),
            BindingModel(input: .midi(.note, number: 36),
                         outputs: [OutputAction(type: .key, keyCode: 40)],
                         note: "Pad / low C (note 36): Return"),
            BindingModel(input: .midi(.note, number: 37),
                         outputs: [OutputAction(type: .key, keyCode: 41)],
                         note: "Pad / C sharp (note 37): Escape"),
        ]
        return makePreset(
            name: "MIDI: Knob Deck",
            tag: "MIDI input drives the Mac: volume fader, Dial scroll, Turn nudges",
            joystickTag: "CC 7 = volume fader, CC 10 pan knob = scroll, CC 71 = arrows, pedal = click",
            bindings: bindings)
    }


    /// Showcase for System Function outputs: a MIDI pad row and two knobs
    /// running the Mac itself - media keys, stepped volume, brightness,
    /// mute, Mission Control - no game controller required.
    static var midiMediaDeck: Preset {
        let bindings: [BindingModel] = [
            BindingModel(input: .midi(.cc, number: 7),
                         outputs: [OutputAction(type: .absoluteVolume)],
                         note: "Volume knob (CC 7): the Mac's volume follows it"),
            BindingModel(input: .midi(.cc, number: 71, direction: .positive, ccMode: .relative),
                         outputs: [OutputAction(type: .systemAction, systemActionKind: .volumeUp)],
                         note: "Knob (CC 71) clockwise: volume up one step"),
            BindingModel(input: .midi(.cc, number: 71, direction: .negative, ccMode: .relative),
                         outputs: [OutputAction(type: .systemAction, systemActionKind: .volumeDown)],
                         note: "Knob (CC 71) counterclockwise: volume down one step"),
            BindingModel(input: .midi(.cc, number: 74, direction: .positive, ccMode: .relative),
                         outputs: [OutputAction(type: .systemAction, systemActionKind: .brightnessUp)],
                         note: "Knob (CC 74) clockwise: brightness up"),
            BindingModel(input: .midi(.cc, number: 74, direction: .negative, ccMode: .relative),
                         outputs: [OutputAction(type: .systemAction, systemActionKind: .brightnessDown)],
                         note: "Knob (CC 74) counterclockwise: brightness down"),
            BindingModel(input: .midi(.note, number: 36),
                         outputs: [OutputAction(type: .systemAction, systemActionKind: .playPause)],
                         note: "Pad 1 (note 36): play / pause"),
            BindingModel(input: .midi(.note, number: 37),
                         outputs: [OutputAction(type: .systemAction, systemActionKind: .nextTrack)],
                         note: "Pad 2 (note 37): next track"),
            BindingModel(input: .midi(.note, number: 38),
                         outputs: [OutputAction(type: .systemAction, systemActionKind: .previousTrack)],
                         note: "Pad 3 (note 38): previous track"),
            BindingModel(input: .midi(.note, number: 39),
                         outputs: [OutputAction(type: .systemAction, systemActionKind: .muteToggle)],
                         note: "Pad 4 (note 39): mute / unmute"),
            BindingModel(input: .midi(.note, number: 40),
                         outputs: [OutputAction(type: .systemAction, systemActionKind: .missionControl)],
                         note: "Pad 5 (note 40): Mission Control"),
            BindingModel(input: .midi(.note, number: 41),
                         outputs: [OutputAction(type: .systemAction, text: "Music", systemActionKind: .openApp)],
                         note: "Pad 6 (note 41): open the Music app"),
        ]
        return makePreset(
            name: "MIDI: Media Deck",
            tag: "Pads and knobs run the Mac: media keys, volume, brightness",
            joystickTag: "CC 7 = fader, CC 71 = volume steps, CC 74 = brightness, pads = media",
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
            joystickTag: "Open a stick row's Options and choose Adjust live to see the live ring visualizer",
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
            bindings: bindings,
            light: RGBLightColor(r: 255, g: 89, b: 0))
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
            joystickTag: "Every phrase plays on the Mac's sound output; pick the controller there in System Settings, Sound",
            bindings: bindings)
    }

    static var showcaseMacrosTurbo: Preset {
        // RB fires the spacebar 12 times per second while held (turbo).
        // A runs a macro that copies, switches windows, then pastes.
        // LB repeats the J key three times with a short delay.
        // Copies, switches windows, and pastes. Uses Hold down / Release
        // step kinds so the Cmd chords actually form: an earlier version
        // used plain sequential steps, which fully release one key before
        // the next, so Cmd was already up before C went down and the
        // chain typed plain letters.
        let copyPasteMacro: [MacroStep] = [
            MacroStep(action: OutputAction(type: .key, keyCode: 227),  // Cmd held...
                      delayMs: 0, holdMs: 30, eventKind: .down),
            MacroStep(action: OutputAction(type: .key, keyCode: 6),    // ...C taps inside it
                      delayMs: 30, holdMs: 50),
            MacroStep(action: OutputAction(type: .key, keyCode: 227),  // Cmd up
                      delayMs: 30, holdMs: 0, eventKind: .up),
            MacroStep(action: OutputAction(type: .key, keyCode: 227),  // Cmd held...
                      delayMs: 200, holdMs: 30, eventKind: .down),
            MacroStep(action: OutputAction(type: .key, keyCode: 43),   // ...Tab switches window
                      delayMs: 30, holdMs: 50),
            MacroStep(action: OutputAction(type: .key, keyCode: 227),  // Cmd up
                      delayMs: 30, holdMs: 0, eventKind: .up),
            MacroStep(action: OutputAction(type: .key, keyCode: 227),  // Cmd held...
                      delayMs: 200, holdMs: 30, eventKind: .down),
            MacroStep(action: OutputAction(type: .key, keyCode: 25),   // ...V pastes
                      delayMs: 30, holdMs: 50),
            MacroStep(action: OutputAction(type: .key, keyCode: 227),  // Cmd up
                      delayMs: 30, holdMs: 0, eventKind: .up),
        ]

        // Walks down a list and confirms: a chord-free macro that shows
        // plain sequential steps with human-readable pacing.
        let listNavigationMacro: [MacroStep] = [
            MacroStep(action: OutputAction(type: .key, keyCode: 81),   // Down arrow
                      delayMs: 0, holdMs: 40),
            MacroStep(action: OutputAction(type: .key, keyCode: 81),   // Down arrow
                      delayMs: 150, holdMs: 40),
            MacroStep(action: OutputAction(type: .key, keyCode: 81),   // Down arrow
                      delayMs: 150, holdMs: 40),
            MacroStep(action: OutputAction(type: .key, keyCode: 40),   // Return to confirm
                      delayMs: 250, holdMs: 40),
        ]
        let added = macrosTurbo19Rows
        let bindings: [BindingModel] = [
            BindingModel(input: .button(5),
                         outputs: [OutputAction(type: .key, keyCode: 44)],   // spacebar
                         turboEnabled: true, turboRate: 12,
                         hapticEnabled: true, hapticIntensity: 0.4),
            BindingModel(input: .button(0),
                         outputs: [],
                         macroSteps: copyPasteMacro),
            added.typed,
            added.sequence,
            BindingModel(input: .button(3),
                         outputs: [],
                         macroSteps: listNavigationMacro),
            BindingModel(input: .button(4),
                         outputs: [OutputAction(type: .key, keyCode: 13)],   // J
                         repeatCount: 3, repeatDelayMs: 80),
        ]
        return makePreset(
            name: "Macros & Turbo",
            tag: "RB = rapid space, A = copy/switch/paste macro, Y = list navigation, X = typed macro, Down Down B = sequence, LB = triple J",
            joystickTag: "Hold RB for turbo, tap A for the chord macro, tap Y to walk a list, tap X for the typed macro, press Down, Down, B for the sequence, tap LB for repeat",
            bindings: bindings)
    }

    /// The two rows 1.9 added to Macros & Turbo: X plays a recorded style
    /// macro, Down, Down, B is a button sequence. Shared with the update
    /// that offers them to a 1.8 copy (BuiltInUpdate.macrosTurbo19).
    static var macrosTurbo19Rows: (typed: BindingModel, sequence: BindingModel) {
        // What the recorder makes: a text, a wait, a shortcut, played at
        // double speed with a little random timing, the way a person types.
        var greetingMacro: [MacroStep] = [
            MacroStep(action: {
                var a = OutputAction(type: .typeText); a.text = "gg"; return a
            }(), delayMs: 0, holdMs: 50),
            MacroStep(action: OutputAction(type: .key, keyCode: 40),   // Return
                      delayMs: 120, holdMs: 40),
            MacroStep(action: OutputAction(type: .key, keyCode: 40),   // a pause on its own
                      delayMs: 600, holdMs: 0, eventKind: .wait),
            MacroStep(action: OutputAction(type: .key, keyCode: 25),   // Cmd V
                      delayMs: 40, holdMs: 40, eventKind: nil, modifiers: [227]),
        ]
        greetingMacro[0].holdMs = 50
        var greeting = BindingModel(input: .button(2), outputs: [], macroSteps: greetingMacro)   // X
        greeting.macroSpeed = 2.0
        greeting.macroJitterPercent = 10
        // A button sequence as an input: Down, Down, B within 600 ms. It ends
        // on B, which has no row here: A's own macro would fire with it.
        var konami = BindingModel(input: .buttonSequence([253, 253, 1]),
                                  outputs: [OutputAction(type: .key, keyCode: 44)])   // spacebar
        konami.gestureWindowMs = 600
        return (greeting, konami)
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
            // Touchpad button = left click, and a tap clicks too, the way a
            // Mac trackpad does. Two fingers tapped together right-click.
            BindingModel(input: .button(13),
                         outputs: [OutputAction(type: .mouseButton, mouseButtonIndex: 0)]),
            BindingModel(input: .touchpadGesture(.oneFingerTap),
                         outputs: [OutputAction(type: .mouseButton, mouseButtonIndex: 0)]),
            BindingModel(input: .touchpadGesture(.twoFingerTap),
                         outputs: [OutputAction(type: .mouseButton, mouseButtonIndex: 1)]),
            BindingModel(input: .button(0),
                         outputs: [OutputAction(type: .mouseButton, mouseButtonIndex: 0)]),
            BindingModel(input: .button(1),
                         outputs: [OutputAction(type: .mouseButton, mouseButtonIndex: 1)]),
        ]
        return makePreset(
            name: "Touchpad Mouse",
            tag: "DualSense / DualShock touchpad drives the mouse cursor",
            joystickTag: "Finger 1 slides the pointer, finger 2 scrolls, a tap or a press clicks, two fingers tapped right-click",
            bindings: bindings,
            light: RGBLightColor(r: 0, g: 200, b: 180))
    }

    /// Showcase: the touchpad carved into four zones, each its own button.
    /// The zones ship inside the preset with fixed ids.
    static let touchpadZoneIDs: [(id: UUID, name: String, minX: Double, maxX: Double, minY: Double, maxY: Double, color: Int)] = [
        (UUID(uuidString: "5A1E0001-0000-4000-8000-000000000001")!, "Undo",  0.00, 0.48, 0.00, 0.48, 0),
        (UUID(uuidString: "5A1E0001-0000-4000-8000-000000000002")!, "Redo",  0.52, 1.00, 0.00, 0.48, 1),
        (UUID(uuidString: "5A1E0001-0000-4000-8000-000000000003")!, "Copy",  0.00, 0.48, 0.52, 1.00, 2),
        (UUID(uuidString: "5A1E0001-0000-4000-8000-000000000004")!, "Paste", 0.52, 1.00, 0.52, 1.00, 3),
    ]

    static var showcaseTouchpadZones: Preset {
        let z = touchpadZoneIDs
        var bindings: [BindingModel] = [
            BindingModel(input: .touchpadRegion(z[0].id), outputs: [OutputAction(type: .key, keyCode: 227), OutputAction(type: .key, keyCode: 29)]),
            BindingModel(input: .touchpadRegion(z[1].id), outputs: [OutputAction(type: .key, keyCode: 227), OutputAction(type: .key, keyCode: 225), OutputAction(type: .key, keyCode: 29)]),
            BindingModel(input: .touchpadRegion(z[2].id), outputs: [OutputAction(type: .key, keyCode: 227), OutputAction(type: .key, keyCode: 6)]),
            BindingModel(input: .touchpadRegion(z[3].id), outputs: [OutputAction(type: .key, keyCode: 227), OutputAction(type: .key, keyCode: 25)]),
            BindingModel(input: .button(13), outputs: [OutputAction(type: .mouseButton, mouseButtonIndex: 0)]),
            BindingModel(input: .touchpadGesture(.twoFingerTap), outputs: [OutputAction(type: .mouseButton, mouseButtonIndex: 1)]),
        ]
        let notes = ["Top-left region: Undo (Cmd Z)", "Top-right region: Redo (Cmd Shift Z)", "Bottom-left region: Copy (Cmd C)", "Bottom-right region: Paste (Cmd V)", "Touchpad press: left click", "Two-finger tap: right click"]
        for i in bindings.indices { bindings[i].note = notes[i]; bindings[i].section = i < 4 ? "Regions" : "Touchpad" }
        for i in 0..<4 { bindings[i].hapticEnabled = true; bindings[i].hapticIntensity = 0.35 }
        var preset = makePreset(
            name: "Touchpad Zones",
            tag: "The DualSense touchpad as four soft buttons",
            joystickTag: "Four regions on the pad send Undo, Redo, Copy, and Paste with a pulse; the press clicks and a two-finger tap right-clicks",
            bindings: bindings,
            light: RGBLightColor(r: 255, g: 120, b: 40))
        preset.touchpadRegions = z.map {
            TouchpadRegion(id: $0.id, name: $0.name, minX: $0.minX, maxX: $0.maxX,
                           minY: $0.minY, maxY: $0.maxY, colorIndex: $0.color)
        }
        return preset
    }

    /// Showcase: three corners of the screen as inputs. The regions belong
    /// to this preset, which is what makes a corner mean one thing here and
    /// something else in another preset.
    static let cursorRegionIDs: [(id: UUID, name: String, minX: Double, maxX: Double, minY: Double, maxY: Double, color: Int)] = [
        (UUID(uuidString: "5A1E0002-0000-4000-8000-000000000001")!, "Top left corner",     0.00, 0.05, 0.00, 0.05, 0),
        (UUID(uuidString: "5A1E0002-0000-4000-8000-000000000002")!, "Top right corner",    0.95, 1.00, 0.00, 0.05, 1),
        (UUID(uuidString: "5A1E0002-0000-4000-8000-000000000003")!, "Bottom right corner", 0.95, 1.00, 0.95, 1.00, 2),
    ]

    static var showcaseCursorRegions: Preset {
        let r = cursorRegionIDs
        var bindings: [BindingModel] = [
            BindingModel(input: InputEvent(type: .cursorRegion, index: 0, cursorRegionID: r[0].id),
                         outputs: [OutputAction(type: .systemAction, systemActionKind: .missionControl)]),
            BindingModel(input: InputEvent(type: .cursorRegion, index: 0, cursorRegionID: r[1].id),
                         outputs: [OutputAction(type: .systemAction, systemActionKind: .spotlight)]),
            BindingModel(input: InputEvent(type: .cursorRegion, index: 0, cursorRegionID: r[2].id),
                         outputs: [OutputAction(type: .systemAction, systemActionKind: .launchpad)]),
        ]
        let notes = ["Pointer in the top-left corner: Mission Control",
                     "Pointer in the top-right corner: Spotlight",
                     "Pointer in the bottom-right corner: Launchpad"]
        for i in bindings.indices { bindings[i].note = notes[i]; bindings[i].section = "Screen corners" }
        var preset = makePreset(
            name: "Cursor Regions",
            tag: "Corners of the screen as buttons",
            joystickTag: "No controller needed: the inputs are areas of the screen, and moving the pointer into one fires it",
            bindings: bindings)
        preset.cursorRegions = r.map {
            TouchpadRegion(id: $0.id, name: $0.name, minX: $0.minX, maxX: $0.maxX,
                           minY: $0.minY, maxY: $0.maxY, colorIndex: $0.color)
        }
        return preset
    }

    /// Showcase: stick zones as rings, trigger bands, and stick gestures.
    static let stickZoneIDs: [String: UUID] = [
        "Sprint": UUID(uuidString: "5A1E0003-0000-4000-8000-000000000001")!,
        "Up": UUID(uuidString: "5A1E0003-0000-4000-8000-000000000002")!,
        "Right": UUID(uuidString: "5A1E0003-0000-4000-8000-000000000003")!,
        "Down": UUID(uuidString: "5A1E0003-0000-4000-8000-000000000004")!,
        "Left": UUID(uuidString: "5A1E0003-0000-4000-8000-000000000005")!,
        "Half pull": UUID(uuidString: "5A1E0003-0000-4000-8000-000000000006")!,
        "Full pull": UUID(uuidString: "5A1E0003-0000-4000-8000-000000000007")!,
    ]

    static var showcaseStickZones: Preset {
        let id = stickZoneIDs
        func zone(_ key: Int, _ name: String) -> InputEvent { .stickRegion(stickIndex: key, id: id[name]!) }
        var rows: [(BindingModel, String)] = []
        func add(_ input: InputEvent, _ out: [Int], _ note: String, _ section: String) {
            var b = BindingModel(input: input, outputs: out.map { OutputAction(type: .key, keyCode: $0) }, note: note)
            b.section = section
            rows.append((b, section))
        }
        add(.axis(1, direction: .negative), [26], "Left stick up: W, walk forward", "Left stick")
        add(.axis(1, direction: .positive), [22], "Left stick down: S, walk back", "Left stick")
        add(.axis(0, direction: .negative), [4], "Left stick left: A", "Left stick")
        add(.axis(0, direction: .positive), [7], "Left stick right: D", "Left stick")
        add(zone(0, "Sprint"), [225], "All the way up: Shift to sprint, as well as W (this ring shares the stick)", "Left stick")
        add(zone(1, "Up"), [82], "Right stick up ring: Up arrow", "Right stick menu")
        add(zone(1, "Right"), [79], "Right stick right ring: Right arrow", "Right stick menu")
        add(zone(1, "Down"), [81], "Right stick down ring: Down arrow", "Right stick menu")
        add(zone(1, "Left"), [80], "Right stick left ring: Left arrow", "Right stick menu")
        add(zone(104, "Half pull"), [30], "Left trigger half pulled: 1", "Left trigger")
        add(zone(104, "Full pull"), [31], "Left trigger pulled all the way: 2", "Left trigger")
        add(.stickGesture(stick: 0, [GestureStep(direction: .down), GestureStep(direction: .down)]), [41],
            "Pull the left stick straight back twice: Escape", "Gestures")
        add(.stickGesture(stick: 0, [GestureStep(direction: .right), GestureStep(direction: .right)]), [43],
            "Flick the left stick right twice: Tab (each flick also steps right with D)", "Gestures")
        var bindings = rows.map(\.0)
        // The menu's rings take over the right stick; the sprint ring shares
        // the left stick with the walking rows.
        for i in bindings.indices where bindings[i].input.type == .stickRegion { bindings[i].zoneSharesStick = false }
        bindings[4].zoneSharesStick = true
        var preset = makePreset(
            name: "Stick Zones & Gestures",
            tag: "Rings, trigger bands and flicks as buttons",
            joystickTag: "Works with any controller: walk on the left stick, a four-way menu on the right, two pulls on the left trigger, and two gestures",
            bindings: bindings)
        func ring(_ name: String, _ inner: Double, _ outer: Double, _ start: Double, _ end: Double, _ color: Int) -> TouchpadRegion {
            var r = TouchpadRegion.ring(name: name, RingSector(inner: inner, outer: outer, start: start, end: end), colorIndex: color)
            r = TouchpadRegion(id: id[name]!, name: r.name, minX: r.minX, maxX: r.maxX, minY: r.minY, maxY: r.maxY, colorIndex: color)
            r.ring = RingSector(inner: inner, outer: outer, start: start, end: end)
            return r
        }
        func band(_ name: String, _ from: Double, _ to: Double, _ color: Int) -> TouchpadRegion {
            TouchpadRegion(id: id[name]!, name: name, minX: 0, maxX: 0, minY: from, maxY: to, colorIndex: color)
        }
        preset.stickRegions = [
            "0": [ring("Sprint", 0.9, 1, 60, 120, 3)],
            "1": [ring("Up", 0.5, 1, 45, 135, 0), ring("Right", 0.5, 1, 315, 45, 1),
                  ring("Down", 0.5, 1, 225, 315, 2), ring("Left", 0.5, 1, 135, 225, 5)],
            "104": [band("Half pull", 0.3, 0.7, 4), band("Full pull", 0.7, 1, 6)],
        ]
        return preset
    }

    /// Showcase: one control, three outputs.
    static var showcaseHoldDoubleTap: Preset {
        var bindings: [BindingModel] = [
            bind("btn 0", ["mbt 0"], "A / Cross: click. Hold it for a right click, tap it twice for Return"),
            bind("btn 1", ["key 44"], "B / Circle: Space. Hold it for Escape"),
            bind("btn 4", ["key 43"], "LB / L1: Tab. Tap it twice for Shift Tab"),
        ].compactMap { $0 }
        bindings[0].holdOutputs = [OutputAction(type: .mouseButton, mouseButtonIndex: 1)]
        bindings[0].holdThresholdMs = 500
        bindings[0].doubleTapOutputs = [OutputAction(type: .key, keyCode: 40)]
        bindings[0].doubleTapWindowMs = 300
        bindings[1].holdOutputs = [OutputAction(type: .key, keyCode: 41)]
        bindings[1].holdThresholdMs = 500
        bindings[2].doubleTapOutputs = [OutputAction(type: .key, keyCode: 225), OutputAction(type: .key, keyCode: 43)]
        bindings[2].doubleTapWindowMs = 300
        for i in bindings.indices { bindings[i].section = "Buttons" }
        return makePreset(
            name: "Hold & Double-Tap",
            tag: "Three outputs on one button",
            joystickTag: "Each row carries a press, a hold, and a double tap, so three buttons do the work of nine",
            bindings: bindings)
    }

    /// Keyboard Deck's rows exactly as 1.5 shipped them. The preset was
    /// retired in 1.6; PresetStore compares installed copies against these so
    /// only an untouched copy is moved to Recently Deleted.
    static var retiredKeyboardDeckRows: [BindingModel] {
        [
            bind("ekb 104 any", ["sys mct"], "F13: Mission Control"),
            bind("ekb 105 any", ["sys spt"], "F14: Spotlight"),
            bind("ekb 106 any", ["sys ply"], "F15: Play / Pause"),
            bind("ekb 107 any", ["sys scr"], "F16: Screenshot menu"),
            bind("ekb 108 any", ["sys lpd"], "F17: Launchpad"),
            bind("ekb 109 any", ["sys dct"], "F18: Start Dictation"),
            bind("ekb 110 any", ["sys lck"], "F19: Lock Screen"),
        ].compactMap { $0 }
    }

    /// The Mac's trackpad or mouse as an input device: the side buttons go
    /// back and forward, the middle click opens Mission Control, and a
    /// force click on the trackpad opens Launchpad.
    static var trackpadAndMouse: Preset {
        var bindings: [BindingModel] = [
            bind("ems button 3 + any", ["key 227", "key 47"], "Side button 4: back"),
            bind("ems button 4 + any", ["key 227", "key 48"], "Side button 5: forward"),
            bind("ems button 2 + any", ["sys mct"], "Middle click: Mission Control"),
            bind("ems deepPress 0 + any", ["sys lpd"], "Force click: Launchpad"),
        ].compactMap { $0 }
        for i in bindings.indices {
            bindings[i].section = bindings[i].input.extMouseKind == .deepPress ? "Trackpad" : "Mouse buttons"
            // The side buttons already go back and forward in Chrome and
            // Firefox, so without blocking each press went two pages.
            if [3, 4].contains(bindings[i].input.index), bindings[i].input.extMouseKind != .deepPress {
                bindings[i].blockOriginal = true
            }
        }
        return makePreset(
            name: "Trackpad & Mouse",
            tag: "Side buttons, middle click, and force click",
            joystickTag: "The Mac's pointer: the two side buttons, the middle click, and the trackpad's force click",
            bindings: bindings)
    }

    /// Modifier keys as inputs with the hold and double-tap fine-tunes, so
    /// a modifier keeps doing its job and only a long hold or a double tap
    /// on its own fires something: no row has a plain press output.
    static var modifierHolds: Preset {
        func row(_ input: String, hold: String, ms: Int, doubleTap: String? = nil, note: String) -> BindingModel? {
            guard let ev = InputEvent.parse(input), let holdAction = OutputAction.parse(hold) else { return nil }
            var b = BindingModel(input: ev, outputs: [])
            b.holdOutputs = [holdAction]
            b.holdThresholdMs = ms
            if let doubleTap, let action = OutputAction.parse(doubleTap) {
                b.doubleTapOutputs = [action]
                b.doubleTapWindowMs = 300
            }
            b.note = note
            b.section = "Modifier keys"
            return b
        }
        let bindings: [BindingModel] = [
            row("ekb 231 any", hold: "sys spt", ms: 450, doubleTap: "sys lpd",
                note: "Right Command: hold for Spotlight, double tap for Launchpad"),
            row("ekb 230 any", hold: "sys dct", ms: 450, note: "Right Option: hold to start Dictation"),
            row("ekb 229 any", hold: "sys mct", ms: 450, note: "Right Shift: hold for Mission Control"),
        ].compactMap { $0 }
        return makePreset(
            name: "Modifier Holds",
            tag: "Hold a modifier on its own to run the Mac",
            joystickTag: "The Mac's keyboard: the right-hand modifiers, held alone, do more",
            bindings: bindings)
    }

    /// Double clicks as inputs. A double click on a button nobody
    /// double-clicks (the side buttons, the middle button) is free to mean
    /// something, and a single click keeps doing what it always did.
    /// An auto clicker: toggle and hold rows with Turbo on a click, from a
    /// controller, and with no controller from fn F6, fn F7 and a mouse's
    /// side button. The keyboard and mouse rows sit in their own group so
    /// the Live Visualizer draws them as the keyboard and mouse.
    /// Raised whenever a built-in preset is added, so existing libraries
    /// pick it up at the next launch even without a new build number
    /// (PresetStore.reseedExamplePresets). 2: the Auto Clicker. 3: the Stick
    /// Zones & Gestures showcase.
    static let seedRevision = 3

    static var autoClicker: Preset {
        func click(_ input: String, button: Int, note: String, toggle: Bool, intervalMs: Int,
                   jitterMs: Int? = nil, stopAfter: Int? = nil, section: String) -> BindingModel? {
            guard var row = bind(input, ["mbt \(button)"], note) else { return nil }
            row.turboEnabled = true
            row.turboIntervalMs = intervalMs
            row.turboJitterMs = jitterMs
            row.turboMaxCount = stopAfter
            row.toggleMode = toggle ? true : nil
            row.section = section
            return row
        }
        var pad: [BindingModel] = [
            bind("axi 0 -", ["mou 0 - 14"], "Move the pointer left"),
            bind("axi 0 +", ["mou 0 + 14"], "Move the pointer right"),
            bind("axi 1 -", ["mou 1 - 14"], "Move the pointer up"),
            bind("axi 1 +", ["mou 1 + 14"], "Move the pointer down"),
        ].compactMap { $0 }
        for i in pad.indices { pad[i].section = "Aim" }
        if var once = bind("btn 0", ["mbt 0"], "Click once") { once.section = "Aim"; pad.append(once) }
        pad += [
            click("btn 7", button: 0, note: "Auto click 10 a second, on and off", toggle: true, intervalMs: 100, section: "Auto click"),
            click("btn 6", button: 1, note: "Auto right click 5 a second, on and off", toggle: true, intervalMs: 200, section: "Auto click"),
            click("btn 5", button: 0, note: "Auto click 20 a second while held", toggle: false, intervalMs: 50, section: "Auto click"),
            click("btn 3", button: 0, note: "Auto click 100 times, then stop", toggle: true, intervalMs: 100, stopAfter: 100, section: "Auto click"),
            click("btn 2", button: 0, note: "Auto click at a human pace (150 ms, give or take 40), on and off", toggle: true,
                  intervalMs: 150, jitterMs: 40, section: "Auto click"),
        ].compactMap { $0 }
        // A buzz when an auto clicker starts or stops, so a controller user
        // feels it change.
        for i in pad.indices where pad[i].toggleMode == true {
            pad[i].hapticEnabled = true
            pad[i].hapticIntensity = 0.4
        }
        var mac: [BindingModel] = [
            click("ekb 63 any", button: 0, note: "fn F6: auto click 10 a second, on and off", toggle: true, intervalMs: 100, section: "Keyboard"),
            click("ekb 64 any", button: 1, note: "fn F7: auto right click 5 a second, on and off", toggle: true, intervalMs: 200, section: "Keyboard"),
            click("ems button 3 + any", button: 0, note: "Mouse button 4: auto click 15 a second while held", toggle: false,
                  intervalMs: 66, section: "Mouse"),
        ].compactMap { $0 }
        // The side button's own Back is held back while it auto clicks.
        for i in mac.indices where mac[i].input.type == .extMouse { mac[i].blockOriginal = true }
        var preset = Preset(name: "Auto Clicker",
                            tag: "Click automatically: toggle, hold, or a set number of clicks",
                            joysticks: [
                                JoystickMapping(tag: "Right trigger starts and stops auto clicking; the left stick aims", bindings: pad),
                                JoystickMapping(tag: "No controller: fn F6 and fn F7 start and stop, mouse button 4 clicks while held", bindings: mac),
                            ],
                            filename: Preset.generateFilename())
        preset.lightBarColor = nil
        return preset
    }

    static var doubleClickDeck: Preset {
        var bindings: [BindingModel] = [
            bind("ems doubleClick 3 + any", ["sys mct"], "Double click side button 4: Mission Control"),
            bind("ems doubleClick 4 + any", ["sys lpd"], "Double click side button 5: Launchpad"),
            bind("ems doubleClick 2 + any", ["sys spt"], "Double click the middle button: Spotlight"),
        ].compactMap { $0 }
        for i in bindings.indices { bindings[i].section = "Double clicks" }
        return makePreset(
            name: "Double Click Deck",
            tag: "Double click a spare mouse button",
            joystickTag: "The Mac's mouse: the side and middle buttons, double clicked",
            bindings: bindings)
    }

    static var showcaseKeyboardMouseInput: Preset {
        var bindings: [BindingModel] = [
            bind("ekb 104 any", ["sys mct"], "F13: Mission Control"),
            bind("ekb 105 any", ["sys spt"], "F14: Spotlight"),
            bind("ekb 106 any", ["sys ply"], "F15: Play / Pause"),
            bind("ems button 3 + any", ["key 227", "key 47"], "Mouse button 4: back (Cmd left bracket)"),
            bind("ems button 4 + any", ["key 227", "key 48"], "Mouse button 5: forward (Cmd right bracket)"),
        ].compactMap { $0 }
        for i in bindings.indices {
            bindings[i].section = bindings[i].input.type == .extKey ? "Keyboard" : "Mouse"
            // Blocked, so a side button goes one page in Chrome and Firefox,
            // which act on the button themselves, not two.
            if bindings[i].input.type == .extMouse { bindings[i].blockOriginal = true }
        }
        return makePreset(
            name: "Keyboard & Mouse Input",
            tag: "Spare keys and mouse buttons as inputs",
            joystickTag: "No controller: F13 to F15 and the two side buttons on a mouse drive the Mac",
            bindings: bindings)
    }

    /// Showcase: the outputs that run something rather than press a key.
    static var showcaseShortcutsAndApps: Preset {
        var bindings: [BindingModel] = [
            bind("btn 0", ["sys opa Safari"], "A / Cross: open Safari"),
            bind("btn 1", ["sys our https%3A%2F%2Finputconfig%2Ecom"], "B / Circle: open inputconfig.com"),
            bind("btn 2", ["sys mct"], "X / Square: Mission Control"),
            bind("btn 3", ["sys spt"], "Y / Triangle: Spotlight"),
        ].compactMap { $0 }
        var shortcut = BindingModel(input: .button(4),
                                    outputs: [OutputAction(type: .systemAction, systemActionKind: .runShortcut)])
        shortcut.note = "LB / L1: run a Shortcut. Pick one of yours from the row's menu"
        bindings.append(shortcut)
        for i in bindings.indices { bindings[i].section = "Buttons" }
        return makePreset(
            name: "Shortcuts & Apps",
            tag: "Open an app, a link, or a Shortcut from a button",
            joystickTag: "Outputs that run something instead of pressing a key: Open App, Open URL, Run Shortcut, and two Mac functions",
            bindings: bindings)
    }

    /// Steam Controller demo preset. Steam Controller is read by our raw-HID
    /// helper (it doesn't speak MFi), so it occupies a virtual slot just
    /// past the last MFi gamepad. The button numbers match
    /// `SteamControllerButton`: A=7, B=5, X=6, Y=4, etc. The stick is axes
    /// 0 and 1, the right trackpad 2 and 3, and the left trackpad 6 and 7
    /// while a finger is on it (SteamControllerService).
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
        // The Steam Controller numbers its controls its own way (the
        // bumpers are buttons 2 and 3, the face buttons 4 to 7), so the
        // standard gamepad sections would file them under the wrong
        // headings. Its sections are set here by what each control is.
        var sectioned = bindings
        for i in sectioned.indices {
            let input = sectioned[i].input
            switch (input.type, input.index) {
            case (.axis, 2), (.axis, 3), (.button, 18): sectioned[i].section = "Right trackpad"
            case (.axis, 4), (.axis, 5): sectioned[i].section = ControllerScaffold.SectionName.triggers
            case (.button, 2), (.button, 3): sectioned[i].section = "Bumpers"
            case (.button, 4...7): sectioned[i].section = ControllerScaffold.SectionName.buttons
            case (.button, 15), (.button, 16): sectioned[i].section = "Grips"
            case (.button, 13): sectioned[i].section = ControllerScaffold.SectionName.menuButtons
            default: break
            }
        }
        let order = ["Right trackpad", ControllerScaffold.SectionName.triggers, "Bumpers", ControllerScaffold.SectionName.buttons, "Grips", ControllerScaffold.SectionName.menuButtons]
        func rank(_ b: BindingModel) -> Int { order.firstIndex(of: b.section ?? "") ?? order.count }
        sectioned = sectioned.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
        var preset = makePreset(
            name: "Steam Controller",
            tag: "Right trackpad drives the mouse, face buttons + grips type keys",
            joystickTag: "Plug in a Steam Controller (wired or wireless dongle); it appears as a virtual slot just past your MFi controllers",
            bindings: sectioned)
        // Reads the Steam Controller by name: on Auto-detect it read slot 0,
        // which is any other pad connected, and fired these rows from it.
        preset.joysticks[0].customName = steamTarget2015
        preset.joysticks[0].inputKind = .controller
        return preset
    }

    /// The device names the two Steam Controller presets read, as the
    /// group's device menu writes them.
    static let steamTarget2015 = "Steam Controller"
    static let steamTarget2026 = "Steam Controller (2026, Experimental)"

    /// The 2026 Steam Controller on the standard numbering its decoder uses:
    /// A to Y at 0 to 3, the bumpers 4 and 5, Steam 10, the back buttons 14
    /// to 17, the right trackpad on axes 8 and 9 and its press on 19.
    static var showcaseSteamController2026: Preset {
        func keys(_ codes: Int...) -> [OutputAction] { codes.map { OutputAction(type: .key, keyCode: $0) } }
        // The right trackpad moves the pointer the way a Mac trackpad does:
        // by the finger's movement, not its position.
        func touch(_ axis: TouchpadAxis, _ dir: AxisDirection, surface: Int? = nil, _ out: OutputAction) -> BindingModel {
            var input = InputEvent.touchpad(finger: 0, axis: axis, direction: dir)
            input.touchpadSurface = surface
            return BindingModel(input: input, outputs: [out])
        }
        func motion(_ axis: MouseAxis, _ dir: MouseDirection) -> OutputAction {
            OutputAction(type: .mouseMotion, mouseAxis: axis, mouseDirection: dir, speed: 12)
        }
        func wheel(_ dir: MouseDirection) -> OutputAction {
            OutputAction(type: .mouseWheel, mouseAxis: .vertical, mouseDirection: dir, speed: 6)
        }
        let bindings: [BindingModel] = [
            touch(.x, .positive, motion(.horizontal, .positive)),
            touch(.x, .negative, motion(.horizontal, .negative)),
            touch(.y, .positive, motion(.vertical, .positive)),
            touch(.y, .negative, motion(.vertical, .negative)),
            BindingModel(input: .touchpadGesture(.oneFingerTap), outputs: [OutputAction(type: .mouseButton, mouseButtonIndex: 0)]),
            touch(.y, .positive, surface: 1, wheel(.positive)),
            touch(.y, .negative, surface: 1, wheel(.negative)),
            BindingModel(input: .axis(5, direction: .positive), outputs: [OutputAction(type: .mouseButton, mouseButtonIndex: 0)]),
            BindingModel(input: .axis(4, direction: .positive), outputs: [OutputAction(type: .mouseButton, mouseButtonIndex: 1)]),
            BindingModel(input: .button(19), outputs: [OutputAction(type: .mouseButton, mouseButtonIndex: 0)]),
            BindingModel(input: .axis(3, direction: .positive),
                         outputs: [OutputAction(type: .mouseWheel, mouseAxis: .vertical, mouseDirection: .positive, speed: 4)],
                         deadzone: 0.2),
            BindingModel(input: .axis(3, direction: .negative),
                         outputs: [OutputAction(type: .mouseWheel, mouseAxis: .vertical, mouseDirection: .negative, speed: 4)],
                         deadzone: 0.2),
            BindingModel(input: .button(0), outputs: keys(40)),
            BindingModel(input: .button(1), outputs: keys(41)),
            BindingModel(input: .button(2), outputs: keys(43)),
            BindingModel(input: .button(3), outputs: keys(44)),
            BindingModel(input: .button(4), outputs: keys(227, 47)),
            BindingModel(input: .button(5), outputs: keys(227, 48)),
            BindingModel(input: .button(10), outputs: keys(227, 44)),
            BindingModel(input: .button(14), outputs: keys(225)),
            BindingModel(input: .button(15), outputs: keys(226)),
        ]
        var preset = makePreset(
            name: "Steam Controller (2026)",
            tag: "Right trackpad drives the mouse, back buttons hold Shift and Option",
            joystickTag: "Plug in, pair over Bluetooth, or use the Steam Controller Puck; quit Steam first",
            bindings: bindings)
        preset.joysticks[0].customName = steamTarget2026
        preset.joysticks[0].inputKind = .controller
        return preset
    }

    /// Gyroscope showcase. Gyro Y (sideways tilt) drives mouse left/right,
    /// gyro X (pitch rate) drives mouse up/down, the standard "motion aim" feel
    /// used by every Nintendo and PlayStation shooter. Triggers click,
    /// face buttons type. Works on any controller whose GCController.motion
    /// is non-nil (DualSense, DualShock 4, Switch Pro, Joy-Con).
    static var showcaseGyroAim: Preset {
        let bindings: [BindingModel] = [
            // Sideways: tilting the controller right moves the pointer right.
            // A positive gyro Y rate is the right side going down, so these
            // are straight.
            BindingModel(input: .motion(.gyroY, direction: .positive),
                         outputs: [OutputAction(type: .mouseMotion, mouseAxis: .horizontal, mouseDirection: .positive, speed: 10)],
                         deadzone: 0.05, variableSensitivity: true),
            BindingModel(input: .motion(.gyroY, direction: .negative),
                         outputs: [OutputAction(type: .mouseMotion, mouseAxis: .horizontal, mouseDirection: .negative, speed: 10)],
                         deadzone: 0.05, variableSensitivity: true),
            // Pitch: tilting the controller up moves the pointer up. A
            // positive gyro X rate is nose UP (checked by hand on a
            // DualSense) while screen Y grows downward, so these rows are
            // crossed.
            BindingModel(input: .motion(.gyroX, direction: .positive),
                         outputs: [OutputAction(type: .mouseMotion, mouseAxis: .vertical, mouseDirection: .negative, speed: 10)],
                         deadzone: 0.05, variableSensitivity: true),
            BindingModel(input: .motion(.gyroX, direction: .negative),
                         outputs: [OutputAction(type: .mouseMotion, mouseAxis: .vertical, mouseDirection: .positive, speed: 10)],
                         deadzone: 0.05, variableSensitivity: true),
            // Triggers click. Right trigger = left mouse click (primary fire),
            // left trigger = right mouse click (aim down sights).
            BindingModel(input: .axis(5, direction: .positive),
                         outputs: [OutputAction(type: .mouseButton, mouseButtonIndex: 0)]),
            BindingModel(input: .axis(4, direction: .positive),
                         outputs: [OutputAction(type: .mouseButton, mouseButtonIndex: 1)]),
            BindingModel(input: .button(0), outputs: [OutputAction(type: .key, keyCode: 44)]),  // space
            BindingModel(input: .button(1), outputs: [OutputAction(type: .key, keyCode: 224)]), // ctrl
            // The two controls a motion layout needs and nothing else
            // provides: ratcheting, so you can swing the controller back to
            // a comfortable angle without the pointer following, and a
            // re-zero for when a rested controller still drifts.
            BindingModel(input: .button(4),
                         outputs: [OutputAction(type: .appAction, appActionKind: .holdMuteMotion)]),
            BindingModel(input: .button(5),
                         outputs: [OutputAction(type: .appAction, appActionKind: .rezeroMotion),
                                   OutputAction(type: .appAction, appActionKind: .centerPointer)]),
        ]
        return makePreset(
            name: "Gyro Aim",
            tag: "Tilt the controller to aim; triggers fire and ADS",
            joystickTag: "Tilt to aim: sideways tilt → mouse X, forward tilt → mouse Y. The left bumper pauses motion while held, the right bumper re-zeros and centers the pointer",
            bindings: bindings,
            light: RGBLightColor(r: 128, g: 0, b: 255))
    }

    /// Motion-driven desktop cursor. Same idea as Gyro Aim but tuned for
    /// everyday Mac use: a wider deadzone so the cursor doesn't drift when
    /// the controller is set down, a slower gain so a small tilt doesn't
    /// shoot the cursor across the screen, and face buttons that act like
    /// trackpad clicks. Useful on the couch with a Switch Pro or
    /// Joy-Con as a "wave-the-controller" pointer.
    static var showcaseMotionCursor: Preset {
        let bindings: [BindingModel] = [
            // Yaw → X, Pitch → Y, with conservative defaults. A positive
            // gyro Y rate is a turn to the right on the Mac, so yaw is
            // straight; pitch below is crossed.
            BindingModel(input: .motion(.gyroY, direction: .positive),
                         outputs: [OutputAction(type: .mouseMotion, mouseAxis: .horizontal, mouseDirection: .positive, speed: 6)],
                         deadzone: 0.05, sensitivityCurve: .exponential, variableSensitivity: true),
            BindingModel(input: .motion(.gyroY, direction: .negative),
                         outputs: [OutputAction(type: .mouseMotion, mouseAxis: .horizontal, mouseDirection: .negative, speed: 6)],
                         deadzone: 0.05, sensitivityCurve: .exponential, variableSensitivity: true),
            // Pitch: tilting the controller up moves the pointer up. A
            // positive gyro X rate is nose up, so these rows are crossed
            // (screen Y grows downward).
            BindingModel(input: .motion(.gyroX, direction: .positive),
                         outputs: [OutputAction(type: .mouseMotion, mouseAxis: .vertical, mouseDirection: .negative, speed: 6)],
                         deadzone: 0.05, sensitivityCurve: .exponential, variableSensitivity: true),
            BindingModel(input: .motion(.gyroX, direction: .negative),
                         outputs: [OutputAction(type: .mouseMotion, mouseAxis: .vertical, mouseDirection: .positive, speed: 6)],
                         deadzone: 0.05, sensitivityCurve: .exponential, variableSensitivity: true),
            // A = left click, B = right click, Y = double-tap (Return)
            BindingModel(input: .button(0), outputs: [OutputAction(type: .mouseButton, mouseButtonIndex: 0)]),
            BindingModel(input: .button(1), outputs: [OutputAction(type: .mouseButton, mouseButtonIndex: 1)]),
            BindingModel(input: .button(3), outputs: [OutputAction(type: .key, keyCode: 40)]),
            // Right stick still scrolls so you can read long pages without
            // tilting, the same way round as Mouse + Scroll and every other
            // built-in: stick up scrolls up (wheel minus).
            BindingModel(input: .axis(3, direction: .positive),
                         outputs: [OutputAction(type: .mouseWheel, mouseAxis: .vertical, mouseDirection: .positive, speed: 4)],
                         deadzone: 0.18, variableSensitivity: true),
            BindingModel(input: .axis(3, direction: .negative),
                         outputs: [OutputAction(type: .mouseWheel, mouseAxis: .vertical, mouseDirection: .negative, speed: 4)],
                         deadzone: 0.18, variableSensitivity: true),
            // Same motion controls as Gyro Aim: hold LB to park the pointer
            // while you bring the controller back to a comfortable angle,
            // press RB with the controller still to re-zero a drifting gyro.
            BindingModel(input: .button(4),
                         outputs: [OutputAction(type: .appAction, appActionKind: .holdMuteMotion)]),
            BindingModel(input: .button(5),
                         outputs: [OutputAction(type: .appAction, appActionKind: .rezeroMotion),
                                   OutputAction(type: .appAction, appActionKind: .centerPointer)]),
        ]
        return makePreset(
            name: "Motion Cursor",
            tag: "Wave the controller to move the cursor; face buttons click",
            joystickTag: "Slower than Gyro Aim, with clicks and scrolling on the buttons; good for couch desktop use on a DualSense or DualShock 4",
            bindings: bindings,
            light: RGBLightColor(r: 0, g: 255, b: 255))
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
            joystickTag: "A = parallel output stack (key + click + MIDI + speech). B = parallel keystroke pair. Different from a macro: no delays, no sequence; these fire simultaneously.",
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
                                   bindings: [BindingModel],
                                   light: RGBLightColor? = nil) -> Preset {
        let joystick = JoystickMapping(tag: joystickTag, bindings: bindings)
        var preset = Preset(name: name, tag: tag, joysticks: [joystick],
                            filename: Preset.generateFilename())
        preset.lightBarColor = light
        return preset
    }

    /// Showcase: Voice Commands. Needs no hardware at all: the input is the
    /// person's voice, so someone who cannot press anything can run the Mac.
    /// Each row is a phrase; the words live in the preset's Voice Phrases.
    static var showcaseVoiceCommands: Preset {
        let commands: [(words: String, action: SystemActionKind)] = [
            ("show my windows", .missionControl),
            ("open search", .spotlight),
            ("start dictation", .startDictation),
            ("read this", .speakSelection),
            ("play music", .playPause),
            // Play and Pause is one toggle on the Mac; two phrases, so either
            // word works.
            ("pause music", .playPause),
            ("volume up", .volumeUp),
            ("volume down", .volumeDown),
        ]
        var phrases: [VoicePhrase] = []
        var bindings: [BindingModel] = []
        for (i, command) in commands.enumerated() {
            // In the app's language, which is the one it listens in.
            var phrase = VoicePhrase()
            phrase.phrase = ShippedText.t(command.words)
            phrase.colorIndex = i
            phrases.append(phrase)
            bindings.append(BindingModel(input: .voicePhrase(phrase.id),
                                         outputs: [OutputAction(type: .systemAction, systemActionKind: command.action)]))
        }
        var preset = makePreset(
            name: "Voice Commands",
            tag: "Say a phrase; no controller needed",
            joystickTag: "Listens only while this preset runs. Change the words in Voice Phrases.",
            bindings: bindings)
        preset.voicePhrases = phrases
        return preset
    }

    /// Parse a legacy-format preset JSON string into a Preset. Nil when
    /// the JSON does not parse: the preset is left out of the seed list
    /// rather than seeded into every library as one named "Error".
    private static func parse(_ json: String) -> Preset? {
        guard let data = json.data(using: .utf8),
              let preset = Preset.fromLegacyJSON(data, filename: Preset.generateFilename()) else {
            assertionFailure("ExamplePresets: a built-in preset's JSON failed to parse")
            return nil
        }
        return preset
    }

    /// Build one binding from the legacy grammar the JSON presets use
    /// ("btn 0", ["key 44"]) plus the per-row note the editor shows under
    /// the input. Keeps a hand-written preset as readable as the JSON ones
    /// while carrying notes, which the legacy parser drops.
    private static func bind(_ input: String, _ outputs: [String], _ note: String) -> BindingModel? {
        guard let inputEvent = InputEvent.parse(input) else { return nil }
        let actions = outputs.compactMap { OutputAction.parse($0) }
        guard !actions.isEmpty else { return nil }
        return BindingModel(input: inputEvent, outputs: actions, note: note)
    }
}

// MARK: - Smart Preset Maker

/// A controller-agnostic mapping profile for a game, app, or workflow. The
/// Smart Preset Maker fuses one of these with the user's chosen controller
/// to generate a ready-to-use Preset. Decoded from the embedded library
/// JSON.
struct SmartPresetProfile: Codable, Identifiable, Hashable {
    enum Category: String, Codable, CaseIterable, Identifiable {
        case game, app, workflow
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .game: return String(localized: "Game")
            case .app: return String(localized: "App")
            case .workflow: return String(localized: "Workflow")
            }
        }
        var pluralPrompt: String {
            switch self {
            case .game: return String(localized: "Pick a game")
            case .app: return String(localized: "Pick an app")
            case .workflow: return String(localized: "Pick a workflow")
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
    /// One catalog row. Only input, outputs and note are required; every other
    /// field is an optional row feature, absent on most entries.
    struct Binding: Codable, Hashable {
        var input: String
        var outputs: [String]
        var note: String
        /// Held past `holdMs` (default 300): these fire instead, until release.
        var hold: [String]? = nil
        var holdMs: Int? = nil
        /// Two presses inside `doubleMs` (default 300): these fire instead.
        var double: [String]? = nil
        var doubleMs: Int? = nil
        /// Chord: the row fires only while these controls are also held.
        var with: [String]? = nil
        var toggle: Bool? = nil
        /// Turbo, in presses per second.
        var turbo: Int? = nil
        var repeatCount: Int? = nil
        var repeatMs: Int? = nil
        /// Stick and trigger shaping: inner and outer deadzone (0 to 1),
        /// curve ("linear", "smooth", "aggressive"), speed by depth, ramp-up ms.
        var deadzone: Double? = nil
        var outer: Double? = nil
        var curve: String? = nil
        var variable: Bool? = nil
        var ramp: Int? = nil
        /// Feedback: rumble strength (0 to 1) and a phrase to speak.
        var rumble: Double? = nil
        var speak: String? = nil
        /// Hardware the row needs: "touchpad", "motion", "lightbar", "paddles".
        /// Rows are left out for controllers that do not have it.
        var needs: String? = nil
    }

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
    /// Optional one-stick driving scheme carried into the built preset.
    /// Absent on the vast majority of profiles (Optional decodes to nil).
    var drive: DriveConfig?
}

/// The library of Smart Preset profiles, decoded once from the bundled
/// SmartPresetLibrary.json, one entry per game or app. It was a string
/// literal here, which put a second copy (0.9 MB) in each binary slice.
enum SmartPresetLibrary {
    /// Decoded one profile at a time: decoding the array in one go dropped
    /// the whole library when any single entry was malformed.
    static let all: [SmartPresetProfile] = {
        guard let url = Bundle.main.url(forResource: "SmartPresetLibrary", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([JSONValue].self, from: data) else { return [] }
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        var out: [SmartPresetProfile] = []
        for entry in entries {
            if let one = try? encoder.encode(entry),
               let profile = try? decoder.decode(SmartPresetProfile.self, from: one) {
                out.append(profile)
            } else {
                #if DEBUG
                print("[SmartPresetLibrary] skipped an unreadable profile")
                #endif
            }
        }
        return out
    }()

    static func profiles(in category: SmartPresetProfile.Category) -> [SmartPresetProfile] {
        all.filter { $0.category == category }.sorted { $0.displayName < $1.displayName }
    }
}

extension ControllerBrand {
    /// Whether this controller has the hardware a catalog row needs.
    func supports(_ need: String) -> Bool {
        switch need {
        case "touchpad": return hasTouchpad
        case "motion", "gyro": return hasMotion
        case "lightbar": return hasLightBar
        // Back paddles: the DualSense Edge, Xbox Elite, and the Steam
        // Controller's grips. A pad of the same brand without them simply
        // never presses the row. Not 8BitDo: the Pro 2's back buttons repeat
        // other buttons inside the pad and are not inputs of their own.
        case "paddles": return [.dualSense, .xbox, .steamController].contains(self)
        default: return true
        }
    }
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
        /// On a pad with a touchpad, add the rows that make it a trackpad:
        /// one finger moves the pointer, two fingers scroll, a tap clicks,
        /// a two-finger tap right-clicks, the pad's press clicks.
        var touchpadAsTrackpad: Bool = false
        /// On a pad with motion, and a profile that looks with the mouse,
        /// add gyro fine aim: tilting nudges the pointer on top of the stick.
        var gyroFineAim: Bool = false
        /// A short rumble whenever a trigger-driven click fires.
        var rumbleOnTriggers: Bool = false
        /// On a pad with back paddles, the paddles repeat A, B, X and Y, so
        /// the thumbs never leave the sticks.
        var backPaddles: Bool = false
        /// Stick rows that move the pointer or the camera start slow and
        /// speed up while held (ramp-up), for landing on small targets.
        var pointerRamp: Bool = false
        /// The left stick pushed all the way forward also holds the game's
        /// sprint key, as console games run at full push and walk at a
        /// light one. The walking rows keep working: the ring shares the stick.
        var sprintAtFullPush: Bool = false
        /// The other way round, for games where Shift walks quietly (CS2,
        /// VALORANT): a light push of the left stick holds the walk key and
        /// a full push runs, as a console's stick walks and runs.
        var walkOnLightPush: Bool = false
    }

    /// The ring that walks: any direction, from where the stick starts to
    /// count to three quarters of the way out.
    static let walkRing = RingSector(inner: 0.25, outer: 0.75, start: 0, end: 0)

    /// The keys the profile walks quietly with, from its left-stick-click
    /// row, when it moves with keys on the left stick.
    static func walkKeys(_ profile: SmartPresetProfile) -> [OutputAction] {
        let movesWithKeys = profile.bindings.contains { b in
            b.input == "axi 1 -" && b.outputs.contains { $0.hasPrefix("key ") }
        }
        guard movesWithKeys,
              let row = profile.bindings.first(where: {
                  let n = $0.note.lowercased()
                  // A held walk key only: a ring presses it on each entry,
                  // which flips a toggle ("L3 toggles walk and run").
                  return $0.input == "btn 11" && n.contains("walk") && !n.contains("sprint") && !n.contains("toggle")
              })
        else { return [] }
        let keys = row.outputs.compactMap { OutputAction.parse($0) }
        return !keys.isEmpty && keys.allSatisfy { $0.type == .key } ? keys : []
    }

    /// Walk on a light push only makes sense where the profile has a walk key.
    static func canWalkOnLightPush(_ profile: SmartPresetProfile) -> Bool { !walkKeys(profile).isEmpty }

    /// The ring at the top of the left stick that sprints: 90 percent of the
    /// way out and further, within 30 degrees of straight up.
    static let sprintRing = RingSector(inner: 0.9, outer: 1, start: 60, end: 120)

    /// The keys the profile sprints with, from its left-stick-click row,
    /// when it walks with keys on the left stick (W on up). None for a game
    /// that walks with the mouse, has no sprint, or sprints with a click.
    static func sprintKeys(_ profile: SmartPresetProfile) -> [OutputAction] {
        let walksWithKeys = profile.bindings.contains { b in
            b.input == "axi 1 -" && b.outputs.contains { $0.hasPrefix("key ") }
        }
        guard walksWithKeys,
              let row = profile.bindings.first(where: {
                  let n = $0.note.lowercased()
                  return $0.input == "btn 11" && n.contains("sprint") && !n.contains("toggle")
              })
        else { return [] }
        let keys = row.outputs.compactMap { OutputAction.parse($0) }
        return !keys.isEmpty && keys.allSatisfy { $0.type == .key } ? keys : []
    }

    /// Sprint at full push only makes sense where the profile has a sprint key.
    static func canSprintAtFullPush(_ profile: SmartPresetProfile) -> Bool { !sprintKeys(profile).isEmpty }

    /// Whether the profile turns the controller into a mouse-look game
    /// (any row sends mouse motion). Gyro fine aim only makes sense then.
    /// Whether a trigger in this profile clicks a mouse button, the only
    /// rows Rumble when a trigger clicks puts a rumble on. 130 of the
    /// profiles have none, and the option still wrote its note.
    static func canRumbleOnTriggers(_ profile: SmartPresetProfile) -> Bool {
        profile.bindings.contains { b in
            guard let input = InputEvent.parse(b.input), input.type == .axis, (4...5).contains(input.index) else { return false }
            return b.outputs.compactMap { OutputAction.parse($0) }.contains { $0.type == .mouseButton }
        }
    }

    static func usesMouseLook(_ profile: SmartPresetProfile) -> Bool {
        profile.bindings.contains { b in b.outputs.contains { $0.hasPrefix("mou ") } }
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
            if let need = b.needs, !brand.supports(need) { continue }
            guard let input = InputEvent.parse(b.input) else { continue }
            let outputs = b.outputs.compactMap { OutputAction.parse($0) }
            let hold = b.hold?.compactMap { OutputAction.parse($0) }
            let double = b.double?.compactMap { OutputAction.parse($0) }
            guard !outputs.isEmpty || hold?.isEmpty == false || double?.isEmpty == false else { continue }
            var bm = BindingModel(input: input, outputs: outputs)
            let trimmed = Self.localizedNote(b.note.trimmingCharacters(in: .whitespacesAndNewlines),
                                             input: b.input, brand: brand)
            bm.note = trimmed.isEmpty ? nil : trimmed
            if let hold, !hold.isEmpty { bm.holdOutputs = hold; bm.holdThresholdMs = b.holdMs ?? 300 }
            if let double, !double.isEmpty { bm.doubleTapOutputs = double; bm.doubleTapWindowMs = b.doubleMs ?? 300 }
            if let with = b.with { bm.setModifiers(with.compactMap { InputEvent.parse($0) }) }
            if b.toggle == true { bm.toggleMode = true }
            if let t = b.turbo, t > 0 { bm.turboEnabled = true; bm.turboRate = t }
            if let r = b.repeatCount, r > 1 { bm.repeatCount = r; bm.repeatDelayMs = b.repeatMs ?? 100 }
            if let dz = b.deadzone { bm.deadzone = Float(dz) }
            if let o = b.outer { bm.outerDeadzone = Float(o) }
            switch b.curve {
            case "smooth": bm.sensitivityCurve = .exponential
            case "aggressive": bm.sensitivityCurve = .aggressive
            default: break
            }
            if let v = b.variable { bm.variableSensitivity = v }
            if let r = b.ramp, r > 0 { bm.rampMs = r }
            if let rumble = b.rumble, rumble > 0 { bm.hapticEnabled = true; bm.hapticIntensity = Float(rumble) }
            if let phrase = b.speak { bm.speechEnabled = true; bm.speechText = phrase }
            // A trigger that clicks can rumble as it does, so a shot or a
            // swing is felt. Only rows a trigger drives to a mouse button.
            if options.rumbleOnTriggers, input.type == .axis, (4...5).contains(input.index),
               outputs.contains(where: { $0.type == .mouseButton }) {
                bm.hapticEnabled = true
                bm.hapticIntensity = 0.35
            }
            bindingModels.append(bm)
        }
        let used = Set(bindingModels.map { $0.input.serialized })
        func add(_ bm: BindingModel) { if !used.contains(bm.input.serialized) { bindingModels.append(bm) } }
        if options.touchpadAsTrackpad, brand.hasTouchpad {
            var rows: [BindingModel] = [
                BindingModel(input: .touchpad(finger: 0, axis: .x, direction: .positive),
                             outputs: [OutputAction(type: .mouseMotion, mouseAxis: .horizontal, mouseDirection: .positive, speed: 12)]),
                BindingModel(input: .touchpad(finger: 0, axis: .x, direction: .negative),
                             outputs: [OutputAction(type: .mouseMotion, mouseAxis: .horizontal, mouseDirection: .negative, speed: 12)]),
                BindingModel(input: .touchpad(finger: 0, axis: .y, direction: .positive),
                             outputs: [OutputAction(type: .mouseMotion, mouseAxis: .vertical, mouseDirection: .positive, speed: 12)]),
                BindingModel(input: .touchpad(finger: 0, axis: .y, direction: .negative),
                             outputs: [OutputAction(type: .mouseMotion, mouseAxis: .vertical, mouseDirection: .negative, speed: 12)]),
                BindingModel(input: .touchpad(finger: 1, axis: .y, direction: .positive),
                             outputs: [OutputAction(type: .mouseWheel, mouseAxis: .vertical, mouseDirection: .positive, speed: 6)]),
                BindingModel(input: .touchpad(finger: 1, axis: .y, direction: .negative),
                             outputs: [OutputAction(type: .mouseWheel, mouseAxis: .vertical, mouseDirection: .negative, speed: 6)]),
                BindingModel(input: .button(13), outputs: [OutputAction(type: .mouseButton, mouseButtonIndex: 0)]),
                BindingModel(input: .touchpadGesture(.oneFingerTap), outputs: [OutputAction(type: .mouseButton, mouseButtonIndex: 0)]),
                BindingModel(input: .touchpadGesture(.twoFingerTap), outputs: [OutputAction(type: .mouseButton, mouseButtonIndex: 1)]),
            ]
            // Written in the app's language, like the preset's notes; the
            // section stays the English key the editor groups by.
            let notes = [String(localized: "One finger: pointer right"), String(localized: "One finger: pointer left"),
                         String(localized: "One finger: pointer down"), String(localized: "One finger: pointer up"),
                         String(localized: "Two fingers: scroll down"), String(localized: "Two fingers: scroll up"),
                         String(localized: "Press the pad: click"), String(localized: "Tap: click"),
                         String(localized: "Two-finger tap: right click")]
            for i in rows.indices { rows[i].note = notes[i]; rows[i].section = "Touchpad" }
            rows.forEach(add)
        }
        if options.gyroFineAim, brand.hasMotion, usesMouseLook(profile) {
            var rows: [BindingModel] = [
                BindingModel(input: .motion(.gyroY, direction: .positive),
                             outputs: [OutputAction(type: .mouseMotion, mouseAxis: .horizontal, mouseDirection: .positive, speed: 10)],
                             deadzone: 0.05, variableSensitivity: true),
                BindingModel(input: .motion(.gyroY, direction: .negative),
                             outputs: [OutputAction(type: .mouseMotion, mouseAxis: .horizontal, mouseDirection: .negative, speed: 10)],
                             deadzone: 0.05, variableSensitivity: true),
                BindingModel(input: .motion(.gyroX, direction: .positive),
                             outputs: [OutputAction(type: .mouseMotion, mouseAxis: .vertical, mouseDirection: .negative, speed: 10)],
                             deadzone: 0.05, variableSensitivity: true),
                BindingModel(input: .motion(.gyroX, direction: .negative),
                             outputs: [OutputAction(type: .mouseMotion, mouseAxis: .vertical, mouseDirection: .positive, speed: 10)],
                             deadzone: 0.05, variableSensitivity: true),
            ]
            let notes = [String(localized: "Tilt right: aim right"), String(localized: "Tilt left: aim left"),
                         String(localized: "Tilt up: aim up"), String(localized: "Tilt down: aim down")]
            for i in rows.indices { rows[i].note = notes[i]; rows[i].section = "Gyro aim" }
            rows.forEach(add)
        }
        if options.backPaddles, brand.supports("paddles") {
            // See paddlePairs for which button numbers they are.
            let kind = brand == .xbox ? String(localized: "smart.paddle", defaultValue: "Paddle",
                                                       comment: "A paddle on the back of an Xbox Elite controller")
                : String(localized: "smart.backButton", defaultValue: "Back button",
                         comment: "A button on the back of the controller, not the Back (View) button")
            for (paddle, face) in Self.paddlePairs(for: brand) {
                guard let src = bindingModels.first(where: { $0.input.type == .button && $0.input.index == face && $0.modifiers.isEmpty }) else { continue }
                var row = src.duplicated()
                row.input = .button(paddle)
                let faceName = label(for: "btn \(face)", brand: brand)
                // The family's name already says paddle or back button.
                let name = label(for: "btn \(paddle)", brand: brand)
                let lower = name.lowercased()
                let named = lower.contains("paddle") || lower.contains("back") || lower.contains(kind.lowercased())
                    ? name : String(localized: "\(kind) \(name)")
                row.note = String(localized: "\(named): same as \(faceName)") + (src.note.map { " (\($0))" } ?? "")
                row.section = brand == .xbox ? "Paddles" : "Back buttons"
                add(row)
            }
        }
        var sprintRegion: TouchpadRegion?
        if options.sprintAtFullPush {
            let keys = sprintKeys(profile)
            if !keys.isEmpty {
                let region = TouchpadRegion.ring(name: String(localized: "Sprint"), Self.sprintRing, colorIndex: 3)
                var row = BindingModel(input: .stickRegion(stickIndex: 0, id: region.id), outputs: keys)
                // Sprinting adds to walking: W keeps walking under it.
                row.zoneSharesStick = true
                row.note = String(localized: "Left stick pushed all the way forward: sprint, while still walking")
                row.section = "Left stick"
                bindingModels.append(row)
                sprintRegion = region
            }
        }
        if options.walkOnLightPush, sprintRegion == nil {
            let keys = walkKeys(profile)
            if !keys.isEmpty {
                let region = TouchpadRegion.ring(name: String(localized: "Walk"), Self.walkRing, colorIndex: 4)
                var row = BindingModel(input: .stickRegion(stickIndex: 0, id: region.id), outputs: keys)
                // Walking quietly is moving with the walk key held: the
                // movement rows keep going under it.
                row.zoneSharesStick = true
                row.note = String(localized: "Left stick pushed lightly: walk quietly; push it all the way to run")
                row.section = "Left stick"
                bindingModels.append(row)
                sprintRegion = region
            }
        }
        if options.pointerRamp {
            for i in bindingModels.indices where bindingModels[i].input.type == .axis
                && bindingModels[i].outputs.contains(where: { $0.type == .mouseMotion }) && bindingModels[i].rampMs == nil {
                bindingModels[i].rampMs = 400
            }
        }
        var slot = JoystickMapping(tag: slotGuide(for: profile, brand: brand),
                                   bindings: bindingModels)
        // Made for the 2026 Steam Controller: read from it, as the built-in
        // Steam presets are. On Auto-detect it read slot 0, which is any
        // other pad connected, since raw pads sit after GameController's.
        if brand == .steamController {
            slot.customName = ExamplePresets.steamTarget2026
            slot.inputKind = .controller
        }
        var preset = Preset(name: options.name, tag: profile.subtitle,
                            joysticks: [slot], filename: Preset.generateFilename())
        preset.sortBindings()
        if let sprintRegion { preset.stickRegions["0"] = [sprintRegion] }
        preset.groupID = options.groupID
        // Made for this brand, so shown as its family.
        preset.buttonFamily = family(for: brand)

        var auto = PresetAutomation()
        if options.autoLaunchApp {
            auto.launchAppPath = options.appPathOverride ?? profile.appPath
            // An app chosen in the maker replaces the Steam launch; with
            // both, the game started twice.
            auto.launchURL = options.appPathOverride == nil ? profile.launchURL : ""
            // A profile with both keeps one: the app when it is on this Mac,
            // else the Steam link. Both meant a Steam prompt for a copy bought
            // elsewhere, and a path that opened nothing for a Steam copy.
            // Not when the app is Steam itself (Half-Life 2, Portal 2, Team
            // Fortress 2): the steam:// link is what starts the game, and the
            // path alone opened Steam and nothing else.
            let pathIsSteam = (auto.launchAppPath as NSString).lastPathComponent.lowercased() == "steam.app"
            if options.appPathOverride == nil, !auto.launchAppPath.isEmpty, !auto.launchURL.isEmpty {
                if pathIsSteam {
                    auto.launchAppPath = ""
                } else if FileManager.default.fileExists(atPath: auto.launchAppPath) {
                    auto.launchURL = ""
                } else {
                    auto.launchAppPath = ""
                }
            }

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
        preset.notes = buildNotes(for: profile, brand: brand, options: options)
        preset.driveConfig = profile.drive
        return preset
    }

    /// Compact "Label = action" summary for the slot subtitle.
    private static func slotGuide(for profile: SmartPresetProfile, brand: ControllerBrand) -> String {
        profile.bindings.prefix(6)
            .map { "\(label(for: $0.input, brand: brand)) = \(localizedAction(of: $0.note))" }
            .joined(separator: ", ")
    }

    /// Short setup guidance baked into `preset.notes`. The per-control detail
    /// now lives on each binding row (each row has its own note), so this stays
    /// concise: a one-line intro, the first-run scan reminder, any hardware
    /// extras, and the profile's tips. No giant per-button dump.
    private static func buildNotes(for profile: SmartPresetProfile, brand: ControllerBrand, options: Options) -> String {
        // Written in the app's language: the notes are the person's own once
        // the preset exists.
        // The profile's name as the maker shows it, not English in a
        // translated sentence.
        var out = String(localized: "Smart preset for \(ShippedText.t(profile.displayName).withoutRTLMark) on \(brand.displayName).") + "\n"
        out += String(localized: "What each control does is noted right on its row in the binding editor.") + " "
        out += String(localized: "If something doesn't respond, open the editor and use Scan to remap it (controllers vary).") + "\n"
        if brand.hasMotion || brand.hasTouchpad {
            out += "\n" + String(localized: "Your \(brand.displayName) extras: \(brand.capabilitySummary).") + "\n"
            if brand.hasMotion {
                if options.gyroFineAim, usesMouseLook(profile) {
                    out += String(localized: "Gyro aim is on: tilting the pad nudges the aim on top of the stick. Run Motion Calibration once (a row's Options, or Controller, Calibrate Motion / Gyro in the menu bar) so a still pad is still.") + "\n"
                } else {
                    out += String(localized: "Motion: add a gyro fine-aim binding, then run Motion Calibration.") + "\n"
                }
            }
            if brand.hasTouchpad {
                if options.touchpadAsTrackpad {
                    out += String(localized: "The touchpad is a trackpad: one finger moves the pointer, two fingers scroll, a tap clicks, a two-finger tap right-clicks.") + "\n"
                } else {
                    out += String(localized: "Touchpad: add a Touchpad binding to use it as a trackpad.") + "\n"
                }
            }
        }
        if options.rumbleOnTriggers, canRumbleOnTriggers(profile) {
            out += String(localized: "The triggers rumble when they click.") + "\n"
        }
        if options.backPaddles, brand.supports("paddles") {
            let faces = Self.paddlePairs(for: brand).map { label(for: "btn \($0.face)", brand: brand) }
            let list = LocalizedList.and(faces)
            out += (brand == .xbox ? String(localized: "The back paddles repeat \(list).") : String(localized: "The back buttons repeat \(list).")) + "\n"
        }
        if options.walkOnLightPush, canWalkOnLightPush(profile), !(options.sprintAtFullPush && canSprintAtFullPush(profile)) {
            out += String(localized: "Walk on a light push is on: a light push of the left stick walks quietly, a full push runs. The ring is in the Regions section of the editor.") + "\n"
        }
        if options.sprintAtFullPush, canSprintAtFullPush(profile) {
            out += String(localized: "Sprint at full push is on: the left stick pushed all the way forward sprints, a lighter push walks. The ring is in the Regions section of the editor.") + "\n"
        }
        if options.pointerRamp {
            out += String(localized: "Pointer ramp-up is on: a short push moves slowly, a held push speeds up. Change it in a stick row's Options.") + "\n"
        }
        if !profile.tips.isEmpty {
            out += "\n" + String(localized: "Tips:") + "\n" + profile.tips.map { "- \(ShippedText.t($0))" }.joined(separator: "\n")
        }
        return out
    }

    /// Translate a serialized input ("btn 0", "axi 2 +", "hat 0 U") into the
    /// physical control label for the chosen controller brand.
    /// Which paddle repeats which face button. The DualSense Edge has two
    /// back buttons (16, 17); the Xbox Elite four paddles (16 to 19); the
    /// 2026 Steam Controller four back buttons, L4, R4, L5, R5 (14 to 17).
    static func paddlePairs(for brand: ControllerBrand) -> [(paddle: Int, face: Int)] {
        switch brand {
        case .dualSense: return [(16, 0), (17, 1)]
        case .steamController: return [(14, 0), (15, 1), (16, 2), (17, 3)]
        default: return [(16, 0), (17, 1), (18, 2), (19, 3)]
        }
    }

    /// The family a preset made for this brand names its buttons in. A
    /// Steam Controller here is the 2026 model: the rows use the standard
    /// numbering, which the 2015 model does not read.
    static func family(for brand: ControllerBrand) -> FaceLetters? {
        brand == .steamController ? .steamController2026 : ButtonNames.family(forBrand: brand)
    }

    /// The catalog writes a row's notes with Xbox names ("A: jump", "B
    /// dodges", "LT/L2: aim", "look right (hold RT)"); on another pad those
    /// names point at the wrong buttons, so they are swapped for this pad's.
    /// A leading name is swapped only when it is the row's own control, and
    /// one mid-sentence only after hold, press, or tap.
    static func renamedNote(_ note: String, input: String, brand: ControllerBrand) -> String {
        var out = note
        if let range = out.range(of: leadingName, options: .regularExpression) {
            out = label(for: input, brand: brand) + ": " + out[range.upperBound...]
        } else if let range = out.range(of: #"^(B|X|Y|LB|RB|LT|RT|View|Menu|Back|Start|Guide|Cross|Circle|Square|Triangle|L1|R1|L2|R2|Options)(?= )|^A(?= = )"#,
                                        options: .regularExpression),
                  isSameControl(String(out[range]), input) {
            out.replaceSubrange(range, with: label(for: input, brand: brand))
        }
        guard let regex = try? NSRegularExpression(pattern: #"\b(hold|holding|press|pressing|tap) (LB|RB|LT|RT|L1|R1|L2|R2|Cross|Circle|Square|Triangle|A|B|X|Y)\b"#) else {
            return out
        }
        let ns = out as NSString
        for match in regex.matches(in: out, range: NSRange(location: 0, length: ns.length)).reversed() {
            let token = ns.substring(with: match.range(at: 2))
            guard let control = xboxControls[token] else { continue }
            out = (out as NSString).replacingCharacters(in: match.range(at: 2), with: label(for: control, brand: brand))
        }
        return out
    }

    /// A catalog note in the app's language, named for this pad. A preset is
    /// written in the language it is made in, like its notes: the English
    /// catalog note goes through the shipped translation table, and the
    /// button name in front ("A: jump", which translations keep as "A:
    /// springen") becomes this pad's ("Kreuz: springen"). English, or a note
    /// with no translation, takes the English renaming.
    static func localizedNote(_ note: String, input: String, brand: ControllerBrand) -> String {
        let shown = ShippedText.t(note)
        guard shown != note else { return renamedNote(note, input: input, brand: brand) }
        // Arabic and Hebrew notes may open with a right-to-left mark that
        // sets their direction; the button name is found after it.
        let rtlMark = shown.hasPrefix("\u{200F}")
        let translated = rtlMark ? String(shown.dropFirst()) : shown
        var out = translated
        if note.range(of: leadingName, options: .regularExpression) != nil,
           let action = actionAfterName(translated) {
            out = String(localized: "\(label(for: input, brand: brand)): \(action)")
        } else if let range = note.range(of: #"^(B|X|Y|LB|RB|LT|RT|View|Menu|Back|Start|Guide|Cross|Circle|Square|Triangle|L1|R1|L2|R2|Options)(?= )|^A(?= = )"#,
                                          options: .regularExpression),
                  isSameControl(String(note[range]), input) {
            // The same name at the start of the translation, which may carry
            // a particle ("Bで", "B는") or a Hungarian article ("A B", "Az Y");
            // a translation that translated the word ("Zurück = ...") is left.
            let name = NSRegularExpression.escapedPattern(for: String(note[range]))
            if let found = out.range(of: #"^(?:Az? )?"# + name + #"(?![A-Za-z0-9])"#, options: .regularExpression),
               let word = out[found].range(of: String(note[range]), options: .backwards) {
                out.replaceSubrange(word, with: label(for: input, brand: brand))
            }
        }
        // The Xbox shoulder names mid-sentence ("halte RT") are this pad's;
        // they never stand for anything else, unlike a lone A or X.
        for token in ["LB", "RB", "LT", "RT", "L1", "R1", "L2", "R2"] {
            guard let control = xboxControls[token], out.contains(token) else { continue }
            out = out.replacingOccurrences(of: #"(?<![A-Za-z0-9])"# + token + #"(?![A-Za-z0-9])"#,
                                           with: label(for: control, brand: brand), options: .regularExpression)
        }
        // A face letter after hold, press or tap in the English ("hold B"):
        // the same lone letter in the translation, when it appears just once.
        if let regex = try? NSRegularExpression(pattern: #"\b(?:hold|holding|press|pressing|tap) ([ABXY])\b"#) {
            let ns = note as NSString
            for match in regex.matches(in: note, range: NSRange(location: 0, length: ns.length)) {
                let letter = ns.substring(with: match.range(at: 1))
                guard let control = xboxControls[letter] else { continue }
                let lone = #"(?<![A-Za-z0-9])"# + letter + #"(?![A-Za-z0-9])"#
                let hits = (try? NSRegularExpression(pattern: lone))?.numberOfMatches(in: out, range: NSRange(out.startIndex..., in: out)) ?? 0
                if hits == 1 {
                    out = out.replacingOccurrences(of: lone, with: label(for: control, brand: brand), options: .regularExpression)
                }
            }
        }
        return rtlMark ? "\u{200F}" + out : out
    }

    /// The action part of a translated note, after its leading button name
    /// and colon (a full-width colon in Chinese and Japanese, a space before
    /// it in French), or nil when there is none near the start.
    private static func actionAfterName(_ s: String) -> String? {
        guard let colon = s.firstIndex(where: { $0 == ":" || $0 == "\u{FF1A}" }),
              s.distance(from: s.startIndex, to: colon) <= 40 else { return nil }
        let action = s[s.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return action.isEmpty ? nil : action
    }

    /// `action(of:)` in the app's language.
    static func localizedAction(of note: String) -> String {
        var translated = ShippedText.t(note)
        if translated.hasPrefix("\u{200F}") { translated.removeFirst() }
        guard translated != note else { return action(of: note) }
        if note.range(of: leadingName, options: .regularExpression) != nil, let action = actionAfterName(translated) {
            return action
        }
        return translated
    }

    /// A catalog note without its leading button name ("A: jump" is
    /// "jump"), for places that print the button name beside it.
    static func action(of note: String) -> String {
        guard let range = note.range(of: leadingName, options: .regularExpression) else { return note }
        return String(note[range.upperBound...])
    }

    private static let leadingName = #"^(A|B|X|Y|LB|RB|LT|RT|View|Menu|Back|Start|Guide|L3|R3|Cross|Circle|Square|Triangle|L1|R1|L2|R2|Options)(\s*/\s*[A-Za-z0-9]+)?:\s*"#

    /// The catalog's Xbox names and the inputs they stand for, and the
    /// PlayStation names the fighting and racing profiles were written with,
    /// so those notes name an Xbox, Switch or 8BitDo pad's buttons too.
    private static let xboxControls: [String: String] = [
        "A": "btn 0", "B": "btn 1", "X": "btn 2", "Y": "btn 3", "LB": "btn 4", "RB": "btn 5",
        "LT": "btn 6", "RT": "btn 7", "View": "btn 8", "Back": "btn 8", "Menu": "btn 9", "Start": "btn 9",
        "Guide": "btn 10", "L3": "btn 11", "R3": "btn 12",
        "Cross": "btn 0", "Circle": "btn 1", "Square": "btn 2", "Triangle": "btn 3",
        "L1": "btn 4", "R1": "btn 5", "L2": "btn 6", "R2": "btn 7", "Options": "btn 9",
    ]

    private static func isSameControl(_ name: String, _ input: String) -> Bool {
        if xboxControls[name] == input { return true }
        return ((name == "LT" || name == "L2") && input.hasPrefix("axi 4"))
            || ((name == "RT" || name == "R2") && input.hasPrefix("axi 5"))
    }

    static func label(for input: String, brand: ControllerBrand) -> String {
        let parts = input.split(separator: " ").map(String.init)
        guard let kind = parts.first else { return input }
        switch kind {
        case "btn":
            return buttonLabel(Int(parts.count > 1 ? parts[1] : "") ?? -1, brand: brand)
        case "axi":
            return axisLabel(Int(parts.count > 1 ? parts[1] : "") ?? -1, brand: brand)
        case "hat":
            return String(localized: "D-pad \(dpadDir(parts.count > 2 ? parts[2] : ""))")
        default:
            return input
        }
    }

    /// A button's short name for notes, from the same tables the editor
    /// and visualizer use (makePreset pins the preset to the brand's
    /// family). A brand with no family takes the Face button names setting
    /// for its face buttons.
    private static func buttonLabel(_ index: Int, brand: ControllerBrand) -> String {
        let family = family(for: brand)
        let model = ButtonNames.ModelNames.of(brand: brand, dualShock3: false)
        if FaceLetters.current == .positions, let position = FaceLetters.positionName(index) {
            return position
        }
        switch index {
        case 0...3:
            // The same name the editor shows for this button: on an Xbox
            // style pad that follows the Face button names setting.
            if let family, family != .xbox, let name = ButtonNames.name(index, family: family) { return name }
            if family == .xbox { return ButtonNames.label(index, family: .xbox, model: model) }
            let choice = FaceLetters.current
            if choice == .playstation { return FaceLetters.genericName(index, choice: .playstation) ?? String(localized: "Button \(index)") }
            let nintendo = FaceLetters.nintendo(for: brand, choice: choice)
            return ButtonNames.name(index, family: nintendo ? .nintendo : .xbox) ?? String(localized: "Button \(index)")
        case 4...10:
            if let short = ButtonNames.short(index, family: family, model: model) { return short }
            return String(localized: "Button \(index)")
        case 11: return String(localized: "Left stick click (L3)")
        case 12: return String(localized: "Right stick click (R3)")
        default:
            return family.flatMap { ButtonNames.name(index, family: $0) }
                ?? (index == 13 ? String(localized: "Touchpad") : String(localized: "Button \(index)"))
        }
    }

    private static func axisLabel(_ index: Int, brand: ControllerBrand) -> String {
        switch index {
        case 0, 1: return String(localized: "Left stick")
        case 2, 3: return String(localized: "Right stick")
        case 4:    return buttonLabel(6, brand: brand)
        case 5:    return buttonLabel(7, brand: brand)
        default:   return String(localized: "Axis \(index)")
        }
    }

    private static func dpadDir(_ d: String) -> String {
        switch d {
        case "U": return String(localized: "Up")
        case "D": return String(localized: "Down")
        case "L": return String(localized: "Left")
        case "R": return String(localized: "Right")
        default:  return d
        }
    }
}

// MARK: - Updates to built-in presets

/// A feature added to a built-in preset after it shipped, offered to a
/// library that already has that preset. Only the addition is applied,
/// never the rest of the shipped preset, so the person's own changes stay.
/// In the editor it is an ordinary edit: Undo takes it back, and nothing is
/// kept until Save.
struct BuiltInUpdate: Identifiable {
    let id: String
    /// The built-in's name on disk (English), which the copy still has.
    let presetName: String
    let title: String
    let detail: String
    /// Already there: the copy has it, so nothing is offered.
    let isApplied: (Preset) -> Bool
    /// Adds the rows to the preset and returns the regions they read, by
    /// stick key, for the region editors to hold until Save.
    let apply: (inout Preset) -> [Int: [TouchpadRegion]]

    static let declinedKey = "InputConfig.builtInUpdates.declined"

    static var all: [BuiltInUpdate] { [minecraftSprint, macrosTurbo19] }

    static var macrosTurbo19: BuiltInUpdate {
        BuiltInUpdate(
            id: "macrosTurbo.typedAndSequence.19",
            presetName: "Macros & Turbo",
            title: String(localized: "A typed macro and a button sequence"),
            detail: String(localized: "New for this built-in preset: X plays a macro that types, waits and pastes at double speed, and Down, Down, B pressed in order sends Space. Only these rows are added; your other changes stay."),
            isApplied: { p in
                let rows = p.joysticks.flatMap(\.bindings)
                return rows.contains { $0.input.type == .buttonSequence }
                    && rows.contains { $0.input.type == .button && $0.input.index == 2 }
            },
            apply: { p in
                guard !p.joysticks.isEmpty else { return [:] }
                let rows = p.joysticks.flatMap(\.bindings)
                var added = ExamplePresets.macrosTurbo19Rows
                // A row the person put on X already keeps X.
                if !rows.contains(where: { $0.input.type == .button && $0.input.index == 2 }) {
                    added.typed.note = ExamplePresets.rowNotes["Macros & Turbo"]?[added.typed.input.serialized]
                    p.joysticks[0].bindings.append(added.typed)
                }
                if !rows.contains(where: { $0.input.type == .buttonSequence }) {
                    added.sequence.note = ExamplePresets.rowNotes["Macros & Turbo"]?[added.sequence.input.serialized]
                    p.joysticks[0].bindings.append(added.sequence)
                }
                return [:]
            })
    }

    static var minecraftSprint: BuiltInUpdate {
        BuiltInUpdate(
            id: "minecraft.sprintAtFullPush.17",
            presetName: "Minecraft",
            title: String(localized: "Sprint at full push"),
            detail: String(localized: "New for this built-in preset: pushing the left stick all the way forward also sprints, while it keeps walking. Only this is added; your other changes stay."),
            isApplied: { p in
                p.joysticks.contains { $0.bindings.contains { $0.input.stickRegionID == ExamplePresets.minecraftSprintID } }
            },
            apply: { p in
                guard !p.joysticks.isEmpty else { return [:] }
                let (ring, row) = ExamplePresets.minecraftSprintRing
                p.joysticks[0].bindings.append(row)
                return [0: [ring]]
            })
    }

    /// What this preset is offered: updates for its built-in, not yet in it,
    /// and not turned down for this preset.
    static func offers(for p: Preset) -> [BuiltInUpdate] {
        let declined = Set(UserDefaults.standard.stringArray(forKey: declinedKey) ?? [])
        // Not to a copy that had it: a row deleted since is the person's.
        return all.filter { u in
            u.presetName == p.name && !u.isApplied(p) && !u.seen(by: p) && !declined.contains("\(u.id)|\(p.id.uuidString)")
        }
    }

    /// The copy has had this update (seeded with it, or added in the editor).
    func seen(by p: Preset) -> Bool { p.seenUpdates?.contains(id) == true }

    /// Notes on a copy that has every update for its name.
    static func markSeen(_ ids: [String], on p: inout Preset) {
        guard !ids.isEmpty else { return }
        p.seenUpdates = Array(Set(p.seenUpdates ?? []).union(ids)).sorted()
    }

    /// Ids of the updates for a built-in by name.
    static func ids(for name: String) -> [String] { all.filter { $0.presetName == name }.map(\.id) }

    static func decline(_ u: BuiltInUpdate, for p: Preset) {
        var list = UserDefaults.standard.stringArray(forKey: declinedKey) ?? []
        let key = "\(u.id)|\(p.id.uuidString)"
        if !list.contains(key) { list.append(key) }
        UserDefaults.standard.set(list, forKey: declinedKey)
    }
}
