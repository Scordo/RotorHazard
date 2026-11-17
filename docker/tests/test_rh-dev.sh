#!/usr/bin/env bash
# Tests for docker/scripts/rh-dev.sh (dry-run mode, no docker needed).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SCRIPT="$REPO/docker/scripts/rh-dev.sh"
COMPOSE="docker compose -f $REPO/docker/compose.dev.yaml"
FAILED=0
LINK=""

# shellcheck disable=SC2329  # invoked via trap
cleanup() { [ -z "$LINK" ] || rm -f "$LINK"; }
trap cleanup EXIT

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; if [ -n "${2:-}" ]; then echo "--- output ---"; echo "$2"; fi; FAILED=1; }

# expect_contains NAME OUTPUT NEEDLE
expect_contains() {
    if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1 (missing: $3)" "$2"; fi
}
expect_lacks() {
    if [[ "$2" == *"$3"* ]]; then fail "$1 (unexpected: $3)" "$2"; else pass "$1"; fi
}

export RH_DEV_DRY_RUN=1

out="$("$SCRIPT" up --mock 3 2>&1)" || out="$out [exit $?]"
expect_contains "up: mock env" "$out" "RH_MOCK_NODES=3"
expect_contains "up: compose command" "$out" "$COMPOSE up -d --build"
expect_contains "up: url" "$out" "http://localhost:5000"

out="$("$SCRIPT" down 2>&1)" || true
expect_contains "down: command" "$out" "$COMPOSE down"
expect_lacks "down: keeps volume" "$out" " -v"

out="$("$SCRIPT" test 2>&1)" || true
expect_contains "test: command" "$out" "exec -T -u rotorhazard rotorhazard sh -c 'cd /app/src/tests && python -m unittest discover'"

out="$("$SCRIPT" shell 2>&1)" || true
expect_contains "shell: command" "$out" "exec -u rotorhazard rotorhazard bash"
expect_lacks "shell: keeps TTY" "$out" " -T"

out="$("$SCRIPT" lint 2>&1)" || true
expect_contains "lint: command" "$out" "pylint --errors-only /app/src/interface/*.py /app/src/server/*.py /app/src/server/util/*.py"

rc=0
out="$("$SCRIPT" bogus 2>&1)" || rc=$?
if [ "$rc" = 2 ]; then pass "bogus: exit 2"; else fail "bogus: exit $rc"; fi
expect_contains "bogus: usage" "$out" "Usage:"

out="$(cd /tmp && "$SCRIPT" down 2>&1)" || true
expect_contains "from /tmp: repo path" "$out" "$COMPOSE down"

LINK="/tmp/rh-dev-link-$$"
ln -s "$SCRIPT" "$LINK"
out="$("$LINK" down 2>&1)" || true
expect_contains "via symlink: repo path" "$out" "$COMPOSE down"

out="$(echo n | "$SCRIPT" reset-data 2>&1)" || true
expect_lacks "reset-data n: no volume rm" "$out" "docker volume rm"
out="$(echo y | "$SCRIPT" reset-data 2>&1)" || true
expect_contains "reset-data y: down first" "$out" "$COMPOSE down"
expect_contains "reset-data y: volume rm" "$out" "+ docker volume rm rotorhazard-dev_rh-dev-data"

if [ "$FAILED" = 0 ]; then echo "ALL CHECKS PASSED"; else echo "TESTS FAILED"; fi
exit "$FAILED"
