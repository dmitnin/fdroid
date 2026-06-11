# dmitnin app repo (Obtainium)

Personal Android app distribution. Each app version is published as a **signed APK
attached to a per-version GitHub Release** on this repo. Apps are installed/updated on
the phone with [Obtainium](https://github.com/ImranR98/Obtainium), which reads this repo's
releases via the GitHub API (and follows GitHub's download redirect, which the F-Droid
client does not — that's why this is Obtainium, not an F-Droid index).

## How it works

This repo owns the signing keys and publishing. App projects stay dumb — they only build
an **unsigned** release APK and drop it here.

### Publishing an app (the whole contract)

```bash
cd /path/to/the/app            # e.g. ~/prj/kartonka/apps/gallery.android
./gradlew :app:assembleRelease # produces app-release-unsigned.apk
cp app/build/outputs/apk/release/app-release-unsigned.apk ~/prj/fdroid/incoming/
~/prj/fdroid/publish.sh
```

`publish.sh` reads each APK's package + version, signs it with a **stable per-package key**
(alias = package name, auto-created on first sight — this is what lets Obtainium offer
in-app updates), and creates a GitHub Release tagged `<slug>-v<versionName>-<versionCode>`
with the signed APK attached. It then prints the exact Obtainium config.

To release an **update**: bump `versionCode` (and usually `versionName`) in the app's
`build.gradle`, rebuild, and run the same three steps — a new release tag is cut and
Obtainium detects it.

### Installing on a device (Obtainium)

Install Obtainium (from its GitHub releases / F-Droid / IzzyOnDroid), then **Add App** with:

- **Source URL:** `https://github.com/dmitnin/fdroid`
- **Filter Releases by Regular Expression:** `^<slug>-v`   (e.g. `^gallery-v`)
- **Filter APKs by Regular Expression:** `<package>_`       (e.g. `com\.dmitnin\.gallery_`)

The release filter is what keeps multiple apps in this one repo separate. `publish.sh`
prints these values per app after each run.

## ⚠️ Back these up (gitignored, never committed)

- `secrets.env` — the app keystore password
- `keystore-apps.jks` — **app** signing keys. Losing this breaks updates for **every** app
  (Android would refuse the new APK as a signature mismatch; users must uninstall +
  reinstall).

Committed: `publish.sh`, `install_deps.sh`, `.gitignore`, `README.md`.

## Notes

- The earlier F-Droid index files (`config.yml`, `keystore.p12`, `metadata/`, the `repo`
  release) are unused in the Obtainium model and can be removed.
- The Google "developer verification" requirement is enforced at install time by the OS,
  independent of the installer — Obtainium doesn't change that. `adb install` stays exempt.
