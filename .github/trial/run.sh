#!/bin/zsh
# How macOS 26 orders menu bar icons by "NSStatusItem Preferred Position": where the arrow lands for each value, next
# to the stored values of the other icons
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
positions() {
    echo "--- $1" >> "$out/defaults.txt"
    for domain in trial.crowd $id com.apple.controlcenter com.apple.Spotlight com.apple.systemuiserver; do
        defaults read $domain 2>/dev/null | grep -i "position\|visible" | sed "s/^/$domain /" >> "$out/defaults.txt"
    done
}

/tmp/probe warp 600 500
"$RUNNER_TEMP/crowd.app/Contents/MacOS/crowd" > "$out/crowd.txt" 2>&1 &
sleep 4
/tmp/probe order 01-crowd | tee -a "$out/summary.txt"
positions 01-crowd

defaults write $id hiddenIcons -bool true
launch
sleep 5
/tmp/probe order 02-arrow-seeded-0 | tee -a "$out/summary.txt"
positions 02-arrow-seeded-0
shot 02-arrow-seeded-0
pkill -x jaredsmacutils
sleep 1
positions 03-after-quitting

for p in 40 100 150 250 350 500 700; do
    defaults write $id "$key" -float $p
    launch
    sleep 3
    /tmp/probe order "pos-$p" | tee -a "$out/summary.txt"
    echo "pos-$p stored after: $(defaults read $id "$key" 2>&1)" | tee -a "$out/summary.txt"
    pkill -x jaredsmacutils
    sleep 1
done
positions 99-end
