#!/usr/bin/env bash
#
# publish.sh — sign an APK and publish it as a per-version GitHub Release.
#
#   ./publish.sh [--icon <icon.svg|icon.png>] <app.apk>
#
# Point it straight at a freshly built APK, e.g.
#   ./publish.sh ../myapp/app/build/outputs/apk/release/app-release-unsigned.apk
#
# --icon attaches a listing icon for the app's F-Droid page. Pass an SVG (rendered
# here to a 512px PNG via rsvg-convert) or a ready PNG; it is uploaded to the
# release as "<package>.png", and the Pages workflow drops it into the repo
# metadata so fdroidserver uses it as the app icon (more reliable than extracting
# the icon from the APK, which release resource-shrinking can mangle).
#
# The APK is signed with a stable per-package key (alias = package name) and
# uploaded to a release tagged "<slug>-v<versionName>-<versionCode>". The release
# event triggers .github/workflows/pages.yml, which rebuilds the signed F-Droid
# index from these Release APKs and serves it on GitHub Pages — so binaries stay
# in Releases (no git bloat) and the F-Droid client reads the Pages index.
#
# The input APK is treated as read-only: it is signed into a temp dir, never
# modified or deleted.
#
set -euo pipefail

GH_REPO="dmitnin/fdroid"

# ---- parse args: optional --icon <path>, then exactly one APK path ----------
icon=""
icon_type=""
apk=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --icon)   [ "$#" -ge 2 ] || { echo "ERROR: --icon requires a path" >&2; exit 2; }
              icon="$2"; shift 2 ;;
    --icon=*) icon="${1#--icon=}"; shift ;;
    -*)       echo "ERROR: unknown option: $1" >&2; exit 2 ;;
    *)        [ -z "$apk" ] || { echo "ERROR: only one APK may be given" >&2; exit 2; }
              apk="$1"; shift ;;
  esac
done

if [ -z "$apk" ]; then
  echo "usage: $(basename "$0") [--icon <icon.svg|icon.png>] <app.apk>" >&2
  exit 2
fi

# Resolve paths against the caller's cwd BEFORE we cd into the repo, so
# relative paths work no matter where publish.sh is invoked from.
[ -f "$apk" ] || { echo "ERROR: APK not found: $apk" >&2; exit 1; }
apk="$(readlink -f "$apk")"
if [ -n "$icon" ]; then
  [ -f "$icon" ] || { echo "ERROR: icon not found: $icon" >&2; exit 1; }
  # Accept a PNG (used as-is) or an SVG (rendered to PNG below). Detect by the
  # PNG magic bytes; otherwise look for an <svg> root.
  if [ "$(head -c8 "$icon" | od -An -tx1 | tr -d ' \n')" = "89504e470d0a1a0a" ]; then
    icon_type=png
  elif head -c512 "$icon" | grep -qi '<svg'; then
    icon_type=svg
    command -v rsvg-convert >/dev/null 2>&1 \
      || { echo "ERROR: rsvg-convert not found (install librsvg2-bin; see ./install_deps.sh)" >&2; exit 1; }
  else
    echo "ERROR: --icon must be a PNG or SVG: $icon" >&2; exit 1
  fi
  icon="$(readlink -f "$icon")"
fi

cd "$(dirname "$(readlink -f "$0")")"

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
BT="$(ls -d "$ANDROID_HOME"/build-tools/*/ 2>/dev/null | sort -V | tail -1)"
[ -n "$BT" ] || { echo "ERROR: no build-tools under $ANDROID_HOME/build-tools" >&2; exit 1; }
AAPT2="${BT}aapt2"; ZIPALIGN="${BT}zipalign"; APKSIGNER="${BT}apksigner"

for bin in gh keytool openssl "$AAPT2" "$ZIPALIGN" "$APKSIGNER"; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' not found" >&2; exit 1; }
done

