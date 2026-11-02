#!/bin/zsh
# Builds build/CCTV.app. Needs: Xcode command line tools + FFmpeg (`brew install ffmpeg`, or tools/build_ffmpeg.sh).
set -e
cd "$(dirname "$0")"
# FFmpeg: the small LGPL static build from tools/build_ffmpeg.sh if present, else Homebrew's.
if [[ -f vendor/ffmpeg/lib/libavformat.a ]]; then
  FF=$PWD/vendor/ffmpeg
  # Static libs need their private dependencies (system frameworks / libs) too.
  FFLIBS=(-L"$FF/lib" -lavformat -lavcodec -lswscale -lswresample -lavutil)
  # Static libs need their private dependencies too; keep only -l… and -framework … (swiftc rejects e.g. -pthread).
  priv=(${(z)$(sed -n 's/^Libs.private: *//p' "$FF"/lib/pkgconfig/lib{avformat,avcodec,swscale,swresample,avutil}.pc | tr '\n' ' ')})
  for (( i = 1; i <= ${#priv}; i++ )); do
    if [[ ${priv[i]} == -framework ]]; then FFLIBS+=(-framework ${priv[i+1]}); (( i++ ))
    elif [[ ${priv[i]} == -l* ]]; then FFLIBS+=(${priv[i]}); fi
  done
  echo "Using LGPL static FFmpeg from vendor/ffmpeg"
else
  FF=$(brew --prefix)
  FFLIBS=(-L"$FF/lib" -lavformat -lavcodec -lavutil -lswscale -lswresample)
fi
MIN=14.0   # macOS Sonoma or newer
APP=build/CCTV.app
rm -rf "$APP" build/obj
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj

# ffmpeg engine (Objective-C): every Engine/*.m
for m in Engine/*.m; do
  clang -c -fobjc-arc -O2 -mmacosx-version-min=$MIN -Wall -Wno-deprecated-declarations \
    -I"$FF/include" "$m" -o "build/obj/$(basename "${m%.m}").o"
done

# SwiftUI app
swiftc -O -swift-version 5 -parse-as-library -target $(uname -m)-apple-macos$MIN \
  -import-objc-header Engine/Bridging.h \
  App/*.swift build/obj/*.o \
  $FFLIBS \
  -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework CoreImage -framework VideoToolbox \
  -Xlinker -w -o "$APP/Contents/MacOS/CCTV"

cp Info.plist "$APP/Contents/"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/"
codesign --force -s - --entitlements CCTV.entitlements "$APP" >/dev/null 2>&1
echo "Built $APP"
