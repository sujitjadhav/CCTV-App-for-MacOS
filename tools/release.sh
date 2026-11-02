#!/bin/zsh
# release.sh — build, bundle ffmpeg, sign, package, notarize, staple.
#
#   SIGN_ID="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE=cctv-notary  tools/release.sh            # zip (default)
#   ... tools/release.sh --dmg                               # DMG instead of zip
#
#   SIGN_ID="CCTV Local" tools/release.sh --local            # self-signed, this Mac only
#   tools/release.sh --adhoc                                 # no identity: test the pipeline
#
# Output goes to dist/ (override with DIST=...). See docs/SIGNING.md for setup.
set -euo pipefail

ROOT=${0:A:h:h}
cd "$ROOT"

MODE=release FORMAT=zip SKIP_BUILD=0
for a in "$@"; do
  case $a in
    --local)  MODE=local ;;
    --adhoc)  MODE=adhoc ;;
    --dmg)    FORMAT=dmg ;;
    --zip)    FORMAT=zip ;;
    --skip-build) SKIP_BUILD=1 ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) print -u2 "release.sh: unknown option '$a' (try --help)"; exit 2 ;;
  esac
done

step() { print -P "\n%B==> $*%b"; }
stop() { print -u2 -- "\nrelease.sh: $*"; exit 1; }

ENTITLEMENTS=${ENTITLEMENTS:-$ROOT/CCTV.entitlements}
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist 2>/dev/null || echo 0)
DIST=${DIST:-$ROOT/dist}
APP=$DIST/CCTV.app

# --------------------------------------------------------------- preflight
ids_valid=$(security find-identity -v -p codesigning 2>/dev/null || true)
ids_all=$(security find-identity -p codesigning 2>/dev/null || true)

case $MODE in
release)
  if [[ -z ${SIGN_ID:-} ]]; then
    stop "SIGN_ID is not set.

  A release that opens cleanly on other Macs must be signed with a
  'Developer ID Application' certificate from a paid Apple Developer account.
  This Mac currently has these code-signing identities:
$(print -r -- "$ids_valid" | sed 's/^/    /')

  Once the certificate is installed (docs/SIGNING.md, step 1), run e.g.:
    SIGN_ID=\"Developer ID Application: Your Name (TEAMID)\" NOTARY_PROFILE=cctv-notary tools/release.sh

  To only stop Keychain prompts on this Mac, use --local with a self-signed
  identity instead; to test the pipeline without any identity, use --adhoc."
  fi
  match=$(print -r -- "$ids_valid" | grep -F -- "$SIGN_ID" || true)
  [[ -n $match ]] ||
    stop "identity '$SIGN_ID' is not in your keychain (or is not valid). Available identities:
$(print -r -- "$ids_valid" | sed 's/^/    /')"
  print -r -- "$match" | grep -q "Developer ID Application" ||
    stop "SIGN_ID='$SIGN_ID' is not a 'Developer ID Application' identity:
    $match
  Apple only notarizes apps signed with Developer ID. (Use --local for a self-signed identity.)"
  if [[ -z ${NOTARY_PROFILE:-} ]]; then
    stop "NOTARY_PROFILE is not set.

  Notarization needs stored App Store Connect credentials. Create them once with:
    xcrun notarytool store-credentials cctv-notary \\
        --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
  then run again with NOTARY_PROFILE=cctv-notary (docs/SIGNING.md, step 2)."
  fi
  RUNTIME=1 TIMESTAMP=1
  ;;
local)
  [[ -n ${SIGN_ID:-} ]] || stop "--local needs SIGN_ID set to the name of your self-signed code-signing
  certificate (e.g. SIGN_ID=\"CCTV Local\"). See docs/SIGNING.md, 'Local signing'.
  This Mac currently has these code-signing identities:
$(print -r -- "$ids_all" | sed 's/^/    /')"
  print -r -- "$ids_all" | grep -qF -- "\"$SIGN_ID\"" ||
    stop "no code-signing identity named '$SIGN_ID' in your keychain. Identities found:
$(print -r -- "$ids_all" | sed 's/^/    /')"
  # A self-signed certificate has no Team ID: the hardened runtime's library
  # validation would then refuse the bundled dylibs, and Apple's timestamp
  # server only serves Apple-issued certificates. Neither is needed locally.
  RUNTIME=0 TIMESTAMP=0
  ;;
adhoc)
  SIGN_ID=- RUNTIME=0 TIMESTAMP=0
  ;;
esac

