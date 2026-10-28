# Windows version

Plans and challenges for bringing Jared's Cool Mac Utilities App to Windows and the Microsoft Store. Nothing is built yet. The facts about Windows and the Store were checked in October 2026, with [sources](#sources) at the end. They change, so check them again before starting.

## In short

- **It would be a second app, not a port of this one.** Swift isn't the problem: it runs on Windows. What the app is built on is. Each feature sits on something only macOS has: AppKit and SwiftUI for the windows, Accessibility for snapping and app previews, IOKit and `pmset` for the lid, `screencapture` and ScreenCaptureKit for snips, Core Audio and AVFoundation for sound, `NSTouch` for the trackpad and Carbon for the shortcuts.
- **What carries over:** the features, the bubble pop look, the icon art and the pure logic, like the snapping geometry, the pitch detector and the drum machine's sequencer and synthesized kit, along with the tests that pin down how they behave.
- **Four features are worth building:** stay awake with the lid closed, the guitar tuner, the drum machine and keyboard cleaning. Windows has nothing like the last three, and only a bare setting for the first.
- **Windows already does the rest.** Taskbar thumbnails are app previews, the taskbar's **^** is the hidden icons arrow, Windows+L locks the screen, Snap does most of window snapping, and Snipping Tool snips, marks up and copies the text in a snip.
- **The stack:** C# on .NET 10 with WPF, an icon in the system tray in place of the menu bar icon, packaged as MSIX for the Microsoft Store.
- **The Store is the easy part.** A developer account for an individual has been free since September 2025, and the Store signs, hosts and updates the app. Each release waits for the Store's review, up to three business days.
- **The hard parts:** reading the touchpad for the drums, making sure the lid setting goes back if the app dies or is uninstalled, and testing, which needs a real Windows laptop.

## Feature by feature

