# Docker Development Guide

This guide is for people who want to change the RotorHazard code and run it, test it and debug it in a Docker container, on Windows (with WSL2) or on Linux. You do not need any previous Docker experience: every step is a command you can copy and paste, followed by what you should see.

If you only want to *run* RotorHazard in Docker, see the [Docker user guide](Docker.md). For the general contribution workflow (forks, pull requests) see [Development](Development.md).

- [Overview](#overview)
- [Windows and WSL2 Setup](#windows-and-wsl2-setup)
- [Linux Setup](#linux-setup)
- [Daily Workflow with `rh-dev`](#daily-workflow-with-rh-dev)
- [USB Nodes from Windows](#usb-nodes-from-windows)
- [VS Code Dev Container](#vs-code-dev-container)
- [Building the Production Images Locally](#building-the-production-images-locally)
- [Troubleshooting](#troubleshooting)

## Overview

There are two ways to work, both based on the same `dev` image (the production image plus Java, `git`, `pylint` and `debugpy`):

* **Compose workflow** (`docker/compose.dev.yaml`): you edit the code with any editor on your computer; the container runs the server with your source folder mounted at `/app`. Restart the container to see code changes. The helper script `rh-dev` wraps all commands, so you never have to remember the long `docker compose -f ...` lines.
* **VS Code Dev Container** (`.devcontainer/devcontainer.json`): VS Code opens the same container, so the editor, the debugger and the terminal run inside it.

In the container your code is in `/app` and the server's data (database, configuration, logs) is kept in a separate volume named `rotorhazard-dev_rh-dev-data`, so it does not mix with your source folder. The server listens on port 5000; port 5678 is reserved for the debugger. The container is named `rotorhazard-dev`.

## Windows and WSL2 Setup

On Windows, Docker runs inside WSL2 (Windows Subsystem for Linux) using Docker Engine installed in an Ubuntu distribution. Docker Desktop is **not** needed. The reference setup uses the distribution `Ubuntu-26.04` (Ubuntu 26.04 LTS).

### The shortcut: `rh-dev setup`

If the repository is already on your computer, the helper script can check everything and fix what is missing, asking before every step. Open PowerShell or cmd in the repository folder and run:

```
docker\scripts\rh-dev.cmd setup
```

It checks WSL2, the distribution, systemd, Docker Engine and `usbipd-win`, and for each missing item it shows the command and asks for confirmation (`y` to do it, anything else to skip). Nothing is installed silently, and running it again is safe. To see what it would run without doing anything, add `-DryRun`.

Skip to [Clone the repository into WSL](#3-clone-the-repository-into-wsl) when the script has finished, or follow the manual steps below to understand what it does.

### Manual setup

**1. Install WSL2 and Ubuntu.** In PowerShell:

```
wsl --install -d Ubuntu-26.04
```

Windows downloads Ubuntu and asks you to create a Linux user name and password. Choose them and remember the password (it is needed for `sudo`). Afterwards check:

```
wsl -l -v
```

You should see `Ubuntu-26.04` with `VERSION 2`.

**2. Enable systemd and install Docker Engine inside Ubuntu.** Open the Ubuntu terminal (`wsl -d Ubuntu-26.04`) and run:

```
printf '[boot]\nsystemd=true\n' | sudo tee -a /etc/wsl.conf
```

This appends the lines `[boot]` and `systemd=true` to `/etc/wsl.conf` (skip it if the file already contains `systemd=true`; Ubuntu 26.04 may have enabled it already). Restart WSL from PowerShell so it takes effect:

```
wsl --shutdown
```

Open the Ubuntu terminal again and install Docker from the Ubuntu packages:

```
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-v2 docker-buildx
sudo usermod -aG docker $USER
```

Close the Ubuntu terminal and run `wsl --shutdown` in PowerShell once more, then open Ubuntu again, so the group membership applies. Verify:

```
docker run --rm hello-world
docker compose version
```

You should see `Hello from Docker!` and a Compose version line.

### 3. Clone the repository into WSL

Clone into the Linux filesystem (your Ubuntu home folder), **not** into `/mnt/c/...`:

```
cd ~
git clone https://github.com/RotorHazard/RotorHazard.git
cd RotorHazard
```

Reason: files on a Windows drive (`/mnt/c`) are accessed through a slow bridge, which makes Docker bind mounts (and so the server start, the tests and `git` itself) very slow, and file change notifications do not work reliably. In the WSL filesystem everything runs at native speed. You can still edit the files with Windows tools, see the next step. If you fork the project, clone your fork instead.

### 4. Use `rh-dev` from Windows

From Windows the same folder is reachable as `\\wsl.localhost\Ubuntu-26.04\home\<user>\RotorHazard` (replace `<user>` with your Linux user name; type it into the Explorer address bar). Open a PowerShell or cmd window in **that folder** (for example, in Explorer address bar type `powershell`, or in VS Code use "Open Folder" with that path) and run:

```
docker\scripts\rh-dev.cmd status
```

`rh-dev.cmd` recognizes from the folder path which WSL distribution and Linux path to use; nothing needs to be configured. You should see something like:

```
Container: not running
URL: http://localhost:5000
Serial devices: unknown (container not running)
```

> [!TIP]
> To type just `rh-dev` instead of `docker\scriptsh-dev.cmd`, add the folder `docker\scripts` of the repository to your `PATH`. The rest of this guide writes `rh-dev` for brevity.

**Repository on a Windows drive?** If you must keep it there (for example `C:\...`), `rh-dev` prints a warning about slow bind mounts. To use the script anyway, tell it the distribution and the Linux path of the repository, either with environment variables:

```
$env:RH_WSL_DISTRO = 'Ubuntu-26.04'
$env:RH_WSL_REPO = '/mnt/c/path/to/RotorHazard'
```

or permanently in the git-ignored file `docker\scripts\rh-dev.local.ps1`, containing the same two lines. This works, but is slow; moving the repository into WSL is strongly recommended.

## Linux Setup

On Ubuntu/Debian, install Docker Engine as described in the [user guide](Docker.md#installing-docker-on-ubuntudebian) (or the Ubuntu packages `docker.io docker-compose-v2 docker-buildx`), add yourself to the `docker` group, log in again, and clone the repository:

```
git clone https://github.com/RotorHazard/RotorHazard.git
cd RotorHazard
```

Use `docker/scripts/rh-dev.sh` wherever this guide says `rh-dev`:

```
docker/scripts/rh-dev.sh status
```

It works from any directory. You can create a short alias if you like: `alias rh-dev="$PWD/docker/scripts/rh-dev.sh"`.

## Daily Workflow with `rh-dev`

All commands below work the same way on Windows (`rh-dev ...`) and on Linux (`docker/scripts/rh-dev.sh ...`).

**Start the server**

```
rh-dev up
```

The first run builds the image (a few minutes), then starts the container and prints:

```
RotorHazard dev server: http://localhost:5000
```

Open that address in your browser (on Windows, `rh-dev open` does it for you). Without hardware, start with simulated nodes instead:

```
rh-dev up --mock 4
```

**Show the log**

```
rh-dev logs
rh-dev logs -f
```

The second form follows the log live (Ctrl+C to leave). The last lines of a healthy start contain `Running http server at port 5000`.

**Restart after a code change.** The source folder is mounted into the container, so you only need to restart the server process:

```
rh-dev restart
```

**Open a shell in the container.** It runs as the `rotorhazard` user, in the same environment as the server:

```
rh-dev shell
```

You get a prompt like `rotorhazard@<id>:/app/src/server$`. Type `exit` to leave. (Plain `docker exec` runs as `root` by default; if you use it directly, add `-u rotorhazard`, for example `docker exec -it -u rotorhazard rotorhazard-dev bash`.)

**Run the tests**

```
rh-dev test
```

This runs `python -m unittest discover` in `src/tests`; you should see a line like `Ran <n> tests` followed by `OK`.

**Run the linter**

```
rh-dev lint
```

This runs `pylint --errors-only` over the same Python files as `tools/pylintchk.bat`. No output means no errors were found.

**Rebuild after requirement changes.** When `src/server/reqsNonPi.txt` (or the Dockerfile) changes, rebuild the image and restart:

```
rh-dev rebuild
```

**Check the state**

```
rh-dev status
```

shows whether the container is running, the URL and which serial devices the container can see.

**Stop the server** (the data volume is kept):

```
rh-dev down
```

**Start with fresh data.** This deletes the dev data volume `rotorhazard-dev_rh-dev-data` (event database, configuration) after asking for confirmation:

```
rh-dev reset-data
```

**The raw Docker equivalents.** `rh-dev` only wraps Docker Compose. For instance, `rh-dev up` is

```
docker compose -f docker/compose.dev.yaml up -d --build
```

and the tests are

```
docker compose -f docker/compose.dev.yaml exec -u rotorhazard rotorhazard sh -c 'cd /app/src/tests && python -m unittest discover'
```

On Windows, `rh-dev -DryRun <command>` prints the `wsl` command it would run, and `RH_DEV_DRY_RUN=1 docker/scripts/rh-dev.sh <command>` prints the `docker compose` commands on Linux, without running them.

## USB Nodes from Windows

A USB timer node plugged into Windows is not visible to WSL2 by default. The free tool [usbipd-win](https://github.com/dorssel/usbipd-win) forwards USB devices into WSL2. `rh-dev setup` offers to install it; manually:

```
winget install --exact dorssel.usbipd-win
```

(Restart the PowerShell window afterwards so the `usbipd` command is found.)

**1. List the devices.** Plug in the node, then:

```
rh-dev usb list
```

Connected USB devices are listed; likely timer nodes (CH340, CP210x, FTDI, STM32, Arduino) are highlighted. Note the bus id of your node, for example `2-3`.

**2. Attach the node to WSL2:**

```
rh-dev usb attach 2-3
```

(without a bus id, the script offers the detected timer devices). The first time, Windows shows an administrator prompt (UAC) for the one-time *bind* of the device; later attaches need none. The script then attaches the device to your WSL distribution in the background with auto-attach, so the node is attached again whenever you replug it.

**3. Check that the container sees it:**

```
rh-dev status
```

Under `Serial devices:` you should see `/dev/ttyUSB0` (or `/dev/ttyACM0`). In the RotorHazard web page, add the port as described in [USB Nodes](USB%20Nodes.md).

**4. Give the node back to Windows:**

```
rh-dev usb detach 2-3
```

While a device is attached to WSL, Windows programs (such as the Arduino IDE for flashing the node) cannot use it; detach it first.

## VS Code Dev Container

With the Dev Container, VS Code runs inside the dev container: the Python extensions, the debugger and the terminal use the container's Python and its packages.

**Prerequisites:** [VS Code](https://code.visualstudio.com/), the "Dev Containers" extension (`ms-vscode-remote.remote-containers`), and the repository set up as described above.

**1. Open the repository.**

* *On Windows with WSL2:* start VS Code from the WSL terminal: `code ~/RotorHazard` (VS Code then runs "in WSL" and the Dev Containers extension uses Docker Engine in WSL). Alternatively open the folder `\\wsl.localhost\Ubuntu-26.04\home\<user>\RotorHazard` from Windows VS Code and enable the setting **Dev › Containers: Execute In WSL** (`dev.containers.executeInWSL`).
* *On Linux:* `code .` in the repository folder.

**2. Reopen in the container.** VS Code shows a pop-up "Reopen in Container"; or press F1 and run **Dev Containers: Reopen in Container**. The first time the image is built. When it is ready, the bottom-left corner of VS Code shows `Dev Container: RotorHazard`.

> [!NOTE]
> The Dev Container does not start the server by itself (the container just keeps running); you start the server with the debugger or from the terminal. It uses the same container name and ports as `rh-dev up`, so stop one before starting the other (`rh-dev down`).

**3. Run and debug the server.** Open the _Run and Debug_ view (Ctrl+Shift+D) and choose one of the launch configurations:

* **RotorHazard server**: starts `src/server/server.py` under the debugger, with the data directory `/data`.
* **RotorHazard server (mock nodes)**: the same with `--mock-nodes 4` (simulated hardware).

Press F5. The terminal shows the server log (`Running http server at port 5000`); breakpoints in the Python files work. Port 5000 is forwarded, so `http://localhost:5000` opens the server.

**4. Run the tests.** In the VS Code terminal (Ctrl+`):

```
cd /app/src/tests && python -m unittest discover
```

Linting: the Pylint extension is installed in the container and shows problems in the editor.

## Building the Production Images Locally

The `docker/Dockerfile` has these targets:

| Target | Result |
|---|---|
| `runtime` | The standard production image |
| `runtime-java` | `runtime` plus Java (IMDTabler / IMD scores) |
| `dev` | `runtime-java` plus `git`, `pylint`, `debugpy` (used by the dev workflow) |

Build and test the production image from the repository folder (in WSL or on Linux):

```
docker build -f docker/Dockerfile --target runtime -t rotorhazard:local .
```

The last output line is like `naming to docker.io/library/rotorhazard:local`. Run it with the end-user Compose file by pointing it to the local image:

```
RH_IMAGE=rotorhazard RH_VERSION=local docker compose -f docker/compose.yaml up -d
```

(`docker compose -f docker/compose.yaml down` stops it.) Replace `runtime` by `runtime-java` for the Java variant. The repository also contains the smoke test that CI uses:

```
bash docker/tests/smoke.sh rotorhazard:local
```

It starts the image with simulated nodes, waits for the web page and checks that the server does not run as root; add `--java` for the Java variant.

**CI and tags.** The GitHub Actions workflow `.github/workflows/docker.yml` builds, tests and publishes both variants to `ghcr.io/<owner>/rotorhazard` (`<owner>` is the owner of the repository, so forks publish to their own account):

| Event | Published tags |
|---|---|
| Push of a tag `vX.Y.Z` | `X.Y.Z`, `X.Y`, `latest`, and the same with the suffix `-java` (`X.Y.Z-java`, `X.Y-java`, `latest-java`) |
| Push of a pre-release tag such as `v4.6.0-beta.1` | only the exact tag (`4.6.0-beta.1`, `4.6.0-beta.1-java`); never `latest` |
| Push to `main` | `dev`, `sha-<short>` and `dev-java`, `sha-<short>-java` |
| Pull request | built and smoke-tested, nothing is published |

Publishing of the `main` builds can be switched off by setting the repository variable `PUBLISH_DEV` to `false`. A manual run (Actions tab, "Run workflow") with the option `publish` enabled pushes `sha-<short>` images, which is useful for testing in a fork.

## Troubleshooting

**Everything is slow (server start, tests, git).** The repository is probably on a Windows drive (`/mnt/c/...`). `rh-dev` warns about this. Move it into the WSL filesystem as described in [Clone the repository into WSL](#3-clone-the-repository-into-wsl). Check where you are with `pwd` in the WSL terminal: the path should start with `/home/`, not `/mnt/`.

**`permission denied while trying to connect to the Docker daemon socket`.** Your Linux user is not in the `docker` group, or the group membership has not been applied yet. Run `sudo usermod -aG docker $USER`, then in PowerShell `wsl --shutdown` and open the Ubuntu terminal again (on Linux: log out and in). `id -nG` must list `docker`.

**`Cannot connect to the Docker daemon` / the Docker service is not running.** Check `systemctl status docker` in WSL. If systemd is not running, enable it as described in [Manual setup](#manual-setup) step 2 and run `wsl --shutdown`. `rh-dev setup` checks this.

**USB device not visible in WSL.** Run `rh-dev usb list` and check the device state: `Attached` means it is available in WSL. If it shows `Not shared`, run `rh-dev usb attach <busid>` (UAC prompt for the one-time bind). If `usbipd` is not found, install it (see [USB Nodes from Windows](#usb-nodes-from-windows)) and open a new PowerShell window. In WSL, `ls /dev/ttyUSB* /dev/ttyACM*` must list the device; the WSL kernel must contain the USB serial drivers (a current WSL: `wsl --update`).

**Port 5000 is already in use on Windows.** Another program uses port 5000 (or an old container still runs). Run `rh-dev down`, and find the other program in PowerShell with `netstat -ano | findstr :5000`. To publish another port, edit the `ports` line in `docker/compose.dev.yaml` (for example `"5001:5000"`), but do not commit that change.

**Line endings: a script fails with `bad interpreter` or `\r: command not found`.** Shell scripts (`*.sh`, `docker/entrypoint.sh`) must have Unix line endings (LF) because they run inside Linux; PowerShell and cmd scripts (`*.ps1`, `*.cmd`) must have CRLF. The repository's `.gitattributes` enforces this on checkout. If you edit the files in an editor, keep the setting "LF" for `.sh` files. If a file got converted by mistake, restore it with `git checkout -- <file>` (or `git add --renormalize .`).

**The container keeps restarting or the server does not start.** Read the log with `rh-dev logs`. After a change of `src/server/reqsNonPi.txt` run `rh-dev rebuild`.

**Docker uses a lot of disk space.** Remove unused build cache and stopped containers with `docker system prune` (it asks for confirmation; read the list it shows first, because it removes everything unused, not only RotorHazard items).
