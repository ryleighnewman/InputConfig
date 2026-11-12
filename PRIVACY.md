# Privacy Policy

InputConfig transmits nothing of its own. Everything it records stays on your Mac. The one exception is speech recognition for a voice phrase in a language your Mac cannot recognize on the device; that audio goes to Apple, as it does for Dictation, and only while such a preset runs or while its Voice Phrases sheet is open. The Voice Phrases sheet says which applies to the language you chose.

Settings, presets, calibration data and usage statistics are stored locally, inside the app's own container. The usage statistics are counts the app keeps for its own Statistics panel: how long a controller was connected each day, which presets were activated and for how long, and how many times each button was pressed. They never leave your Mac, and Reset in the Statistics panel clears them.

To do its job the app reads the controls you have mapped: controller buttons and sticks, MIDI messages, and, for rows bound to them, keys and clicks from the Mac's own keyboard, mouse, and trackpad. While a running preset blocks a key's or a mouse button's own action, the app sees every key and mouse button press on the Mac so it can hold back the blocked ones, and while a preset changes how the Mac scrolls, it sees every scroll so it can reverse, smooth or scale it; everything else passes through untouched. Input is matched against your presets as it happens and is not recorded, apart from the per-control counts above, a short activity log of the actions it fired, which stays in memory and is saved only if you save it yourself, and the keys and clicks you make while you record a macro, which go only into that macro.

For automatic preset switching the app notes which app is in front, to compare it with the apps you listed. That name is not stored or sent anywhere.

Siri, Shortcuts, Spotlight and Voice Control can start, stop and pause presets through the app's actions. macOS handles what you say; the app learns only which action ran and with which preset.

A screen color or screen text row reads the screen: a three by three point square for a color, or the area you marked for text, ten and two times a second, only while a preset with such rows runs, its editor sheet is open, or a macro's Wait for screen step is waiting (Play once in the editor included), and only with the Screen Recording permission you grant. InputConfig's own windows are left out of every reading. The points and the recognized words are compared and dropped. Nothing from the screen is written to disk, kept, or sent anywhere; text recognition runs on your Mac.

A voice phrase row listens to the microphone, only while a preset with such rows runs or its Voice Phrases sheet is open, and only with the Microphone and Speech Recognition permissions you grant. Speech is recognized on your Mac when the language allows it; for other languages macOS sends the audio to Apple's servers for recognition, the same way Dictation does. The app keeps no audio and no transcript beyond the moment it is compared; nothing is written to disk.

Tips in the tip jar are in-app purchases handled entirely by Apple. The app learns only whether a purchase went through, never your payment details.

If you choose to save or share the activity log or a crash report, it contains the app's own actions (which button fired which output, with any text it types, website it opens, or Shortcut it runs counted in characters rather than written out), your preset and device names, your settings, when presets started, stopped, or switched, and the words of a voice phrase when it fires. It goes only where you send it.

The app makes no network calls of its own in normal use (the speech case above is macOS, not the app, and only for languages without on-device recognition). There are no analytics, no crash reporting services, no tracking, and no accounts. The only links that leave the app are the ones you click yourself, such as the source code on GitHub or the tip jar on the Mac App Store, which Apple handles.

The full policy is at https://inputconfig.com/privacy

Last updated: November 3, 2026
