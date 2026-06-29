# InputConfig

Map any game controller to keyboard and mouse on macOS.

## Overview

InputConfig lets you use any game controller as a keyboard and mouse on your Mac. Plug in your controller, pick a preset, and go. Or build your own from scratch.

Works with DualSense (PS5), DualSense Edge, DualShock 4 (PS4), Xbox Wireless, and any MFi or HID-compatible gamepad. No drivers needed.

![Welcome](screenshots/welcome.png)

When you open InputConfig it shows you everything it can do up front. Start a preset from scratch, let the Smart Preset Maker build one for you, or open a guide. The cards below are the features you can build with: keyboard and mouse output, MIDI, variable sensitivity, deadzone calibration, macros and turbo, haptic and spoken feedback, light bar control, full controller support, touchpad mouse, gyroscope motion, and lifetime statistics.

![Main View](screenshots/main_view.png)

The main view shows all your presets on the left with a live status bar for connected controllers. You can see battery level, button count, axis count, and light bar status at a glance. Activate any preset with one click. The bottom panel is a live logger that shows engine activity, connected controllers, and input events in real time at 120Hz.

![Controller Light Bar Customization](screenshots/controller_popover.png)

Click any connected controller in the status bar to open the controller panel. From here you can change the light bar color with presets or a custom color picker, adjust brightness, or kick off an RGB cycle. The panel also shows controller type, button and axis counts, motion support, battery level, and the full list of raw button names exposed by the device.

![Live Controller Visualizer](screenshots/live_visualizer.png)

Activate a preset and the live visualizer mirrors your controller on screen in real time. Every button, stick, and trigger lights up as you press it, so you can confirm a mapping is working at a glance. The preset list on the left is organized into folders you can name and color, and the log along the bottom shows every event as it fires at 120Hz.

![Binding Editor](screenshots/binding_editor.png)

The binding editor is where you set up your mappings. Hit Scan to detect a button press or axis movement from your controller, then assign it to a keyboard key, mouse button, mouse motion, or scroll wheel. Every binding has its own output type picker and value selector. You can add multiple outputs per input, reorder bindings with drag and drop, and duplicate or delete them individually. Each binding has advanced options for per-axis deadzones, axis inversion, sensitivity curves, toggle mode, turbo rapid fire, repeat count and delay, or a full macro sequence with custom wait and hold times per step.

## Features

- Map buttons, triggers, joysticks, and D-pad to keyboard keys, mouse movement, mouse buttons, and scroll wheel
- Built-in presets for adaptive controllers, desktop navigation, web browsing, media control, and popular games
- Live controller visualizer mirrors your input in real time
- Record macro sequences with custom timing per step
- Turbo (rapid fire) and toggle mode on any button
- Adjustable deadzones, axis inversion, and sensitivity curves with visual calibration
- Customize controller light bar colors per preset with a full RGB color picker
- Send MIDI output to your favorite DAW
- Built-in 3D gyroscope and motion tracking
- Touchpad surface calibration
- Create unlimited presets and switch instantly
- Import, export, and share presets between users
- Convert presets between controller types
- Works with any HID-compatible gamepad, no drivers needed
- Lifetime usage statistics

100% free.

## Supported Controllers

- PlayStation DualSense (PS5) and DualSense Edge
- PlayStation DualShock 4 (PS4)
- Xbox Wireless Controller
- Any MFi or HID-compatible gamepad

## Requirements

- macOS 14.0 or later
- Accessibility permission (for keyboard and mouse simulation)

## Building

1. Open `InputConfig.xcodeproj` in Xcode 16+
2. Select your team in Signing & Capabilities
3. Build and run

## License

MIT License. See [LICENSE](LICENSE) for details.

## Privacy

InputConfig does not collect any data. See [PRIVACY.md](PRIVACY.md).

## Contact

Questions, bugs, or feature requests? Reach out at [ryleighnewman.com](https://ryleighnewman.com).
