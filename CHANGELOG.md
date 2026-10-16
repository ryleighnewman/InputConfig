# Changelog

## 1.7

- InputConfig is translated into 26 languages: Arabic, Chinese (Simplified and Traditional), Czech, Danish, Dutch, Finnish, French, German, Hebrew, Hungarian, Indonesian, Italian, Japanese, Korean, Norwegian, Polish, Portuguese, Russian, Slovak, Spanish, Swedish, Thai, Turkish, Ukrainian, and Vietnamese
- The Live Visualizer's keyboard takes the shape of your keyboard, ANSI, ISO or JIS, and labels every key with what it types in your input source, so AZERTY, QWERTZ, Dvorak, Cyrillic, Arabic and every other layout macOS has show as printed; key names in the editor and the Live Visualizer follow your keyboard layout too; rows still store each key by its place, so presets work the same on every layout
- The keyboard map shows the navigation keys and number pad of Apple's Magic Keyboard with Numeric Keypad when one is connected or a row uses them, with every key lined up with the rows beside it; pick the keyboard map's shape, the layout its keys are labeled in, and when the number pad shows from the menu above the map
- In Arabic and Hebrew the app reads right to left, while the drawings of keyboards, controllers, touchpads, and screens keep their real left and right
- Starting a preset by hand that keeps the pointer off the screen edges, recenters or hides it, or takes over mouse buttons first says so and lists every way to stop it, from your own Emergency Stop settings; check Don't show this again to skip it for that preset
- Game presets no longer pull the pointer to the middle of the screen or hide it, so inventories and menus work with the stick again; the games lock and hide the mouse themselves while you play. The built-in Minecraft preset and game presets from the Smart Preset Maker are updated
- The built-in Minecraft preset also sprints with the left stick pushed all the way forward; a Minecraft preset already in your library offers just that in the editor, to add or turn down
- Flight sticks, wheels, pedals and button boxes are read in full from what they report: every flight and driving axis, hat switches that report an angle, and buttons sent as a list, numbered after the controls they already had so existing presets keep working; every axis, hat and button such a device reports can be scanned, added as a row, and clicked in the Live Visualizer, including a wheel's steering and pedals and a flight stick's twist and throttle
- Rests at one end, a new row option for pedals, throttles and levers, reads the whole travel from rest to full; Scan turns it on when the control starts from an end
- Set Up Full Gyro, on any motion row, adds the rows for gyro aiming, tilting to move with the arrow keys, or shakes and jabs, and skips rows the group already has
- New app actions turn motion on and off with one press, or let the motion rows work only while a button is held, from any input, a key or a foot pedal included
- Level is how you hold it, a new option for tilt and pointer rows, measures the lean from your grip instead of from lying flat
- Motion from the 2015 Steam Controller and from a single Joy-Con now reaches presets, Yaw angle rows work, the 2026 Steam Controller can be re-zeroed, and a stalled Steam Controller link no longer holds a motion row's key
- Gyro aiming is steadier: the pointer no longer creeps while the controller is still, a stalled sensor stops it, and each controller remembers which way its tilt runs
- Controllers that need Input Monitoring offer to turn it on from both device menus, and are read as soon as it is allowed
- Groups set to different controllers never share one pad, a pad picked from the USB or Bluetooth list is followed by name, and Use the connected controller switches to the pad that is here
- Switching a controller off in the Live Visualizer lets go of every key, click and note it was holding
- The Globe key can be bound as an input, tapped on its own or held as fn
- MIDI: a CC output can send a set value on press, Scan picks up aftertouch from a key already held, Any channel pitch bend follows the bend being played, All Notes Off and All Sound Off release held note rows, Aftertouch rows no longer offer a direction that silenced them, and Reconnect MIDI Sources lets go of notes and pedals held by a source that went quiet
- A two-finger click on a PlayStation touchpad no longer also counts as a two-finger tap
- Rows keep options written by a newer version of InputConfig when the preset is saved here
- Opening a second copy of InputConfig now says a copy is already running, instead of closing at once
- Stick regions are rings: an area between two distances from the center and two directions, so pushing a stick past half way up is one button and all the way up another
- Triggers and single axes take bands, a range of their travel such as the last third of a trigger pull, each one a button
- A stick row fires by a direction or by a region, picked side by side in its direction menu; while the stick is inside a region, that region's row fires and the stick's direction rows wait, unless the region shares the stick (regions in presets made before 1.7 keep sharing)
- A region row's Options name the direction rows and the other regions it overlaps, and say which rows fire where they meet
- Stick gestures: flicks of a stick in order, such as pulling it straight back twice, fire a row; pick the flicks or record them by doing them; with Quick flicks only on, a push held out never counts
- A stick or trigger row's Options show it live, with the deadzone, the part of the stick that fires the row and its regions, following the sliders as they move; click it for the full view
- The deadzone sliders are now Deadzone and Full push at, each with a line on what it does; they take effect on the row as you move them, and the rows behind the sheet light by them before you save
- The editor has Name, Tag, Activate and the Emergency Stop at the top, and scrolled down, Activate and the Emergency Stop stay in one row beside the preset's name; a preset that is on keeps working while you edit, with a warning that recommends turning it off
- A new showcase and built-in preset, Stick Zones & Gestures, shows rings, bands, regions that share the stick, and gestures
- The Logitech G920 and G923 for Xbox are read through macOS racing wheel support, numbered like the G29 so wheel presets work on them, and show with their own button names and the shifter's gears wherever controllers are listed; InputConfig holds the wheel only while a preset, the editor or the Live Visualizer reads it
- Stream Deck +: each of its four dials can be pressed and turned either way, and its touch strip tapped, long pressed and swiped, each one a button after the eight keys
- Two-port adapters that send each port on its own read the second port's stick too
- A Steam Controller connected over Bluetooth is listed with how to connect it, instead of being taken for a keyboard
- Knobs, dials and wheels that report turns rather than positions are read as turns, and a centered slider or dial is no longer taken for a trigger
- Some USB controllers that read nothing, because of how their descriptor numbers its reports, now work
- A controller with no drawing of its own is named the same way everywhere and lists the buttons it really has; the Stream Deck + files its keys, dials and touch strip under their own headings
- A controller that drops and reconnects takes its old slot back, a pinned group keeps its toggles and held keys when its controller only moves slots, and each controller's connected time survives another one connecting
- The editor clears options an input type cannot use when you change it, no longer offers held actions on taps and gestures that are never held, a direction row says which regions it waits in, and search finds mouse buttons, macro steps, Type Text and Activate Preset targets by what the row shows
- Long dropdowns in the editor, and the Live Visualizer's controller menu, start with Search: type to find any choice in them, nested ones too, then pick it with the arrow keys and Return
- Turning on Vibrate, Speak a phrase, a macro, or a held or double tap action from a row's output menu opens Options with that area glowing for a moment, so it is easy to find
- A section's plus now sits under its last row, Hat in the input type menu says it is a D-pad or thumb switch, and a region row's menu lists only its own stick or trigger and names its region beside a color dot that shows it in the Regions card
- Each device group in the editor ends with a Regions card listing that device's touchpad, trackpads, sticks, triggers and screen, where regions are drawn, moved and resized, right-clicked to rename, duplicate or delete, and each part's rows are a click away; every Edit regions button opens it there
- Undo and Redo in the editor take back regions drawn, moved, resized or renamed too
- The touchpad needs no calibration, so Calibrate Touchpad is gone: macOS reports the whole pad
- A Steam Controller's left and right trackpads each have regions of their own
- A stick or trigger direction row can wait for a region, set in its Options, and fire only while the stick is inside it
- The sidebar can be searched and sorted by name, or by when presets were edited or made; a new library starts A to Z and an existing one keeps its own order
- The Presets menu holds every folder and Trash action, so the library can be organized from the keyboard, VoiceOver or Voice Control; Next Preset, Previous Preset and the menu bar's list follow the sidebar's order, a zoomed map in the Live Visualizer pans from its right-click menu, and a click anywhere on a card's header opens or closes it
- The Quick Start tour is shorter and friendlier, shows regions, opens Help and the motion menu for you, and its pointer reaches the toolbar and the editor
- Tap the Mac says on its row, in its Options, and on its home card that it works only on some MacBooks
- The Live Visualizer draws stick regions inside the sticks and trigger bands inside the triggers, and clicking a stick or trigger shows its regions larger
- The Live Visualizer's 3D controller now turns, tips and leans the way the controller does
- The Smart Preset Maker offers gyro aim on Switch Pro, Joy-Con and Steam Controllers, sprinting with the left stick pushed all the way and walking quietly on a light push, keeps a game's Steam launch link, offers trigger rumble only where a trigger clicks, and names your controller's buttons in fighting and racing notes
- Open URL no longer opens files, Shortcuts, scripts, network shares or calls, the import review says what each link really does, and failed actions are counted in the activity log rather than written out
- Sheets and the main window fit a 13-inch display at the largest text size and a short window too, the View, Window and Presets menus lost their duplicates and gained separators, and the app uses less CPU with a controller connected and scrolls smoothly with One-Stick Driving open
- The Live Visualizer lights the D-pad key line and the 8BitDo Micro's D-pad, shows the latest MIDI pitch bend and program change, and puts a PlayStation pad's light bar color between L2 and R2
- VoiceOver and Voice Control reach every region in the Regions card and the Live Visualizer, and hear search results and each jump between a row and its regions
- Restoring a backup from before 1.5 keeps its stick regions, and Quit and Restart Now keep a field you were still typing in

