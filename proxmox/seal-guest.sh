#!/usr/bin/env bash
# Run as root on a Proxmox VE host, in your own terminal:
#
#   proxmox/seal-guest.sh CTID USER
#
# Seals the GNOME login keyring password of USER inside container CTID into
# this host's TPM, bound to PCR7 (the host's Secure Boot state), for
# tpm-keyring-unlock-guest. The password is typed here interactively, as for
# bin/seal.sh, which does the sealing itself; the sealed object lives in
# /root/.local/share/tpm-keyring-unlock/guests/CTID-USER on the host and is
# useless anywhere but this host's TPM in this Secure Boot state.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CTID="${1:-}"
USERNAME="${2:-}"

[[ "$CTID" =~ ^[0-9]+$ && "$USERNAME" =~ ^[a-z_][a-z0-9_.-]*$ ]] || {
  echo "Usage: $0 CTID USER" >&2
  exit 2
}
[ "$(id -u)" = 0 ] || { echo "Run this as root on the Proxmox VE host." >&2; exit 1; }
command -v pct >/dev/null || { echo "pct not found - this is not a Proxmox VE host." >&2; exit 1; }
pct config "$CTID" >/dev/null 2>&1 || { echo "There is no container $CTID on this host." >&2; exit 1; }
if pct status "$CTID" | grep -q running; then
  pct exec "$CTID" -- id -u "$USERNAME" >/dev/null 2>&1 || {
    echo "Container $CTID has no user $USERNAME." >&2
    exit 1
  }
else
  echo "Container $CTID is not running; the user name is not checked." >&2
fi

DATA_DIR="/root/.local/share/tpm-keyring-unlock/guests/$CTID-$USERNAME"
install -d -m 700 /root/.local /root/.local/share /root/.local/share/tpm-keyring-unlock \
  /root/.local/share/tpm-keyring-unlock/guests
echo "Sealing the login keyring password of $USERNAME in container $CTID."
echo "Type the password the keyring of that user is locked with (normally the"
echo "user's login password in the container)."
TPM_KEYRING_DATA_DIR="$DATA_DIR" "$REPO_DIR/bin/seal.sh"
echo
echo "Check it (unlocks the keyring if it is locked; 0 = unlocked, 3 = was"
echo "unlocked already):"
echo "  /usr/local/sbin/tpm-keyring-unlock-guest $CTID $USERNAME; echo \$?"
