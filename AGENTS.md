# Agents

Notes for any coding agent working on Jared's Cool Mac Utilities App, which is Yafie inside.

## What the app is

A macOS menu bar app with eight features: stay awake with the lid closed, window snapping, app previews from the Dock, a screenshot tool, an arrow for hidden menu bar icons, a guitar tuner, a drum machine and keyboard cleaning. It's Swift 6 with SwiftPM, with no Xcode project and no third-party dependencies. It runs on macOS 14 or later, on Apple silicon or Intel. It's an accessory app (`LSUIElement`), with no Dock icon or menu bar except while a snip editor is open or the hidden menu bar icons are out. [README.md](README.md) is the user guide.

**Names:** users see Jared's Cool Mac Utilities App (`Yafie.fullName`), or Jared's Mac App (`Yafie.name`, `CFBundleName`) in menus, alerts and tooltips. The menu's header says Jared's Cool Mac App, as Jared asked. On disk it's `jaredsmacutils.app`, with the executable and installer named to match. It was called Yafie before 1.1.4, and still is inside: the Swift package and module, the bundle ID `io.github.jfreema.yafie`, `/etc/sudoers.d/yafie` and the log subsystem. Never rename those: users' permissions, settings and password-free setup depend on them.

## Build and test

```sh
swift build            # compile
swift test             # unit tests (Swift Testing)
./build.sh             # build/jaredsmacutils.app
./build.sh --install   # replace /Applications/jaredsmacutils.app (and Yafie.app) and restart it
```

- **Command Line Tools only:** everything must build without Xcode. SwiftUI's `@State` doesn't build with them, since the macro plugin it needs isn't included. Keep SwiftUI state in `@Observable` models, as `TunerWindow` and `SnipEditor` do.
- **`swift test` sometimes fails with "plugin for module 'TestingMacros' not found".** It's a toolchain glitch, not the tests, so run it again. A real compile error can show up on a retry, so read the output each time.
- **Linker warnings about missing search paths** come from the Command Line Tools. Ignore them.
- **`./build.sh --install` quits and replaces the copy the user is running.** Ask first.
- **A debug build won't start while the installed app is running.** The second copy hands over to the first and quits, so quit the app first. These hooks work in debug builds only: `--tuner`, `--drums`, `--snip-editor <image file>`, `--update-now` and `--show-hidden-icons` (with its switch on, after 3 seconds).
- **Logs:** `/usr/bin/log show --last 1h --predicate 'subsystem == "io.github.jfreema.yafie"'`. The categories are `lid`, `snap`, `preview`, `snip`, `icons`, `tuner`, `drums` and `clean`.

## Code

The app is one flat folder, `Sources/Yafie`, and the tests are in `Tests/YafieTests`.

