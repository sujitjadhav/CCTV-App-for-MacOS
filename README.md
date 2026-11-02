# CCTV Viewer for macOS

A fast, native macOS app for watching XMEye-based NVR/DVR security cameras (built for a
**Securus Crimson** NVR; RTSP server "H264DVR 1.0"). Live view, playback of the NVR's own recordings,
motion alerts and a menu bar item — **without recording or storing anything on your Mac**.

> Not affiliated with Securus, Xiongmai or XMEye. Use it only with cameras and NVRs you own or are allowed to access.

## Download

Get **CCTV-x.y.z-macOS-AppleSilicon.dmg** from the [Releases](../../releases) page (macOS 14+, Apple Silicon).

1. Open the DMG and drag **CCTV** into **Applications**.
2. Open CCTV. The download isn't notarized by Apple, so the first time macOS blocks it:
   - **macOS 15+**: System Settings → Privacy & Security → scroll down → **Open Anyway** next to CCTV.
   - **macOS 14**: right-click CCTV in Applications → **Open** → **Open**.
3. In **Settings**, enter the NVR's IP address, username and password → **Test Connection** → **Save**.
   Allow **Local Network** access when macOS asks.

Intel Macs: build from source (below).

## Features

- **Live view** — 1×1, 2×2 and 1 large + 3 small layouts. The grid uses low-bandwidth substreams; the large /
  full-size camera switches to the HD main stream. Double-click for full size, Esc to go back.
- **Low latency, low CPU** — FFmpeg handles RTSP, Apple VideoToolbox decodes on the GPU, frames are shown the
  moment they arrive. Streams pause when the window is minimized, hidden, covered, or the Mac sleeps.
- **Status & recovery** — LIVE / CONNECTING / ERROR badge per camera, automatic reconnect with backoff.
- **Recordings from the NVR's hard disk** — pick a camera and day, see a 24-hour timeline, click to jump,
  play at 1× / 2× / 4× / 8×, full-size view (double-click or Esc). Video streams from the NVR and starts in a
  second or two; it's held in memory only and released when you leave the screen.
- **Alerts** — NVR motion/alarm events as macOS notifications (per-camera toggle, quiet hours); clicking one opens
  that camera live. An event log links each alert to the recording at that moment.
- **Menu bar** — camera previews and recent alerts; keeps running when the window is closed; open at login.
- **Sound** on/off per camera, snapshot to clipboard, rename cameras.
- **Settings** — NVR IP, RTSP and DVRIP ports, username, password (stored in the macOS **Keychain**), and a
  **Test Connection** button that checks RTSP (401 without a password, 200 with it) and DVRIP login.

## Build from source

### Requirements

- macOS 14 Sonoma or newer (Apple Silicon or Intel)
- Xcode Command Line Tools: `xcode-select --install`
- [Homebrew](https://brew.sh) FFmpeg: `brew install ffmpeg`
- An XMEye-based NVR/DVR reachable on your network (RTSP port 554, DVRIP port 34567)

### Build and install

```bash
git clone https://github.com/<you>/<repo>.git
cd <repo>
./build.sh                               # builds build/CCTV.app
tools/bundle_ffmpeg.sh build/CCTV.app    # optional: put FFmpeg inside the app so it runs without Homebrew
cp -R build/CCTV.app /Applications/
```

On first launch, open **Settings**, enter the NVR's IP, username and password, press **Test Connection**, then
**Save**. Allow **Local Network** access when macOS asks (or later in System Settings → Privacy & Security →
Local Network).

Optional: `tools/build_ffmpeg.sh` builds a small LGPL-only FFmpeg into `vendor/` (about 5 minutes);
`./build.sh` then uses it instead of Homebrew's, and the app no longer needs Homebrew at all.

### Making a release

Publish a release on GitHub with a tag like `v1.0.1`. The **Release DMG** workflow
([.github/workflows/release.yml](.github/workflows/release.yml)) builds FFmpeg (LGPL), the app and the DMG on
GitHub's Macs and attaches the DMG to the release. Locally, `tools/release.sh --adhoc --dmg` makes the same DMG
in `dist/`. Signed and notarized builds (no "Open Anyway" step): see [docs/SIGNING.md](docs/SIGNING.md).

## Compatibility

Live view uses the XMEye RTSP URL format:

```
rtsp://USER:PASS@IP:554/user=USER&password=PASS&channel=N&stream=S.sdp   (N = 1…4, S = 0 main / 1 sub)
```

Recordings and alerts use the XMEye **DVRIP / Sofia** protocol on port 34567 (login, file query, download,
alarm subscription), implemented in [App/DVRIP.swift](App/DVRIP.swift) following the open-source
[OpenIPC/python-dvr](https://github.com/OpenIPC/python-dvr) project. Many Xiongmai-based NVRs/DVRs sold under
other brands should work; the app currently assumes 4 channels.

## How it works

| Folder | What's inside |
| --- | --- |
| `App/` | SwiftUI app: live grid, recordings, events, settings, menu bar, Keychain, DVRIP client |
| `Engine/` | Objective-C + FFmpeg: low-latency RTSP playback, XMEye `.h264` → MP4 conversion in memory |
| `tools/` | Fake NVR for testing, protocol test harness, icon generator, FFmpeg bundling and release scripts |
| `docs/` | Code signing and notarization guide |

## Development and testing (no real NVR needed)

```bash
python3 tools/fake_nvr.py --port 34568 --password test      # fake DVRIP NVR with recordings and alarms
CCTV_FAKE_NVR=127.0.0.1:34568:test CCTV_SELFTEST=recordings build/CCTV.app/Contents/MacOS/CCTV
```

Other debug switches: `CCTV_STATS=1` (frames per camera), `CCTV_TEST_URL='udp://127.0.0.1:50{s}{ch}'`
(play local test feeds instead of RTSP), `CCTV_SELFTEST=view|layouts`, `CCTV_IGNORE_VISIBILITY=1`.
See the header of [tools/dvrip_check.swift](tools/dvrip_check.swift) for the protocol test suite.

## Privacy and security

- Nothing is recorded or saved on the Mac. The only file written is a small alert log
  (`~/Library/Application Support/CCTV/events.json`: time, camera, event type).
- The NVR password is stored only in the macOS Keychain. Passwords and stream URLs (which contain the
  password) are never logged or shown.
- XMEye's RTSP and DVRIP protocols are not encrypted. Keep the NVR on your home network and don't expose
  ports 554 / 34567 to the internet.

## License

[MIT](LICENSE) for this project's source code.

The DMGs on the Releases page are built with a minimal **LGPL** FFmpeg ([FFmpeg](https://ffmpeg.org) 9.0.2,
configured by [tools/build_ffmpeg.sh](tools/build_ffmpeg.sh), linked statically; this repository has everything
needed to rebuild and relink it). A DMG built locally against Homebrew's FFmpeg includes GPL components
(x264, x265) and would have to be distributed under the GPL — see [docs/SIGNING.md](docs/SIGNING.md).
