#!/usr/bin/env bash
# Entrypoint test for a RotorHazard image (PUID/PGID, device groups, plugin dependencies).
# Usage: entrypoint.sh IMAGE
set -euo pipefail

usage() { echo "Usage: $0 IMAGE" >&2; exit 2; }

[ $# -eq 1 ] || usage
IMAGE="$1"

PREFIX="rh-smoke-$$"
CONTAINERS=()
VOLUMES=()
DIRS=()
FAILED=0
CURRENT=""      # most recently started container
PORT=""

# remove_dir DIR: delete a (possibly foreign-owned) host directory using the image as root
# shellcheck disable=SC2329  # invoked from cleanup (trap)
remove_dir() {
    docker run --rm --user 0 --entrypoint sh -v "$1":/d "$IMAGE" \
        -c 'find /d -mindepth 1 -delete' >/dev/null 2>&1 || true
    rmdir "$1" 2>/dev/null || true
}

# shellcheck disable=SC2329  # invoked via trap
cleanup() {
    local x
    for x in "${CONTAINERS[@]}"; do docker rm -f "$x" >/dev/null 2>&1 || true; done
    for x in "${VOLUMES[@]}"; do docker volume rm -f "$x" >/dev/null 2>&1 || true; done
    for x in "${DIRS[@]}"; do remove_dir "$x"; done
}
trap cleanup EXIT

pass() { echo "PASS $1"; }
fail() {
    echo "FAIL $1"
    FAILED=1
    if [ -n "$CURRENT" ]; then
        echo "--- logs of $CURRENT ---"
        docker logs "$CURRENT" 2>&1 | tail -n 100 || true
        echo "--- end logs ---"
    fi
}

new_volume() { VOLUMES+=("$PREFIX-$1"); docker volume create "$PREFIX-$1" >/dev/null; }
new_dir() { DIRS+=("$1"); mkdir -p "$1"; }

# start NAME [docker run args...]: run image detached with mock nodes; extra args go before the image
start() {
    local name="$1"; shift
    CURRENT="$PREFIX-$name"
    CONTAINERS+=("$CURRENT")
    docker run -d --name "$CURRENT" -p 127.0.0.1::5000 -e RH_MOCK_NODES=1 "$@" "$IMAGE" >/dev/null
}

# wait_http: poll the mapped port of CURRENT until HTTP 200 (max 90 s)
wait_http() {
    local deadline=$((SECONDS + 90))
    PORT=""
    while [ "$SECONDS" -lt "$deadline" ]; do
        [ -n "$PORT" ] || PORT="$(docker port "$CURRENT" 5000/tcp 2>/dev/null | head -n1 | sed 's/.*://')" || PORT=""
        if [ -n "$PORT" ] && curl -fsS -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null; then
            return 0
        fi
        if [ "$(docker inspect -f '{{.State.Running}}' "$CURRENT" 2>/dev/null)" != "true" ]; then
            return 1
        fi
        sleep 2
    done
    return 1
}

# proc_status: /proc status of the server process in CURRENT (docker exec itself runs as root)
proc_status() {
    docker exec "$CURRENT" sh -c 'for d in /proc/[0-9]*; do
        if grep -q "^python" "$d/comm" 2>/dev/null; then cat "$d/status"; break; fi
    done'
}
proc_uid() { proc_status | awk '/^Uid:/ {print $3}'; }
proc_groups() { proc_status | awk '/^Groups:/ {$1=""; print}'; }

check_puid() {
    local dir="/tmp/$PREFIX-puid" uid owner
    new_dir "$dir"
    start puid -e PUID=1234 -e PGID=1234 -v "$dir":/data
    if ! wait_http; then fail puid; return; fi
    uid="$(proc_uid)"
    owner="$(docker exec "$CURRENT" stat -c %u /data/config.json)"
    if [ "$uid" = "1234" ] && [ "$owner" = "1234" ]; then pass puid; else fail "puid (uid=$uid owner=$owner)"; fi
}

check_puid_restart() {
    docker restart -t 20 "$CURRENT" >/dev/null
    if ! wait_http; then fail "puid restart idempotent (http)"; return; fi
    local logs
    logs="$(docker logs "$CURRENT" 2>&1)"  # capture first: pipefail + grep -q can SIGPIPE docker logs
    if [ "$(proc_uid)" = "1234" ] && ! grep -qi 'usermod\|groupmod' <<<"$logs"; then
        pass "puid restart idempotent"
    else
        fail "puid restart idempotent"
    fi
}

check_bind_created() {
    local dir="/tmp/$PREFIX-new" owner
    DIRS+=("$dir")      # must not exist before: Docker creates it
    start bindnew -v "$dir":/data
    if ! wait_http; then fail "bind mount created by docker"; return; fi
    owner="$(stat -c %u "$dir")"
    if [ "$owner" = "1000" ]; then pass "bind mount created by docker"; else fail "bind mount created by docker (owner=$owner)"; fi
}

check_extra_gids() {
    local groups
    new_volume extra
    start extra -e RH_EXTRA_GIDS=4242,4343 -v "$PREFIX-extra":/data
    if ! wait_http; then fail "extra gids"; return; fi
    groups=" $(proc_groups) "
    if [[ "$groups" == *" 20 "* && "$groups" == *" 4242 "* && "$groups" == *" 4343 "* ]]; then
        pass "extra gids"
    else
        fail "extra gids (groups:$groups)"
    fi
}

check_tty_root() {
    local groups
    new_volume tty
    start tty --device /dev/null:/dev/ttyUSB7 -v "$PREFIX-tty":/data
    if ! wait_http; then fail "tty group skips root"; return; fi
    groups=" $(proc_groups) "
    if [[ "$groups" == *" 0 "* ]]; then fail "tty group skips root (groups:$groups)"; else pass "tty group skips root"; fi
}

check_user_flag() {
    new_volume user
    docker run --rm --user 0 --entrypoint chown -v "$PREFIX-user":/data "$IMAGE" 1000:1000 /data >/dev/null
    start user --user 1000:1000 -v "$PREFIX-user":/data
    if wait_http; then pass "user flag"; else fail "user flag"; fi
}

check_plugin_deps() {
    local out
    new_volume plugins
    start plugins1 -v "$PREFIX-plugins":/data
    if ! wait_http; then fail "plugin deps persist (start)"; return; fi
    # mimic the plugin installer: pip as the server user with its home directory
    if ! out="$(docker exec -u 1000:1000 -e HOME=/home/rotorhazard "$CURRENT" python -m pip install tabulate 2>&1)"; then
        echo "$out"; fail "plugin deps persist (pip install)"; return
    fi
    if grep -Eqi 'cache|permission|not writable' <<<"$out"; then
        echo "$out"; fail "plugin deps persist (pip warning)"; return
    fi
    if ! docker exec "$CURRENT" test -d /data/python/lib/python3.12/site-packages/tabulate; then
        fail "plugin deps persist (not in /data/python)"; return
    fi
    docker rm -f "$CURRENT" >/dev/null
    start plugins2 -v "$PREFIX-plugins":/data
    if wait_http && docker exec -u 1000:1000 "$CURRENT" python -c 'import tabulate'; then
        pass "plugin deps persist"
    else
        fail "plugin deps persist (import after recreate)"
    fi
}

check_no_recursive_chown() {
    local owner
    new_volume chown
    docker run --rm --user 0 --entrypoint sh -v "$PREFIX-chown":/data "$IMAGE" -c \
        'mkdir -p /data/python && chown 1000:1000 /data /data/python && touch /data/marker && chown 4321:4321 /data/marker' >/dev/null
    start chown -v "$PREFIX-chown":/data
    if ! wait_http; then fail "no recursive chown"; return; fi
    owner="$(docker exec "$CURRENT" stat -c %u /data/marker)"
    if [ "$owner" = "4321" ]; then pass "no recursive chown"; else fail "no recursive chown (owner=$owner)"; fi
}

# check_rejects LABEL EXPECTED_TEXT ENV_ASSIGNMENT: container must exit non-zero with the message
check_rejects() {
    local label="$1" text="$2" out rc=0
    out="$(docker run --rm -e "$3" "$IMAGE" true 2>&1)" || rc=$?
    if [ "$rc" != 0 ] && grep -q "$text" <<<"$out"; then pass "reject $label"; else fail "reject $label (rc=$rc: $out)"; fi
}

check_invalid_ids() {
    check_rejects "PUID=0" "must not be 0" PUID=0
    check_rejects "PGID=0" "must not be 0" PGID=0
    check_rejects "RH_EXTRA_GIDS=0" "must not contain 0" RH_EXTRA_GIDS=0
    check_rejects "RH_EXTRA_GIDS=20,0" "must not contain 0" RH_EXTRA_GIDS=20,0
    check_rejects "RH_EXTRA_GIDS=abc" "digits and commas" RH_EXTRA_GIDS=abc
}

check_mock_only_server() {
    local out
    out="$(docker run --rm -e RH_MOCK_NODES=2 "$IMAGE" python -c 'import sys; print(sys.argv)' 2>&1)" || true
    if [ "$out" = "['-c']" ]; then pass "mock nodes only appended for server.py"; else fail "mock nodes only appended for server.py (got: $out)"; fi
}

check_puid
[ "$FAILED" = 0 ] && check_puid_restart
check_bind_created
check_extra_gids
check_tty_root
check_user_flag
check_plugin_deps
check_no_recursive_chown
check_invalid_ids
check_mock_only_server

if [ "$FAILED" = 0 ]; then echo "ALL CHECKS PASSED"; else echo "ENTRYPOINT TEST FAILED"; fi
exit "$FAILED"
