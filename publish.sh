#!/usr/bin/env bash
#
# publish.sh — sign incoming APKs and publish each as a per-version GitHub Release
# for consumption by Obtainium.
#
# App projects only need to:
#   ./gradlew :app:assembleRelease
#   cp .../app-release-unsigned.apk ~/prj/fdroid/incoming/
#   ~/prj/fdroid/publish.sh
#
# Each APK is signed with a stable per-package key (alias = package name) and
# uploaded to a release tagged "<slug>-v<versionName>-<versionCode>". Obtainium
# watches this repo's releases (filtered per app) and follows GitHub's download
# redirect, so APKs stay in Releases with no git bloat and no signed index.
#
set -euo pipefail

GH_REPO="dmitnin/fdroid"

cd "$(dirname "$(readlink -f "$0")")"

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
BT="$(ls -d "$ANDROID_HOME"/build-tools/*/ 2>/dev/null | sort -V | tail -1)"
[ -n "$BT" ] || { echo "ERROR: no build-tools under $ANDROID_HOME/build-tools" >&2; exit 1; }
AAPT2="${BT}aapt2"; ZIPALIGN="${BT}zipalign"; APKSIGNER="${BT}apksigner"

for bin in gh keytool openssl "$AAPT2" "$ZIPALIGN" "$APKSIGNER"; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' not found" >&2; exit 1; }
done

# ---- one-time bootstrap: app-signing password -------------------------------
if [ ! -f secrets.env ]; then
  echo "[bootstrap] generating secrets.env (back this up!)"
  ( umask 077; echo "APP_KS_PASS=$(openssl rand -hex 24)" > secrets.env )
fi
# shellcheck disable=SC1091
source ./secrets.env

mkdir -p incoming out tmp

# ---- ingest, sign, publish --------------------------------------------------
shopt -s nullglob
published=()
for apk in incoming/*.apk; do
  info="$("$AAPT2" dump badging "$apk")"
  pkg="$(sed -n "s/.*package: name='\([^']*\)'.*/\1/p" <<<"$info")"
  vc="$(sed -n  "s/.*versionCode='\([^']*\)'.*/\1/p" <<<"$info")"
  vn="$(sed -n  "s/.*versionName='\([^']*\)'.*/\1/p" <<<"$info")"
  [ -n "$pkg" ] && [ -n "$vc" ] || { echo "ERROR: cannot read pkg/versionCode from $apk" >&2; exit 1; }
  slug="${pkg##*.}"
  tag="${slug}-v${vn}-${vc}"
  echo "[ingest] $apk -> $pkg  vName=$vn vCode=$vc  -> release tag '$tag'"

  # stable per-package signing key (alias = package name)
  if ! keytool -list -keystore keystore-apps.jks -storetype PKCS12 \
        -storepass "$APP_KS_PASS" -alias "$pkg" >/dev/null 2>&1; then
    echo "[ingest]   creating new signing key for $pkg"
    keytool -genkeypair -keystore keystore-apps.jks -storetype PKCS12 -alias "$pkg" \
      -keyalg RSA -keysize 4096 -validity 10000 -dname "CN=$pkg" \
      -storepass "$APP_KS_PASS" -keypass "$APP_KS_PASS" >/dev/null 2>&1
  fi

  aligned="tmp/${pkg}_${vc}-aligned.apk"
  signed="out/${pkg}_${vc}.apk"
  "$ZIPALIGN" -f -p 4 "$apk" "$aligned"
  "$APKSIGNER" sign --ks keystore-apps.jks --ks-key-alias "$pkg" \
    --ks-pass "pass:$APP_KS_PASS" --key-pass "pass:$APP_KS_PASS" \
    --v4-signing-enabled false --out "$signed" "$aligned"
  rm -f "$aligned" "$apk"
  echo "[sign]   signed -> $signed"

  if gh release view "$tag" --repo "$GH_REPO" >/dev/null 2>&1; then
    echo "[publish] updating existing release '$tag'"
    gh release upload "$tag" "$signed" --clobber --repo "$GH_REPO"
  else
    echo "[publish] creating release '$tag'"
    gh release create "$tag" --repo "$GH_REPO" \
      --title "${slug} ${vn} (${vc})" \
      --notes "Auto-published ${pkg} versionCode ${vc}. Install/update via Obtainium." \
      "$signed"
  fi
  published+=("${slug}|${pkg}")
done
shopt -u nullglob

if [ ${#published[@]} -eq 0 ]; then
  echo "Nothing in incoming/ to publish."
  exit 0
fi

# ---- report Obtainium config ------------------------------------------------
echo
echo "================================================================"
echo "Published. In Obtainium, Add App (one source per app):"
while IFS='|' read -r slug pkg; do
  [ -n "$slug" ] || continue
  echo
  echo "  $pkg"
  echo "    Source URL                          : https://github.com/${GH_REPO}"
  echo "    Filter Releases by Regular Expression: ^${slug}-v"
  echo "    Filter APKs by Regular Expression    : ${pkg//./\\.}_"
done < <(printf '%s\n' "${published[@]}" | sort -u)
echo "================================================================"
