# App Store metadata for 1.5

Drafted 2026-09-17 from the App Store optimisation research (full report: content/seo-reports/05-app-store.md in the site repo). Name, subtitle, keywords and description can only change with a new version, so these go in with the 1.5 submission.


Character counts verified with Python (`len()` and UTF-8 byte length are identical for all strings).

### Name (30 max) - proposed: `InputConfig: Controller Mapper` (30/30)

- Puts "controller" and "mapper" into `<title>`, `<h1>`, JSON-LD name and the App Store name index in one move. This is the only change that can reach the Google title tag.
- Brand stays first and unchanged, so the Dock/menu bar/bundle name "InputConfig" remains "similar" per 2.3.8.
- The URL slug `/app/inputconfig/` does not change.
- Fallback if Review objects to the descriptor: `InputConfig Controller Mapper` (29) or revert to `InputConfig` and lean on the subtitle.
- Risk: low. Format is ubiquitous on the Mac App Store; the phrase is generic and true. Not another app's name.

### Subtitle (30 max) - proposed: `Gamepad to Keyboard & Mouse` (27/30)

- Adds the three tokens the name does not carry: gamepad, keyboard, mouse. Combined with the name this matches "controller to keyboard", "controller as mouse", "gamepad keyboard", "controller keyboard mouse", "gamepad mapper" (via name+subtitle tokens).
- No repeated word across name and subtitle (Apple's rule). "Advanced Input Configuration" currently repeats both halves of the brand and adds nothing searchable.
- Alternative if the name stays plain `InputConfig`: `Controller to Keyboard & Mouse` (30/30).
- Verifiable, no other-app reference, no trademark: clears 2.3.7.

### Keywords (100 max) - proposed (97 chars):

```
accessibility,assistive,access,adaptive,dualsense,xbox,midi,joystick,remap,key,button,gyro,switch
```

Why each token:
- `accessibility`, `assistive`: the mission; already approved in 1.0.
- `access`: with "controller" in the name matches "access controller" (PlayStation Access controller searches) without spelling a Sony product name.
- `adaptive`: with "xbox" and "controller" matches "xbox adaptive controller" and "adaptive controller".
- `dualsense`, `xbox`: already approved; real, relevant hardware support.
- `midi`: unique differentiator; "midi mapper" currently returns nothing for InputConfig.
- `joystick`: catches "joystick mapper" queries (a real competitor name, but the token alone is generic).
- `remap`: stems to remapper/remapping; already working ("controller remap" #7).
- `key`, `button`: combine with "mapper" for "key mapper", "button mapper" (InputConfig absent today).
- `gyro`: unique feature, low competition.
- `switch`: Nintendo Switch Pro and macOS Switch Control searches.
- Dropped versus the 1.0 kit: `controller`, `gamepad` (moved into name/subtitle, so they would be duplicates), `8bitdo`, `joycon`, `steam` (brand tokens with tiny Mac search volume; can return if the Review-approved set is preferred). Alternative with `macro` instead of `switch` is 96 chars.

### IAP display names (indexed, 30 chars each, currently "Small Tip" etc.)

Optional, zero-risk gain: rename tips descriptively but honestly, e.g. "Support InputConfig: Small Tip" still says nothing searchable. Do NOT copy Gamepad Mapper's "Xbox ... Driver" pattern. Leave as is unless a genuinely descriptive, non-trademark name applies.

### Secondary category

Unused. Adding a secondary category costs nothing and is a listed relevance input. Candidates on macOS: Productivity or Games (Games would place the app in a browsable game-tools context; Productivity fits the accessibility/desktop story). Suggest Productivity.

### Description - proposed first three paragraphs (replace the current first three; keep the FEATURES list, trimmed to stay under 4,000)

The current description is 3,995 of 4,000 characters, so anything added above must be paid for below. The rewrite below is 1,036 chars against the current 673 for the same three paragraphs; trim about 370 chars from the FEATURES list (suggested cuts: merge the two MIDI knob bullets; merge "Per-preset automation" into "Per-app auto-switch"; drop "Lifetime usage statistics").

```
InputConfig is a free controller mapper for Mac. It turns any game controller into a keyboard and mouse: map every button, trigger, and stick to keys, clicks, mouse movement, scrolling, macros, MIDI notes, Siri Shortcuts, and system functions, then use the controller as a mouse and keyboard in every app.

Built for accessibility first. If a keyboard and mouse are hard to hold or press, a gamepad, the PlayStation Access Controller, the Xbox Adaptive Controller, or a MIDI pad can run your whole Mac. One-stick driving steers, accelerates, brakes, and shifts from a single stick, and every option is tuned for tremor and limited range of motion.

Works with DualSense and DualSense Edge, DualShock 4, Xbox One and Xbox Series controllers, Switch Pro, Joy-Cons, 8BitDo, Stadia, Steam Controller, and any MFi or HID gamepad, over USB or Bluetooth. Every mapping runs at the system level, in every app, with nothing extra to install. No account, no telemetry, and the full source is on GitHub.
```

Coverage check of the eight target phrases in those three paragraphs: "controller mapper" (line 1), "controller to keyboard" is expressed as "controller into a keyboard and mouse" and "controller as a mouse and keyboard" (line 1; Google matches these as phrase variants), "controller as mouse" (line 1), "accessibility" (line 2), "DualSense" (line 3), "Xbox" (lines 2 and 3), "Access Controller" (line 2), "Xbox Adaptive Controller" (line 2, conditional on a test).

Why this order: Google takes the snippet from the passage that matches the query, and the first paragraph is the one most likely to be shown regardless. The three lines each carry a different query family (mapper/keyboard/mouse; accessibility/adaptive hardware; brand compatibility), so any of the eight queries finds a self-contained sentence.

### Promotional text (170, not indexed, above the description)

Keep as a conversion line; it does not affect search. Suggest: "Free and open source. Any controller or MIDI device runs your Mac. Built for accessibility, with presets for the PlayStation Access Controller." (139 chars)

### What's New

Already strong (1.4, 6 days old). Nothing to change for search; not indexed.

---


## Also in App Store Connect

- Accessibility Nutrition Labels: declare VoiceOver, Dark Interface, Differentiate Without Color Alone, Sufficient Contrast, Reduced Motion (all implemented; the listing currently says the developer has not indicated any).
- Secondary category: Productivity.
- Promotional text (editable any time): Free and open source. Any controller or MIDI device runs your Mac. Built for accessibility, with presets for the PlayStation Access Controller.
