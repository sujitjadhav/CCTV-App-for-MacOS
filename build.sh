#!/bin/zsh
# Builds build/CCTV.app. Needs: Xcode command line tools + `brew install ffmpeg`.
set -e
cd "$(dirname "$0")"
BREW=$(brew --prefix)
MIN=14.0   # macOS Sonoma or newer
APP=build/CCTV.app
rm -rf "$APP" build/obj
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj

# ffmpeg engine (Objective-C): every Engine/*.m
for m in Engine/*.m; do
  clang -c -fobjc-arc -O2 -mmacosx-version-min=$MIN -Wall -Wno-deprecated-declarations \
    -I"$BREW/include" "$m" -o "build/obj/$(basename "${m%.m}").o"
done

# SwiftUI app
swiftc -O -swift-version 5 -parse-as-library -target $(uname -m)-apple-macos$MIN \
  -import-objc-header Engine/Bridging.h \
  App/*.swift build/obj/*.o \
  -L"$BREW/lib" -lavformat -lavcodec -lavutil -lswscale -lswresample \
  -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework CoreImage \
  -Xlinker -w -o "$APP/Contents/MacOS/CCTV"

cp Info.plist "$APP/Contents/"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/"
codesign --force -s - --entitlements CCTV.entitlements "$APP" >/dev/null 2>&1
echo "Built $APP"
