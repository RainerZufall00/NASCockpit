#!/bin/zsh
# Takes the raw screenshots for the iPhone Duo, one run per display, with the same demo data as capture-screenshots.sh.
# Run from the repository root: AppStore/Tools/capture-duo-screenshots.sh outer|inner [screens…]
# Then: swift AppStore/Tools/compose-screenshots.swift
#
# Uses its own simulator "NAS Cockpit Shots Duo" with the Duo runtime (iOS-27-2-iPhone19-4; the generic runtime has no Duo).
# Folding cannot be scripted: fold (outer) or unfold (inner) it by hand in Device Hub first, and hold it upright.
# Folded, the simulator unfolds by itself after about a minute – if a run aborts, fold again and pass the missing screens.

set -e
KIND=$1
SCREENS=(${@:2})
[[ $KIND == (outer|inner) ]] || { echo "Usage: $0 outer|inner [screens…]"; exit 1 }
cd "$(dirname "$0")/../.."
RAW=$PWD/AppStore/Screenshots/raw
BUILD=build/screenshots
BUNDLE=com.nascockpit.app
if [[ $KIND == outer ]]; then DISPLAY_ID=primary WIDTH=1398
else DISPLAY_ID=primary-1 WIDTH=2007; fi
mkdir -p $RAW

UDID=$(xcrun simctl list devices | grep "NAS Cockpit Shots Duo (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
[[ -z $UDID ]] && UDID=$(xcrun simctl create "NAS Cockpit Shots Duo" com.apple.CoreSimulator.SimDeviceType.iPhone-Duo \
  com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4)
xcrun simctl boot $UDID 2>/dev/null || true
xcrun simctl bootstatus $UDID >/dev/null

echo "Building …"
xcodebuild -project NASCockpit.xcodeproj -scheme NASCockpit -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath $BUILD build -quiet 2>&1 | grep -E 'error:' || true
xcrun simctl install $UDID "$(find $BUILD/Build/Products/Debug-iphonesimulator -maxdepth 1 -name 'NASCockpit.app' | head -1)"
# Only the time: the Duo simulator rejects further status bar values with a misleading message about the date.
xcrun simctl status_bar $UDID override --time 9:41

shot() { # file name, screen, light/dark, wait
  [[ -z $SCREENS || ${SCREENS[(ie)$2]} -le ${#SCREENS} ]] || return 0
  xcrun simctl ui $UDID appearance $3
  xcrun simctl terminate $UDID $BUNDLE >/dev/null 2>&1 || true
  xcrun simctl launch $UDID $BUNDLE -screenshot $2 -AppleLanguages "(en)" -AppleLocale en_US >/dev/null
  sleep $4
  local file=$RAW/duo-$KIND-$1.png
  rm -f $file
  xcrun simctl io $UDID screenshot --display=$DISPLAY_ID $file >/dev/null 2>&1
  # Wrongly folded or held sideways: the image is landscape or nearly empty – stop rather than collect blank shots.
  local width=$(sips -g pixelWidth $file | tail -1 | awk '{print $2}')
  local bytes=$(stat -f %z $file)
  if [[ $width != $WIDTH || $bytes -lt 200000 ]]; then
    echo "Stopped: duo-$KIND-$1 is $width px wide and $bytes bytes. Fold or unfold the Duo in Device Hub and hold it upright."
    exit 1
  fi
  echo $file
}

if [[ $KIND == outer ]]; then
  shot overview      overview      light 7
  shot updates       updates       light 9
  shot dashboard     dashboard     dark  7
  shot containers    containers    light 6
  shot notifications notifications light 6
else
  shot dashboard     dashboard     dark  8
  shot guests        guests        dark  7
  shot backup        backup        light 7
  shot containers    containers    light 7
  shot packages      packages      light 7
fi

xcrun simctl status_bar $UDID clear
