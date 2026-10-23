# Troubleshooting

- **“jaredsmacutils.pkg” was blocked to protect your Mac.** Expected the first time, since the installer isn't signed. See [Install](../README.md#install).
- **Nothing in the menu bar after Open Anyway.** macOS can get stuck approving the app, and then holds it before it starts, every time. Restart your Mac, or run `sudo killall syspolicyd`, then open the app again.
- **See what the app did:** `/usr/bin/log show --last 1h --predicate 'subsystem == "io.github.jfreema.yafie"'`

## Updating from Yafie

The app was called Yafie before version 1.1.4. **Check for Updates…** in Yafie takes it to the new name, keeping your settings and permissions.

- **The update didn't work, or Yafie is still there.** Quit Yafie, delete `/Applications/Yafie.app`, then [download the installer](../README.md) and install the app fresh. It keeps your settings and permissions. If that doesn't help, [uninstall](../README.md#uninstall) it completely, then install it again.
- **Doesn't open at login after the update.** Turn **Open at Login** off and on in the app's menu.

## Updating to 1.1.6

From 1.1.6, the app is signed with an Apple Developer ID and notarized, so macOS sees it as a new app once, and asks for its permissions again.

- **A feature asks for a permission it had.** Allow it again, the way you did the first time. Later updates keep it.
- **Its switch is on in System Settings, but the feature still asks.** That switch is for the copy from before 1.1.6. In **System Settings → Privacy & Security**, open **Accessibility** (or **Screen & System Audio Recording**), select **Jared's Cool Mac Utilities App**, click **−** to remove it, then choose the feature's **Allow…** item in the app's menu and turn it on again.

## Stay awake with the lid closed

- **Check whether sleep is off right now:** `pmset -g | grep SleepDisabled` (`1` means off).
- **Turn sleep back on by hand:** `sudo pmset disablesleep 0`
- **Mac won't sleep after a crash or power loss.** If macOS crashes or loses power while sleep is off, the setting stays off through the restart until the app next starts and turns it back on. Open the app, or turn sleep back on by hand (above).
- **Warning triangle after updating to 1.0.6.** **Low Power Mode** needs your password once more. Click the app's icon and choose **Finish Setup…**, or turn that option off.
- **Check whether Low Power Mode is on right now:** `pmset -g | grep powermode` (`1` means on).
- **Low Power Mode stays on after a crash or power loss.** Like sleep, it goes back to your setting the next time the app starts. Or turn it off in **System Settings → Battery**.
- **Another app with a closed-lid mode.** Don't use it at the same time as this one. Both apps change the same setting.
- **Sleeps even though you're online.** With **Online Only** on, the app counts the Mac as offline when `https://captive.apple.com` doesn't load for about a minute, for example on a network that blocks it. Turn that option off.
- **Sleeps on battery.** **Plugged In Only** is on, or the battery is at 10% or less.
- **control+option+L doesn't lock the screen.** Another app is using that shortcut. Quit it, then click the app's icon in the menu bar to take the shortcut back. Or choose **Lock Screen** in the Apple menu.
- **Two of the app's processes in Activity Monitor.** The one without an icon is the watchdog, which turns sleep back on, and puts Low Power Mode back, if the app crashes. It ends by itself when the app quits.

## Guitar tuner

- **Says Jared's Mac App can't use the microphone.** Turn on **Jared's Cool Mac Utilities App** in **System Settings → Privacy & Security → Microphone**, then click the tuner window to try again.
- **Asks for the microphone again after an update.** Expected once, when updating to 0.7.5: that's when the app got its own signing certificate, so macOS sees a new app. Allow it again. Later updates keep the permission.
- **Shows nothing when you play.** Check the input in **System Settings → Sound → Input**, and that its level moves when you play. Play closer to the microphone: an unplugged electric guitar is quiet.
- **Doesn't use your Bluetooth headset's microphone.** On purpose. Opening it switches the headset to call mode, which can make everything it plays suddenly much louder. The tuner uses the Mac's own microphone instead, or a wired one.
- **A third process in Activity Monitor while the tuner is open.** That's the tuner's listener. It listens in a process of its own, so a stuck audio device can't freeze the app, and it ends when you close the tuner.
## Drum machine

- **Feel makes no difference.** Quantize **None** bypasses it. Choose a grid, a feel other than **Straight**, and raise **Amount**. Swing needs eighths or sixteenths with hits on alternating subdivisions; Laid Back affects snare hits on beats 2 and 4.

- **Tapping the trackpad doesn't play the drums.** Click the drum machine to bring it to the front, and keep the pointer over its pads: the trackpad's taps go to the window under the pointer.
- **Hits sound late.** Bluetooth headphones and speakers add a delay that no app can take out. Turn on **Mute Taps** to play along to the metronome and the loop without hearing your taps late, or use wired headphones or the Mac's own speakers.
- **Taps light up the pads but make no sound.** **Mute Taps** is on. Turn it off to hear them.
- **The loop plays hits late over Bluetooth.** The headphones lag more than they tell macOS. While the loop plays, move **Bluetooth Offset** until its hits land on the metronome's clicks.
- **Says Couldn't play sound.** Check the output in **System Settings → Sound**, then click **Try Again**.
- **A fourth process in Activity Monitor while the drum machine is open.** That's its player, which makes the sound in a process of its own, like the tuner's listener. It ends when you close the drum machine.

## Keyboard cleaning

- **macOS asks for Accessibility instead.** The app doesn't have it yet. Click **Open System Settings**, turn on **Jared's Cool Mac Utilities App**, then choose **Clean Keyboard and Trackpad…** again.
- **Says Couldn't turn off the keyboard and trackpad.** macOS wouldn't let the app hold them back, which can happen when its Accessibility switch is on but out of date. Turn **Jared's Cool Mac Utilities App** off and back on in **System Settings → Privacy & Security → Accessibility**, then try again.
- **Stuck with the keyboard and trackpad off.** They come back on by themselves after 5 minutes. For sooner, hold down both ⌘ keys, left and right, together for 1.5 seconds. If the app quits or crashes, they come back on right away.

## Window snapping

- **The keys do nothing.** The app doesn't have the Accessibility permission. Turn on **Jared's Cool Mac Utilities App** in **System Settings → Privacy & Security → Accessibility**.
- **"Another app is using a control+option+arrow key."** Another app, such as a window manager, has the same shortcut. Quit it or change its shortcut, then turn snapping off and on.
- **A window doesn't fill its column exactly.** Some apps keep a minimum size, and Terminal rounds to whole characters. The app centers those on the column and keeps them on the display.
- **A full-screen window doesn't move.** The app leaves full-screen windows alone. Leave full screen first.

## App preview

- **Titles but no pictures.** The app can't record the screen yet. Turn on **Jared's Cool Mac Utilities App** in **System Settings → Privacy & Security → Screen & System Audio Recording**, then click **Quit & Reopen**.
- **Nothing appears over the Dock.** Check that the app is on in **Accessibility**, then turn **Show App Previews in the Dock** off and on.
- **A window is missing.** Only windows on the current desktop show, plus minimized ones. Full-screen windows, which have desktops of their own, and small panels like palettes don't.
- **The app's icon, or an old picture, instead of the window.** macOS can't picture minimized windows or a hidden app's windows, so they show the last picture taken of them, or the app's icon.
- **macOS asks whether the app can bypass the system private window picker.** As with snips, click **Allow**. macOS asks again about once a month.
- **A window comes to the front instead of closing.** Its app is asking whether to save changes, or to confirm. Answer it there.
- **A window has no ×.** Its app doesn't let it be closed from outside, like some panels and full-screen windows.

## Screenshot tool

- **The menu shows Allow Screen Snipping….** The app doesn't have the Screen & System Audio Recording permission. Choose it, turn on the app in the list that opens, then click **Quit & Reopen**.
- **Still shows Allow Screen Snipping… after you allowed it.** macOS only tells the app when it starts. Quit the app and open it again.
- **Nothing seems to happen when you turn on Snipping Tool.** macOS adds the app to its Screen & System Audio Recording list, switched off, without asking. Choose **Allow Screen Snipping…** in the app's menu to get there. See [Screenshot tool](../README.md#screenshot-tool).
- **The menu vanished on your first snip.** macOS asked whether the app can bypass the system private window picker, which closes the menu. Click **Allow**, then snip again.
- **macOS asks every month whether the app can record the screen.** Expected on macOS 15 and later, for every app that takes screenshots. Click **Allow**. If the snip you were taking comes out wrong, take it again.
- **"Another app is using control+option+P."** Another app has the same shortcut. Quit it or change its shortcut, then turn snipping off and on.
- **An app's own ⌃⌥P stopped working.** While snipping is on, ⌃⌥P belongs to the snipping tool in every app. Turn snipping off to give it back.
- **Copy Text says No text found, or gets words wrong.** It reads clear text best. Zoom in on small or blurry text, then snip it again.
