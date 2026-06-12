# dmitnin app repo (F-Droid)

Personal Android app distribution. Each app version is built as an **unsigned** APK
by its own project, then signed and published here. The signed APKs live as **GitHub
Release assets** (so they never bloat git), and a GitHub Actions workflow builds a
**signed F-Droid index** from them and serves it on **GitHub Pages**. The phone runs
the ordinary **F-Droid client**, pointed at this repo's Pages index.

## How it works

Two stages, both already wired up:

1. **Publish** (`publish.sh`, run locally): reads each incoming APK's package +
   version, signs it with a **stable per-package key** (alias = package name, which
   is what lets the client offer in-app updates), and uploads it to a GitHub Release
   tagged `<slug>-v<versionName>-<versionCode>`.
2. **Index** (`.github/workflows/pages.yml`, runs in CI): on each release it
   downloads every Release APK, runs `fdroid update` to build + **sign the index**
   with the repo key, and deploys `repo/` to GitHub Pages — no APKs committed to git.

The index is signed by a *separate* key (`secrets/keystore.p12`, alias `index`),
independent of the per-app keys in `secrets/keystore-apps.jks`.

### Publishing an app (the whole contract)

```bash
cd /path/to/the/app            # e.g. ~/prj/kartonka/apps/gallery.android
./gradlew :app:assembleRelease # produces app-release-unsigned.apk
cp app/build/outputs/apk/release/app-release-unsigned.apk ~/prj/fdroid/incoming/
~/prj/fdroid/publish.sh
```

To release an **update**: bump `versionCode` (and usually `versionName`) in the app's
`build.gradle`, rebuild, and run the same three steps. `publish.sh` cuts a new release
tag, which triggers the Pages workflow to rebuild the index; the F-Droid client picks
up the new version on its next refresh.

### Installing on a device (F-Droid client)

Install F-Droid, then **Settings → Repositories → +** and add:

```
https://dmitnin.github.io/fdroid/repo?fingerprint=252ca1154b9f20c4af70ba20e59dec8236b53f6a7694d85ca771592ab7d978d6
```

Every app published here appears under that one repo. (The Pages workflow's run
summary reprints this URL after each build.)

### One-time CI setup (already done — kept here for a fresh clone)

1. **Settings → Pages → Build and deployment → Source: GitHub Actions.**
2. Set the repo-index signing secrets from your local files:

   ```bash
   gh secret set FDROID_KEYSTORE_P12_BASE64 < <(base64 -w0 secrets/keystore.p12)
   gh secret set FDROID_KEYSTORE_PASS --body "$(sed -n 's/^keystorepass: "\(.*\)"/\1/p' secrets/config.yml)"
   ```

## ⚠️ Back these up (gitignored, never committed)

The plaintext secrets live in **`secrets/`** (the whole directory is gitignored except
the encrypted backup blob):

- `secrets/secrets.env` — the app keystore password.
- `secrets/keystore-apps.jks` — **app** signing keys. Losing this breaks updates for
  **every** app (Android refuses the new APK as a signature mismatch; users must
  uninstall + reinstall).
- `secrets/keystore.p12` / `secrets/config.yml` — the **index** signing key + its
  password. Lower stakes: losing it only changes the repo fingerprint, forcing users to
  re-add the repo. Also mirrored as the `FDROID_KEYSTORE_*` CI secrets.

Backup of the whole `secrets/` directory is automated by **`secrets.sh`**:
`./secrets.sh backup` encrypts everything in `secrets/` (AES256, passphrase-protected)
into `secrets.tar.gz.gpg` at the repo root, which *is* committed — the only secret left
outside is the passphrase (store it in a password manager). `./secrets.sh restore`
decrypts it back on a fresh clone. Re-run `backup` after onboarding a **new** app;
routine version bumps don't change the keystore.

Committed: `publish.sh`, `install_deps.sh`, `secrets.sh`, `secrets.tar.gz.gpg`,
`.github/workflows/pages.yml`, `.gitignore`, `README.md`.

## Notes

- Why not point the F-Droid client straight at the GitHub Releases? The client refuses
  HTTP 302 redirects, and every `releases/download/...` URL redirects to a CDN. Serving
  a real signed index from Pages (200, no redirect) is the workaround — that's the whole
  reason the Pages stage exists.
- The Google "developer verification" requirement is enforced at install time by the OS,
  independent of the installer. `adb install` stays exempt.
