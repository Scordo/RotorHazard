#!/usr/bin/env bash
# Smoke test for a RotorHazard image.
# Usage: smoke.sh IMAGE [--java] [--dev]
set -euo pipefail

usage() { echo "Usage: $0 IMAGE [--java] [--dev]" >&2; exit 2; }

[ $# -ge 1 ] || usage
IMAGE="$1"; shift
WITH_JAVA=0
WITH_DEV=0
for arg in "$@"; do
    case "$arg" in
        --java) WITH_JAVA=1 ;;
        --dev) WITH_DEV=1 ;;
        *) usage ;;
    esac
done

PREFIX="rh-smoke-$$"
VOLUME="$PREFIX-data"
CONTAINERS=()
FAILED=0
CURRENT=""      # most recently started container
PORT=""

# shellcheck disable=SC2329  # invoked via trap
cleanup() {
    local c
    for c in "${CONTAINERS[@]}"; do
        docker rm -f "$c" >/dev/null 2>&1 || true
    done
    docker volume rm -f "$VOLUME" >/dev/null 2>&1 || true
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

# start_container NAME: run image detached with mock nodes on the shared volume
start_container() {
    CURRENT="$PREFIX-$1"
    CONTAINERS+=("$CURRENT")
    docker run -d --name "$CURRENT" -p 127.0.0.1::5000 \
        -e RH_MOCK_NODES=2 -v "$VOLUME":/data "$IMAGE" >/dev/null
}

# wait_http: poll the mapped port of CURRENT until HTTP 200 (max 90 s)
wait_http() {
    local deadline=$((SECONDS + 90))
    PORT="$(docker port "$CURRENT" 5000/tcp 2>/dev/null | head -n1 | sed 's/.*://')" || PORT=""
    while [ "$SECONDS" -lt "$deadline" ]; do
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

check_http() {
    if start_container first 2>&1 && wait_http; then pass http; else fail http; return 1; fi
}

check_nonroot() {
    # docker exec runs as the container's default user (root), so inspect the server process itself.
    local status uid groups
    status="$(docker exec "$CURRENT" sh -c 'for d in /proc/[0-9]*; do
        if grep -q "^python" "$d/comm" 2>/dev/null; then cat "$d/status"; break; fi
    done')" || status=""
    uid="$(awk '/^Uid:/ {print $3}' <<<"$status")"
    groups="$(awk '/^Groups:/ {$1=""; print}' <<<"$status")"
    if [ "$uid" = "1000" ] && [[ " $groups " == *" 20 "* ]]; then pass nonroot; else fail nonroot; fi
}

check_data_layout() {
    if docker exec "$CURRENT" sh -c 'test -f /data/config.json && test -f /data/database.db && test -d /data/logs'; then
        pass data-layout
    else
        fail data-layout
    fi
}

# Capture logs before grepping: with pipefail, `docker logs | grep -q` can fail
# (SIGPIPE on docker logs after grep exits early on a match).
check_mock_nodes() {
    local logs
    logs="$(docker logs "$CURRENT" 2>&1)"
    if grep -q 'Using mock hardware interface' <<<"$logs"; then pass mock-nodes; else fail mock-nodes; fi
}

check_no_mismatch() {
    local logs
    logs="$(docker logs "$CURRENT" 2>&1)"
    if grep -qF 'Try "pip install' <<<"$logs"; then fail no-mismatch; else pass no-mismatch; fi
}

check_restart() {
    local first="$CURRENT" start elapsed logs
    start=$SECONDS
    docker stop -t 20 "$first" >/dev/null 2>&1 || true
    elapsed=$((SECONDS - start))
    if [ "$elapsed" -ge 25 ]; then fail "restart after stop (stop took ${elapsed}s)"; return; fi
    if ! { start_container second && wait_http; }; then fail "restart after stop (http)"; return; fi
    logs="$(docker logs "$CURRENT" 2>&1)"
    if grep -q 'Traceback' <<<"$logs" || grep -q 'database is locked' <<<"$logs"; then
        fail "restart after stop (errors in log)"
    else
        pass "restart after stop"
    fi
}

check_java() {
    if docker exec "$CURRENT" java -jar /app/src/server/static/IMDTabler.jar -v >/dev/null 2>&1; then pass java; else fail java; fi
}

check_dev() {
    if docker exec "$CURRENT" sh -c 'pylint --version && python -c "import debugpy" && git --version' >/dev/null 2>&1; then
        pass dev
    else
        fail dev
    fi
}

check_http || true
if [ -n "$PORT" ] && [ "$FAILED" = 0 ]; then
    check_nonroot
    check_data_layout
    check_mock_nodes
    check_no_mismatch
    [ "$WITH_JAVA" = 1 ] && check_java
    [ "$WITH_DEV" = 1 ] && check_dev
    check_restart
fi

if [ "$FAILED" = 0 ]; then echo "ALL CHECKS PASSED"; else echo "SMOKE TEST FAILED"; fi
exit "$FAILED"
