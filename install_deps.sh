#!/usr/bin/env bash
#
# install_deps.sh — install the host packages the publish tooling needs:
#   - gh        (GitHub CLI — uploads signed APKs as Release assets)
#   - gnupg     (secrets.sh — encrypt/decrypt the secrets backup)
#   - openssl   (publish.sh bootstrap — generates the app keystore password)
#   - a JDK     (keytool — creates the per-app signing keys)
#
# The F-Droid index itself is built in CI (fdroidserver runs in the GitHub Actions
# workflow, not here), so it is intentionally NOT installed locally. APK signing
# also needs the Android SDK build-tools (aapt2/zipalign/apksigner); those come
# from your Android SDK ($ANDROID_HOME), not apt.
#
# Run with sudo privileges available (it calls sudo itself). Debian/Ubuntu only.
#
set -euo pipefail

if ! command -v apt-get >/dev/null 2>&1; then
  echo "ERROR: this script targets Debian/Ubuntu (apt-get not found)." >&2
  exit 1
fi

echo "==> Updating package lists"
sudo apt-get update

echo "==> Installing openssl, gnupg, JDK (keytool)"
sudo apt-get install -y openssl gnupg default-jdk-headless

echo "==> Installing GitHub CLI (gh)"
if apt-cache show gh >/dev/null 2>&1; then
  sudo apt-get install -y gh
else
  # gh isn't in the distro repos here — add GitHub's official apt repository.
  echo "    gh not in distro repos; adding GitHub's official apt repository"
  sudo apt-get install -y curl
  sudo install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
  sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  sudo apt-get update
  sudo apt-get install -y gh
fi

echo
echo "==> Versions"
gh --version | head -1 || echo "WARNING: gh not on PATH"
command -v keytool >/dev/null 2>&1 && echo "keytool: present" || echo "WARNING: keytool not on PATH"
gpg --version | head -1 || echo "WARNING: gpg not on PATH"

echo
echo "Heads up: APK signing needs the Android SDK build-tools (aapt2/zipalign/"
echo "apksigner). Ensure ANDROID_HOME points at your SDK (default ~/Android/Sdk)."
echo
echo "Next: authenticate the GitHub CLI (interactive, opens a browser):"
echo "    gh auth login        # GitHub.com -> HTTPS -> login with browser"