## 1.6

- Optimized for macOS 27, with a new app icon made for the Dark, Clear, and Tinted styles
- Added infrastructure for far more controllers: generic USB pads and arcade sticks take their button names from the community SDL GameControllerDB, and wheels, flight sticks, and pedals are read on every axis at full resolution and every hat switch
- Generic USB pads and a single Joy-Con number their controls like other controllers; InputConfig offers to update older rows on USB pads
- Added infrastructure for two-player adapters and dual arcade encoders, so each player gets a controller of their own
- Added infrastructure for Valve's 2026 Steam Controller on a USB cable, over Bluetooth, or through its Puck: every button, the four back buttons, both trackpads, the gyro, rumble, and battery, and a built-in preset
- Added trackpad handling for both Steam Controllers: slide, tap, double tap, and press on either pad
- Added infrastructure for the Logitech G29 and G923 wheels: a wheel in compatibility mode is switched to its own mode, the pedals read 0 to 1, and the Live Visualizer shows how far the wheel is turned in degrees
- Added infrastructure for the Stream Deck, the Neo's touch points and the Stream Deck modules included, connected from the Devices menu or the menu bar
- A controller that also acts as a keyboard, such as some arcade sticks, works once Input Monitoring is allowed for InputConfig in System Settings
- With two PlayStation controllers connected, each gets its own light color, rumble, and Edge paddles, and two identical controllers can go to two players
- A group set to one controller reads another of the same family when its own is away, such as an Edge for a DualSense, and otherwise says it is waiting, with one click to use the controller that is connected
- InputConfig explains controllers macOS cannot read: Xbox 360 pads in the Devices menu, and 8BitDo pads in the wrong mode in the main window
- Disconnect a controller from its entry at the top of the sidebar, or switch it off from its Live Visualizer panel so it reads as idle everywhere, remembered for that controller
- The Live Visualizer draws 19 controllers as themselves, with every control where it really is and what each one is bound to
- One menu on each Live Visualizer panel: Automatic, Screen, Keyboard, Touchpad, Mouse and MIDI, then Connected, where you pick which connected controller a group reads, and a menu for each maker for the model it is drawn as, even with nothing connected
- The Live Visualizer lists what each control does in a key down both sides of the drawing, each caption joined to its control by a line that never crosses another, so no label sits on a control or another label
- Drag the Live Visualizer map to move it around inside its panel; where you leave it and its zoom are kept for each preset, and Reset View puts it back
- The Live Visualizer marks every deadzone a group's rows set, on sticks, triggers, pedals, wheels and the gyro, the way the deadzone calibration does, and triggers are taller so the percent reads clearly
- Click a control, or any part of the Mouse, Keyboard, Touchpad, Screen or stick region map, in the Live Visualizer to see what it does and jump to its rows, and draw a screen region or open Touchpad Setup from there
- Light bar color as an output: any input can turn a DualSense or DualShock 4 light a color while held, set a color that stays, or switch the rainbow on and off, and a preset's rainbow runs at its own speed
- Share, Create, and Capture keep their macOS screenshot and recording shortcut unless the running preset uses them
- The controller emergency stop is a hold of Back and Start together, with a buzz a second in, and the same hold starts the preset again; on an Access Controller it is socket 7, and an Emergency Stop button under Activate and Edit shows the shortcut
- The binding editor opens faster and scrolls smoothly
- While the editor is open, the controller still moves the pointer and clicks, and Escape, Return, Tab, the arrows and Space still work from it, so Save and Cancel are always in reach
- Override on the editor's paused banner lets the running preset work fully while you edit; Scan still holds outputs back while it listens
- A row's hold and double tap each get a full second action at the bottom of Options: keys and shortcuts, clicks, typed text, MIDI, system functions, several outputs at once, and on a hold, pointer movement and scrolling
- Macro steps can send keyboard shortcuts, a row can repeat a held key like a real keyboard, and a repeating macro waits between passes
- Choose how long Scan waits, up to until canceled, and hear when it times out
- Type a screen region's, stick region's or touchpad region's place and size, and a fixed click point's X and Y, instead of only dragging
- Undo in the editor still steps back after Save and opening the editor again, and Previous versions lists a change the moment it is saved
- Every stick row shows its deadzone, and Adjust live sets it while you watch the stick
- Pointer speed and Scroll speed sliders on the preset page, Ramp-up on pointer rows, a D-pad that can take one direction at a time, and the pointer stops the moment you let go of the stick
- Re-zeroing the gyro centers the pointer on the display it is on, and tilt aiming is steadier: turning the controller no longer reads as tilt, and a resting hand no longer twitches the pointer
- Shortcuts in presets follow your keyboard layout, so Command A selects all on AZERTY, QWERTZ and Dvorak keyboards; Settings, Keyboard output can make typed keys follow it too, off by default since games read keys by position
- Bind keys from gaming, ISO, and Japanese keyboards, mouse buttons up to 32, controller buttons up to 128, and a tilt wheel
- MIDI Start, Continue, and Stop can be bound as inputs, and stick-driven MIDI CC reaches the full 0 to 127 range past the deadzone
- Name every button the Xbox, PlayStation, Nintendo, Stadia, GameCube, or Steam Controller way for each preset, or North, South, East, and West in Settings
- Pick the app's accent color in Settings, or any custom color
- Higher contrast text in Settings brightens hints and status lines, and turns on with the Mac's Increase Contrast
- A mouse side button can be kept from also going Back in a browser
- Star your favorite presets and show only favorites in the sidebar and the menu bar
- New built-in presets: Easy Browse for using the whole Mac from a controller, Easy Edit for a controller in one hand and a mouse in the other, and Auto Clicker, which clicks 5 to 20 times a second, on and off, while held, or a set number of times
- Restore Built-in Presets in Settings puts back any built-in you deleted
- Check Older Presets Again in Settings offers the update for presets made before 1.6 once more
- Import a preset by opening it or dropping it on the Dock icon: the review shows every action, macro and pointer setting in full, actions that open apps or websites can be removed first, and the preset asks before its first start
- Convert To makes a new preset beside the original
- The Smart Preset Maker fills back paddles, gives 13 apps their Mac shortcuts instead of Windows ones, and opens Steam games through Steam
- The built-in presets list rows on one stick or the D-pad in the same order on every install
- The Access Controller preset follows Sony's base profile: the center button clicks, socket 5 right-clicks, and socket 7 opens Spotlight
- Desktop Navigation: A clicks, and Select All moved to the right stick press
- Built-in presets you never changed are updated: Minecraft's right stick click swaps hands, the PS5 FPS touchpad opens the map, MIDI: Knob Deck scrolls from a centered knob, MIDI: Transport Control no longer drops the volume to 0, and Motion Cursor scrolls the same way as the other pointer presets
- In Trackpad & Mouse and Keyboard & Mouse Input, the side buttons send Command [ and ] and no longer also go Back on their own
- The Xbox and 8BitDo FPS presets, Minecraft, and Racing Game use Menu for Escape and View for Tab
- Keyboard Deck is retired: a copy you never changed moves to the Trash, and a copy you changed stays
- Confine, recenter, and hide cursor pause while InputConfig, the Finder, System Settings, the Dock or a permission prompt is in front; when a preset lists apps they work only there, and a preset that launches an app keeps them in the game it starts, such as Minecraft from its launcher
- New touchpad rows move the pointer as far up and down as they do side to side; rows made before 1.6 keep the speed they had
- One-Stick Driving with Throttle axis is a trigger uses the whole travel of a gas pedal that reads -1 to 1
- While the Mac sleeps or is locked no key is sent: at the lock screen only the pointer, clicks, and scrolling work
- After a crash, InputConfig asks before starting your preset again, and starts it by itself after 20 seconds with no answer
- Cancel in the editor asks before throwing away changes, and Empty Trash and deleting a folder ask first
- VoiceOver names every field in the binding editor and the visualizers, and the keyboard focus ring is back
- Text Size and Reduce Transparency reach every part of the app
- The menu bar icon turns orange when a running preset needs Accessibility, and rows start working the moment it is granted
- Statistics has a new look, and counts each controller's own time
- Uses less CPU and energy while nothing is moving
- Fixed the Switch Pro Controller and Joy-Con face buttons, where pressing A fired the rows meant for B; when one first connects, InputConfig offers to update rows recorded on it before
- Fixed 8BitDo back buttons, which were read as a DualSense Edge's Fn buttons, and the Pro 2's back buttons and wired model over USB; rows recorded on them before are offered the same update
- Fixed a gamepad that macOS GameController reads under a different name also being read directly, which doubled every press on a second slot
- Fixed a plain row and a chord row on the same button both lighting in the editor: a row lights only when it would fire, its held controls included
- Fixed keys and mouse buttons left held after a crash, a forced quit, or when two buttons share a key
- Fixed quick presses on two buttons mixing their shortcuts, and double clicks not opening files
- Fixed One-Stick Driving accelerating when the stick was pulled back; Invert throttle, the old workaround, is turned off
- Fixed recording a shortcut that InputConfig already uses, and Settings now says which shortcut or app holds a chord
- Fixed lifting or tilting a MacBook counting as a tap
- Fixed the Steam Controller's buttons, stick click, and wireless connection
- Fixed two identical controllers switching on and off together and sharing a motion zero, and controllers lost after a Bluetooth reconnect or a sleep
- Fixed the pointer vanishing past a screen edge, and recenter and confine fighting the stick
- Fixed chords firing the plain row on release, and gyro aim losing part of every turn
- Fixed Launchpad, brightness, keyboard light, Eject, Lock Screen, and Mouse Wheel Step outputs
- Fixed a damaged preset file freezing the app, and presets dropping rows made by a newer version
- Restoring a backup on a new Mac no longer duplicates the built-in presets, and says what it restored
- Fixed touchpad regions saving to the wrong preset, and Clear in Motion Calibration not sticking
- Fixed several built-in presets and Smart Presets whose rows did not match their notes
- Help is corrected throughout, and now covers gaming keypads, macro pads, pen tablets, switch interfaces, and Xbox Elite paddles

