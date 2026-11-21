#!/usr/bin/env bash
# Run as root on a Proxmox VE host, in your own terminal:
#
#   proxmox/install-guest.sh CTID USER
#
# Sets up TPM unlock of the GNOME login keyring of USER inside container CTID
# (see README.md, "Proxmox VE containers"): installs tpm2-tools on the host
# if missing, installs tpm-keyring-unlock-guest to /usr/local/sbin, then
# seals the password with proxmox/seal-guest.sh. Shows the plan first and
# asks once. Nothing is changed inside the container, and the container gets
# no TPM device.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER_DST="/usr/local/sbin/tpm-keyring-unlock-guest"
CTID="${1:-}"
USERNAME="${2:-}"

# shellcheck source=../bin/lib.sh
source "$REPO_DIR/bin/lib.sh"

[[ "$CTID" =~ ^[0-9]+$ && "$USERNAME" =~ ^[a-z_][a-z0-9_.-]*$ ]] || {
  echo "Usage: $0 CTID USER" >&2
  exit 2
}
[ "$(id -u)" = 0 ] || { echo "Run this as root on the Proxmox VE host." >&2; exit 1; }
command -v pct >/dev/null || { echo "pct not found - this is not a Proxmox VE host." >&2; exit 1; }
[ -e /dev/tpmrm0 ] || { echo "No /dev/tpmrm0 on this host - is TPM 2.0 enabled in the firmware?" >&2; exit 1; }
require_secure_boot

echo "== tpm-keyring-unlock for container $CTID, user $USERNAME =="
echo
echo "This will:"
n=1
if ! command -v tpm2_createprimary >/dev/null; then
  echo "  $n. Install tpm2-tools on this host (apt-get install tpm2-tools)."; n=$((n + 1))
fi
echo "  $n. Install $HELPER_DST (root:root 0700)."; n=$((n + 1))
echo "  $n. Seal the keyring password of $USERNAME into this host's TPM (you type it)."
echo
echo "The container itself is not changed and gets no TPM access."
read -rp "Continue? [y/N] " ans
[[ "$ans" =~ ^[Yy]$ ]] || exit 0

command -v tpm2_createprimary >/dev/null || apt-get install -y tpm2-tools
install -m 0700 -o root -g root "$REPO_DIR/proxmox/tpm-keyring-unlock-guest.sh" "$HELPER_DST"
"$REPO_DIR/proxmox/seal-guest.sh" "$CTID" "$USERNAME"
