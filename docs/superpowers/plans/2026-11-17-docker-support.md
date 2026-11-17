# Docker Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Docker images (default + Java variant) for end users on non-Pi Linux, a dev image with Compose and VS Code Dev Container workflows, Windows/WSL2 helper scripts, CI publishing to GHCR, and two user-facing guides.

**Architecture:** One multi-stage `docker/Dockerfile` (`builder` → `runtime` → `runtime-java` → `dev`) with a root-start/privilege-drop entrypoint; data and pip user-site live in `/data`. Compose files for users and devs, a bash helper (`rh-dev.sh`) as the single source of dev commands, and a PowerShell wrapper that resolves the WSL distro/path and adds setup and USB (usbipd) commands. GitHub Actions builds, smoke-tests and publishes both variants.

**Tech Stack:** Docker (BuildKit/buildx), Docker Compose v2, bash, PowerShell 5.1, Pester 3.4, GitHub Actions, Python 3.12 slim (Debian bookworm).

**Spec:** `docs/superpowers/specs/2026-11-17-docker-support-design.md` – read it before starting any task; section numbers below refer to it.

## Global Constraints

- Base image `python:3.12-slim-bookworm`; `ARG PYTHON_VERSION=3.12`; no venv in the image.
- Image paths: `/app/src/server`, `/app/src/interface`, `/app/doc`, `/app/firmware`; `WORKDIR /app/src/server`; data at `/data`.
- ENV in `runtime`: `RH_DATA_DIR=/data`, `PIP_USER=1`, `PYTHONUSERBASE=/data/python`, `PYTHONUNBUFFERED=1`, `PIP_DISABLE_PIP_VERSION_CHECK=1`.
- User `rotorhazard` UID/GID 1000, supplementary group `dialout` (20). The server process never runs as root.
- No `--privileged` anywhere in shipped files; USB via `/dev:/dev`, `/run/udev:/run/udev:ro`, `device_cgroup_rules` `c 188:* rmw` and `c 166:* rmw`.
- No `HEALTHCHECK`. No application code changes under `src/`.
- Image name `ghcr.io/<owner>/rotorhazard`; Java variant uses tag suffix `-java`; pre-releases never get `latest`/`latest-java`.
- Env vars (exact names): `RH_IMAGE`, `RH_VERSION`, `TZ`, `PUID`, `PGID`, `RH_EXTRA_GIDS`, `RH_MOCK_NODES`, `RH_WSL_DISTRO`, `RH_WSL_REPO`, workflow variable `PUBLISH_DEV`.
- Shell scripts LF, `*.ps1`/`*.cmd` CRLF (enforced by `.gitattributes`).
- Docs in English; no mention of or credit to PR #1115.
- Never add Claude/AI attribution or `Co-Authored-By` trailers to commits.
- Do not commit `docs/superpowers/**` into the upstream PR (it stays on the branch; exclude when preparing the PR).

## Test environment

- Windows repo: `C:\P\Remote\github\RotorHazard` (branch `docker-support`).
- WSL2 distro `Ubuntu-26.04`, default user `scordo` (UID 1000, in `docker` group), Docker Engine 29.1, Compose 2.40, buildx, shellcheck installed.
- Run Linux-side commands from PowerShell as: `wsl -d Ubuntu-26.04 --cd /mnt/c/P/Remote/github/RotorHazard -- <command>` (abbreviated below as **`W:`**).
- Pester: Windows PowerShell 5.1 with Pester 3.4: `powershell.exe -NoProfile -Command "Invoke-Pester docker/tests/rh-dev.Tests.ps1 -EnableExit"` (abbreviated **`P:`**). Pester 3 syntax (`Should Be`, `Should Match`).
- Not available locally: usbipd-win (installed by the user via `rh-dev setup` in Task 6), real USB node, Raspberry Pi.

## Review Focus