| Area | Files |
|---|---|
| Menu, alerts, launch | `AppDelegate`, `Yafie` (entry point, one copy at a time, the app's names), `MenuPanel` (the menu bar icon's menu, drawn in SwiftUI), `BubbleStyle` (the bubble pop look the menu and the tool windows share) |
| Stay awake | `LidAwakeController`, `SleepSetting` (`pmset` through a sudoers rule), `LowPowerSetting` (Low Power Mode with the lid closed, through the same rule), `PowerManager` (and `LidMonitor`), `PowerSource`, `Connectivity`, `Watchdog` (a second process that turns sleep back on, and puts Low Power Mode back, if the app dies), `ScreenLock` (control+option+L locks the screen, to walk away while the Mac stays awake) |
| Window snapping | `WindowSnapper`, `SnapLayout` (pure geometry) |
| App preview | `AppPreview`, `DockWatcher` (the icon under the pointer), `AppWindows` (windows and their pictures), `PreviewPanel`, `PreviewLayout` (pure geometry) |
| Screenshot tool | `ScreenSnipper`, `SnipDrawing` (pure drawing and layout), `SnipEditor`, `TextRecognizer` (Copy Text, with Vision) |
| Hidden menu bar icons | `HiddenIcons` (the ‹ arrow, and `RevealWatch`, the pure timing of when the icons hide again) |
| Guitar tuner | `TunerAudio`, `TunerWindow`, `PitchDetector` |
| Drum machine | `DrumMachine` (window, pads and model), `DrumAudio` (the player process, from the app's side), `DrumPlayer` (the player process), `DrumSequencer` (pure timing and recording), `DrumKit` (pure sounds and mixing) |
| Keyboard cleaning | `KeyboardCleaner` (window, event tap and `CleaningSession`, the pure timing) |
| Shared | `HotKeys` (every global shortcut), `Updater`, `Shell`, `Toast` (a brief message by the pointer) |

Put logic that can be pure, like geometry, drawing and parsing, in pure types with unit tests. Tests use shell scripts as stand-ins for child processes, such as the tuner's listener and `screencapture`.

## Things that bite

- **The main thread runs lid sleep, so never block it.** Accessibility calls run on a queue with a timeout. Core Audio runs in child processes (`--tuner-listen`, `--drum-play`), because AVAudioEngine can hang for good after an audio device changes.
- **The sudoers rule allows only the `pmset` commands the app runs** (`SleepSetting.allowedCommands`). A new command needs a new rule, so everyone has to enter their password again: the app tests the rule with a real `sudo -n` write and shows **Finish Setup…** if it's old, as it did for Low Power Mode. `sudo -l` can't tell, since it says yes to anything an admin may run with a password. `SleepSettingTests` checks that every command matches the rule.
- **App Preview reads the Dock through Accessibility.** The Dock selects the icon under the pointer and posts `AXSelectedChildrenChanged` on its list, as DockDoor relies on too. Windows are matched to their pictures with the private `_AXUIElementGetWindow`, found with `dlsym`, since two windows can share a frame and title. Its panel is non-activating and must never take the focus.
- **The drum player only plays.** It never touches an input, so it can't switch a Bluetooth headset to call mode. Its clock runs on its audio thread, a sample at a time, so the metronome and loop stay in time. The app writes its commands to a pipe set never to wait and never to raise SIGPIPE, so a stuck or dead player can't block or kill the app.
- **Trackpad drumming uses `NSTouch`**, so taps reach the pads only while the drum window is key and the pointer is over them. A tap can also arrive as a click, which the pads ignore.
- **Keyboard cleaning drops every input event with an event tap**, where HID events enter the window server, so it needs Accessibility. The tap's source is on the main run loop on purpose: if the main thread hangs, macOS turns the tap off and input comes back, where a tap on its own thread could leave the Mac stuck. Secure input, like a focused password field, hides keystrokes from taps, so the cleaning window takes the keyboard, which ends other apps' secure input and catches any key that still gets past.
- **Two update feeds.** From 1.1.3, Check for Updates reads `downloads/update.json` and finds the app in the installer by bundle ID, so a version with a new name goes in beside the old copy, which is removed (`Updater.replace`). Open at Login follows by itself: macOS keys login items by bundle ID and moves one to the app's new place the first time the app asks about it, which it does at launch (`Updater.keepOpenAtLogin`). Copies before 1.1.3 read `downloads/latest.json` and only take `Yafie.app`, so it and `Yafie.pkg` stay at 1.1.3, the last Yafie, for good. Old copies pass through it. `build.sh` doesn't write them, and the Release workflow fails if they change.
- **Finder's name for the app comes from `Resources/en.lproj/InfoPlist.strings`,** and only while `CFBundleDisplayName` in `Info.plist` matches the file name, `jaredsmacutils`. Otherwise Finder, the Dock and Spotlight show `jaredsmacutils`. `AppNameTests` checks they match.
- **The menu bar icon's menu is a panel, not an NSMenu,** so it can have the bubble pop look: blue, white cards with thick ink outlines and hard shadows, rounded black type. `MenuPanelController` makes it act like a menu: a borderless, non-activating panel that hangs from the icon, takes the keyboard for Esc and ⌘Q without activating the app, and closes on a click elsewhere, a second click on the icon, or losing the keyboard. Options under a switch are chips side by side, to keep it short, and it scrolls on a screen too short for it. Switches stay open and update in place. Buttons close it first, then act (`AppDelegate.run`), as menu items did. AppDelegate fills in `MenuModel` and hears back through its `onToggle` and `onCommand`.
- **macOS has no way to show the menu bar icons it hides.** It hides the leftmost ones that don't fit, and on a MacBook with a notch it only puts them right of the notch, where an app whose menus run past it, like Chrome, takes the room. So the ‹ arrow makes Yafie a regular app, in front with a menu bar of just its name (`HiddenIcons.makeMenuBar`), since only a regular app gets the menu bar, with a Dock icon for as long. macOS 26 turned a plain `activate(ignoringOtherApps:)` down while Yafie had no window open, so `askForMenuBar` asks again 50 ms later with `NSRunningApplication.current.activate(from:)` the app in front, as Thaw does, and `RevealWatch` keeps asking for 1.5 s until `NSWorkspace.menuBarOwningApplication` is Yafie. control+option+H does the same, for when even the arrow is hidden, and then the pointer gets longer to reach the menu bar (`RevealWatch.reachingDelay`). It hides them again when another app has the menu bar, on a key press, or once the pointer leaves the menu bar with nothing open (`RevealWatch`, from the window list, which shows menus without Screen Recording). The arrow starts at the right end, where icons are hidden last, through `NSStatusItem Preferred Position HiddenIconsArrow` (0 is the right end, as Ice and Thaw seed theirs). macOS deletes that key when the item is removed, so `removeArrow` puts it back. Ice, Thaw and Bartender move other apps' icons with synthesized ⌘-drags instead, which needs Screen Recording too and breaks with most macOS releases.
- **Global shortcuts go through `HotKeys`**, which owns the app's one Carbon handler. A second handler would take other features' key presses.
- **⌘Q in the snip editor closes the editors, not the app.** While an editor is open, the app looks like a regular one, but quitting it would also stop Stay Awake and window snapping. **Quit Jared's Mac App** is in the menu, without the shortcut.
- **A menu item takes its key even when it's disabled.** So the snip editor's single-key shortcuts (R, L, A, H, T, 1 to 4, W) only exist while an editor has the keyboard and no text is being typed (`SnipMenu.setSingleKeys`). Otherwise those letters couldn't be typed in a text or a Save dialog's name.
- **Activation:** since macOS 14, `NSApp.activate()` is a request that macOS can turn down. Anything shown after a wait or from a pop-up menu must use `NSApp.activateRegardless()`. That includes alerts, the snip editor and Save dialogs. Otherwise it opens behind the app in front and the app looks stuck. Hand focus back with `NSApp.handFocus(back:)`.
- **The tuner must never open a Bluetooth microphone, or play any sound.** Opening a headset's microphone switches it to call mode, which can make everything it plays dangerously loud, and many headsets then feed the microphone back into the ears. So the listener records with AVCaptureSession, which never opens an output, and only from built-in and wired inputs (`TunerInput`). It also skips virtual inputs, which carry other apps' sound, and interface channels past 2, which can be loopback.
- **Screen Recording:** on recent macOS, `CGRequestScreenCaptureAccess()` shows no dialog. It only adds the app to the list in System Settings. The "bypass the system private window picker" alert comes with the first snip, then about once a month.

## Signing

From 1.1.6, releases are signed with Jared's Developer ID certificates, team `885XHF7XLL`, and notarized: Developer ID Application for the app, with the hardened runtime and `Resources/jaredsmacutils.entitlements`, and Developer ID Installer for the installer. macOS ties users' permissions (Accessibility, Microphone, Screen Recording) to the team. Never sign a release with another team, or ad hoc, or everyone has to grant the permissions again. The Release workflow refuses any other team, and Check for Updates refuses an update from one. A new capability under the hardened runtime, like Apple Events to other apps, needs its entitlement. See [docs/buildfromsource.md](docs/buildfromsource.md#signing).

## Versioning

Every update to the published package raises the version in `Resources/Info.plist` (`CFBundleShortVersionString`):

- **A new feature**, one that gets its own section in the README, like the drum machine was: the middle number up by one, and the last back to 0. For example, 1.0.3 → 1.1.0.
- **Anything else**, including fixes and additions to an existing feature, like a new tool in the snip editor: the last number up by one. For example, 1.1.0 → 1.1.1.
- **A major version**, like 1.0.0, only when the user asks for one.

**Raise it as part of every change**, without being asked. Count from the published version in `downloads/update.json` (`downloads/latest.json` before 1.1.3), not from `Info.plist`. Changes that go out together share one raise, and if any of them is a new feature, that raise is a new feature's.

**Don't commit or push.** The user commits and pushes with GitHub Desktop. Pushing a new version to main publishes it to everyone: the Release workflow builds, signs and publishes the installer, and Check for Updates offers it. See [docs/buildfromsource.md](docs/buildfromsource.md#release-an-update).

- **After a release,** the workflow pushes a commit of its own with the installer, the update feeds and the README's version line, so the local copy is behind until that's pulled.
- **Leave `downloads/` alone.** Don't build or commit it by hand.
- **The README's version line** (`Version 0.8.0 · …`) is rewritten by `build.sh`. Keep its format, or change the `sed` in `build.sh` to match.

## Docs

- **[README.md](README.md)** is for users, and lean. Each feature has the same parts: what it does, **Turn it on**, then **Use it**. Update it, and [docs/troubleshooting.md](docs/troubleshooting.md), with every change users will see.
- **`docs/ideas/`** holds specs for features before they're built. It's gitignored, so specs stay local.
- **Code style:** short, sparse comments, and lines of 120 columns at most. Match the code around you.
