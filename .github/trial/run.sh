#!/bin/zsh
# Where the arrow starts: left of the icons Control Center keeps spots for, and right of other apps' icons, which
# macOS hides first
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
key="NSStatusItem Preferred Position HiddenIconsArrow"
step() {
    /tmp/probe order "$1" | tee -a "$out/summary.txt"
    echo "$1: arrow kept at $(defaults read $id "$key" 2>&1)" | tee -a "$out/summary.txt"
}

# Three of the crowd stand in for the system icons, with spots out of the order they're added in, so their order shows
# whether macOS goes by the spots: 01 at 289, 03 at 239, 02 at 191. Control Center gets spots like theirs, as it keeps
# for sound and Wi-Fi, and one further left that's turned off, which shouldn't count.
defaults write trial.crowd "NSStatusItem Preferred Position Crowd01" -float 289
defaults write trial.crowd "NSStatusItem Preferred Position Crowd02" -float 191
defaults write trial.crowd "NSStatusItem Preferred Position Crowd03" -float 239
defaults write com.apple.controlcenter "NSStatusItem Preferred Position TrialSound" -float 289
defaults write com.apple.controlcenter "NSStatusItem Preferred Position TrialWiFi" -float 191
defaults write com.apple.controlcenter "NSStatusItem Preferred Position TrialOff" -float 900
defaults write com.apple.controlcenter "NSStatusItem VisibleCC TrialOff" -bool false

/tmp/probe warp 600 500
"$RUNNER_TEMP/crowd.app/Contents/MacOS/crowd" > "$out/crowd.txt" 2>&1 &
sleep 4
/tmp/probe order 01-crowd | tee -a "$out/summary.txt"

# Turned on for the first time: expected at 290, between the crowd's other icons and Crowd01
defaults write $id hiddenIcons -bool true
launch
sleep 4
step 02-new-arrow
shot 02-new-arrow
pkill -x jaredsmacutils
sleep 1

# Where 1.1.10 started it: expected to move to 290 too
defaults write $id "$key" -float 0
launch
sleep 4
step 03-from-1.1.10
pkill -x jaredsmacutils
sleep 1

# As if dragged between Crowd03 and Crowd02: expected to stay there
defaults write $id "$key" -float 200
launch
sleep 4
step 04-dragged
pkill -x jaredsmacutils
sleep 1

# Back where it starts, with an app with Chrome's menus in front: the crowd's other icons go first
defaults delete $id "$key"
launch
sleep 4
"$RUNNER_TEMP/wide.app/Contents/MacOS/wide" > /dev/null 2>&1 &
sleep 4
step 05-wide-in-front
shot 05-wide-in-front

# And the arrow still brings them back
arrow=$(/tmp/probe find HiddenIconsArrow)
echo "arrow at: ${arrow:-not found by name}" | tee -a "$out/summary.txt"
click "$arrow"
sleep 1
shot 06-arrow-clicked
click "$arrow"
sleep 1
shot 07-arrow-clicked-again
pkill -x jaredsmacutils
for domain in trial.crowd $id com.apple.controlcenter; do
    defaults read $domain 2>/dev/null | grep -i "position\|visible" | sed "s/^/$domain /" >> "$out/defaults.txt"
done
/usr/bin/log show --last 10m --info --style compact --predicate "subsystem == \"$id\"" > "$out/log.txt" 2>&1
