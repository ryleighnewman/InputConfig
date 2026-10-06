# InputConfig: free controller mapper for Mac

InputConfig is a free, open-source controller mapper for macOS. Map any PS5, Xbox or
Switch controller to keyboard keys and mouse movement, use a controller as a mouse,
run your Mac from a MIDI knob box, play games that never supported controllers, or
replace a keyboard entirely if using one is difficult. It works in every app, not
only games.

Works with PS5 DualSense and DualSense Edge, PS4 DualShock 4, Xbox Wireless, Series
and Elite, Switch Pro and Joy-Con, 8BitDo Pro 2 and Ultimate 2C, the PlayStation Access Controller, the
Xbox Adaptive Controller, MIDI keyboards and pad controllers, and any HID-compatible
gamepad. No drivers, no subscription, no account.

Website and documentation: [inputconfig.com](https://inputconfig.com), with
[help for every feature](https://inputconfig.com/help/), [guides](https://inputconfig.com/guides/),
and [ready-made presets for 450+ games and apps](https://inputconfig.com/presets/).

<a href="https://apps.apple.com/us/app/inputconfig/id6777759147?pt=128760092&amp;ct=github&amp;mt=12"><img src="https://toolbox.marketingtools.apple.com/api/v2/badges/download-on-the-mac-app-store/black/en-us" alt="Download on the Mac App Store" height="56"></a>

## Overview

Plug in your device, pick a preset, and go. Or build your own from scratch: every
button, trigger, stick, key, knob, and pad can send keys, clicks, mouse motion,
scroll, macros, MIDI, spoken phrases, or a system function like volume, brightness,
or a Siri Shortcut.

It is not just for game controllers. Your Mac keyboard, a second keyboard, extra
mouse buttons, the trackpad (including Force Touch pressure), regions of the screen,
and full MIDI gear all work as inputs too.

## What's new in 1.6

- Optimized for macOS 27, with a new app icon made for the Dark, Clear, and Tinted styles
- Added infrastructure for far more controllers: generic USB pads and arcade sticks take their button names from the community SDL GameControllerDB, and wheels, flight sticks, and pedals are read on every axis at full resolution and every hat switch
- Generic USB pads and a single Joy-Con number their controls like other controllers; InputConfig offers to update older rows on USB pads
- Added infrastructure for two-player adapters and dual arcade encoders, so each player gets a controller of their own
- Added infrastructure for Valve's 2026 Steam Controller on a USB cable, over Bluetooth, or through its Puck: every button, the four back buttons, both trackpads, the gyro, rumble, and battery, and a built-in preset
- Added infrastructure for the Stream Deck, the Neo's touch points and the Stream Deck modules included, connected from the Devices menu or the menu bar
- New built-in presets: Easy Browse for using the whole Mac from a controller, Easy Edit for a controller in one hand and a mouse in the other, and Auto Clicker, which clicks 5 to 20 times a second, on and off, while held, or a set number of times
- While the editor is open, the controller still moves the pointer and clicks, and Escape, Return, Tab, the arrows and Space still work from it, so Save and Cancel are always in reach
- Star your favorite presets and show only favorites in the sidebar and the menu bar
- A controller that also acts as a keyboard, such as some arcade sticks, works once Input Monitoring is allowed for InputConfig in System Settings
- With two PlayStation controllers connected, each gets its own light color, rumble, and Edge paddles, and two identical controllers can go to two players
- While the Mac sleeps or is locked no key is sent: at the lock screen only the pointer, clicks, and scrolling work

Full release history in [CHANGELOG.md](CHANGELOG.md). This section tracks the latest release.

## A tour

![Turn literally anything into your Mac's input](Marketing/posters/01-hero.jpg)

Open InputConfig and everything it can do is on one screen. Controllers, keyboards,
mice, trackpads, and MIDI gear go in; keys, mouse, macros, MIDI, system functions,
and Siri Shortcuts come out. Forty-five presets ship with it, sorted into folders you
can name and color, and the Smart Preset Maker draws on a library of more than 450
games and apps.

![Press anything to bind it](Marketing/posters/02-scan.jpg)

Scanning maps any input the instant you touch it. No manual codes, no guesswork,
and it works for controllers, MIDI gear, and your Mac's own keyboard and trackpad.

![Fine-tune every binding](Marketing/posters/04-advanced.jpg)

One press can send a key, a click, a MIDI note, and a spoken phrase at once, then
repeat while held, send Return on a double tap, run a two-step macro, and rumble,
with every timing set right in the row.

![Your Mac is an input, too](Marketing/posters/05-mac-inputs.jpg)

Every key on the keyboard, every click, scroll gesture, and Force Touch on the
trackpad or mouse, any area of the screen, and a knock on the palm rest can all be
scanned and mapped like a controller button.

![Built for accessibility](Marketing/posters/06-accessibility.jpg)

Drive your whole Mac from a single stick. One-stick driving steers, accelerates,
brakes, and shifts from one control, and it outputs keyboard and mouse, so it works
in games that never planned for it. Built with the PlayStation Access Controller
and other adaptive hardware in mind.

![Send MIDI in and out](Marketing/posters/07-outputs.jpg)

Play notes into your DAW through a virtual MIDI port, or let a MIDI keyboard or knob
box drive the Mac itself: volume, tracks, brightness, Mission Control, a Siri
Shortcut. Every binding shows exactly what it sends.

![See every input live](Marketing/posters/03-visualizer.jpg)

The Live Visualizer mirrors your controller and your MIDI gear in real time. Sticks,
triggers, keys, and knobs light up as you play, clicking any control jumps straight
to its binding, and Edit Layout rearranges the keyboard, mouse, touchpad and generic
maps; a drawn controller keeps its real layout.

![Touchpad support, done right](Marketing/posters/08-touchpad.jpg)

Calibrate a controller touchpad so swipes feel uniform, then carve it into tap zones
that fire their own bindings, with two fingers tracked independently.

![Deadzones, dialed in](Marketing/posters/09-precision.jpg)

Tune the inner and outer deadzone on every stick and trigger with a live plot, so
drift disappears and full travel stays. Bind gyroscope rotation to the mouse for
motion aim in any app, with live sensor readings and a resting-zero calibration.

![Open source, yours](Marketing/posters/10-about.jpg)

No accounts, no tracking, no locked features. Built by one person who needed it.

## How it compares

| | InputConfig | Joystick Mapper | Gamepad Companion | Enjoyable | Karabiner-Elements |
|---|---|---|---|---|---|
| Cost | Free | Paid | Paid | Free | Free |
| Open source | Yes, MIT | No | No | Yes | Yes |
| Game controllers | Yes | Yes | Yes | Yes | No, keyboards only |
| MIDI keyboards and pads as input | Yes | No | No | No | No |
| Mac keyboard/mouse/trackpad as input | Yes | No | No | No | Keyboard only |
| DualSense Edge paddles and extras | Yes | No | No | No | No |
| System functions and Siri Shortcuts | Yes | No | No | No | Limited |
| Per-app preset switching | Yes | No | No | No | Yes |
| Macros, turbo, tap and hold | Yes | Limited | Limited | No | Limited |
| MIDI output | Yes | No | No | No | No |
| Gyroscope and motion | Yes | No | No | No | No |
| Light bar control | Yes | No | No | No | No |
| Still updated | Yes | Rarely | Rarely | No | Yes |

Checked August 2026. Some of these have been around far longer than mine and are good
tools. Check for yourself before you switch.

## Everything it does

### Input sources

- Every button, trigger, joystick, and D-pad on any MFi or HID-compatible gamepad
- DualSense Edge extras: both back paddles, both FN buttons, and the mute button, over USB and Bluetooth
- Controller touchpads: cursor control, two-finger tracking, tap zones, one-finger and two-finger taps, with calibration
- Gyroscope, accelerometer, and absolute attitude on Sony controllers (DualSense, DualShock 4)
- MIDI notes and pads, CC knobs, sliders, and pedals, the pitch wheel, channel and polyphonic aftertouch, Program Change, and transport Start, Continue, and Stop, from any MIDI device over USB or Bluetooth
- Three knob modes for MIDI dials: Switch (fires past halfway), Dial (speed grows from center, like a stick), and Turn (a nudge per step of rotation, for knobs and for endless encoders set to absolute mode)
- Per-binding MIDI channel and device filters, so two keyboards stay independent
- Your Mac keyboard as an input: every key, including Shift, Control, Option, Command, Caps Lock, fn, and the brightness, media, and volume keys, on the built-in keyboard or any keyboard you connect (all keyboards read as one)
- Your mouse and trackpad as inputs: every button, double click, scroll in four directions, scroll gestures, Force Touch pressure, and Force Click
- Tap the Mac: knock on the palm rest and the MacBook's motion sensor fires any output, single to quintuple taps, with a live calibration plot
- Screen regions: areas of any display that act as inputs while the pointer is inside them, per display or on every display
- Bluetooth headset and hearing aid buttons as media keys
- Switches, pedals, and sticks plugged into a PlayStation Access Controller or Xbox Adaptive Controller
- Stick regions: directional zones on any stick with their own bindings

### Outputs

- Keyboard keys, including full modifier combos (Cmd+Shift+3 and friends fire as real chords)
- Type whole words or phrases from a single press
- Mouse buttons, analog mouse motion, smooth scrolling, and single scroll steps
- Macro sequences with custom timing, chord steps that hold one key while tapping others, and interrupt-on-release
- MIDI out to your DAW through a virtual port: notes with velocity, CC, pitch bend, Program Change, and transport (start, stop, continue)
- Spoken phrases, in the system voice or any installed voice
- Haptic feedback with adjustable strength and duration
- App actions: switch presets, jump to a specific preset, pause and resume output, all from the controller

### System functions

- Volume up, volume down, and mute, in the same steps as the keyboard keys
- System volume as a fader: the Mac's level follows a knob's position 1-to-1, and only takes over once you actually move it
- Play/pause, next track, and previous track, as real media keys
- Screen brightness up and down
- Mission Control, Launchpad, Spotlight, lock screen, and the screenshot toolbar
- Run any Siri Shortcut by name, picked from a list of your installed Shortcuts, without stealing focus
- Open any app or any URL, from https links to app schemes

### Per-binding control

- Toggle mode: press once to latch, press again to release
- Turbo with an adjustable rate, and repeat counts with custom delays
- Hold actions and double-tap actions, each with their own outputs and timing windows
- Chords: a row can require up to three controls held together, each chosen from the menu or scanned
- Inner and outer deadzones with a live visual calibrator on every stick and trigger
- Axis inversion and three sensitivity curves: linear, smooth, aggressive
- Variable sensitivity: trigger pressure and stick depth scale the output speed
- Stacked outputs: one input firing several outputs in parallel
- A note field on every binding, so a preset explains itself

### Presets

- 45 built-in presets: Easy Browse and Easy Edit, an Auto Clicker, the Access Controller and One-Stick Driving, the Mac's own keyboard, trackpad, and modifiers, desktop navigation, web browsing, media control, popular games, MIDI and creative work, and feature showcases, every row annotated
- Smart Preset Maker builds a tailored preset from a few questions, from a library of more than 450 games, apps, and workflows, and can add a touchpad-as-trackpad, gyro fine aim, and trigger rumble
- Folders with names and colors, and unlimited presets of your own
- Per-app auto-switch: presets activate themselves when their app comes to the front
- Per-preset automation: launch an app or URL on activate, confine the cursor, auto-recenter, hide the pointer
- Import, export, and share presets, and convert them between controller types
- A global keyboard shortcut to toggle the most recent preset from anywhere
- Crash recovery offers to start your active preset again after a crash

### Live Visualizer

- A real-time mirror of every connected device, one panel per slot
- Switchable layouts per slot: controller, keyboard, mouse and trackpad, controller touchpad, screen regions, or MIDI instrument, with auto-detection from the bindings
- The MIDI instrument: a seven-octave velocity-shaded keyboard, a named dial for every knob (Mod Wheel, Cutoff, Sustain and the rest), knob-mode badges, pitch bend and aftertouch meters, a 16-channel activity strip, and a rolling event log
- Click any control to jump straight to its binding in the editor
- Edit Layout to rearrange the keyboard, mouse, touchpad and generic maps (a drawn controller keeps its real layout), plus zoom, pan, and four backgrounds

### Accessibility

- One-stick driving: steer, accelerate, brake, and shift from a single stick
- App-wide text size, bold text, reduced transparency, and reduced motion, layered on top of the system settings
- VoiceOver support throughout, including the Live Visualizer spoken in plain words
- Built-in presets for the PlayStation Access Controller: Access Controller runs the whole desktop from one stick and eight sockets, and One-Stick Driving drives a whole car from one stick
- Deadzone and sensitivity tuning that matters for tremor and limited range of motion

### The app

- Light bar colors per preset with a full RGB picker, brightness control, and an RGB cycle, over USB and Bluetooth
- Battery level and connection state for every controller
- A changelog inside the app and a What's New popup after updates
- 42 built-in help guides, the same pages as inputconfig.com, and a guided Quick Start tour
- Menu bar control with a choice of twelve icons, plus Dock-only and menu-bar-only modes
- An activity log of everything the app does, with a one-file report ready to send
- Adjustable polling rate: 60, 120, 180, or 240 Hz, with an automatic battery saver
- Sandboxed, no network access, no telemetry

100% free.

## Supported controllers

- PlayStation Access Controller (and other adaptive hardware)
- PlayStation DualSense (PS5) and DualSense Edge, including the Edge's paddles and extra buttons
- PlayStation DualShock 4 (PS4)
- Xbox Wireless Controller (One, Series X|S), Xbox Elite Series 2, and the Xbox Adaptive Controller
- Nintendo Switch Pro Controller and Joy-Cons
- 8BitDo Pro 2, SN30 Pro+, SN30 Pro, and Ultimate 2C
- Steam Controller (2015 and 2026), Stadia Controller, and the Logitech G29 and G923 wheels
- Any MFi or HID-compatible gamepad
- MIDI keyboards, pad controllers, knob boxes, and control surfaces
- Stream Deck keys
- Your Mac keyboard, mouse, and trackpad

Other controllers, joysticks and wheels are read as well, shown in a generic drawing.

## Questions people ask

**How do I use a PS5 or Xbox controller as a keyboard and mouse on Mac?**
Install InputConfig, plug in or pair the controller, pick a preset, and press Activate.
macOS will ask for Accessibility permission the first time, which is what lets any app send
keystrokes and mouse movement.

**Can I use a MIDI keyboard or pad controller to control my Mac?**
Yes, and it needs no game controller alongside it. Notes and pads act like buttons,
knobs get three modes (Switch, Dial, Turn), the sustain pedal is a switch, and a knob
bound to System Volume becomes a hardware volume fader. The built-in MIDI: Knob Deck
and MIDI: Media Deck presets are ready to remap.

**Can I map the DualSense Edge back paddles and FN buttons?**
Yes. The Edge's back paddles, both FN buttons, and the mute button are bindable like
any other input, over both USB and Bluetooth.

**Can a button run a Siri Shortcut or change the volume?**
Yes. System Functions are outputs like any other: volume, mute, media keys,
brightness, Mission Control, lock screen, the screenshot toolbar, any Siri Shortcut
by name, or opening any app or URL.

**Is there a free alternative to Joystick Mapper or Gamepad Companion?**
This is one. InputConfig is free with nothing locked, and the source is public under MIT.

**Can I use a controller instead of a keyboard and mouse entirely?**
Yes, that is the point. There are built-in presets for desktop navigation, web browsing,
and media control, plus presets built for adaptive controllers. You can map screen regions,
type whole phrases from one button, and switch presets automatically per app.

**Does it work with the PlayStation Access Controller or the Xbox Adaptive Controller?**
Yes, along with anything else that presents as an MFi or HID gamepad, and the switches,
pedals, and sticks plugged into their ports are inputs too. The Access Controller preset
runs the whole desktop from one stick and eight sockets, and One-Stick Driving lets a
single stick handle steering, throttle, braking, and gear changes. Accessibility is why the app exists, not an
afterthought.

**Do I need drivers?**
No. Connect the controller by USB or Bluetooth and macOS handles the rest. MIDI
devices are found automatically too. Wired Xbox One and Series pads need macOS 15
or later; on macOS 14, connect them over Bluetooth.

**Can I map a controller for a game that has no controller support?**
Yes. Map the buttons and sticks to whatever keys and mouse motion the game expects, and it
sees a normal keyboard and mouse.

**Is it really free?**
Yes. No paid tier, no trial, no locked features. There is a tip jar in the app that unlocks
nothing.

## Requirements

- macOS 14.0 or later
- Accessibility permission (for keyboard and mouse simulation)
- Tap the Mac needs an Apple silicon MacBook: desktop Macs and Intel Macs have no motion sensor, and some earlier models do not publish it. On macOS 27 the Mac App Store sandbox does not let InputConfig switch the motion sensor on, so taps are heard while the sensor is already on

## Building

1. Open `InputConfig.xcodeproj` in Xcode 26 or later
2. Select your team in Signing & Capabilities
3. Build and run

## License

MIT License. See [LICENSE](LICENSE) for details.

## Acknowledgments

- [SDL_GameControllerDB](https://github.com/mdqinc/SDL_GameControllerDB) and SDL, Copyright (C) 1997-2025 Sam Lantinga, used under the zlib license. The full notice is in `SDLGameControllerDBData.swift`.
- [procon2-mac](https://github.com/caqlayan/procon2-mac), Copyright (c) 2026 Arda Caglayan Ercan, used under the MIT License, for the Switch 2 controller USB start-up commands. The full license text is in `Switch2USBEnabler.swift`.

## Privacy

InputConfig does not collect any data. See [PRIVACY.md](PRIVACY.md).

## Contact

Questions, bugs, or feature requests? Open an issue here, see [inputconfig.com/help](https://inputconfig.com/help/), or reach out at [ryleighnewman.com](https://ryleighnewman.com).

<a href="https://apps.apple.com/us/app/inputconfig/id6777759147?pt=128760092&amp;ct=github&amp;mt=12"><img src="https://toolbox.marketingtools.apple.com/api/v2/badges/download-on-the-mac-app-store/black/en-us" alt="Download on the Mac App Store" height="56"></a>