| Feature | What Windows has | Plan | Size |
|---|---|---|---|
| [Stay awake with the lid closed](#stay-awake-with-the-lid-closed) | A lid setting in Control Panel | Build | Medium |
| [Guitar tuner](#guitar-tuner) | Nothing | Build | Medium |
| [Drum machine](#drum-machine) | Nothing | Build | Large |
| [Keyboard cleaning](#keyboard-cleaning) | Nothing | Build | Small |
| [Screenshot tool](#screenshot-tool) | Snipping Tool | Maybe the snip menu and editor, on top of Snipping Tool | Small, or large with the editor |
| [Window snapping](#window-snapping) | Snap, and PowerToys FancyZones | Maybe, to have the same keys on both | Medium |
| [App preview](#features-to-skip) | Taskbar thumbnails | Skip | |
| [Hidden menu bar icons](#features-to-skip) | The taskbar's ^ | Skip | |
| [control+option+L](#features-to-skip) | Windows+L | Skip | |

The sizes are rough, and only relative to each other. Whatever gets built, [the menu bar icon and its menu](#the-menu-bar-icon-and-its-menu) and [everything around the features](#everything-around-the-features), like Open at Login, come first.

### The menu bar icon and its menu

On the Mac it's an `NSStatusItem` whose menu is a SwiftUI panel in the bubble pop style (`MenuPanel`, `BubbleStyle`). The icon shows Stay Awake's status, and turns green to red with the tuner's loudness.

On Windows it becomes an icon in the system tray, through `Shell_NotifyIcon`, with a borderless window that opens just above it (`Shell_NotifyIconGetRect` says where the icon is) and closes when it loses the focus, as the Mac panel closes on a click elsewhere.

- **New tray icons usually start out hidden.** Windows 11 tends to put a new app's icon behind the taskbar's **^** until it's dragged onto the taskbar, or turned on in **Settings → Personalization → Taskbar → Other system tray icons**. That would be the first step of the Windows README.
- **Light and dark.** A tray icon is 16 pixels at 100% scaling and 32 at 200%. Windows doesn't tint it to match the taskbar, as macOS does with template images, so the app draws a light and a dark version and swaps them when the theme changes. The tuner's colored icons work as they do now.
- **The look.** WPF draws the cards, ink outlines and hard shadows easily, with the window clear around them like the Mac panels. SF Pro Rounded is licensed for Apple platforms only, so the app needs a rounded font with an open license bundled in, like Nunito. SF Symbols are Apple's too: Segoe Fluent Icons, built into Windows 11, or Microsoft's MIT-licensed Fluent UI icons stand in for them.
- **Fitting the screen.** A 1080p laptop screen at 150% scaling is 720 effective pixels tall, less the taskbar, so the menu needs the same scrolling fallback it has on the Mac.

### Stay awake with the lid closed

On the Mac: `pmset disablesleep` through a sudoers rule (`SleepSetting`), Low Power Mode through the same rule (`LowPowerSetting`), the lid from IOKit (`LidMonitor`), the power source and battery (`PowerSource`), the online check (`ConnectivityMonitor`), and a second process that turns sleep back on if the app dies (`Watchdog`). `LidAwakeController` ties them together.

Windows has a setting for the basic case: **When I close the lid** can be **Do nothing**, with one value for battery and one for plugged in, which already covers Plugged In Only. Someone could set it once and never need the app. What the app adds is a switch in the tray instead of a trip to Control Panel, Online Only, the low battery cutoff, Low Power Mode, the status icon, and the setting coming back as soon as the switch is off.

Windows lets any signed-in user change power settings, unless a work PC's policy locks them, so there's no password step and nothing like the sudoers rule. The app would:

- Set the lid to **Do nothing** while it should keep the laptop awake, then put back whatever was there, with the documented power settings API (`PowerWriteACValueIndex` and `PowerWriteDCValueIndex`, then `PowerSetActiveScheme`). From a command line, the same thing is:

  ```sh
  powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0
  powercfg /setactive SCHEME_CURRENT
  ```

  `/setacvalueindex` is for plugged in and `/setdcvalueindex` for battery. 0 is Do nothing, 1 Sleep, 2 Hibernate and 3 Shut down. **Plugged In Only** maps straight onto the plugged-in value.
- Keep idle sleep away with `SetThreadExecutionState`, which Windows drops by itself when the app quits. PowerToys Awake works this way and leaves the power plan alone, so with it, closing the lid still does what the plan says. That's the gap this feature fills.
- Hear about the lid, the power source and the battery from `RegisterPowerSettingNotification` (`GUID_LIDSWITCH_STATE_CHANGE`, `GUID_ACDC_POWER_SOURCE`, `GUID_BATTERY_PERCENTAGE_REMAINING`).
- Ask Windows whether it's online (`NetworkInformation`), from the same check that puts "No internet" on the taskbar, instead of loading captive.apple.com. The network adapter's type tells Wi-Fi, Ethernet and cellular from a VPN alone.

The challenges:

- **The setting stays put.** Do nothing is a saved setting: it outlasts the app quitting or crashing, and the PC restarting, until something sets it back. So the watchdog matters as much as on the Mac: a second process that waits on the app and puts the setting back when it dies, a check at every launch, and a restore when Windows signs out or shuts down.
- **Uninstalling can't clean up.** An MSIX app runs nothing when it's uninstalled, so uninstalling it while it keeps the laptop awake leaves the lid on **Do nothing**. The app should hold the setting only while it's actually keeping the laptop awake, and the README needs the fix by hand: **Control Panel → Power Options → Choose what closing the lid does**. Store policy 10.2.7 asks for a clean uninstall, so the notes for the Store's testers should say this too.
- **Consent.** Store policy 10.2.8 lets an app change Windows settings only by supported methods and with the user's consent. The documented API is supported, and turning the switch on is consent, as long as the switch says what it changes.
- **Sleeping right away.** When the Mac version gives sleep back with the lid already shut, as when it's unplugged with Plugged In Only on, it sleeps the Mac at once. Most new Windows laptops use Modern Standby, where an app putting the PC to sleep works differently. Needs a trial.
- **Low Power Mode** has no exact match. Windows' **Energy saver** has no documented switch for apps while plugged in. On battery, its threshold setting can go to 100% while the lid is shut, and back afterwards. Plugged in, the nearest supported setting is the processor's maximum state, which runs it cooler. Both need trials.
- **Heat.** The warning about bags holds on Windows too.

### Guitar tuner

On the Mac: a listener process records with `AVCaptureSession` (`TunerAudio`, `TunerListener`), `PitchDetector` finds the note with the McLeod pitch method, `PitchAnalyzer`, `PitchSmoother` and `LoudnessMeter` turn that into what the window shows, and `TunerInput` decides which inputs are safe to open.

On Windows it records from the default input with WASAPI, Windows' audio API, directly or through the built-in `AudioGraph`. The pitch math ports line for line, with its tests, and so do the window and the colored tray icon.

- **The Bluetooth trap is the same.** On Windows too, opening a Bluetooth headset's microphone switches it into a call, the hands-free profile, which is what `TunerInput` exists to avoid. So the tuner keeps the rule: built-in and wired inputs only, telling Bluetooth ones apart by their device properties.
- **Virtual inputs,** like Stereo Mix and virtual audio cables, look like ordinary ones, so skipping them takes device properties too. Needs a trial.
- **Permission:** the package declares the microphone, and Windows asks the first time, as macOS does. The switch is in **Settings → Privacy & security → Microphone**.
- **A process of its own may not be needed.** The Mac version records in a child process because Core Audio can hang after a device changes. WASAPI reports a lost device as an error to recover from (`AUDCLNT_E_DEVICE_INVALIDATED`), so a thread of its own is the place to start.

### Drum machine

On the Mac: the trackpad is the kit, read with `NSTouch` (`TrackpadPads`). The sounds are synthesized when the player starts (`DrumKit`), the timing, recording, quantize and feel are pure (`DrumSequencer`), and a player process renders a sample at a time on its audio thread (`DrumPlayer`), allowing for the delay Core Audio reports for Bluetooth.

On Windows:

- **The touchpad.** A Precision Touchpad, which most laptops of the last several years have, reports where each finger is as raw HID input (usage page 0x0D, usage 0x05), which an app reads with `RegisterRawInputDevices`. ThreeFingerDragOnWindows, an app in the Store, reads touchpads that way. As on the Mac, a tap can also come through as a click, which the pads ignore. Without a Precision Touchpad, the pads take clicks only. On a touchscreen they could take touches.
- **Sound.** `DrumKit` and `DrumSequencer` port as they are, with no sound files to ship. Playing wants WASAPI in shared mode with a small buffer, filled a sample at a time like the Mac player. Exclusive mode would cut the lag further, but would take the speakers from every other app.
- **Bluetooth.** Windows may not tell apps how late Bluetooth headphones play, so **Bluetooth Offset** could have to do all the work it now shares with Core Audio's figure. **Mute Taps** carries over as it is. Needs a trial.

It's the largest piece: raw touchpad input, and sound that keeps time.

### Keyboard cleaning

On the Mac: an event tap that holds back every input event (`InputBlocker`), on the main run loop on purpose, so macOS turns it off if the app hangs, and both ⌘ keys held for 1.5 seconds to end early (`CleaningSession`).

On Windows: low-level keyboard and mouse hooks (`SetWindowsHookEx` with `WH_KEYBOARD_LL` and `WH_MOUSE_LL`) that swallow everything, touchpads included, since they move the pointer as a mouse does. No permission is needed.

- **A hung app gives input back,** as on the Mac: Windows skips any hook that takes more than a second to answer, and quietly removes it. The flip side is that one slow answer ends cleaning without the app knowing, so the hook's thread must never wait on anything. control+alt+delete always gets through too, as the power button does on the Mac.
- **Both ⌘ keys** become **both Shift keys.** On some laptops the Copilot key took the right Ctrl key's place, and few laptops have a right Windows key.
- **Apps running as administrator:** a hook can miss keys headed for one, so the cleaning window takes the focus, as the Mac version does to end secure input.
- **Touchscreens and gestures** may reach Windows before any hook. A full-screen window that takes touches covers the screen. Touchpad gestures, like three-finger swipes, need a trial.

### Screenshot tool

On the Mac: macOS's own `screencapture` makes the selection (`ScreenSnipper`), then the app's menu offers **Copy to Clipboard**, **Copy Text** (Vision, in `TextRecognizer`), **Open in Editor** (`SnipEditor`, drawn by `SnipDrawing`) and **Save…**.

On Windows, Snipping Tool covers most of this: Windows+Shift+S or Print Screen snips, it marks up, and its **Text actions** copy the text in a snip. What it lacks is this app's editor, with its outlined boxes, arrows and highlights, and the bubble pop look.

If it's built, the Mac design maps neatly. Snipping Tool can make the selection for another app and hand the snip back (`ms-screenclip://capture/image?rectangle&redirect-uri=…`), as `screencapture` does for the Mac version, though only for a packaged app, which a Store app is. **Copy Text** uses `Windows.Media.Ocr`, which reads text on the PC, as Vision does on the Mac. The editor is a rewrite in WPF's drawing, keeping `SnipDrawing`'s geometry and tests.

- Snipping Tool answers by opening a link to the app, which starts a second copy, so the one-copy-at-a-time code passes the answer to the copy that's running.
- control+alt+P is free on Windows, but Windows+Shift+S is the shortcut Windows users know.

### Window snapping

On the Mac: Carbon shortcuts (`HotKeys`), and the Accessibility API on a queue of its own (`WindowSnapper`), with the geometry in `SnapLayout`.

Windows snaps windows already: Windows+arrow keys for halves and quarters and to move between displays, Windows+Z for layouts, with thirds on wide displays, and PowerToys FancyZones for columns of your own. So this is worth building only to have the same keys on both computers.

If it's built, `RegisterHotKey` takes the shortcuts (it fails if another app holds one, which the menu reports, as on the Mac) and `SetWindowPos` moves the window in front, with no permission to ask for. `SnapLayout` ports with its tests, with these differences:

- Windows' coordinates run down from the top left of the main display, as Accessibility's do, so `SnapLayout.flipped` goes away. But `cells` puts the top row at the larger y, which on Windows is the bottom.
- Most windows have an invisible border for resizing, so placing a window by its outer frame leaves gaps. `DwmGetWindowAttribute` with `DWMWA_EXTENDED_FRAME_BOUNDS` gives the visible frame.
- Each display's area without the taskbar comes from `GetMonitorInfo`, and the app must be per-monitor DPI aware to see true sizes across mixed displays.
- It can't move the windows of apps running as administrator.
- **Thirds on External Displays** needs to know which display is the laptop's own, which Windows' display configuration API says.
- Some older Intel graphics drivers rotate the screen on control+alt+arrow keys.

### Features to skip

- **App preview.** Resting the pointer on an app in the taskbar already shows each of its windows, with a × to close one, and clicking one brings it to the front. This feature brought that to the Mac.
- **Hidden menu bar icons.** The taskbar's **^** already shows the icons that don't fit, and there's no notch.
- **control+option+L.** Windows+L locks the screen.

### Everything around the features

| On the Mac | On Windows |
|---|---|
| **Open at Login** (`SMAppService`) | A startup task in the package. If someone turns it off in Settings, the app can't turn it back on itself, so it sends them to **Settings → Apps → Startup**, as the Mac version sends them to Login Items. |
| **Check for Updates…** (`Updater`, `downloads/update.json`) | The Store updates the app, so the menu item goes, or opens the app's Store page. |
| One copy at a time (`Yafie.main`) | A named mutex. A second copy hands its arguments to the first, which is also how Snipping Tool's answers arrive. |
| Settings in `UserDefaults` | The package's settings (`ApplicationData`), which last across updates. |
| Shortcuts through Carbon (`HotKeys`) | `RegisterHotKey`. On many keyboards outside the US, control+alt is AltGr, which types letters like ł, so a worldwide release should let people change the shortcuts. |
| Developer ID signing and notarization | The Store signs the package. |

## What carries over

Port the tests first, then the code, so both apps behave the same.

| Mac code | Its tests | On Windows |
|---|---|---|
| `SnapLayout` | `SnapLayoutTests` | y runs down, so mind `cells` |
| `PitchDetector`, `PitchAnalyzer`, `PitchSmoother`, `LoudnessMeter` | `PitchDetectorTests`, `PitchAnalyzerTests`, `PitchSmootherTests` | Accelerate becomes plain loops or `System.Numerics` |
| `TunerInput`'s rule | `TunerInputTests` | Read from Windows' device properties |
| `DrumSequencer`, `DrumKit` | `DrumTests` | As they are: the kit is synthesized, so there are no sound files |
| `CleaningSession` | `CleaningSessionTests` | Both Shift keys |
| `Annotation`, `SnipFit`, `SnipEditorLayout`, `SnipEditorModel` | `SnipDrawingTests`, `SnipEditorModelTests` | The drawing itself is redone |
| `Bubble`'s colors, outline and radius | | Exactly, so the two apps match |
| `Resources/AppIcon.png`, `Resources/MenuIcon.png` | | Made into Windows' icon and logo sizes |

About a fifth of the Mac code, for app previews, hidden icons, the lock shortcut and the updater, has nothing to port, and the sudoers setup goes too.

## The stack

**C# on .NET 10, the current long-term support release, with WPF for the windows.**

- WPF makes transparent, borderless windows easy, which the bubble pop panels need around their cards and hard shadows. WinUI 3 has no simple, supported way to do that.
- The rest is a few Win32 calls each, through P/Invoke, which Microsoft's CsWin32 generates: the tray icon, the hooks, raw input, shortcuts and power settings. Windows' newer APIs, like OCR, the Snipping Tool hand-off and startup tasks, work from WPF too.
- WPF code can be compile-checked on Linux (`EnableWindowsTargeting`), which suits working from the cloud. Builds to ship still happen on Windows.
- Like the Mac app, it needs no third-party packages. Sound is where one, like NAudio, would save the most work.

Other ways considered:

- **WinUI 3,** in the Windows App SDK (2.0 since April 2026): Microsoft's newest UI, with the Windows 11 look. But it has no tray icon without a community package, no simple transparent windows, and its XAML compiler only runs on Windows. It's only worth it for the Windows 11 look, which the bubble pop style doesn't use.
- **Swift on Windows,** with The Browser Company's swift-winrt, which Arc for Windows was built with. It keeps one language, and the pure code could be shared, but with no SwiftUI or AppKit every window is rewritten anyway, and the tools and examples are thin.
- **Cross-platform frameworks,** like Avalonia, Tauri or Electron: no. The Mac app leans on macOS too much to share its UI, and should stay native.

Target Windows 11, on x64 and ARM64. Windows 10's support ended in October 2025.

## Where the code goes

In a `windows/` folder in this repo, with its own README and workflow. The Mac Release workflow only runs for `Sources`, `Resources`, `Package.swift` and `build.sh`, so Windows pushes wouldn't release the Mac app, and a Windows workflow would watch `windows/` alone. The art, the docs and the tests the Windows code follows stay in one place.

Don't rename the repo for it. Every installed Mac copy checks for updates at this repo's path (`Updater`'s feed), and a rename would leave them all relying on GitHub's redirects.

## The Microsoft Store

- **Account:** a Partner Center account for an individual has been free since September 2025, verified with a government ID and a selfie.
- **Package:** MSIX. It declares the microphone, for the tuner, and `runFullTrust`, which every desktop app needs. That one is a restricted capability, so the submission explains it on its **Submission options** page.
- **Signing:** the Store signs the package after its review, so there's no certificate to buy, unlike Apple's Developer ID. A download outside the Store as well would need one: Azure Artifact Signing is about $9.99 a month, and open to individuals in the US and Canada.
- **Name:** it must be unique, and is reserved in Partner Center. "Mac" shouldn't be in it: it's Apple's trademark, and it reads oddly on Windows.
- **Privacy policy:** required for every desktop app (policy 10.5.1), as a link in Partner Center. A short page in this repo would do: the app collects nothing, and the tuner's sound never leaves the PC.
- **Listing:** a description, screenshots and an age rating questionnaire.
- **Review:** up to three business days per submission, updates included, then it's live in about 15 minutes. So for the Windows app, "every push to main that changes the app is released" becomes "every such push is submitted", with that wait.
- **Trying changes first:** a package flight sends a build to chosen testers through the Store, after its own review. A test build signed with a certificate trusted once on the test PC skips the wait.
- **Automation:** the Microsoft Store Developer CLI (`msstore`) submits from GitHub Actions, as the Release workflow publishes the Mac app now.
- **Policies to mind:** 10.2.8 (change Windows settings only by supported methods, with consent), 10.2.7 (a clean uninstall), 10.1.1 (a unique name) and 10.5.1 (the privacy policy). The lid setting touches the first two.

## Testing

- **No Windows in the cloud.** The cloud container has no Windows, as it has no Mac, so builds and tests would run on GitHub's Windows runners, the way the Mac compile check runs on GitHub's Macs. The container's network also refuses the .NET download today (builds.dotnet.microsoft.com). Allowing it in the environment's network settings would let WPF code be compile-checked there.
- **A real Windows laptop** is needed for the lid, keyboard cleaning and drumming, ideally with a Precision Touchpad. A Windows 11 virtual machine on the Mac, in Parallels, VMware Fusion or UTM, is fine for the menu, the tuner and snips, but it has no lid and no real touchpad.

## Order of work

1. **Decide** the Windows name, the features and a laptop to test on. Register in Partner Center and reserve the name.
2. **The shell:** the tray icon, the bubble pop menu, Open at Login, settings, the MSIX build on GitHub Actions, and a hidden Store listing to test through.
3. **Stay awake and keyboard cleaning,** the features that change how Windows behaves.
4. **The tuner, then the drum machine,** each with its tests ported first.
5. **Maybe** the snip menu and editor over Snipping Tool, then window snapping.
6. **Release** it in the Store.

## Open questions

- What's it called on Windows? Something like Jared's Cool Utilities App.
- Which features? This plan says the four above, then maybe the snip editor.
- Is there a Windows laptop to test on, with a Precision Touchpad?
- The Store only, or a download too, at about $9.99 a month for signing?
- Keep control+alt shortcuts, or pick ones that don't clash with AltGr?

## Sources

Checked in October 2026.

- Microsoft Store: [free registration for individual developers](https://blogs.windows.com/windowsdeveloper/2025/09/10/free-developer-registration-for-individual-developers-on-microsoft-store/), [Store policies](https://learn.microsoft.com/en-us/windows/apps/publish/store-policies) (version 7.20), [the certification process](https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/msix/app-certification-process), [package flights](https://learn.microsoft.com/windows/uwp/publish/package-flights), [the Store Developer CLI](https://learn.microsoft.com/en-us/windows/apps/publish/msstore-dev-cli/overview)
- Packaging and signing: [code signing options](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/code-signing-options), [capability declarations](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/app-capability-declarations)
- Lid and power: [who may change power settings](https://learn.microsoft.com/en-us/windows/win32/power/administrator-overrides), [PowerWriteACValueIndex](https://learn.microsoft.com/windows/win32/api/powersetting/nf-powersetting-powerwriteacvalueindex), [the lid close action and its powercfg values](https://www.elevenforum.com/t/change-lid-close-action-in-windows-11.3356/), [PowerToys Awake](https://learn.microsoft.com/en-us/windows/powertoys/awake), [Energy saver's threshold](https://www.elevenforum.com/t/turn-on-or-off-energy-saver-in-windows-11.20226/)
- Input: [low-level hook timeouts](https://learn.microsoft.com/en-us/windows/win32/winmsg/lowlevelkeyboardproc), [the Precision Touchpad's HID collection](https://learn.microsoft.com/en-us/windows-hardware/design/component-guidelines/touchpad-windows-precision-touchpad-collection), [ThreeFingerDragOnWindows](https://github.com/ClementGre/ThreeFingerDragOnWindows), [the Copilot key](https://support.microsoft.com/en-us/accessibility/windows/copilot/understand-updates-to-the-copilot-key-on-windows-devices)
- Snips: [launching Snipping Tool from an app](https://learn.microsoft.com/en-us/windows/apps/develop/launch/launch-snipping-tool)
- Stack: [.NET support policy](https://dotnet.microsoft.com/en-US/platform/support/policy), [Windows App SDK 2.0](https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/release-notes/windows-app-sdk-2-0), [compile-checking Windows projects on Linux](https://github.com/dotnet/docs/issues/34197), [transparent WinUI 3 windows](https://learn.microsoft.com/en-sg/answers/questions/1463839/how-to-make-winui-3-window-transparent), [Swift, meet WinRT](https://speakinginswift.substack.com/p/swift-meet-winrt)