## 1.5

- Tap the Mac is now enhanced with additional compatibility on more MacBooks
- Quadruple and quintuple taps are now available in the binding editor
- Tap the Mac: Calibrate Taps is now in the Options of any tap row. Knock on the chassis and watch each strike to set the firmness threshold with a slider
- Your Mac is now an official input: every key on the keyboard and every click, scroll, and Force Touch on the mouse or trackpad can be mapped
- The Live Visualizer's Keyboard and Mouse & Trackpad templates are live: press a key or click and it lights on the diagram
- Four new presets for the Mac's own devices: Keyboard Deck, Trackpad & Mouse, Modifier Holds, and Double Click Deck, each with a home page showcase
- Screen regions are now their own input: draw an area of any display and it fires while the pointer is inside it
- The Live Visualizer has a Screen template showing the display, its regions, and the live pointer
- Zones and regions now belong to the preset they were drawn in
- The Live Visualizer builds its map from the connected controller, with proper PlayStation button shapes, a condensed layout, zoom, and a choice of background
- Every control in the Live Visualizer is clickable and opens its row in the editor
- The editor has a search field that finds any row by input, output, section, or note
- Rows sit under section headings, and Automatically insert available inputs adds a row for every control the device has
- The device menu lists everything the app can hear from: controllers, Bluetooth and USB devices, this Mac's keyboard and mouse, and MIDI sources
- A row's Options panel is laid out as boxes, with the input side on the left and the output side on the right
- The output menu now lists your Shortcuts, applications, presets, and every key by group
- Chords can hold up to three controls, chosen from the menu or scanned
- Accessories plugged into a PlayStation Access Controller or Xbox Adaptive Controller are picked up as inputs
- Bluetooth headset and hearing aid buttons can be mapped as media keys
- Gyro pointing follows the controller's tilt like a laser pointer, and the gyro zero learns itself
- Motion Calibration is one simple sheet with a 3D controller model and a Re-zero button you can assign
- Pointer motion from a stick, touchpad, or gyro is smooth, and the touchpad no longer lags while the Live Visualizer is open
- Touchpad Mouse works, with one-finger tap, two-finger tap, and double tap as inputs
- Rumble on a DualSense Edge is much stronger, its strength setting works, and vibration has a Duration slider
- New presets: One-Stick Driving, Access Controller, Cursor Regions, Hold & Double-Tap, Keyboard & Mouse Input, Shortcuts & Apps, and Touchpad Zones
- Every built-in preset now carries notes on every row
- The Smart Preset Maker can add touchpad-as-trackpad, gyro fine aim, and trigger rumble
- Every Feature Showcase opens its preset, with arrows to step through them
- The sidebar splits into My Presets and Built-in Presets, with colored folder outlines and Move to Group
- Help is rewritten: shorter, plainer, and current, with every guide's steps in the app
- First launch opens with a welcome and the ways to reach out
- Settings: choose the menu bar icon, a spoken feedback voice, Next and Previous Preset, and Reset Settings
- The activity log shows everything the app does, pops out into its own window, and can save a report
- The emergency stop releases held keys, silences the motors, and stops any haptic
- VoiceOver speaks the Live Visualizer in plain words, and Reduce Motion applies immediately
- The app naps when idle and reads nothing from a controller nobody is looking at
- Fixed a crash on the first launch of a fresh install or after an update
- Fixed the pointer walking off target with two displays of different heights
- Fixed lone modifier keys being invisible to apps, and modifiers left held after quick presses
- Fixed mouse buttons 3 and up hanging the app
- Fixed the Speed sliders, Confine cursor, Recenter, and Hide cursor doing nothing while a preset ran
- Fixed touchpad zones being lost or copied between presets
- Fixed a fixed-point click forgetting its point on relaunch
- Presets saved by a newer version still open in an older one, and an unreadable preset is named in the log
- Export Backup carries every setting, and the privacy policy says nothing is transmitted

