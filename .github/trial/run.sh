#!/bin/zsh
# A crowded menu bar and an app in front with Chrome's menus, then control+option+H: the icons shown and left alone with
# the pointer away, then pressed again to hide them, then with the pointer brought to the menu bar. Last, the arrow.
set -u
out="${1:-trial}"
mkdir -p "$out"
cd .github/trial
for tool in crowd wide probe; do swiftc -swift-version 5 -O -o "/tmp/$tool" "$tool.swift" || exit 1; done
cd - > /dev/null

# Bundled, as apps are on a Mac, so macOS treats them as it would Chrome
bundle() {
    local dir="$RUNNER_TEMP/$1.app"
    mkdir -p "$dir/Contents/MacOS"
    cp "/tmp/$1" "$dir/Contents/MacOS/$1"
    cat > "$dir/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$1</string>
<key>CFBundleIdentifier</key><string>trial.$1</string>
<key>CFBundleName</key><string>$1</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
    codesign --force --sign - "$dir" > /dev/null 2>&1
}
bundle crowd
bundle wide

# The debug build in a bundle, as installed: an LSUIElement app with its real name and bundle ID
app="$RUNNER_TEMP/jaredsmacutils.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/debug/Yafie "$app/Contents/MacOS/jaredsmacutils"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/MenuIcon.tiff Resources/MenuIconOutline.tiff "$app/Contents/Resources/"
cp -R Resources/en.lproj "$app/Contents/Resources/"
codesign --force --sign - "$app"
id=io.github.jfreema.yafie
launch() { "$app/Contents/MacOS/jaredsmacutils" "$@" >> "$out/yafie.txt" 2>&1 & }

width=$(/tmp/probe list x | sed -n 's/^screen (0.0, 0.0, \([0-9.]*\),.*/\1/p' | head -1 | cut -d. -f1)
width=${width:-1920}
shot() {
    /tmp/probe sum "$1" | tee -a "$out/summary.txt"
    /tmp/probe list "$1" >> "$out/windows.txt"
    screencapture -x -R0,0,$width,40 "$out/$1.png" 2>&1 || true
}
click() { [[ -n "$1" ]] && /tmp/probe click ${=1}; }

/tmp/probe warp 600 500
"$RUNNER_TEMP/crowd.app/Contents/MacOS/crowd" > "$out/crowd.txt" 2>&1 &
sleep 4
count=$(sed -n 's/^crowd: \([0-9]*\) icons.*/\1/p' "$out/crowd.txt")
shot 01-crowd
"$RUNNER_TEMP/wide.app/Contents/MacOS/wide" > /dev/null 2>&1 &
sleep 4
shot 02-wide-in-front

defaults write $id hiddenIcons -bool true
launch
sleep 6
shot 03-arrow-added
/tmp/probe key 4 control option  # H
sleep 0.75
shot 04-shortcut-soon-after
screencapture -x "$out/04-full-screen.png" || true
sleep 3
shot 05-pointer-away-4s-later
sleep 3.5
shot 06-pointer-away-7s-later

/tmp/probe key 4 control option
sleep 1
shot 07-shortcut-again
/tmp/probe key 4 control option
sleep 1
shot 08-shortcut-a-third-time

/tmp/probe key 4 control option
sleep 0.75
/tmp/probe warp 400 15  # into the menu bar
sleep 6
shot 09-pointer-in-menu-bar-6s
/tmp/probe warp 600 500
sleep 4
shot 10-pointer-left-4s-ago

arrow=$(/tmp/probe find HiddenIconsArrow)
echo "arrow at: ${arrow:-not found by name}" | tee -a "$out/summary.txt"
click "$arrow"
sleep 1
shot 11-arrow-clicked
click "$arrow"
sleep 1
shot 12-arrow-clicked-again
pkill -x jaredsmacutils
/usr/bin/log show --last 10m --info --style compact --predicate "subsystem == \"$id\"" > "$out/log.txt" 2>&1
