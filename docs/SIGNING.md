# Signing, notarizing and shipping CCTV.app

`./build.sh` makes a **development** build: it links against Homebrew's ffmpeg in
`/opt/homebrew` and is ad-hoc signed, so it only runs on a Mac that has Homebrew ffmpeg
installed. `tools/release.sh` turns that into an app you can hand to someone else.

| Command | What you get |
|---|---|
| `tools/release.sh --adhoc` | Self-contained app + zip, ad-hoc signed. Good for testing the pipeline; other Macs will block it. |
| `SIGN_ID="CCTV Local" tools/release.sh --local` | Self-contained app signed with your own self-signed certificate. For **this Mac only**: no more Keychain "allow" prompts after every rebuild. |
| `SIGN_ID=… NOTARY_PROFILE=… tools/release.sh [--dmg]` | Signed + notarized + stapled zip (or DMG) that opens cleanly on any Mac. |

Everything lands in `dist/`. The helpers it uses:

- `tools/bundle_ffmpeg.sh <app>` copies ffmpeg and every Homebrew library it needs into
  `Contents/Frameworks` (16 dylibs, about 33 MB), points all references at
  `@rpath`, and re-signs. You can run it more than once on the same app.
- `tools/make_icon.swift` regenerates `AppIcon.icns` (`swift tools/make_icon.swift`).

## 1. Get a Developer ID certificate (one time)

1. Join the Apple Developer Program (paid, individual or organisation).
2. Xcode → Settings → Accounts → add your Apple ID → *Manage Certificates…* → **+** →
   **Developer ID Application**. (Or create it at developer.apple.com → Certificates and
   install the downloaded `.cer` by double-clicking it.)
3. Check that it's there:
   ```
   security find-identity -v -p codesigning
   #  1) ABC123… "Developer ID Application: Your Name (TEAMID)"
   ```
   Use that quoted name (or the hash) as `SIGN_ID`.

## 2. Store notarization credentials (one time)

Create an app-specific password at appleid.apple.com (Sign-In and Security →
App-Specific Passwords), then:
```
xcrun notarytool store-credentials cctv-notary \
    --apple-id you@example.com --team-id TEAMID --password abcd-efgh-ijkl-mnop
```
This saves them in your login keychain under the name `cctv-notary`. (An App Store Connect
API key works too: `--key AuthKey_XXXX.p8 --key-id … --issuer …`.)

## 3. Make a release

```
export SIGN_ID="Developer ID Application: Your Name (TEAMID)"
export NOTARY_PROFILE=cctv-notary
tools/release.sh          # -> dist/CCTV-<version>.zip
tools/release.sh --dmg    # -> dist/CCTV-<version>.dmg
```
It builds, bundles ffmpeg, signs every dylib and the app with the hardened runtime and
a secure timestamp, packages the app, uploads it to Apple and waits (usually a few minutes),
staples the ticket, and prints `spctl` results. Look for
`accepted … source=Notarized Developer ID`. If notarization fails, the script prints
Apple's log. If `SIGN_ID` or `NOTARY_PROFILE` is missing, it stops before building
and tells you what to set.

## What "opens cleanly on another Mac" needs

- **Self-contained:** nothing loaded from `/opt/homebrew`. `bundle_ffmpeg.sh` checks this
  with `otool -L` on every binary in the app and fails if anything is left.
- **Developer ID signature** on the app *and* on every dylib inside it, all from the same
  team. The hardened runtime only loads libraries signed by the same Team ID, so an
  ad-hoc or self-signed app with the hardened runtime won't even start.
- **Hardened runtime + secure timestamp.** Notarization requires both.
- **Notarized and stapled.** Stapling attaches the ticket, so the first launch works
  offline too.
- **Downloaded as a zip or DMG** without changes after signing. Editing anything inside the
  `.app` afterwards breaks the signature.
- The Mac must run macOS 26 or later (`LSMinimumSystemVersion`) on Apple silicon (the
  build is arm64-only).

On first launch macOS still asks once: "CCTV is an app downloaded from the Internet…" →
Open, and later asks for Local Network access. That's normal.

## Local signing (this Mac only, optional)

Each ad-hoc build has a new signature, so the Keychain treats it as a new app and asks
"CCTV wants to use your confidential information…" again. A self-signed certificate
gives the app a stable identity:

1. Keychain Access → menu *Keychain Access* → *Certificate Assistant* → *Create a Certificate…*
2. Name: `CCTV Local`, Identity Type: **Self Signed Root**, Certificate Type: **Code Signing** → Create.
3. `security find-identity -p codesigning` should now list `"CCTV Local"`. If `codesign`
   says the certificate isn't trusted, open it in Keychain Access → Trust →
   Code Signing: **Always Trust**.
4. Build with `SIGN_ID="CCTV Local" tools/release.sh --local`, move `dist/CCTV.app` to
   /Applications, and click **Always Allow** once at the next Keychain prompt.

Keep using `--local` for builds you run every day, because `./build.sh` on its own goes
back to ad-hoc signing. Local signing skips the hardened runtime and timestamp, since a
self-signed certificate has no Team ID. The result is not suitable for distribution.

## ffmpeg licensing caveat (read before sharing the app)

Homebrew's ffmpeg is configured with `--enable-gpl --enable-version3` and links
**x264 and x265 (GPL)**, plus OpenSSL, libvpx, dav1d, SVT-AV1, opus, lame and mpg123. If you
distribute those dylibs inside the app, the combined app falls under the **GPL (v3)**.
That means shipping the complete source for the app and ffmpeg (or a written offer to
provide it), under GPL terms. Fine for a personal or open-source project. Not fine for a
closed-source app.

To avoid that, build ffmpeg yourself as **LGPL-only** (no `--enable-gpl`, no
`--enable-nonfree`, and leave out `--enable-version3` if you want LGPL 2.1) with only what
CCTV uses:

- decoders: `h264`, `hevc`, `mpeg4`, `aac`, `pcm_alaw` (plus VideoToolbox hwaccel)
- demuxers/protocols: `rtsp`, `sdp`, `rtp`, `h264`, `hevc` / `tcp`, `udp`, `rtp`, `file`
- muxer: `mp4` (`mov` family)
- encoder: `aac`
- parsers `h264`, `hevc`, `aac`; libswscale and libswresample

For example: `./configure --prefix=$HOME/ffmpeg-lgpl --enable-shared --disable-static
--disable-programs --disable-doc --disable-autodetect --enable-videotoolbox --enable-audiotoolbox
--disable-everything --enable-decoder=h264,hevc,mpeg4,aac,pcm_alaw --enable-encoder=aac
--enable-demuxer=rtsp,sdp,rtp,h264,hevc,mov --enable-muxer=mp4,mov
--enable-parser=h264,hevc,aac --enable-protocol=tcp,udp,rtp,file
--enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,aac_adtstoasc`.
Point `build.sh` at that prefix instead of `brew --prefix`. The bundle drops to a few
MB and to LGPL obligations: keep the dylibs dynamically linked (they are), include the
LGPL text and ffmpeg's copyright notice, and say where to get the ffmpeg source you
built.
This is a summary, not legal advice.
