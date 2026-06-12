# Dmitnin F-Droid

Personal Android app distribution as a self-hosted F-Droid repository. Each app is built
as an **unsigned** APK by its own project, then signed and published here. Signed APKs
live as **GitHub Release assets** (so they never bloat git); a GitHub Actions workflow
builds a **signed F-Droid index** from them and serves it on **GitHub Pages**. Phones use
the ordinary **F-Droid client**, pointed at the Pages index.

## How it works

Two stages:

1. **Publish** — `./publish.sh <app.apk> …`, run locally. For each APK path you pass it,
   it reads the package name + version, signs it with a **stable per-package key**
   (alias = package name — that stable identity is what lets the F-Droid client offer
   in-app updates instead of treating a new version as a different app), and uploads it
   to a GitHub Release tagged `<slug>-v<versionName>-<versionCode>`. The input APK is read
   only; signing happens in an auto-removed temp dir, so nothing accumulates locally.
2. **Index** — `.github/workflows/pages.yml`, runs in CI on every published release. It
   downloads every Release APK, runs `fdroid update` to build and **sign the index** with
   the repository's index key, and deploys the result to GitHub Pages. No APKs are ever
   committed to git.

Two independent keys are involved:

- **Index key** (`secrets/keystore.p12`, alias `index`) — signs the repository index.
  Mirrored into CI as the `FDROID_KEYSTORE_*` secrets.
- **App keys** (`secrets/keystore-apps.jks`) — one stable key per app package, signs the
  APKs themselves.

### How the APKs reach Pages without bloating git

The repo's Pages source is set to **GitHub Actions**, not "Deploy from a branch" — so Pages
serves an **uploaded artifact**, never a git branch. Following the APK bytes through one
workflow run makes it concrete:

1. **Checkout** pulls only the git contents — scripts, `metadata/`, the workflow. No APKs
   (they were never committed).
2. **Download from Releases** — `gh release download` fetches the signed APKs into a `repo/`
   directory on the CI runner's disk. Ephemeral scratch; nothing is `git add`ed.
3. **Build index** — `fdroid update` writes the signed index (`index-v2.json`, `entry.jar`,
   icons…) alongside those APKs in `repo/`.
4. **Upload + deploy** — `actions/upload-pages-artifact` tars `repo/` into a Pages artifact,
   and `actions/deploy-pages` publishes it to GitHub's Pages CDN at the repo URL.

So the APK bytes live in exactly two places, **neither of which is git history**: GitHub
**Releases** (durable upload assets) and the **Pages deployment** (the served copy). The
Pages site is disposable — rebuilt from scratch on every release event, re-downloading from
Releases each time. There's no `gh-pages` branch, no commit, no accumulating git objects.
Releases are the durable source of truth; Pages is a regenerated, redirect-free `200` cache
in front of them (the whole point of [the Releases-*and*-Pages split](#why-releases-and-pages-not-releases-alone)).

### Installing on a device

Add this repo to the F-Droid client by either:

- **On the phone** — open
  **[the repo link](https://dmitnin.github.io/fdroid/repo?fingerprint=252ca1154b9f20c4af70ba20e59dec8236b53f6a7694d85ca771592ab7d978d6)**;
  the F-Droid landing page shows a **QR code** to scan straight into the client, or
- **Manually** — **Settings → Repositories → +** and paste the URL:

  ```
  https://dmitnin.github.io/fdroid/repo?fingerprint=252ca1154b9f20c4af70ba20e59dec8236b53f6a7694d85ca771592ab7d978d6
  ```

Every app published here appears under that one repo. The Pages workflow reprints this
URL in its run summary after each build.

### Why Releases *and* Pages, not Releases alone?

The F-Droid client refuses HTTP 302 redirects, and every `releases/download/...` URL
redirects to a CDN — so the client can't read APKs straight from Releases. Serving a real
signed index from Pages (HTTP 200, no redirect) is the workaround; that's the entire
reason the Pages stage exists.

(Separately: Google's "developer verification" is enforced at install time by the OS,
independent of the installer. `adb install` stays exempt.)

## Setup (fresh checkout)

1. **Restore the secrets.** They ship encrypted in `secrets.tar.gz.gpg`:

   ```bash
   ./secrets.sh restore        # decrypts into secrets/ (asks for the passphrase)
   ```

   The passphrase lives only in your password manager — it is the one secret kept outside
   this repo.

2. **Install host tooling:**

   ```bash
   ./install_deps.sh           # gh, gnupg, openssl, a JDK (keytool)
   gh auth login
   ```

   APK signing also needs the Android SDK build-tools (`aapt2`/`zipalign`/`apksigner`);
   point `ANDROID_HOME` at your SDK.

3. **Configure CI** — only when wiring up the GitHub repo itself:

   - **Settings → Pages → Build and deployment → Source: GitHub Actions.**
   - Seed the index-signing secrets:

     ```bash
     gh secret set FDROID_KEYSTORE_P12_BASE64 < <(base64 -w0 secrets/keystore.p12)
     gh secret set FDROID_KEYSTORE_PASS --body "$(sed -n 's/^keystorepass: "\(.*\)"/\1/p' secrets/config.yml)"
     ```

   > GitHub Actions secrets are **write-only** — once set you can never read them back. The
   > encrypted `secrets.tar.gz.gpg` is therefore the only retrievable copy of the index
   > key; guard the passphrase accordingly.

### What's in `secrets/`

The whole directory is gitignored; `./secrets.sh backup` re-encrypts it into the committed
`secrets.tar.gz.gpg`.

- `secrets/keystore-apps.jks` — the **app** signing keys. Losing this is unrecoverable:
  Android rejects updates signed by a different key, forcing users to uninstall +
  reinstall every affected app.
- `secrets/secrets.env` — the password protecting `keystore-apps.jks`.
- `secrets/keystore.p12` + `secrets/config.yml` — the **index** key plus its config and
  password. Lower stakes: replacing it only changes the repo fingerprint, forcing users to
  re-add the repo.

## Publishing

The contract for any app, whichever project it comes from — build the unsigned APK, then
point `publish.sh` at it:

```bash
# in the app's own project:
./gradlew :app:assembleRelease          # produces app-release-unsigned.apk

# then, from this repo:
./publish.sh /path/to/app-release-unsigned.apk
```

`publish.sh` signs each APK path you give it (one or more), cuts the Release(s), and leaves
the source APK untouched. The new release triggers the Pages workflow to rebuild the index;
the F-Droid client picks up the change on its next refresh.

**Updating an existing app:** bump `versionCode` (and usually `versionName`) in the app's
`build.gradle`, rebuild, and run the same two steps. The app already has a key in
`keystore-apps.jks`, so that key is reused — the keystore does **not** change.

**Onboarding a new app:** same two steps. On the first publish of a package it has never
seen, `publish.sh` generates a fresh per-package key (alias = the package name) in
`keystore-apps.jks`. Optionally add `metadata/<package>.yml` to curate the listing (name,
summary, links); without it, CI auto-stubs minimal metadata from the APK on each build.

### What can go stale after publishing

- **`secrets.tar.gz.gpg`** — only when `keystore-apps.jks` changes, i.e. after
  **onboarding a new app**. Re-run `./secrets.sh backup` and commit the refreshed blob.
  Routine version bumps never touch the keystore, so they need no re-backup.
- Editing `secrets/config.yml` (e.g. the repo name) also drifts the blob; re-run `backup`
  if you want it current. `config.yml` is reconstructable, so this is optional.
