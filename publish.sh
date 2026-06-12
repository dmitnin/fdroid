#!/usr/bin/env bash
#
# publish.sh — sign one or more APKs and publish each as a per-version GitHub Release.
#
#   ./publish.sh <app.apk> [more.apk ...]
#
# Point it straight at a freshly built APK, e.g.
#   ./publish.sh ../myapp/app/build/outputs/apk/release/app-release-unsigned.apk
#
# Each APK is signed with a stable per-package key (alias = package name) and
# uploaded to a release tagged "<slug>-v<versionName>-<versionCode>". The release
# event triggers .github/workflows/pages.yml, which rebuilds the signed F-Droid
# index from these Release APKs and serves it on GitHub Pages — so binaries stay
# in Releases (no git bloat) and the F-Droid client reads the Pages index.
#
# Input APKs are treated as read-only: each is signed into a temp dir, never
# modified or deleted.
#
set -euo pipefail

GH_REPO="dmitnin/fdroid"

if [ "$#" -eq 0 ]; then
  echo "usage: $(basename "$0") <app.apk> [more.apk ...]" >&2
  exit 2
fi
# Resolve APK paths against the caller's cwd BEFORE we cd into the repo, so
# relative paths work no matter where publish.sh is invoked from.
apks=()
for a in "$@"; do
  [ -f "$a" ] || { echo "ERROR: APK not found: $a" >&2; exit 1; }
  apks+=("$(readlink -f "$a")")
done

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
published=()
for apk in "${apks[@]}"; do
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
  published+=("${slug}|${pkg}")
done

# ---- report -----------------------------------------------------------------
echo
echo "================================================================"
echo "Published ${#published[@]} APK(s) to GitHub Releases."
echo "The Pages workflow will rebuild the F-Droid index automatically"
echo "(watch: gh run watch \$(gh run list --workflow=pages.yml -L1 --json databaseId -q '.[0].databaseId'))."
echo
echo "F-Droid client -> Settings -> Repositories -> + :"
echo "  https://dmitnin.github.io/fdroid/repo?fingerprint=252ca1154b9f20c4af70ba20e59dec8236b53f6a7694d85ca771592ab7d978d6"
echo "================================================================"