## 1.4

- Tap the Mac. Your MacBook has a motion sensor, and InputConfig can now feel you knock on the case. Double tap or triple tap the palm rest or the lid to fire any output. It is the first input that needs no hardware at all: no controller, no MIDI device, nothing plugged in
- Taps are told apart by counting: two taps close together are a double, three are a triple, and a pause starts a new count. Typing is ignored on purpose, so working at the keyboard never sets it off
- New built-in preset Tap the Mac under Feature Showcases: double tap for Mission Control, triple tap to start dictation
- Emergency stop: one action that only ever stops, never starts. It halts the engine, releases every held key, button, and note, and gives the pointer back
- The emergency stop works three ways: a system-wide keyboard shortcut, holding Home / PS / Guide on the controller for two seconds, and a button in the menu bar. Any control can also be bound to it directly
- The controller hold works no matter what the preset maps that button to, so a preset that has taken over the keyboard and mouse can always be escaped from the controller itself
- Start Dictation as a System Function output: a control now presses the dictation key itself, exactly as pressing F5 does, so it works with no extra setup
- New Accessibility group under System Function: Start Dictation, Speak Selection, Zoom On / Off, Zoom In, and Zoom Out, so the accessibility shortcuts no longer have to be built by hand out of key combinations
- Per-preset shortcuts: give any preset its own system-wide key that switches to it, and press it again to stop it
- Chords: a binding can now require a second button, so Triangle + D-pad up can run a macro while D-pad up alone keeps its normal job. Set it under Press Behavior with the new While holding menu
- Gyro ratcheting: the new Pause Motion While Held app action stops motion aim while a button is held, so you can re-aim the controller without dragging the cursor, the way you lift a mouse
- The fn / Globe key is now available in two places, because macOS treats them as two different things. fn / Globe (hold) is under Modifier Keys and adds the fn modifier to another key, which is how shortcuts like Globe + E and Globe + D work. Globe Key (Emoji) is under Special Keys and presses the Globe key on its own, firing whatever you have set it to do
- Keyboard Brightness Up and Down added to the Display group
- Fixed: presets that use only the trackpad, a cursor region, or a Mac tap did nothing unless a game controller happened to be connected. They now work on their own, which is the whole point of them
- Presets can be reordered by dragging, and dragged from one folder into another. Drop a preset onto another to place it there. The order you set now sticks, instead of rearranging itself whenever a preset was edited
- Fixed a crash when dragging presets or folders in the sidebar
- The scan button now detects modifier keys pressed on their own, including Shift, Control, Option, Command and the fn / Globe key, plus the right Command key and F16 to F19. None of these could be scanned before
- The trigger deadzone bar is see-through, so the red inner-deadzone band stays visible while you pull the trigger
- InputConfig no longer opens a second copy of itself. Two copies fought over the keyboard and mouse, and only one could use the emergency stop
- The app now says so when another app has taken the emergency stop shortcut, instead of failing silently
- Editing a preset while it is running now takes effect straight away, instead of waiting for a restart
- Duplicating a binding or a slot, and converting a preset between controllers, now keep every setting. Chords, macros, deadzone and the rest used to be dropped
- Bindings switched to Axis or Hat by hand now pick a direction, so they fire the way the menu says
- Dragging with a controller works: holding a mapped click while moving the stick now sends real drag events, so window moves, text selection, sliders, and drag and drop all work
- Cursor motion from a stick no longer asks the system where the cursor is on every frame. This was the cause of high CPU with Variable Sensitivity on
- Slow scrolling from a stick is smooth instead of dead or jittery; the fractional part is carried between frames the way cursor motion already was
- A stick resting at the edge of its deadzone no longer chatters on and off every frame
- The binding editor scrolls and expands smoothly. Moving the pointer across the list no longer makes every row redraw, and row measurements no longer feed back into the layout
- Bindings can be reordered by dragging the handle on the left of each row. The row lifts and follows the pointer, the list opens a gap where it will land, and a row with its Options open folds them away while you drag it
- A controller reconnecting over Bluetooth no longer shows up twice in the list
- A Cancel button on the scan overlay, so a scan can be canceled without a keyboard
- The help guides have a search field, plus new guides for chords, ratcheting, and tapping the Mac
- New built-in preset Anki in Desktop & Productivity: the face buttons rate flashcards, the bumpers undo and replay audio, stick clicks mark and bury, and the D-pad scrolls the card. Every row is labeled with its Anki action, and Anki is in the Smart Preset Maker's app list too
- Fixed: the release notes you are reading now did not appear for people who already had the app installed, so earlier updates arrived silently