1. **Bind-mount directory that does not exist yet** – Docker creates it owned by root; the entrypoint must take ownership and the server must start. → Task 2, test `bind mount created by docker`.
2. **Container restarted with a non-default `PUID`/`PGID`** – the UID change is already applied on the second start; the entrypoint must be idempotent. → Task 2, test `puid restart idempotent`.
3. **Repo opened from a Windows drive in PowerShell** (`C:\…`) – `rh-dev.ps1` must not pass a Windows path to `wsl --cd`; it uses `RH_WSL_REPO`/`RH_WSL_DISTRO` or exits with a clear message. → Task 6, Pester `Resolve-RhWslTarget` cases.
4. **Windows checkout with `core.autocrlf=true`** – `.sh` files must stay LF or the entrypoint fails with "no such file or directory". → Task 1, step `line endings`.
5. **`docker stop` while the server is running** – clean shutdown, restart on the same volume shows no DB lock/traceback. → Task 1, smoke check `restart after stop`.

---

### Task 1: Runtime image, entrypoint (basic), smoke test

**Files:**
- Create: `.gitattributes`, `.dockerignore`, `docker/Dockerfile` (stages `builder`, `runtime`), `docker/entrypoint.sh`, `docker/tests/smoke.sh`

**Interfaces:**
- Produces: image target `runtime`; entrypoint contract (starts as root, ensures `/data` + `/data/python`, `RH_MOCK_NODES=N` → appends `--mock-nodes N`, drops to `rotorhazard` via `setpriv`, `exec "$@"` when not root); `docker/tests/smoke.sh IMAGE [--java] [--dev]` → exit 0 on success, prints `PASS <check>`/`FAIL <check>` per check, dumps container logs on failure, always removes its containers/volumes.

- [ ] **Step 1: `.gitattributes`** with `*.sh text eol=lf`, `docker/entrypoint.sh text eol=lf`, `*.ps1 text eol=crlf`, `*.cmd text eol=crlf`. Applies only to the new files; existing files are unaffected (no renormalization). Verified in Step 9.

- [ ] **Step 2: Write `docker/tests/smoke.sh`** (bash, `set -euo pipefail`, shellcheck-clean). Checks, each a named function printing PASS/FAIL:
  - `http`: `docker run -d -p 127.0.0.1::5000 -e RH_MOCK_NODES=2 -v <unique volume>:/data IMAGE`, poll `curl -fsS http://127.0.0.1:<mapped>/` until 200, timeout 90 s.
  - `nonroot`: `docker exec C id -u` → `1000`; `id -G` contains `20`.
  - `data-layout`: `/data/config.json`, `/data/database.db`, `/data/logs/` exist in the container.
  - `mock-nodes`: `docker logs C` contains `Using mock hardware interface`.
  - `no-mismatch`: logs do not contain `Try "pip install`.
  - `restart after stop`: `docker stop -t 20 C` finishes < 25 s; start a new container on the same volume, `http` passes again, its logs contain no `Traceback` and no `database is locked`.
  - `--java`: `docker exec C java -jar /app/src/server/static/IMDTabler.jar -v` exits 0.
  - `--dev`: `pylint --version`, `python -c "import debugpy"`, `git --version` exit 0.
  - Volume/container names include `$$` so parallel runs don't collide; `trap` cleanup on EXIT.

- [ ] **Step 3: Run it against a non-existent image to see it fail cleanly**
  Run `W: bash docker/tests/smoke.sh rotorhazard:nope` → non-zero exit, `FAIL http`, no leftover containers (`docker ps -a` empty of smoke containers).

- [ ] **Step 4: `.dockerignore`** exactly per spec 5.9 (plus `docker/tests`, `.github`).

- [ ] **Step 5: `docker/Dockerfile` stages `builder` and `runtime`** per spec 5.2: builder `pip wheel -r src/server/reqsNonPi.txt -w /wheels`; runtime installs from `/wheels` with `--no-index`, apt `tini util-linux` (`--no-install-recommends`, clean lists), creates user/group 1000 + `dialout`, copies the four dirs, writes `pip freeze > /app/requirements.lock.txt`, ENV/VOLUME/EXPOSE/OCI labels (`ARG RH_VERSION`, `ARG RH_SOURCE`), `ENTRYPOINT ["tini","--","/usr/local/bin/entrypoint.sh"]`, `CMD ["python","server.py"]`. `runtime` is the last stage for now.

