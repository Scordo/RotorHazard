# Docker Support for RotorHazard – Design

Date: 2026-11-17 · Branch: `docker-support`

## 1. Intent and why

Installing RotorHazard on systems that are **not a Raspberry Pi** (e.g. a small Ubuntu server) regularly
causes trouble: dependencies get rebuilt from source, and in the end the versions don't fit together.
Docker should eliminate this: a reproducible environment with fixed versions that runs the same everywhere.

Two audiences, one shared base:

- **End users:** pull a ready-made image from a registry and start it with `docker compose up -d`.
  No local Python, no pip, no build.
- **Developers:** work with the same image (plus dev tools), source code bind-mounted; either via Compose
  in the terminal or via a VS Code Dev Container. The requester's reference setup: Windows with
  **Docker Engine installed directly in WSL2** (no Docker Desktop).

## 2. Goals, non-goals, anti-goals

**Goals**
- A production image for `linux/amd64` and `linux/arm64`, published to GHCR via GitHub Actions.
- USB nodes (Arduino/STM32 via USB serial) work inside the container, including unplug/replug while
  running and stable `/dev/serial/by-id/…` names – without `--privileged`.
- Data (config, DB, logs, plugins, plugin dependencies) lives exclusively in the data volume and survives
  image updates.
- Dev setup via Compose **and** a VS Code Dev Container, both on the same Dockerfile target.
- Mock nodes for development without hardware, switchable via an environment variable.
- Documentation for end users (Linux server) and developers (WSL2 incl. `usbipd-win`).

**Non-goals**
- Raspberry Pi hardware inside the container (GPIO, I2C nodes, sensors, WS281x LEDs, shutdown button).
  On the Pi, `rh_install.sh` remains the recommended path. The arm64 image *runs* on a Pi, but only with
  USB nodes and without Pi-specific hardware.
- NuclearHazard-specific images, host provisioning, Wi-Fi hotspot.
- USB passthrough on macOS/Docker Desktop, Windows containers.
- Auto-update (Watchtower etc.), Kubernetes, reverse proxy/HTTPS.
- Any reference to PR RotorHazard/RotorHazard#1115 – no link, no credits.

**Anti-goals** (counts as failure even if it technically works)
- The image builds or downloads packages itself at startup or after an update.
- Plugin dependencies or data are missing after an image update.
- End users have to edit Compose files for USB nodes to work (standard Ubuntu/Debian).
- The container runs as root.

## 3. Constraints from the existing code (main @ 2d1c9e21)

- **Data directory:** `server.py --data <dir>` or environment variable `RH_DATA_DIR`
  ([server.py:80-103](../../../src/server/server.py)). The directory must exist. Afterwards the server
  calls `os.chdir(DATA_DIR)` (server.py:152) – so logs (`logs/`), `config.json`, `database.db` and
  `plugins/` automatically end up in the data volume.
- **Program directory layout** must be preserved, because files are read relative to `PROGRAM_DIR`
  (= `src/server`): `../interface` (hardware interfaces), `../../doc` (doc pages in the UI,
  server.py:758/780), `../../firmware/…` (node firmware for release versions, server.py:376). In the image
  therefore `/app/src/server`, `/app/src/interface`, `/app/doc`, `/app/firmware`.
- **Requirements:** `src/server/reqsNonPi.txt` (non-Pi). `check_requirements()` picks this file
  automatically when no Pi is detected and warns about version mismatches.
- **Plugin installer** calls `sys.executable -m pip install <deps>`
  ([plugin_installation.py:492](../../../src/server/util/plugin_installation.py)). No code change needed
  if pip is redirected via environment into a directory inside the data volume (see 5.4).
- **Serial ports:** `GENERAL.SERIAL_PORTS` in `config.json`; the port picker in the UI lists ports via
  pyserial and recommends `/dev/serial/by-id/…` ([SerialPortInfo.py](../../../src/server/util/SerialPortInfo.py));
  ports can be added/removed at runtime.