# --------------------------------------------------------------- build
if (( ! SKIP_BUILD )); then
  step "Building (./build.sh)"
  ./build.sh
fi
[[ -d build/CCTV.app ]] || stop "build/CCTV.app not found — did ./build.sh succeed?"

step "Staging dist/CCTV.app"
rm -rf "$APP"; mkdir -p "$DIST"
ditto build/CCTV.app "$APP"

step "Bundling ffmpeg + signing ($MODE, identity: $SIGN_ID)"
SIGN_ID=$SIGN_ID ENTITLEMENTS=$ENTITLEMENTS RUNTIME=$RUNTIME TIMESTAMP=$TIMESTAMP \
  "$ROOT/tools/bundle_ffmpeg.sh" "$APP"

codesign -dv --verbose=2 "$APP" 2>&1 | grep -E '^(Identifier|Authority|TeamIdentifier|Timestamp|CodeDirectory)' || true

if [[ $MODE == local ]]; then
  step "Done"
  print "Signed with '$SIGN_ID': $APP
Move it to /Applications (replace the old copy) and run it from there. Because the
signature now has a stable identity, Keychain 'allow' answers survive future rebuilds
as long as you keep signing with --local."
  exit 0
fi

# --------------------------------------------------------------- package
package() {   # creates $PKG from $APP
  rm -f "$PKG"
  if [[ $FORMAT == zip ]]; then
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$PKG"
  else
    local stage=$DIST/dmg-stage
    rm -rf "$stage"; mkdir -p "$stage"
    ditto "$APP" "$stage/CCTV.app"
    ln -s /Applications "$stage/Applications"
    # Unnotarized builds: explain how to get past Gatekeeper the first time.
    [[ $MODE == release ]] || cp "$ROOT/tools/HowToOpen.txt" "$stage/How to Open CCTV.txt"
    # hdiutil sometimes fails with "Resource busy" on CI machines: retry a few times.
    local try
    for try in 1 2 3 4; do
      hdiutil create -quiet -volname "CCTV $VERSION" -srcfolder "$stage" -ov -format UDZO "$PKG" && break
      (( try == 4 )) && stop "hdiutil create failed"
      print -u2 "hdiutil failed, retrying in 5 s…"; sleep 5
    done
    rm -rf "$stage"
    [[ $SIGN_ID == - ]] || codesign --force --sign "$SIGN_ID" --timestamp "$PKG"
  fi
}
PKG=$DIST/CCTV-$VERSION-macOS-$( [[ $(uname -m) == arm64 ]] && echo AppleSilicon || echo Intel ).$FORMAT
step "Packaging $PKG"
package

if [[ $MODE == adhoc ]]; then
  step "Done (ad-hoc, not notarized)"
  print "Created $PKG
Not notarized: on other Macs, users approve it once (System Settings → Privacy & Security →
Open Anyway; see "How to Open CCTV.txt" inside the DMG). A Developer ID + NOTARY_PROFILE removes that step."
  spctl -a -vv -t exec "$APP" 2>&1 || true
  exit 0
fi

# --------------------------------------------------------------- notarize
step "Submitting to Apple notary service (this usually takes 1–10 minutes)"
out=$(xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1) || true
print -r -- "$out"
if ! print -r -- "$out" | grep -q 'status: Accepted'; then
  sub=$(print -r -- "$out" | awk '/^ *id:/ {print $2; exit}')
  [[ -n $sub ]] && xcrun notarytool log "$sub" --keychain-profile "$NOTARY_PROFILE" || true
  stop "notarization failed (see the log above). Common causes: a dylib not signed with
  the hardened runtime, a missing secure timestamp, or wrong NOTARY_PROFILE credentials."
fi

step "Stapling"
if [[ $FORMAT == zip ]]; then
  # A zip can't hold a ticket: staple the app, then re-zip the stapled app.
  xcrun stapler staple "$APP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$PKG"
else
  xcrun stapler staple "$PKG"
  # also staple the staged app so dist/CCTV.app is usable on its own
  xcrun stapler staple "$APP" || true
fi

step "Gatekeeper assessment"
spctl -a -vv -t exec "$APP" 2>&1 || true
[[ $FORMAT == dmg ]] && { spctl -a -vv -t open --context context:primary-signature "$PKG" 2>&1 || true; }
xcrun stapler validate "$APP" 2>&1 || true

step "Done"
print "Release: $PKG  ($(du -h "$PKG" | cut -f1))
Expect 'source=Notarized Developer ID' above. That file opens cleanly on other Macs."