- [ ] **Step 6: `docker/entrypoint.sh`** (`#!/bin/sh`, `set -eu`, shellcheck-clean) implementing spec 5.3 steps 2, 4, 5, 6 only (PUID/PGID and tty-group detection come in Task 2). `setpriv --reuid=rotorhazard --regid=rotorhazard --init-groups -- "$@"`.

- [ ] **Step 7: Build and run smoke test**
  `W: docker build -f docker/Dockerfile --target runtime -t rotorhazard:runtime .` then `W: bash docker/tests/smoke.sh rotorhazard:runtime` → all checks PASS (`--java`/`--dev` not passed).

- [ ] **Step 8: shellcheck** `W: shellcheck docker/entrypoint.sh docker/tests/smoke.sh` → no output.

- [ ] **Step 9: line endings** `git ls-files --eol docker/ .gitattributes` → `.sh` files show `i/lf w/lf`. Then delete and re-checkout `docker/entrypoint.sh` (`git checkout -- docker/entrypoint.sh` after removing it) and rebuild – smoke still passes.

- [ ] **Step 10: Commit** `git add .gitattributes .dockerignore docker/Dockerfile docker/entrypoint.sh docker/tests/smoke.sh` → `git commit -m "Docker: runtime image, entrypoint and smoke test"`.

---

### Task 2: Entrypoint – PUID/PGID, device groups, plugin dependencies

**Files:**
- Modify: `docker/entrypoint.sh`
- Create: `docker/tests/entrypoint.sh` (bash test script, same PASS/FAIL style as smoke)

**Interfaces:**
- Consumes: image `rotorhazard:runtime` from Task 1.
- Produces: env contract `PUID`, `PGID` (default 1000), `RH_EXTRA_GIDS` (comma-separated); `docker/tests/entrypoint.sh IMAGE`.

- [ ] **Step 1: Write `docker/tests/entrypoint.sh`** with these named checks (each starts its own container with `RH_MOCK_NODES=1`, waits for HTTP like smoke):
  - `puid`: bind-mount a temp dir, `-e PUID=1234 -e PGID=1234` → `id -u` = `1234`, `stat -c %u /data/config.json` = `1234`.
  - `puid restart idempotent`: `docker restart` the same container → HTTP 200 again, `id -u` still `1234`, no `usermod` error in logs.
  - `bind mount created by docker`: `-v /tmp/rh-smoke-$$-new:/data` (path does not exist before) → HTTP 200; host dir owned by 1000.
  - `extra gids`: `-e RH_EXTRA_GIDS=4242,4343` → `id -G` contains `20`, `4242`, `4343`.
  - `tty group skips root`: `--device /dev/null:/dev/ttyUSB7` (group 0) → process groups (`id -G`) do **not** contain `0`. (A real tty with a non-root group is verified with hardware in Task 10.)
  - `user flag`: `--user 1000:1000` with a named volume → HTTP 200 (entrypoint skips root-only steps).
  - `plugin deps persist`: `docker exec C python -m pip install tabulate` → `/data/python/lib/python3.12/site-packages/tabulate` exists; remove container, new container on the same volume → `python -c "import tabulate"` succeeds.
  - `no recursive chown`: pre-create a file in the volume owned by 4321 while `/data` itself is 1000 → after start the file is still 4321.

- [ ] **Step 2: Run it** `W: bash docker/tests/entrypoint.sh rotorhazard:runtime` → `puid`, `puid restart idempotent`, `bind mount created by docker`, `extra gids` FAIL; `user flag` and `plugin deps persist` may already PASS.