- **Mock nodes:** `server.py --mock-nodes N`.
- **HTTP port:** default 5000 (`GENERAL.HTTP_PORT`), server binds to `0.0.0.0`.
- **Tests:** `python -m unittest discover` in `src/tests` (no extra test requirements).
  Lint: `pylint --errors-only` (see `tools/pylintchk.bat`).
- **Release tags** look like `v4.5.1`, `v4.5.0-beta.2`.
- `.github/` exists (`FUNDING.yml`, `ISSUE_TEMPLATE/`), but there is **no** `.github/workflows/`.
- **Pi detection:** `RHUtils.idAndLogSystemInfo()` sets `Is_sys_raspberry_pi_flag` based solely on
  `/proc/device-tree/model`. Without `--privileged`, Docker masks `/sys/firmware` by default (the target of
  the `/proc/device-tree` symlink) – so inside the container a Pi is detected as non-Pi (see 5.11).

## 4. Approaches

| | Approach | Trade-off |
|---|---|---|
| **A** | One multi-stage Dockerfile (targets `runtime`, `dev`), `compose.yaml` for end users, `compose.dev.yaml` for dev, GitHub Actions workflow → GHCR | Dev and production on an identical base; editor-agnostic. No IDE integration. |
| **B** | Like A, plus a VS Code Dev Container (`.devcontainer/`) | Debugger/extensions inside the container, one-click setup. A second config, tied to VS Code. |
| C | One image without a dev target, dev only via Compose override | Fewest files, but dev tools are missing in the container → local Python needed again. |

**Chosen: A + B.** B builds on A (same Dockerfile target `dev`, same `compose.dev.yaml`), so there is no
second environment, only an additional entry point. C was rejected because it doesn't solve the core
problem (local Python) for developers.

Decided by the requester: distribution as a **ready-made image from a registry** (GHCR via CI), with local
build remaining as a fallback; dev on Windows via **Docker Engine in WSL2**; plugin dependencies go into the
data volume via `PIP_USER`/`PYTHONUSERBASE`.

## 5. Design

### 5.1 Files

```
.dockerignore                       # build context = repo root
docker/
  Dockerfile                        # stages: builder, runtime, runtime-java, dev
  entrypoint.sh                     # permissions, groups, privilege drop, mock nodes
  compose.yaml                      # end users (GHCR image)
  compose.dev.yaml                  # developers (local build, bind mount)
  README.md                         # short pointer to the docs below
  scripts/
    rh-dev.sh                       # dev helper inside WSL2/Linux (wraps docker compose)
    rh-dev.ps1                      # dev helper on Windows (WSL2 + usbipd), delegates to rh-dev.sh
    rh-dev.cmd                      # wrapper so rh-dev.ps1 runs regardless of execution policy
.devcontainer/
  devcontainer.json                 # uses docker/compose.dev.yaml
.vscode/launch.json                 # (only if not already present) debugpy launch for server.py
.github/workflows/docker.yml        # build, smoke test, push to GHCR
doc/Docker.md                       # end-user guide (English)
doc/Docker Development.md           # developer guide (English)
```
`doc/Docker.md` is linked from `doc/README.md` and `doc/Software Setup.md`; `doc/Docker Development.md`
from `doc/README.md`, `doc/Development.md` and `doc/Docker.md`.

### 5.2 Dockerfile (`docker/Dockerfile`)

- Base: `python:3.12-slim-bookworm`, version via `ARG PYTHON_VERSION=3.12` (minor fixed; patch follows the tag).
- **Stage `builder`:** `build-essential`, `libffi-dev`; builds wheels for `src/server/reqsNonPi.txt` into
  `/wheels` (`pip wheel`). The runtime image thus needs no compilers, and wheels missing on arm64 are built
  once during the image build.
