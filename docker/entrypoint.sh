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

mkdir -p "$DATA_DIR" "$DATA_DIR/python"

# Fix ownership only when the top-level directory is wrong (no recursive chown on every start).
want="$(id -u rotorhazard):$(id -g rotorhazard)"
if [ "$(stat -c '%u:%g' "$DATA_DIR")" != "$want" ]; then
    chown -R "$want" "$DATA_DIR"
else
    chown "$want" "$DATA_DIR/python"
fi

exec setpriv --reuid=rotorhazard --regid=rotorhazard --init-groups -- "$@"
