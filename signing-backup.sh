#!/usr/bin/env bash
#
# signing-backup.sh — encrypted backup/restore of the app-signing secrets.
#
#   ./signing-backup.sh backup    # encrypt secrets.env + keystore-apps.jks -> committed blob
#   ./signing-backup.sh restore   # decrypt the blob back into place
#
# The blob 'signing-backup.tar.gz.gpg' is safe to commit (AES256, passphrase-
# protected); the raw secrets stay gitignored. Store the passphrase in your
# password manager — it's the only secret that must live outside this repo.
#
# Re-run 'backup' whenever the keystore changes (i.e. after onboarding a NEW
# app — routine version bumps don't change it).
#
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

BLOB="signing-backup.tar.gz.gpg"
FILES=(secrets.env keystore-apps.jks)

command -v gpg >/dev/null 2>&1 || { echo "ERROR: gpg not found" >&2; exit 1; }

case "${1:-}" in
  backup)
    for f in "${FILES[@]}"; do
      [ -f "$f" ] || { echo "ERROR: '$f' missing — nothing to back up" >&2; exit 1; }
    done
    echo "[backup] encrypting ${FILES[*]} -> $BLOB (you'll be asked for a passphrase)"
    tar czf - "${FILES[@]}" \
      | gpg --symmetric --cipher-algo AES256 --yes -o "$BLOB"
    echo "[backup] verifying the blob decrypts..."
    contents="$(gpg -d "$BLOB" 2>/dev/null | tar tzf -)"
    for f in "${FILES[@]}"; do
      grep -qx "$f" <<<"$contents" || { echo "ERROR: '$f' not found in blob — backup FAILED" >&2; exit 1; }
    done
    echo "[backup] OK — blob contains: ${FILES[*]}"
    echo
    echo "Next: commit & push it ->"
    echo "    git add $BLOB && git commit -m 'Refresh encrypted signing backup' && git push"
    ;;

  restore)
    [ -f "$BLOB" ] || { echo "ERROR: '$BLOB' not found" >&2; exit 1; }
    for f in "${FILES[@]}"; do
      if [ -f "$f" ]; then
        echo "ERROR: '$f' already exists — refusing to overwrite." >&2
        echo "       Move it aside first if you really want to restore." >&2
        exit 1
      fi
    done
    echo "[restore] decrypting $BLOB (you'll be asked for the passphrase)"
    gpg -d "$BLOB" | tar xzf -
    echo "[restore] OK — restored: ${FILES[*]}"
    ;;

  *)
    echo "usage: $(basename "$0") {backup|restore}" >&2
    exit 2
    ;;
esac