- **Stage `runtime`:**
  - `pip install --no-index --find-links=/wheels -r reqsNonPi.txt` (system-wide, no venv – otherwise
    `PIP_USER` doesn't work).
  - Packages: `util-linux` (for `setpriv`), `tini` as init (signal forwarding, zombie reaping, clean DB
    shutdown on `docker stop`).
  - User `rotorhazard` (UID/GID 1000), member of `dialout` (GID 20 on Debian/Ubuntu).
  - Copies `src/server`, `src/interface`, `doc`, `firmware` to `/app/…`; `WORKDIR /app/src/server`.
  - `/data` created, owned by 1000:1000, `VOLUME /data`, `EXPOSE 5000`.
  - ENV: `RH_DATA_DIR=/data`, `PIP_USER=1`, `PYTHONUSERBASE=/data/python`, `PYTHONUNBUFFERED=1`,
    `PIP_DISABLE_PIP_VERSION_CHECK=1`.
  - OCI labels (source, version, licenses) via build args from CI.
  - `ENTRYPOINT ["tini", "--", "/usr/local/bin/entrypoint.sh"]`, `CMD ["python", "server.py"]`.
  - No `HEALTHCHECK` (the port can be changed in `config.json`; a hard-wired check would then report wrongly).
- **Stage `runtime-java`** (`FROM runtime`): additionally `openjdk-17-jre-headless` (`--no-install-recommends`).
  This enables the IMDTabler feature: at startup the server checks `java -version` and
  `java -jar static/IMDTabler.jar -v` (server.py:4845ff) and then uses it for the IMD page and ratings
  (RHUI.py:1925ff). No code change. Published with a `-java` tag suffix (see 5.8); everything else
  (user, entrypoint, volume) is identical to `runtime`.
- **Stage `dev`** (`FROM runtime-java`): additionally `git`, `pylint`, `debugpy`. Same user, same entrypoint.
  Based on `runtime-java` so developers can test every feature, including IMDTabler. Source code is
  bind-mounted over `/app` at runtime.

### 5.3 Entrypoint (`docker/entrypoint.sh`)

Starts as root, then drops privileges:
1. `PUID`/`PGID` (default 1000) – adjusts UID/GID of `rotorhazard` if different (for bind mounts whose
   owner is not 1000).
2. Creates `/data` and `/data/python` if needed and fixes the owner of `/data` (only if it isn't already
   correct – no recursive `chown` over large data on every start; recursive only when the root directory
   has the wrong owner).
3. Determines the group IDs of existing `/dev/ttyUSB*`/`/dev/ttyACM*` devices and adds them, in addition
   to 20, as supplementary groups (for distros with a different `dialout` GID); optionally `RH_EXTRA_GIDS`
   (comma-separated).
4. `RH_MOCK_NODES=N` → appends `--mock-nodes N` to the command line.
5. `exec setpriv --reuid … --regid … --groups … -- "$@"`.
6. If the container is already started as non-root (`user:` in Compose), steps 1–3 are skipped and it
   runs `exec "$@"` directly.

### 5.4 Plugin dependencies in the data volume

`PIP_USER=1` + `PYTHONUSERBASE=/data/python` → the plugin installer installs into
`/data/python/lib/python3.12/site-packages`; Python adds this user-site directory to `sys.path`
automatically. After an image update the packages are still there.

Known limitations (document, don't solve):
- The user site comes **before** the image packages in `sys.path`. If a plugin pulls in a different version
  of a core package, it shadows the image version. `check_requirements()` already warns about this in the
  UI. Remedy noted in the docs: delete `/data/python` and reinstall plugins.
- When the image's Python minor version changes, old packages live under a different path and are ignored
  → reinstall plugins. Mention it in the image release notes when this happens.

### 5.5 End-user Compose (`docker/compose.yaml`)

```yaml
services:
  rotorhazard:
    image: ${RH_IMAGE:-ghcr.io/rotorhazard/rotorhazard}:${RH_VERSION:-latest}
    container_name: rotorhazard
    restart: unless-stopped
    ports: ["5000:5000"]
    volumes:
      - rh-data:/data
      - /dev:/dev                    # USB nodes incl. hotplug
      - /run/udev:/run/udev:ro       # by-id names / udev info for pyserial
    device_cgroup_rules:
      - "c 188:* rmw"                # ttyUSB* (CH340, CP210x, FTDI)
      - "c 166:* rmw"                # ttyACM* (CDC-ACM, e.g. STM32/Arduino native USB)
    environment:
      - TZ=${TZ:-Etc/UTC}
volumes:
  rh-data:
```
`RH_IMAGE`/`RH_VERSION` can be set via a `.env` file next to the Compose file – e.g. for a fork image or a
pinned version. For the Java/IMDTabler variant users set `RH_VERSION=latest-java` (or e.g. `4.6.0-java`).
The docs show the bind-mount variant (`./rh-data:/data`, with `PUID`/`PGID` if needed) for
users who want to see their data as a folder. Usage: download the file, `docker compose up -d`; update:
`docker compose pull && docker compose up -d`.

### 5.6 Dev Compose (`docker/compose.dev.yaml`)

- `build: { context: .., dockerfile: docker/Dockerfile, target: dev }`, image name `rotorhazard:dev`.
- Volumes: `..:/app` (source code), `rh-dev-data:/data`, `/dev:/dev`, `/run/udev:/run/udev:ro`;
  same `device_cgroup_rules` as 5.5.
- Ports `5000:5000` and `5678:5678` (debugpy).
- `environment: RH_MOCK_NODES=${RH_MOCK_NODES:-}` – empty = off.
- Default `command`: start the server. Code change → `docker compose -f docker/compose.dev.yaml restart`.
  Rebuild only when requirements change.
- Tests/lint via `docker compose -f docker/compose.dev.yaml run --rm rotorhazard python -m unittest discover -s /app/src/tests`
  or `pylint --errors-only …`. Short commands in the docs.

### 5.7 VS Code Dev Container (`.devcontainer/devcontainer.json`)

- `dockerComposeFile: ["../docker/compose.dev.yaml"]`, `service: rotorhazard`, `workspaceFolder: /app`.
- `overrideCommand: true` (container keeps running with `sleep infinity`; the server is started via the
  debugger or terminal), `remoteUser: rotorhazard`.
- Extensions: `ms-python.python`, `ms-python.debugpy`, `ms-python.pylint`.
- `.vscode/launch.json`: configuration "RotorHazard server" (`program: src/server/server.py`,
  `cwd: src/server`, env `RH_DATA_DIR=/data`) and "RotorHazard server (mock nodes)" with `--mock-nodes 4`.
  Note: `overrideCommand` does not bypass the entrypoint – it still runs and then executes `sleep infinity`.
- WSL2: Dev Containers works with Docker Engine in WSL; the docs mention the setting
  "Dev › Containers: Execute In WSL" or opening the folder from within WSL.

### 5.8 CI (`.github/workflows/docker.yml`)

- Triggers: `push` to `main`, `push` of tags `v*`, `pull_request` (build + smoke test only, no push),
  `workflow_dispatch`.
- Image name: `ghcr.io/${{ github.repository_owner }}/rotorhazard` (lowercased) → works upstream and in forks.
- Steps: checkout → `setup-qemu` → `setup-buildx` → `metadata-action` → GHCR login (`GITHUB_TOKEN`,
  `packages: write`) → build amd64 + smoke test → multi-arch build & push (`linux/amd64,linux/arm64`,
  GHA cache).
- Tags: `vX.Y.Z` → `X.Y.Z`, `X.Y`, `latest`; pre-releases (`-beta.N`) → exact tag only, **no** `latest`;
  `main` → `dev` and `sha-<short>` (can be disabled via the workflow variable `PUBLISH_DEV`, default on).
- **Java variant:** the workflow builds the targets `runtime` and `runtime-java` (e.g. as a matrix). The
  Java variant gets the same tags with the suffix `-java`: `X.Y.Z-java`, `X.Y-java`, `latest-java`,
  `dev-java`, `sha-<short>-java` (via `metadata-action` `flavor: suffix=-java`). Pre-release rule is the
  same: no `latest-java` for `-beta.N`.
- **Smoke test** (both variants): start the container with `RH_MOCK_NODES=2`, wait for HTTP 200 on `/`
  (timeout ~60 s), additionally check `docker exec … id` (not running as root), print logs on failure.
  For `runtime-java` additionally `docker exec … java -jar /app/src/server/static/IMDTabler.jar -v`
  succeeds.

### 5.9 `.dockerignore`

Exclude: `.git`, `**/__pycache__`, `**/*.pyc`, `*.db*`, `logs`, `**/config.json`, `datapath.ini`,
`venv`/`.venv`, `docs/superpowers`, `tools/rhPortableFiles`, `src/node` (Arduino source, not needed at
runtime). Do **not** exclude images under `doc/img` (doc pages in the UI).

### 5.10 Documentation

Good documentation is an explicit requirement. Both guides are written for someone who has never used
Docker: every step is a copy-pasteable command, followed by what you should see. Style matches the existing
`doc/*.md` files (English, headings with anchors, a table of contents at the top).

**`doc/Docker.md` – end-user guide (Linux server)**
1. What you get / when to use Docker vs. `rh_install.sh` (Pi hardware → `rh_install.sh`; image variants
   with and without Java/IMDTabler).
2. Quick start (5 commands: install Docker, create folder, download `compose.yaml`, `docker compose up -d`,
   open `http://<server-ip>:5000`).
3. Installing Docker on Ubuntu/Debian (official apt repo, add user to `docker` group, verify).
4. Configuration: table of all variables (`RH_IMAGE`, `RH_VERSION`, `TZ`, `PUID`, `PGID`, `RH_EXTRA_GIDS`,
   `RH_MOCK_NODES`) with defaults and examples; `.env` file; changing the published port.
5. Connecting USB timer nodes: plug in, pick the `by-id` port in the UI, hotplug behaviour, verifying with
   `ls -l /dev/serial/by-id`.
6. Data: where it lives, bind-mount variant, backup and restore (volume → tar and back), moving an existing
   native `~/rh-data` into the container.
7. Updating, pinning a version, rolling back.
8. Plugins and their dependencies (`/data/python`, limitations from 5.4).
9. Troubleshooting: port already in use, `Permission denied` on `/dev/ttyUSB0`, node not detected, container
   restarts in a loop (`docker compose logs`), package mismatch warning, starting with `--privileged`
   (don't).
10. Uninstall.

**`doc/Docker Development.md` – developer guide**
1. Overview: Compose workflow vs. VS Code Dev Container, both on the `dev` image.
2. Windows + WSL2 setup, step by step: install WSL2 + Ubuntu, enable systemd, install Docker Engine in WSL
   (not Docker Desktop), clone the repo **into the WSL filesystem** (not `/mnt/c`, with the reason) –
   with `rh-dev setup` (5.14) as the shortcut for all of this.
3. Linux setup (short).
4. Daily workflow with the helper scripts: start/stop/restart, logs, shell, tests, lint, rebuild after
   requirement changes, mock nodes.
5. USB nodes from Windows: `usbipd-win`, one-time bind, attach/auto-attach, detach – via `rh-dev usb`.
6. VS Code Dev Container: open, debug the server (launch configs), run tests.
7. Building the production images locally (`runtime`, `runtime-java`) and the CI/tag scheme.
8. Troubleshooting: slow file access (repo under `/mnt/c`), `docker: permission denied` (group membership,
   re-login WSL), USB device not visible in WSL, port 5000 already used on Windows, line endings
   (`.sh` files must stay LF – see 5.14).

`docker/README.md` is a short pointer: one paragraph each for users and developers, linking to both guides.

### 5.14 Developer helper scripts (Windows/WSL2 and Linux)

Goal: a developer on Windows can do everything from a normal PowerShell/cmd window in the repo, without
remembering `wsl`, `docker compose -f …` or `usbipd` syntax.

**`docker/scripts/rh-dev.sh`** (bash, runs inside WSL2 or on any Linux; works from any current directory,
locates the repo relative to the script). Subcommands:

| Command | Does |
|---|---|
| `up [--mock N]` | build if needed, start dev container in background, print the URL |
| `down` | stop and remove the container (volume kept) |
| `restart` | restart after code changes |
| `logs [-f]` | show server logs |
| `shell` | open a bash shell in the container |
| `test` | run `python -m unittest discover` in the container |
| `lint` | run `pylint --errors-only` over the same dirs as `tools/pylintchk.bat` |
| `rebuild` | rebuild the image (after requirement changes) and restart |
| `reset-data` | delete the dev data volume (asks for confirmation) |
| `status` | container state, URL, attached serial devices |

**`docker/scripts/rh-dev.ps1`** (PowerShell 5.1-compatible, runs on Windows) + **`rh-dev.cmd`** wrapper
(`powershell -NoProfile -ExecutionPolicy Bypass -File …`, so it works without changing the execution policy).
- Detects the WSL distro and Linux path automatically when the repo is opened via
  `\\wsl.localhost\<distro>\…` or `\\wsl$\<distro>\…`; otherwise uses `RH_WSL_DISTRO` / `RH_WSL_REPO`
  (env vars or a `docker/scripts/rh-dev.local.ps1` that is git-ignored). If the repo is on a Windows drive,
  it warns (slow bind mount) and points to the docs.
- All `rh-dev.sh` subcommands are passed through: `rh-dev up` → `wsl -d <distro> --cd <repo> docker/scripts/rh-dev.sh up`.
- Windows-only subcommands:
  - `setup` – checks and, **after asking for each step**, fixes: WSL2 installed, distro present, systemd
    enabled (`/etc/wsl.conf`, then `wsl --shutdown`), Docker Engine in the distro (Ubuntu packages
    `docker.io` + `docker-compose-v2`, user added to `docker` group), `usbipd-win` (via `winget`). Never
    installs anything silently; every step can be skipped and is idempotent.
  - `usb list` – lists USB devices from `usbipd list`, highlighting likely timer nodes by VID
    (CH340 `1a86`, CP210x `10c4`, FTDI `0403`, STM32 `0483`, Arduino `2341`).
  - `usb attach [<busid>]` – binds once (elevates via UAC only if the device isn't bound yet) and attaches
    to the distro with `--auto-attach` in a background process, so replugging works; without a bus id it
    offers the detected timer devices.
  - `usb detach [<busid>]` – stops the auto-attach process and detaches.
  - `open` – opens `http://localhost:5000` in the browser.
- `.gitattributes`: `docker/**/*.sh` and `docker/entrypoint.sh` with `eol=lf`, `*.ps1`/`*.cmd` with `eol=crlf`
  – otherwise a Windows checkout breaks the scripts inside the container.

### 5.11 Behaviour on a Raspberry Pi

The arm64 image *may* run on a Pi, but it is not a supported target there (non-goal, see 2). Because the
shipped Compose files don't use `--privileged`, `/proc/device-tree/model` stays unreadable and RotorHazard
behaves as on any other Linux machine: `check_requirements()` checks against `reqsNonPi.txt`, the I2C/GPIO
paths and Pi shutdown/reboot stay off. **No code change.** The docs state clearly: Pi hardware →
`rh_install.sh`; inside the container only USB nodes; don't start with `--privileged` (otherwise RH switches
to Pi mode without the Pi libraries being in the image). A verification step on a Pi is optional (see 6).

### 5.12 Dependency versions

`reqsNonPi.txt` only pins minor versions (`Flask==3.1.*` …). The goal is that **every published image is
frozen** – end users build nothing. Two CI builds of the same tag may differ in patch versions; **no**
additional lock file is maintained. For traceability the build writes the output of `pip freeze` to
`/app/requirements.lock.txt` inside the image.

### 5.13 Coordination with upstream (still open)

Publishing under `ghcr.io/rotorhazard/rotorhazard` has **not yet been agreed** with the maintainers. Therefore:
- The default in `compose.yaml` and the docs stays `ghcr.io/rotorhazard/rotorhazard` (target state after
  merge), overridable via `RH_IMAGE`.
- Until the merge, testing uses the fork image `ghcr.io/scordo/rotorhazard` (the workflow uses
  `github.repository_owner`, so it works in the fork unchanged).
- The PR description contains a checklist for the maintainers: set the GHCR package to "public" after the
  first run; allow the workflow permission `packages: write`; decide whether `main` should be published as
  `dev` (can be disabled via the workflow variable `PUBLISH_DEV`, default on).
- The docs are written so that they are only fully accurate after the first published release image; until
  then they additionally point to the local build (`docker compose -f docker/compose.dev.yaml` or
  `docker build --target runtime`).

## 6. Verification (to be done by the builder)

- Locally in WSL2: build the `runtime` and `dev` targets; server starts with an empty volume; UI reachable;
  `config.json`, DB and logs under `/data`.
- Mock nodes visible via `RH_MOCK_NODES`.
- `runtime-java`: IMD page in the UI shows IMDTabler results; `runtime`: server starts without Java and
  only logs the existing "Unable to find java" hint.
- Install a plugin with a dependency via the plugin installer → package lands under `/data/python`; replace
  the container with a freshly built image → plugin still loads.
- Container doesn't run as root; a bind mount with a foreign UID works via `PUID`/`PGID`.
- With a real USB node (via `usbipd` in WSL2): port shows up in the picker incl. `by-id`; unplug and replug
  → node comes back after re-`attach`, without restarting the container.
- Helper scripts on Windows: on a fresh-ish Windows + WSL2 machine, `rh-dev setup` walks through all steps
  and is safe to run twice; `rh-dev up`, `logs`, `test`, `lint`, `down` work from a PowerShell window in the
  repo opened via `\\wsl.localhost\…`; `rh-dev usb attach` makes a real node appear in the UI and survives
  replugging; `rh-dev.sh` works directly inside WSL and on plain Linux.
- Docs: follow `doc/Docker.md` quick start and `doc/Docker Development.md` Windows setup literally on a
  clean machine/VM; every command works as written.
- Optional on a Pi (arm64 image, Compose without `--privileged`): log shows no "Host machine: Raspberry Pi"
  entry and no package mismatch warning.
- `docker stop` shuts the server down cleanly (no DB lock/error on next start).
- Unit tests pass in the `dev` container (or same state as native).
- Run the CI workflow once end to end in the fork (`Scordo/RotorHazard`) (push to `ghcr.io/scordo/rotorhazard`).

## 7. Left to the builder

- Exact package list in the `builder` stage, in case wheels are missing.
- QEMU vs. native arm64 runners (`ubuntu-24.04-arm`) – QEMU is the starting point; switch if the arm64
  build becomes too slow.
- Wording and structure of the docs in detail.
- Whether `.vscode/launch.json` already exists/is ignored – if so, put the launch configuration into
  `devcontainer.json` (`customizations.vscode`) or the docs instead.

## 8. Own decisions (for review by the requester)

- Files under `docker/` (not in the repo root), image name `ghcr.io/<owner>/rotorhazard`, overridable in
  Compose via `RH_IMAGE`; `dev` push from `main` can be disabled via `PUBLISH_DEV` (5.13).
- Python 3.12 slim (Debian bookworm), no venv in the image.
- Two image variants: default without Java (smaller), plus `-java` tags with `openjdk-17-jre-headless` for
  IMDTabler (requested by the requester; the JRE choice and tag suffix are my call). The `dev` target is
  based on the Java variant.
- Non-root user UID 1000 with `PUID`/`PGID` adjustment, privilege drop via `setpriv`, `tini` as init.
- USB via `/dev` mount + `device_cgroup_rules` (188/166) instead of `--privileged`/`--device`.
- No `HEALTHCHECK`.
- Docs in English only (translations later); two guides (users / developers) instead of one.
- Helper scripts: bash script as the single source of truth, PowerShell script only delegates and adds the
  Windows-specific parts (setup, USB); `setup` asks before every change; Docker in WSL via Ubuntu's own
  packages (`docker.io`, `docker-compose-v2`) instead of Docker's install script.
- Pi inside the container: no code change, docs only (5.11).
- Versions frozen per image, no separate lock file; `pip freeze` stored in the image (5.12).
- This design document is not part of the upstream PR.
