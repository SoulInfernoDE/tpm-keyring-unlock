#!/usr/bin/env bash
# Installed on a Proxmox VE host at /usr/local/sbin/tpm-keyring-unlock-guest,
# root:root mode 0700, by proxmox/install-guest.sh.
#
# Usage: tpm-keyring-unlock-guest CTID USER
#
# Unlocks the GNOME login keyring of USER inside the running container CTID
# with the password proxmox/seal-guest.sh sealed for that pair in this host's
# TPM (PCR7 policy, as for a local login). For containers nobody has logged
# in to since they started - programs started there remotely (for example
# over xpra) otherwise find the keyring locked.
#
# The container gets no TPM access: the host unseals, and the password goes
# straight from tpm2_unseal through a pipe into the container, where the
# running keyring daemon is unlocked over its own D-Bus interface
# (UnlockWithMasterPassword, as Seahorse does). It is never written to disk,
# never part of a command line, and never printed; the caller only gets the
# exit status:
#   0  unlocked now
#   3  was unlocked already (nothing unsealed)
#   2  nothing sealed for this container and user
#   1  failure: container or keyring unreachable, the TPM refused (PCR7
#      changed, e.g. after a Secure Boot update - re-seal), or the keyring
#      did not accept the password (it was changed - re-seal)
set -euo pipefail

CTID="${1:-}"
USERNAME="${2:-}"
[[ "$CTID" =~ ^[0-9]+$ ]] || exit 1
[[ "$USERNAME" =~ ^[a-z_][a-z0-9_.-]*$ ]] || exit 1
[ "$(id -u)" = 0 ] || exit 1

DATA_DIR="/root/.local/share/tpm-keyring-unlock/guests/$CTID-$USERNAME"
PCR_BANK="sha256:7"

[ -f "$DATA_DIR/seal.priv" ] || exit 2
pct status "$CTID" 2>/dev/null | grep -q running || exit 1
guest_uid="$(pct exec "$CTID" -- id -u "$USERNAME" </dev/null 2>/dev/null)" || exit 1
[[ "$guest_uid" =~ ^[0-9]+$ ]] || exit 1

# A command as USER inside the container, with that user's session bus and
# runtime directory (the keyring daemon is started there on demand through
# D-Bus activation, also when nobody is logged in).
in_guest() {
  pct exec "$CTID" -- runuser -u "$USERNAME" -- env \
    "XDG_RUNTIME_DIR=/run/user/$guest_uid" \
    "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$guest_uid/bus" "$@"
}

# "true" or "false" for the login collection; nothing when there is none.
login_locked() {
  in_guest gdbus call --session --dest org.freedesktop.secrets \
    --object-path /org/freedesktop/secrets/collection/login \
    --method org.freedesktop.DBus.Properties.Get \
    org.freedesktop.Secret.Collection Locked </dev/null 2>/dev/null |
    grep -o -E 'true|false' | head -n 1 || true
}

# Reads the password on stdin and unlocks the login collection of the
# keyring daemon that owns the Secret Service on the user's bus. Not
# "gnome-keyring-daemon --unlock": with a daemon already running (started by
# systemd or D-Bus activation) that started another, disconnected daemon
# instead - see JOURNAL.md, 2026-11-21.
UNLOCK_PY='import sys
from gi.repository import Gio, GLib
password = sys.stdin.buffer.read()
bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
name, root = "org.freedesktop.secrets", "/org/freedesktop/secrets"
reply = bus.call_sync(name, root, "org.freedesktop.Secret.Service", "OpenSession",
                      GLib.Variant("(sv)", ("plain", GLib.Variant("s", ""))),
                      GLib.VariantType("(vo)"), Gio.DBusCallFlags.NONE, 10000, None)
session = reply.unpack()[1]
try:
    bus.call_sync(name, root, "org.gnome.keyring.InternalUnsupportedGuiltRiddenInterface",
                  "UnlockWithMasterPassword",
                  GLib.Variant("(o(oayays))", (root + "/collection/login",
                                               (session, b"", password, "text/plain"))),
                  None, Gio.DBusCallFlags.NONE, 30000, None)
finally:
    bus.call_sync(name, session, "org.freedesktop.Secret.Session", "Close", None, None,
                  Gio.DBusCallFlags.NONE, 10000, None)'

case "$(login_locked)" in
  false) exit 3 ;;
  true) ;;
  *) exit 1 ;;
esac

# One TPM user at a time, shared with the login helper of this repository
# (see pam/tpm-keyring-unseal.sh and JOURNAL.md, 2026-08-14).
exec 9>/run/lock/tpm-keyring-unseal.lock
flock -w 10 9 || exit 1

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# Same steps as pam/tpm-keyring-unseal.sh, which stays a standalone file for
# its PAM caller; see the comments there for the primary handle and retries.
if [ -f "$DATA_DIR/primary.handle" ]; then
  PRIMARY_HANDLE="$(cat "$DATA_DIR/primary.handle")"
else
  tpm2_createprimary -C o -c "$WORKDIR/primary.ctx" >/dev/null
  PRIMARY_HANDLE="$WORKDIR/primary.ctx"
fi
tpm2_load -C "$PRIMARY_HANDLE" \
  -u "$DATA_DIR/seal.pub" -r "$DATA_DIR/seal.priv" \
  -c "$WORKDIR/seal.ctx" >/dev/null 2>&1 || exit 1

secret=""
attempt=1
while :; do
  SESSION_CTX="$WORKDIR/session.$attempt"
  if tpm2_startauthsession -S "$SESSION_CTX" --policy-session >/dev/null 2>&1 \
     && tpm2_policypcr -S "$SESSION_CTX" -l "$PCR_BANK" >/dev/null 2>&1 \
     && secret="$(tpm2_unseal -c "$WORKDIR/seal.ctx" -p "session:$SESSION_CTX" 2>/dev/null)"; then
    tpm2_flushcontext "$SESSION_CTX" >/dev/null 2>&1 || true
    break
  fi
  tpm2_flushcontext "$SESSION_CTX" >/dev/null 2>&1 || true
  [ "$attempt" -ge 5 ] && exit 1
  attempt=$((attempt + 1))
  sleep 0.3
done

# printf is a shell builtin: the password is no process argument here either.
printf '%s' "$secret" | in_guest /usr/bin/python3 -I -c "$UNLOCK_PY" >/dev/null 2>&1 || true
secret=""
unset secret

[ "$(login_locked)" = false ] || exit 1
exit 0
