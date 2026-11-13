#!/bin/zsh
# Takes the raw App Store screenshots in the simulator, using the demo data (Packages/Core/Sources/DemoBackend).
# Run from the repository root: AppStore/Tools/capture-screenshots.sh [iphone|ipad] [screens…] – default: both devices, all screens.
# Then: swift AppStore/Tools/compose-screenshots.swift
#
# The app starts with `-screenshot <screen>` (Debug builds only, see ScreenshotScreen in App/Model/AppModel.swift): it opens
# the demo at that screen and hides the "Demo" title. The UI is English only, so there is one set of raw shots; the
# composer adds German and English captions.
# Uses its own simulators ("NAS Cockpit Shots iPhone/iPad"), so running simulators stay untouched.
# iPad: landscape, so all three columns of the split view are visible. Rotate the iPad simulator once (Device Hub, or
# the Claude Code simulator tool) if the shots come out in portrait; the script warns when the size is wrong.

set -e
ONLY=$1
SCREENS=(${@:2})
cd "$(dirname "$0")/../.."
RAW=$PWD/AppStore/Screenshots/raw
BUILD=build/screenshots
BUNDLE=com.nascockpit.app
mkdir -p $RAW

runtime=$(xcrun simctl list runtimes | grep -E '^iOS' | grep -v iPhone19 | tail -1 | sed -E 's/.*\) - (.*)$/\1/')

device() { # name, device type
  local id=$(xcrun simctl list devices | grep "$1 (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
  [[ -z $id ]] && id=$(xcrun simctl create "$1" "$2" "$runtime")
  xcrun simctl boot $id 2>/dev/null || true
  xcrun simctl bootstatus $id >/dev/null
  echo $id
}

echo "Building …"
xcodebuild -project NASCockpit.xcodeproj -scheme NASCockpit -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath $BUILD build -quiet 2>&1 | grep -E 'error:' || true
APP=$(find $BUILD/Build/Products/Debug-iphonesimulator -maxdepth 1 -name 'NASCockpit.app' | head -1)

DEVICES=()
[[ $ONLY != ipad ]] && IPHONE=$(device "NAS Cockpit Shots iPhone" com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro-Max) && DEVICES+=$IPHONE
[[ $ONLY != iphone ]] && IPAD=$(device "NAS Cockpit Shots iPad" "iPad Pro 13-inch (M5)") && DEVICES+=$IPAD
for id in $DEVICES; do
  xcrun simctl install $id $APP
  # English system language, so the date in the iPad status bar matches the app. Needs a reboot once.
  if [[ $(xcrun simctl spawn $id defaults read -g AppleLocale 2>/dev/null) != en_US ]]; then
    xcrun simctl spawn $id defaults write -g AppleLanguages -array en
    xcrun simctl spawn $id defaults write -g AppleLocale en_US
    xcrun simctl shutdown $id; xcrun simctl boot $id; xcrun simctl bootstatus $id >/dev/null
  fi
  # Once per device: overriding before every shot left the screenshots one launch behind.
  xcrun simctl status_bar $id override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
done
: # Rotation and headless screenshots need no visible window.
sleep 3

shot() { # device, file name, screen, light/dark, wait, expected width
  [[ -z $1 ]] && return 0
  [[ -z $SCREENS || ${SCREENS[(ie)$3]} -le ${#SCREENS} ]] || return 0
  xcrun simctl ui $1 appearance $4
  xcrun simctl terminate $1 $BUNDLE >/dev/null 2>&1 || true
  xcrun simctl launch $1 $BUNDLE -screenshot $3 -AppleLanguages "(en)" -AppleLocale en_US >/dev/null
  sleep $5
  rm -f $RAW/$2.png
  xcrun simctl io $1 screenshot $RAW/$2.png >/dev/null 2>&1
  local width=$(sips -g pixelWidth $RAW/$2.png | tail -1 | awk '{print $2}')
  [[ $width == $6 ]] || echo "  ⚠️  $2 is $width px wide, expected $6 (rotate the simulator?)"
  echo $RAW/$2.png
}

shot "$IPHONE" iphone-overview      overview      light 6 1320
shot "$IPHONE" iphone-updates       updates       light 9 1320
shot "$IPHONE" iphone-server        server        light 6 1320
shot "$IPHONE" iphone-dashboard     dashboard     dark  7 1320
shot "$IPHONE" iphone-containers    containers    light 6 1320
shot "$IPHONE" iphone-guests        guests        dark  6 1320
shot "$IPHONE" iphone-backup        backup        light 6 1320
shot "$IPHONE" iphone-notifications notifications light 6 1320
shot "$IPHONE" iphone-welcome       welcome       light 5 1320

# iPad: only screens with something in all three columns. Overview, updates and notifications leave the detail empty.
shot "$IPAD"   ipad-dashboard       dashboard     dark  8 2752
shot "$IPAD"   ipad-containers      containers    light 7 2752
shot "$IPAD"   ipad-guests          guests        dark  7 2752
shot "$IPAD"   ipad-backup          backup        light 7 2752
shot "$IPAD"   ipad-packages        packages      light 7 2752

for id in $DEVICES; do xcrun simctl status_bar $id clear; done
