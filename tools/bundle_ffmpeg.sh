#!/bin/zsh
# bundle_ffmpeg.sh <path-to-.app>
#
# Makes the app self-contained: copies every non-system dylib the main
# executable needs (the full recursive closure: ffmpeg + everything Homebrew's
# ffmpeg pulls in) into Contents/Frameworks, rewrites all references to
# @rpath/<name>, adds the rpaths, then re-signs every dylib and the app.
#
# Environment:
#   SIGN_ID       codesign identity. Default "-" (ad-hoc). With a real identity
#                 (e.g. "Developer ID Application: Name (TEAMID)") the hardened
#                 runtime and a secure timestamp are enabled.
#   ENTITLEMENTS  entitlements plist for the app (default: <project>/CCTV.entitlements)
#   RUNTIME       force hardened runtime on/off: 1 or 0 (default: on for real IDs)
#   TIMESTAMP     force secure timestamp on/off: 1 or 0 (default: on for real IDs;
#                 a self-signed identity can't get Apple timestamps, so use 0)
#
# Safe to run more than once on the same bundle.
set -euo pipefail

die() { print -u2 -- "bundle_ffmpeg: error: $*"; exit 1; }
log() { print -- "bundle_ffmpeg: $*"; }

[[ $# -eq 1 ]] || die "usage: $0 <path-to-.app>"
APP=${1%/}
[[ -d $APP/Contents ]] || die "'$APP' is not an app bundle"
APP=${APP:A}                                   # absolute
PROJECT=${0:A:h:h}

EXE_NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist" 2>/dev/null || true)
[[ -n $EXE_NAME ]] || EXE_NAME=CCTV
EXE=$APP/Contents/MacOS/$EXE_NAME
[[ -f $EXE ]] || die "executable not found: $EXE"
FW=$APP/Contents/Frameworks
mkdir -p "$FW"

SIGN_ID=${SIGN_ID:--}
ENTITLEMENTS=${ENTITLEMENTS:-$PROJECT/CCTV.entitlements}
[[ -f $ENTITLEMENTS ]] || die "entitlements file not found: $ENTITLEMENTS"
if [[ $SIGN_ID == - ]]; then
  : ${RUNTIME:=0} ${TIMESTAMP:=0}
else
  : ${RUNTIME:=1} ${TIMESTAMP:=1}
fi
BREW_PREFIX=${BREW_PREFIX:-/opt/homebrew}
if (( RUNTIME )) && [[ $SIGN_ID == - ]] && ! grep -q disable-library-validation "$ENTITLEMENTS"; then
  print -u2 -- "bundle_ffmpeg: warning: hardened runtime with an ad-hoc signature has no Team ID, so library\n  validation will refuse to load the bundled dylibs and the app will not start. Use RUNTIME=0."
fi

# ---------------------------------------------------------------- helpers
is_system() { [[ $1 == /usr/lib/* || $1 == /System/* ]]; }

# install_name_tool, minus the expected "will invalidate the code signature" warning.
int() {
  local out rc=0
  out=$(install_name_tool "$@" 2>&1) || rc=$?
  out=$(print -r -- "$out" | grep -v "invalidate the code signature" || true)
  [[ -n $out ]] && print -u2 -r -- "$out"
  return $rc
}

install_id() { otool -D "$1" | sed -n '2p'; }

# Non-system and system deps of a Mach-O, excluding its own install name.
deps_of() {
  local f=$1 id
  id=$(install_id "$f")
  otool -L "$f" | tail -n +2 | sed -E 's/^[[:space:]]+//; s/ \(compatibility version.*$//' \
    | grep -v '^$' | sort -u | while IFS= read -r d; do
        [[ -n $id && $d == "$id" ]] && continue
        print -r -- "$d"
      done
}

rpaths_of() {
  otool -l "$1" | awk '/cmd LC_RPATH/ { getline; getline; print $2 }'
}

# expand <path> <loader_dir>
expand() {
  local p=$1 ld=$2
  p=${p//@loader_path/$ld}
  p=${p//@executable_path/${EXE:h}}
  print -r -- "$p"
}

# resolve <dep> <file-being-examined> <its original dir> -> realpath, or empty
resolve() {
  local dep=$1 file=$2 ld=$3 c r
  local -a cands
  if [[ $dep == @rpath/* ]]; then
    local rest=${dep#@rpath/}
    for r in ${(f)"$(rpaths_of "$file")"} ${(f)"$(rpaths_of "$EXE")"}; do
      [[ -n $r ]] || continue
      if [[ $file == "$EXE" ]]; then cands+=("$(expand "$r" "${EXE:h}")/$rest")
      else cands+=("$(expand "$r" "$ld")/$rest"); fi
    done
    cands+=("$FW/$rest" "$BREW_PREFIX/lib/$rest")
  else
    cands=("$(expand "$dep" "$ld")" "$FW/${dep:t}" "$BREW_PREFIX/lib/${dep:t}")
  fi
  for c in $cands; do
    [[ -f $c ]] && { print -r -- "${c:A}"; return 0; }
  done
  return 0
}

# ---------------------------------------------------------------- closure
typeset -A NAME_OF      # source realpath -> bundled name
typeset -A SRC_OF       # bundled name -> source realpath (to detect clashes)
typeset -A DONE         # bundled file -> 1 (already processed this run)
typeset -a QUEUE QDIR   # bundled files to process, and their original dirs

QUEUE=("$EXE"); QDIR=("${EXE:h}")
while (( ${#QUEUE} )); do
  f=${QUEUE[1]}; ld=${QDIR[1]}; shift QUEUE; shift QDIR
  [[ -n ${DONE[$f]:-} ]] && continue
  DONE[$f]=1

  for dep in ${(f)"$(deps_of "$f")"}; do
    [[ -n $dep ]] || continue
    is_system "$dep" && continue
    real=$(resolve "$dep" "$f" "$ld")
    [[ -n $real ]] || die "cannot resolve '$dep' (needed by ${f#$APP/})"
    [[ $real == *.framework/* ]] && die "'$dep' is a framework; only plain dylibs are handled"

    if [[ $real == "$FW"/* ]]; then
      name=${real:t}                       # already bundled (re-run)
      target=$real; origdir=$FW
    else
      name=${NAME_OF[$real]:-}
      if [[ -z $name ]]; then
        name=$(install_id "$real"); name=${name:t}
        [[ -n $name ]] || name=${dep:t}
        if [[ -n ${SRC_OF[$name]:-} && ${SRC_OF[$name]} != "$real" ]]; then
          die "two different libraries want the name $name: ${SRC_OF[$name]} and $real"
        fi
        NAME_OF[$real]=$name; SRC_OF[$name]=$real
        rm -f "$FW/$name"
        cp "$real" "$FW/$name"
        chmod u+w,a+r "$FW/$name"
        log "bundled $name  <- ${real#$BREW_PREFIX/}"
      fi
      target=$FW/$name; origdir=${real:h}
    fi

    new="@rpath/$name"
    if [[ $dep != "$new" ]]; then int -change "$dep" "$new" "$f"; fi
    if [[ -z ${DONE[$target]:-} ]]; then QUEUE+=("$target"); QDIR+=("$origdir"); fi
  done

  # install name + rpaths
  if [[ $f == "$EXE" ]]; then want_rpath='@executable_path/../Frameworks'
  else
    want_rpath='@loader_path'
    if [[ $(install_id "$f") != "@rpath/${f:t}" ]]; then int -id "@rpath/${f:t}" "$f"; fi
  fi
  for r in ${(f)"$(rpaths_of "$f")"}; do
    [[ -n $r && $r != "$want_rpath" ]] || continue
    # keep only rpaths that stay inside the bundle / the OS
    if [[ $r != @executable_path* && $r != @loader_path* && $r != /usr/lib* && $r != /System/* ]]; then
      int -delete_rpath "$r" "$f"
    fi
  done
  if ! rpaths_of "$f" | grep -qxF -- "$want_rpath"; then int -add_rpath "$want_rpath" "$f"; fi
done

# Drop stale dylibs from earlier runs that nothing references any more.
for d in "$FW"/*.dylib(N); do
  [[ -n ${DONE[$d]:-} ]] || { log "removing unreferenced ${d:t}"; rm -f "$d"; }
done

# ---------------------------------------------------------------- sign
typeset -a opts
opts=(--force --sign "$SIGN_ID")
(( RUNTIME ))   && opts+=(--options runtime)
(( TIMESTAMP )) && opts+=(--timestamp)

log "signing with identity '$SIGN_ID' (runtime=$RUNTIME timestamp=$TIMESTAMP)"
for d in "$FW"/*.dylib(N); do
  codesign "${opts[@]}" "$d" 2>&1 | grep -v 'replacing existing signature' >&2 || true
done
codesign "${opts[@]}" --entitlements "$ENTITLEMENTS" "$APP" 2>&1 | grep -v 'replacing existing signature' >&2 || true

# ---------------------------------------------------------------- verify
bad=0
while IFS= read -r -d '' m; do
  file -b "$m" | grep -q 'Mach-O' || continue
  if otool -L "$m" | tail -n +2 | grep -q "$BREW_PREFIX"; then
    print -u2 -- "still references $BREW_PREFIX: ${m#$APP/}"; bad=1
  fi
  if rpaths_of "$m" | grep -q "$BREW_PREFIX"; then
    print -u2 -- "rpath into $BREW_PREFIX: ${m#$APP/}"; bad=1
  fi
done < <(find "$APP/Contents" -type f -print0)
(( bad )) && die "bundle still depends on $BREW_PREFIX"
codesign --verify --deep --strict "$APP" || die "codesign verification failed"

libs=("$FW"/*.dylib(N)); n=${#libs}
log "OK: $n dylibs in Contents/Frameworks ($(du -sh "$FW" | cut -f1)), signature valid"
