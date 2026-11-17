#!/bin/sh
# RotorHazard container entrypoint: prepare /data, then run the command as 'rotorhazard'.
set -eu

DATA_DIR="${RH_DATA_DIR:-/data}"

# RH_MOCK_NODES=N -> append --mock-nodes N to the command line
if [ -n "${RH_MOCK_NODES:-}" ]; then
    set -- "$@" --mock-nodes "$RH_MOCK_NODES"
fi

# Already started as non-root (e.g. 'user:' in Compose): nothing to prepare or drop.
if [ "$(id -u)" != "0" ]; then
    exec "$@"
fi

RH_HOME=/home/rotorhazard
want_uid="${PUID:-1000}"
want_gid="${PGID:-1000}"
case "$want_uid$want_gid" in
    *[!0-9]*|"") echo "entrypoint: PUID and PGID must be numeric" >&2; exit 1 ;;
esac

# Align the 'rotorhazard' user/group with PUID/PGID (only when they differ, so restarts are no-ops).
if [ "$(id -g rotorhazard)" != "$want_gid" ]; then
    groupmod -o -g "$want_gid" rotorhazard
fi
if [ "$(id -u rotorhazard)" != "$want_uid" ]; then
    usermod -o -u "$want_uid" rotorhazard
fi
want="$want_uid:$want_gid"

# HOME for the server process (pip cache etc.); must belong to the (possibly changed) user.
mkdir -p "$RH_HOME"
chown "$want" "$RH_HOME"
export HOME="$RH_HOME"

mkdir -p "$DATA_DIR" "$DATA_DIR/python"

# Fix ownership only when the top-level directory is wrong (no recursive chown on every start).
if [ "$(stat -c '%u:%g' "$DATA_DIR")" != "$want" ]; then
    chown -R "$want" "$DATA_DIR"
else
    chown "$want" "$DATA_DIR/python"
fi

# Supplementary groups: dialout (20), GIDs of serial devices (never root), RH_EXTRA_GIDS.
groups="20"
for dev in /dev/ttyUSB* /dev/ttyACM*; do
    [ -e "$dev" ] || continue
    gid="$(stat -L -c '%g' "$dev")"
    [ "$gid" != "0" ] || continue
    groups="$groups,$gid"
done
if [ -n "${RH_EXTRA_GIDS:-}" ]; then
    groups="$groups,$RH_EXTRA_GIDS"
fi
# de-duplicate, keep order
groups="$(printf '%s' "$groups" | tr ',' '\n' | awk 'NF && !seen[$0]++' | paste -sd, -)"

exec setpriv --reuid="$want_uid" --regid="$want_gid" --groups "$groups" -- "$@"