## 1.3

- Knob modes for MIDI dials: Dial mode treats the center of the knob as zero, so scrolling and mouse motion speed up the further you turn, with a deadzone to stop at center
- Turn mode fires a nudge for every few steps of rotation, clockwise or counterclockwise, built for volume, brightness, and stepped scrolling
- Both modes work with the sensitivity curves, deadzone settings, and variable speed the analog sticks already use
- System volume as a fader: a new output that makes the Mac's volume follow a knob, the pitch wheel, aftertouch, or a controller trigger 1-to-1
- Turn Step setting per binding: Fine, Normal, Coarse, or Chunky nudge sensitivity for Turn mode
- The volume fader only takes over once you actually move the control, so activating a preset never jumps the volume
- New built-in preset MIDI: Knob Deck and a new welcome-screen demo showing MIDI devices driving the Mac
- System Function outputs: volume, mute, media keys, brightness, Mission Control, Launchpad, Spotlight, lock screen, screenshot, Siri Shortcuts, and opening any app or URL
- New built-in preset MIDI: Media Deck, with pads and knobs running media keys, volume steps, and brightness
- A What's New popup after each update, so new features are never silently installed
- The YapToText shoutout now lives at the bottom of the welcome screen with a one-click App Store link
- An About button on the welcome screen opens the redesigned About page: the story behind the app, the changelog, source code, and support
- An Accessibility area in Settings: app-wide text size, bold text, reduced transparency, and reduced motion
- MIDI is now a full Live Visualizer template: a seven-octave velocity-shaded keyboard, named knob dials, pitch bend and aftertouch meters, a channel strip, and a live event log, switchable like any layout and automatic for MIDI presets
- Five new welcome-screen cards: Siri Shortcuts, Keyboard & Mouse as Input, Hold & Double-Tap, Per-App Auto-Switch, and Cursor Regions, ordered by importance
- The version number now shows in the menu bar popover

