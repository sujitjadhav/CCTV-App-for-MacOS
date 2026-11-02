#!/bin/zsh
# Optional: builds a small, LGPL-only, static FFmpeg into vendor/ffmpeg for release builds.
# ./build.sh uses vendor/ffmpeg automatically when it exists (otherwise Homebrew's FFmpeg).
#
# Contains only what CCTV needs: RTSP/RTP over TCP/UDP, H.264/H.265 (VideoToolbox),
# G.711/AAC audio, MP4 muxing + AAC encoding (recording-format converter), swscale, swresample.
# No GPL parts and no external libraries, so the app has no Homebrew dependency and stays small.
#
#   tools/build_ffmpeg.sh            # ~3–5 minutes on Apple Silicon
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=9.0.2
SHA256=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e   # official ffmpeg.org tarball
MIN=14.0
ARCH=$(uname -m)
SRC=vendor/src
PREFIX=$PWD/vendor/ffmpeg
TARBALL=$SRC/ffmpeg-$VERSION.tar.xz

mkdir -p "$SRC"
if [[ ! -f $TARBALL ]]; then
  echo "Downloading FFmpeg $VERSION from ffmpeg.org…"
  curl -fL --progress-bar -o "$TARBALL.part" "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz"
  mv "$TARBALL.part" "$TARBALL"
fi
echo "$SHA256  $TARBALL" | shasum -a 256 -c - >/dev/null || { echo "Checksum mismatch for $TARBALL" >&2; exit 1; }

rm -rf "$SRC/ffmpeg-$VERSION" "$PREFIX"
tar -xf "$TARBALL" -C "$SRC"
cd "$SRC/ffmpeg-$VERSION"

./configure \
  --prefix="$PREFIX" \
  --arch="$ARCH" --cc=clang \
  --extra-cflags="-mmacosx-version-min=$MIN" --extra-ldflags="-mmacosx-version-min=$MIN" \
  --enable-static --disable-shared --enable-pic \
  --disable-programs --disable-doc --disable-debug \
  --disable-avdevice --disable-avfilter \
  --disable-everything \
  --enable-network \
  --enable-protocol=tcp,udp,rtp,file \
  --enable-demuxer=rtsp,rtp,sdp,h264,hevc,mpegts \
  --enable-decoder=h264,hevc,aac,pcm_alaw,pcm_mulaw,mp2 \
  --enable-parser=h264,hevc,aac,mpegaudio \
  --enable-encoder=aac \
  --enable-muxer=mp4,mov \
  --enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,extract_extradata \
  --enable-videotoolbox --enable-hwaccel=h264_videotoolbox,hevc_videotoolbox \
  --enable-swscale --enable-swresample \
  --disable-iconv --disable-lzma --disable-bzlib --disable-sdl2 --disable-xlib \
  --disable-securetransport --disable-audiotoolbox --disable-appkit --disable-avfoundation --disable-coreimage \
  | grep -E "^License" || true

# Refuse to continue if anything GPL slipped in.
grep -q '#define CONFIG_GPL 0' config.h || { echo "Not an LGPL configuration!" >&2; exit 1; }

make -j"$(sysctl -n hw.ncpu)" >/dev/null
make install >/dev/null
echo "FFmpeg $VERSION (LGPL, static) installed in vendor/ffmpeg"