- [ ] **Step 3: Implement spec 5.3 steps 1–3** in `docker/entrypoint.sh`: `groupmod -o -g`/`usermod -o -u` only when the current IDs differ; chown `/data` recursively only if `/data` itself is not owned by PUID:PGID, else just `/data` and `/data/python`; collect GIDs of `/dev/ttyUSB*` and `/dev/ttyACM*` (skip missing globs, never GID 0) plus `RH_EXTRA_GIDS` plus 20, de-duplicated, pass as `setpriv --groups`.

- [ ] **Step 4: Run** `W: docker build -f docker/Dockerfile --target runtime -t rotorhazard:runtime . && bash docker/tests/entrypoint.sh rotorhazard:runtime && bash docker/tests/smoke.sh rotorhazard:runtime` → all PASS. `W: shellcheck docker/entrypoint.sh docker/tests/entrypoint.sh` → clean.

- [ ] **Step 5: Commit** `git commit -m "Docker: PUID/PGID, device groups and persistent plugin dependencies"`.

---

### Task 3: `runtime-java` and `dev` stages

**Files:**
- Modify: `docker/Dockerfile`

**Interfaces:**
- Produces: targets `runtime-java` (`FROM runtime` + `openjdk-17-jre-headless`) and `dev` (`FROM runtime-java` + `git`, `pylint`, `debugpy`); `dev` is the last stage. If `openjdk-17-jre-headless` is unavailable in bookworm for arm64, use `default-jre-headless` and note it in the commit.

- [ ] **Step 1: Run smoke for the missing targets** `W: docker build -f docker/Dockerfile --target runtime-java -t rotorhazard:java .` → fails (unknown target).
- [ ] **Step 2: Add both stages** per spec 5.2. `pylint`/`debugpy` installed with `PIP_USER=0` so they land in the image, not in `/data/python`.
- [ ] **Step 3: Verify**
  `W: docker build -f docker/Dockerfile --target runtime-java -t rotorhazard:java . && bash docker/tests/smoke.sh rotorhazard:java --java` → all PASS.
  `W: docker build -f docker/Dockerfile --target dev -t rotorhazard:dev . && bash docker/tests/smoke.sh rotorhazard:dev --java --dev` → all PASS.
  `W: docker run --rm rotorhazard:runtime sh -c 'command -v java || echo nojava'` → `nojava`; a running `runtime` container's logs contain `Unable to find java` and HTTP still works (covered by Task 1 smoke).
  `W: docker build -f docker/Dockerfile -t rotorhazard:default .` produces the `dev` image (last stage) – documented, CI always passes `--target`.
- [ ] **Step 4: Commit** `git commit -m "Docker: Java (IMDTabler) and dev image targets"`.

---

### Task 4: Compose files

**Files:**
- Create: `docker/compose.yaml`, `docker/compose.dev.yaml`

**Interfaces:**
- Produces: project names `rotorhazard` (users) and `rotorhazard-dev` (dev); service name `rotorhazard` in both; container names `rotorhazard` and `rotorhazard-dev`; volumes `rh-data` and `rh-dev-data` (→ `rotorhazard_rh-data`, `rotorhazard-dev_rh-dev-data`); dev ports `5000`, `5678`.

- [ ] **Step 1: Write `docker/compose.yaml`** exactly per spec 5.5, plus top-level `name: rotorhazard` and `environment` entries `PUID=${PUID:-1000}`, `PGID=${PGID:-1000}`, `RH_EXTRA_GIDS=${RH_EXTRA_GIDS:-}`, `RH_MOCK_NODES=${RH_MOCK_NODES:-}`.
- [ ] **Step 2: Write `docker/compose.dev.yaml`** per spec 5.6 with `name: rotorhazard-dev`, `image: rotorhazard:dev`, same env entries, same device settings, volume `..:/app`.
- [ ] **Step 3: Validate** `W: docker compose -f docker/compose.yaml config -q && docker compose -f docker/compose.dev.yaml config -q` → no output, exit 0.
- [ ] **Step 4: End-user flow with a local image**
  `W: docker tag rotorhazard:runtime rotorhazard-local:test && RH_IMAGE=rotorhazard-local RH_VERSION=test RH_MOCK_NODES=2 docker compose -f docker/compose.yaml up -d` → `curl -fsS localhost:5000/` returns HTML within 90 s; `docker compose -f docker/compose.yaml down` (volume kept: `docker volume ls` shows `rotorhazard_rh-data`); then `down -v`.