## 1.2.1

- Fixes MIDI devices not appearing as an option when creating a binding
- MIDI now works with no game controller connected, so a MIDI keyboard or pad controller can drive your Mac on its own
- Connected MIDI devices are listed by name when you pick an input, so you can confirm yours was found
- Input groups are now called Input Device rather than Joystick, since a group can hold MIDI, keyboard, and mouse bindings too
- A group no longer warns about a missing controller when nothing in it needs one
- The scan panel now tells you that you can play a note or twist a knob to map it

## 1.2

- MIDI devices can now be used as an input: bind notes, pads, knobs, the pitch wheel, the sustain pedal, and aftertouch to keys, clicks, macros, or anything else
- DualSense Edge extra buttons: the back paddles, both FN buttons, and mute are now bindable like any other input, over Bluetooth and USB
- Light bar colors now work over Bluetooth: preset colors, the RGB cycle, and brightness all reach the controller wirelessly
- A new DualSense Edge help guide covers binding the extra buttons
- More reliable controller data reading behind the scenes, with an automatic fallback when a Bluetooth session goes quiet

## 1.1.1

- Fixes a crash that prevented InputConfig from launching on macOS 14 Sonoma

## 1.1

- 431 built-in presets, over 300 of them new: games, creative and productivity apps, and accessibility workflows including VoiceOver Navigation, Numeric Keypad, Menu Bar and Dock, Emulator, and Comic Reader
- Much broader controller compatibility: DualShock 3, Logitech F-series in D mode, fight sticks, multi-mode pads, and wheels, with correct d-pad handling on far more controllers
- Keyboard shortcut outputs with modifiers (Cmd+C and friends) now fire as real combos
- Fixed stuck mouse buttons after sleep, stuck MIDI controllers and pitch bend after stopping a preset, and edits to a running preset not applying until reactivation
- Crash recovery now fully restores your active preset, including restarting the mapping engine
- Macros: Toggle plus Macro works as documented, the editor shows macro state accurately, and duplicating a binding keeps every setting
- VoiceOver: the input scan overlay announces itself and speaks what it detected, and the binding editor controls are labeled
- Live Visualizer: the zoomed controller map stays cleanly inside its panel
- Faster and lighter: large reductions in per-frame work across the input path and the interface

