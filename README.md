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

## Alternative: the F-Droid client (via GitHub Pages)

The F-Droid *client* can't consume the Releases directly — it refuses HTTP 302
redirects, and every `github.com/.../releases/download/...` URL redirects to a
CDN. The workaround is to serve a real, signed F-Droid index from **GitHub Pages**
without bloating git: `.github/workflows/pages.yml` downloads the already-signed
APKs from Releases, runs `fdroid update` to build + sign the index, and deploys
`repo/` as a **Pages artifact** (nothing is committed — history stays clean).

This reuses everything above: `publish.sh` still owns the APKs in Releases; a
release event just triggers the workflow to rebuild the index. The index is signed
by a *separate* key (`keystore.p12`, alias `index`) — independent of the per-app
keys in `keystore-apps.jks`.

### One-time setup

1. **Settings → Pages → Build and deployment → Source: GitHub Actions.**
2. Set the two CI secrets from your local `keystore.p12` / `config.yml`:

   ```bash
   gh secret set FDROID_KEYSTORE_P12_BASE64 < <(base64 -w0 keystore.p12)
   gh secret set FDROID_KEYSTORE_PASS --body "$(sed -n 's/^keystorepass: "\(.*\)"/\1/p' config.yml)"
   ```

3. Trigger once: `gh workflow run "Build & deploy F-Droid repo to Pages"`.

### Installing on a device (F-Droid client)

Add the repo (Settings → Repositories → +). The workflow's run summary prints the
exact URL incl. fingerprint; it is:

```
https://dmitnin.github.io/fdroid/repo?fingerprint=252ca1154b9f20c4af70ba20e59dec8236b53f6a7694d85ca771592ab7d978d6
```

Losing `keystore.p12` only changes this fingerprint (users must re-add the repo) —
it does **not** break app updates the way losing `keystore-apps.jks` does.

## ⚠️ Back these up (gitignored, never committed)

- `secrets.env` — the app keystore password
- `keystore-apps.jks` — **app** signing keys. Losing this breaks updates for **every** app
  (Android would refuse the new APK as a signature mismatch; users must uninstall +
  reinstall).

Backup is automated by **`signing-backup.sh`**: `./signing-backup.sh backup` encrypts both
files (AES256, passphrase-protected) into `signing-backup.tar.gz.gpg`, which *is* committed
and rides along in this repo — the only secret left outside is the passphrase (store it in a
password manager). `./signing-backup.sh restore` decrypts them back into place on a fresh
clone. Re-run `backup` whenever the keystore changes (i.e. after onboarding a **new** app;
routine version bumps don't change it).

Committed: `publish.sh`, `install_deps.sh`, `signing-backup.sh`, `signing-backup.tar.gz.gpg`,
`.gitignore`, `README.md`.

## Notes

- The earlier F-Droid index files (`config.yml`, `keystore.p12`, `metadata/`, the `repo`
  release) are unused in the Obtainium model and can be removed.
- The Google "developer verification" requirement is enforced at install time by the OS,
  independent of the installer — Obtainium doesn't change that. `adb install` stays exempt.
