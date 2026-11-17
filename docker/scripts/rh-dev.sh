#!/usr/bin/env bash
# RotorHazard developer helper: wraps the docker compose dev workflow.
# Works from any directory (and via symlink). RH_DEV_DRY_RUN=1 prints the commands instead of running them.
set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd "$(dirname "$SCRIPT_PATH")/../.." && pwd)"
COMPOSE_FILE="$REPO_ROOT/docker/compose.dev.yaml"
SERVICE=rotorhazard
RUN_USER=rotorhazard
DATA_VOLUME=rotorhazard-dev_rh-dev-data
URL="http://localhost:5000"
DRY_RUN="${RH_DEV_DRY_RUN:-0}"

usage() {
    cat >&2 <<USAGE
Usage: $(basename "$0") <command> [args]

Commands:
  up [--mock N]  build if needed, start the dev container in the background, print the URL
  down           stop and remove the container (data volume kept)
  restart        restart the container after code changes
  logs [-f]      show server logs
  shell          open a bash shell in the container
  test           run the unit tests (python -m unittest discover)
  lint           run pylint --errors-only over the server and interface code
  rebuild        rebuild the image (after requirement changes) and restart
  reset-data     delete the dev data volume (asks for confirmation)
  status         container state, URL, attached serial devices
USAGE
    exit 2
}

# quote ARG: shell-quote only if needed, for the dry-run display
quote() {
    if [[ "$1" =~ [^A-Za-z0-9_./:=@%+,-] ]]; then
        local sq="'" esc="'\\''"
        printf "'%s'" "${1//$sq/$esc}"
    else
        printf '%s' "$1"
    fi
}

# run [VAR=value ...] CMD ARGS...: execute, or print as "+ ..." in dry-run mode
run() {
    if [ "$DRY_RUN" = 1 ]; then
        local out="+" a
        for a in "$@"; do out+=" $(quote "$a")"; done
        echo "$out"
        return 0
    fi
    if [[ "${1:-}" == *=* ]]; then
        env "$@"
    else
        "$@"
    fi
}

compose() { run docker compose -f "$COMPOSE_FILE" "$@"; }
cexec() { compose exec -u "$RUN_USER" "$SERVICE" "$@"; }

need_docker() {
    [ "$DRY_RUN" = 1 ] && return 0
    command -v docker >/dev/null 2>&1 || { echo "docker not found" >&2; exit 1; }
}

cmd_up() {
    local mock=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --mock) [ $# -ge 2 ] && [[ "$2" =~ ^[0-9]+$ ]] || { echo "--mock needs a number" >&2; usage; }
                    mock="$2"; shift 2 ;;
            *) usage ;;
        esac
    done
    if [ -n "$mock" ]; then
        run RH_MOCK_NODES="$mock" docker compose -f "$COMPOSE_FILE" up -d --build
    else
        compose up -d --build
    fi
    echo "RotorHazard dev server: $URL"
}

cmd_down() { compose down; }
cmd_restart() { compose restart "$SERVICE"; }

cmd_logs() {
    case "${1:-}" in
        "") compose logs "$SERVICE" ;;
        -f) compose logs -f "$SERVICE" ;;
        *) usage ;;
    esac
}

cmd_shell() { cexec bash; }
cmd_test() { cexec sh -c 'cd /app/src/tests && python -m unittest discover'; }

cmd_lint() {
    cexec sh -c 'pylint --errors-only /app/src/interface/*.py /app/src/server/*.py /app/src/server/util/*.py'
}

cmd_rebuild() {
    compose build
    compose up -d
    echo "RotorHazard dev server: $URL"
}

cmd_reset_data() {
    local answer=""
    printf 'Delete dev data volume? [y/N] ' >&2
    read -r answer || true
    case "$answer" in
        y|Y|yes|YES)
            compose down
            run docker volume rm "$DATA_VOLUME"
            ;;
        *) echo "Aborted." >&2 ;;
    esac
}

cmd_status() {
    if [ "$DRY_RUN" = 1 ]; then
        compose ps "$SERVICE"
        echo "URL: $URL"
        return 0
    fi
    local state
    state="$(docker compose -f "$COMPOSE_FILE" ps --format '{{.State}}' "$SERVICE" 2>/dev/null || true)"
    echo "Container: ${state:-not running}"
    echo "URL: $URL"
    if [ "$state" = running ]; then
        echo "Serial devices:"
        docker compose -f "$COMPOSE_FILE" exec -T "$SERVICE" sh -c \
            'ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null || echo none' | sed 's/^/  /'
    else
        echo "Serial devices: unknown (container not running)"
    fi
}

[ $# -ge 1 ] || usage
command="$1"; shift
need_docker
case "$command" in
    up) cmd_up "$@" ;;
    down) cmd_down ;;
    restart) cmd_restart ;;
    logs) cmd_logs "$@" ;;
    shell) cmd_shell ;;
    test) cmd_test ;;
    lint) cmd_lint ;;
    rebuild) cmd_rebuild ;;
    reset-data) cmd_reset_data ;;
    status) cmd_status ;;
    *) usage ;;
esac