## 1.0

- Initial release: map any controller, keyboard, or mouse to keyboard, mouse, MIDI, and more, anywhere on macOS
- Preset system with groups, notes, per-preset light bar colors, and app auto-activation
- Scan to bind: press any control and it maps instantly
- Live Visualizer with customizable widget layout
- Turbo, macros, hold and double-tap actions, haptics, and spoken feedback per binding
- Touchpad calibration and regions, gyroscope aim, deadzone tuning, one-stick driving
- MIDI notes, CC, and pitch bend outputs through a built-in virtual MIDI port

## 1.2 (as JoystickConfig)

- Support for controllers beyond Apple's framework: the app now reads raw HID gamepads directly, with a descriptor parser and a controller profile database
- Your Mac's own keyboard and mouse can be used as input sources
- Cursor regions and stick regions: fire bindings when the pointer or a stick enters a zone you draw
- Crash recovery restores your active preset after an unexpected quit
- Menu bar icon with quick preset switching
- Freeze watchdog and cursor guard for a safer always-on experience

## 1.1 (as JoystickConfig)

- MIDI output: send notes, CC, and pitch bend to any music app through a built-in virtual port
- Steam Controller support
- Controller touchpad as a mouse, with calibration
- Deadzone calibration with a live plot
- Motion calibration for gyroscope presets
- Usage statistics, a test bench for trying bindings, and Launch at Login

## 1.0 (as JoystickConfig)

- The original release: map a game controller to keyboard and mouse anywhere on macOS
- Presets, the mapping engine, and scan to bind
- DualSense light bar control and haptic feedback
