#!/usr/bin/env bash
#
# install_deps.sh — install the system packages the F-Droid repo tooling needs:
#   - fdroidserver  (builds/signs the repo index)
#   - gh            (GitHub CLI, uploads release assets)
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

echo "==> Installing fdroidserver"
sudo apt-get install -y fdroidserver

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
fdroid --version || echo "WARNING: fdroid not on PATH"
gh --version | head -1 || echo "WARNING: gh not on PATH"

echo
echo "Next: authenticate the GitHub CLI (interactive, opens a browser):"
echo "    gh auth login        # GitHub.com -> HTTPS -> login with browser"