# ---- one-time bootstrap: app-signing password -------------------------------
mkdir -p secrets
if [ ! -f secrets/secrets.env ]; then
  echo "[bootstrap] generating secrets/secrets.env (back this up!)"
  ( umask 077; echo "APP_KS_PASS=$(openssl rand -hex 24)" > secrets/secrets.env )
fi
# shellcheck disable=SC1091
source ./secrets/secrets.env

# Scratch space for aligned/signed APKs — created per run, auto-removed on exit.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---- ingest, sign, publish --------------------------------------------------
info="$("$AAPT2" dump badging "$apk")"
pkg="$(sed -n "s/.*package: name='\([^']*\)'.*/\1/p" <<<"$info")"
vc="$(sed -n  "s/.*versionCode='\([^']*\)'.*/\1/p" <<<"$info")"
vn="$(sed -n  "s/.*versionName='\([^']*\)'.*/\1/p" <<<"$info")"
[ -n "$pkg" ] && [ -n "$vc" ] || { echo "ERROR: cannot read pkg/versionCode from $apk" >&2; exit 1; }
slug="${pkg##*.}"
tag="${slug}-v${vn}-${vc}"
echo "[ingest] $apk -> $pkg  vName=$vn vCode=$vc  -> release tag '$tag'"

# stable per-package signing key (alias = package name)
if ! keytool -list -keystore secrets/keystore-apps.jks -storetype PKCS12 \
      -storepass "$APP_KS_PASS" -alias "$pkg" >/dev/null 2>&1; then
  echo "[ingest]   creating new signing key for $pkg"
  keytool -genkeypair -keystore secrets/keystore-apps.jks -storetype PKCS12 -alias "$pkg" \
    -keyalg RSA -keysize 4096 -validity 10000 -dname "CN=$pkg" \
    -storepass "$APP_KS_PASS" -keypass "$APP_KS_PASS" >/dev/null 2>&1
fi

aligned="$WORK/${pkg}_${vc}-aligned.apk"
signed="$WORK/${pkg}_${vc}.apk"
"$ZIPALIGN" -f -p 4 "$apk" "$aligned"
"$APKSIGNER" sign --ks secrets/keystore-apps.jks --ks-key-alias "$pkg" \
  --ks-pass "pass:$APP_KS_PASS" --key-pass "pass:$APP_KS_PASS" \
  --v4-signing-enabled false --out "$signed" "$aligned"
rm -f "$aligned"
echo "[sign]   signed -> $signed"

if gh release view "$tag" --repo "$GH_REPO" >/dev/null 2>&1; then
  echo "[publish] updating existing release '$tag'"
  gh release upload "$tag" "$signed" --clobber --repo "$GH_REPO"
else
  echo "[publish] creating release '$tag'"
  gh release create "$tag" --repo "$GH_REPO" \
    --title "${slug} ${vn} (${vc})" \
    --notes "Auto-published ${pkg} versionCode ${vc}. Install/update via the F-Droid repo." \
    "$signed"
fi

# Optional listing icon, named so the Pages workflow can map it to the package.
if [ -n "$icon" ]; then
  iconasset="$WORK/${pkg}.png"
  if [ "$icon_type" = svg ]; then
    rsvg-convert -w 512 -h 512 "$icon" -o "$iconasset"
  else
    cp "$icon" "$iconasset"
  fi
  echo "[icon]   uploading $(basename "$iconasset") to release '$tag'"
  gh release upload "$tag" "$iconasset" --clobber --repo "$GH_REPO"
fi

# ---- report -----------------------------------------------------------------
echo
echo "================================================================"
echo "Published ${pkg} (${vn}/${vc}) to GitHub Releases."
echo "The Pages workflow will rebuild the F-Droid index automatically"
echo "(watch: gh run watch \$(gh run list --workflow=pages.yml -L1 --json databaseId -q '.[0].databaseId'))."
echo
echo "F-Droid client -> Settings -> Repositories -> + :"
echo "  https://dmitnin.github.io/fdroid/repo?fingerprint=252ca1154b9f20c4af70ba20e59dec8236b53f6a7694d85ca771592ab7d978d6"
echo "================================================================"