- [ ] **Step 5: Dev flow** `W: RH_MOCK_NODES=2 docker compose -f docker/compose.dev.yaml up -d --build` → HTTP 200; `docker compose -f docker/compose.dev.yaml exec rotorhazard ls /app/src/server/server.py` works (bind mount); `exec rotorhazard sh -c 'cd /app/src/tests && python -m unittest discover'` runs (record result; if failures appear, rerun once on `main`'s code to confirm they are pre-existing – do not fix them); `down`.
- [ ] **Step 6: Commit** `git commit -m "Docker: compose files for users and developers"`.

---

### Task 5: `rh-dev.sh`

**Files:**
- Create: `docker/scripts/rh-dev.sh`, `docker/tests/test_rh-dev.sh`

**Interfaces:**
- Consumes: `docker/compose.dev.yaml` (project `rotorhazard-dev`, service `rotorhazard`, volume `rotorhazard-dev_rh-dev-data`).
- Produces: CLI `rh-dev.sh <command> [args]` with commands from spec 5.14 table; exit 2 + usage on unknown command; `RH_DEV_DRY_RUN=1` prints every docker command as `+ <command>` instead of running it; repo root resolved from the script's real path (`readlink -f`), so it works from any cwd and via symlink. `up --mock N` sets `RH_MOCK_NODES=N` for that invocation. `lint` runs `pylint --errors-only /app/src/interface/*.py /app/src/server/*.py /app/src/server/util/*.py` in the container. `reset-data` asks `Delete dev data volume? [y/N]`.

- [ ] **Step 1: Write `docker/tests/test_rh-dev.sh`** asserting (with `RH_DEV_DRY_RUN=1`):
  - `up --mock 3` output contains `RH_MOCK_NODES=3` and `docker compose -f <repo>/docker/compose.dev.yaml up -d --build`, and prints `http://localhost:5000`.
  - `down` → `… down` without `-v`.
  - `test` → `… exec rotorhazard sh -c 'cd /app/src/tests && python -m unittest discover'` (or `run --rm` if not running – dry-run uses `exec`).
  - `bogus` → exit 2, stdout/stderr contains `Usage:`.
  - Run from `/tmp` and via a symlink in `/tmp` → same `<repo>` path.
  - `reset-data` with stdin `n` → no `docker volume rm`; with `y` → `+ docker volume rm rotorhazard-dev_rh-dev-data` (after `down`).
- [ ] **Step 2: Run** `W: bash docker/tests/test_rh-dev.sh` → FAIL (script missing).
- [ ] **Step 3: Implement `docker/scripts/rh-dev.sh`** (`#!/usr/bin/env bash`, `set -euo pipefail`, executable bit: `git update-index --chmod=+x`).
- [ ] **Step 4: Verify** `W: bash docker/tests/test_rh-dev.sh` → all PASS; `W: shellcheck docker/scripts/rh-dev.sh docker/tests/test_rh-dev.sh` clean; real run `W: docker/scripts/rh-dev.sh up --mock 2 && docker/scripts/rh-dev.sh status && docker/scripts/rh-dev.sh lint; docker/scripts/rh-dev.sh down` → server reachable, status shows running + URL, lint runs.
- [ ] **Step 5: Commit** `git commit -m "Docker: rh-dev.sh developer helper"`.

---

### Task 6: Windows helper `rh-dev.ps1` / `rh-dev.cmd`

**Files:**
- Create: `docker/scripts/rh-dev.ps1`, `docker/scripts/rh-dev.cmd`, `docker/tests/rh-dev.Tests.ps1`
- Modify: `.gitignore` (add `docker/scripts/rh-dev.local.ps1`)

**Interfaces:**
- Consumes: `docker/scripts/rh-dev.sh` CLI (Task 5).
- Produces (PowerShell 5.1-compatible; script is dot-sourceable – main logic only runs when not dot-sourced):
  - `Resolve-RhWslTarget([string]$Path) -> [pscustomobject]@{ Distro; LinuxPath }` or `$null`. Accepts `\\wsl.localhost\<distro>\…`, `\\wsl$\<distro>\…`, and the `Microsoft.PowerShell.Core\FileSystem::` prefix; falls back to `$env:RH_WSL_DISTRO` + `$env:RH_WSL_REPO` (also loadable from `rh-dev.local.ps1`); returns `$null` for a drive path without those vars.
  - `ConvertFrom-UsbipdList([string[]]$Lines) -> objects @{ BusId; VidPid; Device; State; IsTimer }` – parses only the `Connected:` section; `IsTimer` true for VIDs `1a86`, `10c4`, `0403`, `0483`, `2341`.
  - `Get-RhWslInvocation($Target, [string[]]$Arguments) -> [string[]]` = `wsl.exe -d <Distro> --cd <LinuxPath> -- docker/scripts/rh-dev.sh <args>`.
  - CLI: `rh-dev <rh-dev.sh command…>` (passthrough), `setup`, `usb list|attach [busid]|detach [busid]`, `open`, `-DryRun` switch prints the wsl/usbipd command lines instead of running them.

- [ ] **Step 1: Write `docker/tests/rh-dev.Tests.ps1`** (Pester 3 syntax, dot-sources the script):
  - `\\wsl.localhost\Ubuntu-26.04\home\scordo\RotorHazard` → Distro `Ubuntu-26.04`, LinuxPath `/home/scordo/RotorHazard`.
  - `\\wsl$\Ubuntu\home\a b\RH` → LinuxPath `/home/a b/RH`.
  - `Microsoft.PowerShell.Core\FileSystem::\\wsl.localhost\Ubuntu\x` → Distro `Ubuntu`, LinuxPath `/x`.
  - `C:\P\RotorHazard` without env vars → `$null`; with `RH_WSL_DISTRO=Ubuntu-26.04`, `RH_WSL_REPO=/home/scordo/RH` → those values.
  - `ConvertFrom-UsbipdList` on a fixture with a `Connected:` section (`1-4    1a86:7523  USB-SERIAL CH340 (COM5)                Not shared`, `2-1    046d:c52b  Logitech USB Input Device, USB-Eingabegerät   Not shared`, `3-2    0483:5740  USB Serial Device (COM7)   Attached`) followed by `Persisted:` lines → 3 objects, `IsTimer` = true, false, true; `State` = `Not shared`, `Not shared`, `Attached`.
  - `Get-RhWslInvocation` with args `up`,`--mock`,`2` → `wsl.exe`,`-d`,`Ubuntu-26.04`,`--cd`,`/home/scordo/RotorHazard`,`--`,`docker/scripts/rh-dev.sh`,`up`,`--mock`,`2`.
- [ ] **Step 2: Run** `P:` → failures (script missing).
- [ ] **Step 3: Implement `rh-dev.ps1`**: functions above; `setup` per spec 5.14 – each step prints what it checks, asks `[y/N]` before changing anything (`wsl --install -d Ubuntu-26.04` only if no distro; `/etc/wsl.conf` systemd; `apt-get install docker.io docker-compose-v2 docker-buildx` + `usermod -aG docker` via `wsl -u root`; `winget install --exact dorssel.usbipd-win`), skips steps already satisfied; `usb attach` runs `usbipd bind --busid X` via `Start-Process -Verb RunAs` only if `State` is `Not shared`, then `Start-Process -WindowStyle Hidden usbipd 'attach --wsl --busid X --auto-attach'` and stores the PID in `$env:TEMP\rh-dev-usb-<busid>.pid`; `usb detach` stops that PID and runs `usbipd detach --busid X`; drive-path warning per spec. `rh-dev.cmd`: `@powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0rh-dev.ps1" %*`.
- [ ] **Step 4: Verify** `P:` → all pass; `powershell.exe -NoProfile -File docker/scripts/rh-dev.ps1 -DryRun up --mock 2` from the Windows repo with `RH_WSL_DISTRO`/`RH_WSL_REPO` set prints the expected `wsl.exe` line; without them prints the drive-path warning and exits non-zero. Real passthrough: `$env:RH_WSL_DISTRO='Ubuntu-26.04'; $env:RH_WSL_REPO='/mnt/c/P/Remote/github/RotorHazard'; docker\scripts\rh-dev.cmd up --mock 2` → server reachable at `http://localhost:5000` from Windows; `docker\scripts\rh-dev.cmd down`.
- [ ] **Step 5: Ask the user** to run `docker\scripts\rh-dev.cmd setup` once interactively (installs usbipd-win; everything else should report "already done") and `docker\scripts\rh-dev.cmd usb list`. Record the result.
- [ ] **Step 6: Commit** `git commit -m "Docker: Windows/WSL2 helper rh-dev.ps1"`.

---

### Task 7: VS Code Dev Container

**Files:**
- Create: `.devcontainer/devcontainer.json`

**Interfaces:**
- Consumes: `docker/compose.dev.yaml` (service `rotorhazard`). `.vscode/` is git-ignored (`.gitignore:10`), so launch configurations go into `customizations.vscode.settings.launch` (VS Code reads `launch` from settings).

- [ ] **Step 1: Write `devcontainer.json`** per spec 5.7: `name`, `dockerComposeFile`, `service`, `workspaceFolder: /app`, `overrideCommand: true`, `remoteUser: rotorhazard`, `forwardPorts: [5000]`, extensions `ms-python.python`, `ms-python.debugpy`, `ms-python.pylint`, `settings.launch` with configurations "RotorHazard server" and "RotorHazard server (mock nodes)" (`type: debugpy`, `program: /app/src/server/server.py`, `cwd: /app/src/server`, `env: {RH_DATA_DIR: /data}`, second one `args: ["--mock-nodes","4"]`).
- [ ] **Step 2: Verify** `W: python3 -c "import json,re,sys; json.loads(re.sub(r'^\s*//.*$','',open('.devcontainer/devcontainer.json').read(),flags=re.M))"` → no error; `W: docker compose -f docker/compose.dev.yaml config -q` still clean.
- [ ] **Step 3: Ask the user** to open the repo in VS Code via "Dev Containers: Reopen in Container" (WSL), start "RotorHazard server (mock nodes)", hit a breakpoint in `server.py` route `/`. Record the result.
- [ ] **Step 4: Commit** `git commit -m "Docker: VS Code dev container"`.

---

### Task 8: CI workflow

**Files:**
- Create: `.github/workflows/docker.yml`

**Interfaces:**
- Consumes: targets `runtime`, `runtime-java`; `docker/tests/smoke.sh`, `docker/tests/entrypoint.sh`.

- [ ] **Step 1: Write the workflow** per spec 5.8: matrix `variant: [{target: runtime, suffix: ""}, {target: runtime-java, suffix: "-java"}]`; job steps: checkout → setup-qemu → setup-buildx → metadata (image `ghcr.io/${{ github.repository_owner }}` lowercased + `/rotorhazard`, `flavor: latest=false, suffix=${{ matrix.variant.suffix }}`, tags: `type=semver,pattern={{version}}`; `type=semver,pattern={{major}}.{{minor}}` and `type=raw,value=latest` both enabled only for `v*` tags without `-`; `type=raw,value=dev` and `type=sha,prefix=sha-` enabled for `refs/heads/main` when `vars.PUBLISH_DEV != 'false'`, and `type=sha` also for `workflow_dispatch` with input `publish: true`) → build amd64 with `load: true` → `bash docker/tests/smoke.sh <local tag>` (+`--java` for the java variant) → `bash docker/tests/entrypoint.sh` (runtime variant only) → login GHCR (skip on `pull_request`) → build multi-arch `linux/amd64,linux/arm64`, `push: true` only when the event publishes (tags, main with PUBLISH_DEV, dispatch with publish), cache `type=gha,scope=${{ matrix.variant.target }}`; OCI build args `RH_VERSION`, `RH_SOURCE`. `permissions: contents: read, packages: write`. Use the current major versions of the official `actions/*` and `docker/*` actions at implementation time.
- [ ] **Step 2: Lint** `W: docker run --rm -v "$PWD":/repo -w /repo rhysd/actionlint:latest -color` → no findings.
- [ ] **Step 3: Ask the user for permission to push** the branch to `origin` (`Scordo/RotorHazard`). After approval: `git push -u origin docker-support`, trigger `gh workflow run docker.yml --ref docker-support -f publish=true`, watch with `gh run watch`. Expected: both matrix jobs green, `ghcr.io/scordo/rotorhazard:sha-<short>` and `…:sha-<short>-java` exist for amd64 and arm64 (`docker buildx imagetools inspect`).
- [ ] **Step 4: Commit** `git commit -m "Docker: GitHub Actions build, test and publish workflow"` (before Step 3's push).

---

### Task 9: Documentation

**Files:**
- Create: `doc/Docker.md`, `doc/Docker Development.md`, `docker/README.md`
- Modify: `doc/README.md`, `doc/Software Setup.md`, `doc/Development.md` (one link line each, in the existing style)

**Interfaces:**
- Consumes: every name above (env vars, commands, tags, volume names, script commands). The docs must use them verbatim.

- [ ] **Step 1: Write `doc/Docker.md`** with the ten sections of spec 5.10 in that order, TOC at the top, each step a copy-pasteable command followed by expected output. Include the env-var table (`RH_IMAGE`, `RH_VERSION`, `TZ`, `PUID`, `PGID`, `RH_EXTRA_GIDS`, `RH_MOCK_NODES` – default + example), the variant tags (`latest`, `X.Y.Z`, `X.Y`, `latest-java`, `dev`), backup/restore commands for volume `rotorhazard_rh-data`, migration from `~/rh-data`, and the interim note from spec 5.13 (local build until the first published release).
- [ ] **Step 2: Write `doc/Docker Development.md`** with the eight sections of spec 5.10, using `rh-dev` commands for every daily task and showing the raw `docker compose` equivalent once.
- [ ] **Step 3: Write `docker/README.md`** (two short paragraphs + links) and add the link lines to the three existing docs.
- [ ] **Step 4: Verify links** – a one-off check: every relative `](…)` target in the new/changed docs exists (`W: grep -o '](\([^)#]*\)' … | …` or a small python snippet); every command in the quick start of `doc/Docker.md` executed literally in WSL with `RH_IMAGE=rotorhazard-local RH_VERSION=test` works (download step replaced by `cp docker/compose.yaml`).
- [ ] **Step 5: Commit** `git commit -m "Docker: user and developer documentation"`.

---

### Task 10: Final verification against spec section 6

- [ ] **Step 1:** Re-run everything on a clean Docker state (`W: docker system prune -af --volumes` – ask the user first, it deletes all local images/volumes in the WSL Docker): build all targets, `smoke.sh` for runtime/java/dev, `entrypoint.sh`, `test_rh-dev.sh`, `P:` → all green.
- [ ] **Step 2: Real USB node** (user, with hardware): `rh-dev usb attach`, `rh-dev up`, port appears in the UI incl. `/dev/serial/by-id/…`, nodes detected; unplug/replug → node returns without container restart. Record result.
- [ ] **Step 3: IMDTabler** in the `dev` container: IMD page in the UI shows results.
- [ ] **Step 4:** Walk through spec section 6 bullet by bullet and tick each with evidence (command + result) in the PR description draft; list anything not verified (e.g. Pi) explicitly.
- [ ] **Step 5:** Prepare the upstream PR branch without `docs/superpowers/**` (e.g. a separate branch with that directory removed in one commit) and draft the PR description incl. the maintainer checklist from spec 5.13. Do not open the PR without the user's go-ahead.
