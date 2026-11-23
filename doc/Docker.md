# Running RotorHazard with Docker

This guide explains how to run the RotorHazard server in a Docker container on a Linux computer (a mini PC, a home server, a laptop, a virtual machine). It is written for people who have never used Docker: every step is a command you can copy and paste, followed by what you should see.

If you want to work on the RotorHazard code itself, see the [Docker Development Guide](Docker%20Development.md) instead.

- [What You Get](#what-you-get)
- [Quick Start](#quick-start)
- [Installing Docker on Ubuntu/Debian](#installing-docker-on-ubuntudebian)
- [Configuration](#configuration)
- [Connecting USB Timer Nodes](#connecting-usb-timer-nodes)
- [Your Data](#your-data)
- [Updating, Pinning a Version, Rolling Back](#updating-pinning-a-version-rolling-back)
- [Plugins and Their Dependencies](#plugins-and-their-dependencies)
- [Troubleshooting](#troubleshooting)
- [Uninstall](#uninstall)

## What You Get

A Docker image is a ready-made package of the RotorHazard server together with Python and every library it needs. You do not install Python, create a virtual environment or run `pip` yourself; you start the container and open the web page.

**When to use Docker**

* Use Docker to run the RotorHazard server on an ordinary Linux computer (Intel/AMD or ARM), with timer nodes connected **via USB**.
* If you build a standard timer on a **Raspberry Pi** with nodes connected through the Pi's I2C/GPIO pins, do **not** use Docker. Use the normal installation described in [Software Setup Instructions](Software%20Setup.md) (the `rh_install.sh` script). The container can only talk to USB serial nodes; it does not provide GPIO/I2C access, LED control, or shutdown/reboot of the host.

**Image variants**

| Variant | Tag | Contents |
|---|---|---|
| Standard | `latest`, `X.Y.Z`, `X.Y` | RotorHazard server |
| With Java | `latest-java`, `X.Y.Z-java`, `X.Y-java` | Same, plus Java, which enables the IMD score (IMDTabler) feature |
| Development | `dev`, `dev-java` | Latest unreleased code from the `main` branch; may be unstable. |

Pre-release versions (for example `4.6.0-beta.1`) only get their exact tag, never `latest`.

Choose "With Java" only if you want IMD scores (see [Java Support](Software%20Setup.md#java-support)); otherwise use the standard variant.

> [!NOTE]
> **Interim note:** until the first release image has been published to the GitHub Container Registry (`ghcr.io`), the image has to be built on your own computer. The quick start below shows both ways. Once release images exist, only the "Download the ready-made image" path is needed.

## Quick Start

Five steps on a Linux computer that has internet access. If Docker is not installed yet, do [Installing Docker on Ubuntu/Debian](#installing-docker-on-ubuntudebian) first (step 1).

**1. Check that Docker works**

```
docker compose version
```

You should see a line like `Docker Compose version v2.40.3`. If you see `command not found`, install Docker first (see below).

**2. Create a folder for RotorHazard**

```
mkdir -p ~/rotorhazard && cd ~/rotorhazard
```

There is no output.

**3. Download the Compose file**

```
curl -fsSLO https://raw.githubusercontent.com/RotorHazard/RotorHazard/main/docker/compose.yaml
ls
```

You should see `compose.yaml` listed.

**3b. Interim: build the image locally (only while no release image exists)**

Skip this step once release images are published. Until then, download the source and build the image once (this takes a few minutes the first time):

```
git clone https://github.com/RotorHazard/RotorHazard.git ~/RotorHazard-src
cd ~/RotorHazard-src
docker build -f docker/Dockerfile --target runtime -t rotorhazard:local .
cd ~/rotorhazard
printf 'RH_IMAGE=rotorhazard\nRH_VERSION=local\n' > .env
```

The build ends with a line like `naming to docker.io/library/rotorhazard:local`. The `.env` file tells Compose to use this local image (`rotorhazard:local`) instead of the published one. (For the Java variant use `--target runtime-java -t rotorhazard:local-java` and `RH_VERSION=local-java`.)

**4. Start RotorHazard**

```
docker compose up -d
```

The first start downloads the image (not needed with the local build) and then prints something like:

```
 Network rotorhazard_default  Created
 Volume rotorhazard_rh-data  Created
 Container rotorhazard  Started
```

Check that it is running:

```
docker compose ps
```

You should see a line for `rotorhazard` with `Up` in the `STATUS` column and `0.0.0.0:5000->5000/tcp` in `PORTS`. After a few seconds the log shows the server is ready:

```
docker compose logs --tail 5
```

The last lines contain `Running http server at port 5000`.

**5. Open the web page**

Find the IP address of the computer:

```
hostname -I
```

Then open `http://<server-ip>:5000` in a browser (for example `http://192.168.1.50:5000`), or `http://localhost:5000` on the server itself. You should see the RotorHazard start page. The next sections explain how to connect timer nodes and where your data lives.

> [!TIP]
> No timer hardware yet? To try everything with simulated nodes, add the line `RH_MOCK_NODES=4` to the `.env` file (create it if needed) and run `docker compose up -d` again.

## Installing Docker on Ubuntu/Debian

These steps install Docker Engine and Compose from Docker's official package repository. For other distributions see the [official Docker instructions](https://docs.docker.com/engine/install/).

**1. Add Docker's package repository**

Ubuntu:

```
sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
sudo apt-get update
```

On Debian, replace the two occurrences of `ubuntu` in the URL lines (`.../linux/ubuntu/gpg` and `URIs: https://download.docker.com/linux/ubuntu`) with `debian`, and use `echo "$VERSION_CODENAME"` for the `Suites:` line.

The last command should list `download.docker.com` among the lines starting with `Get:` or `Hit:`.

**2. Install Docker**

```
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

**3. Allow your user to run Docker without `sudo`**

```
sudo usermod -aG docker $USER
```

Now **log out and log in again** (or reboot) so the new group membership takes effect. Check it:

```
id -nG
```

The list of groups should include `docker`.

**4. Verify**

```
docker run --rm hello-world
```

You should see `Hello from Docker!`. Then:

```
docker compose version
```

prints the Compose version. Docker is ready.

## Configuration

The container is configured with environment variables. Compose reads them from the shell or, more conveniently, from a file named `.env` in the same folder as `compose.yaml`. Each line is `NAME=value`:

```
cd ~/rotorhazard
nano .env
```

After changing `.env`, apply it with:

```
docker compose up -d
```

Compose recreates the container if something changed (your data is kept, see [Your Data](#your-data)).

| Variable | Default | What it does | Example |
|---|---|---|---|
| `RH_IMAGE` | `ghcr.io/rotorhazard/rotorhazard` | Image name (without tag). Change it for an image built locally or published by someone else. | `RH_IMAGE=rotorhazard` |
| `RH_VERSION` | `latest` | Image tag: `latest`, a version such as `4.6.0`, `latest-java`, `dev`. See [Image variants](#what-you-get). | `RH_VERSION=latest-java` |
| `TZ` | `Etc/UTC` | Time zone used for log files and timestamps. [List of names](https://en.wikipedia.org/wiki/List_of_tz_database_time_zones). | `TZ=Europe/Berlin` |
| `PUID` | `1000` | User ID the server runs as inside the container. Needed only if you use a [bind-mounted data folder](#option-store-the-data-in-a-normal-folder) owned by another user. | `PUID=1001` |
| `PGID` | `1000` | Group ID the server runs as. Same purpose as `PUID`. | `PGID=1001` |
| `RH_EXTRA_GIDS` | empty | Extra group IDs (comma-separated) to give the server process, for serial devices owned by an unusual group. Rarely needed. | `RH_EXTRA_GIDS=986,987` |
| `RH_MOCK_NODES` | empty (off) | Start with this many simulated nodes instead of real hardware. | `RH_MOCK_NODES=4` |

`PUID`, `PGID` and `RH_EXTRA_GIDS` must be numbers (`RH_EXTRA_GIDS`: comma-separated) and must not be `0`; the container refuses to start otherwise. The server never runs as `root` inside the container, regardless of these settings.

**Changing the port**

The web page is served on port 5000 by default. To use another port, for example 8080, open `compose.yaml` and change the line

```
    ports: ["5000:5000"]
```

to

```
    ports: ["8080:5000"]
```

(only the first number changes), then run `docker compose up -d`. RotorHazard is then reachable at `http://<server-ip>:8080`.

## Connecting USB Timer Nodes

**1. Plug in the node(s)** before or after starting the container; both work.

**2. Check that the computer sees the node**

```
ls -l /dev/serial/by-id
```

You should see one entry per node, for example:

```
lrwxrwxrwx 1 root root 13 Nov 18 10:15 usb-1a86_USB_Serial-if00-port0 -> ../../ttyUSB0
```

**3. Check that the container sees it**

```
docker exec rotorhazard ls -l /dev/serial/by-id
```

The same entries should appear.

**4. Select the port in RotorHazard.** Open the web page and go to the _Advanced Settings_ page, _Hardware_ panel, _Serial Ports_ section. Click `List Ports`; every serial port the server can see is shown. Click `Add` next to your node, and restart the server if RotorHazard asks you to. See [USB Nodes](USB%20Nodes.md) for details on node setup and flashing. Prefer the stable `/dev/serial/by-id/...` names over `/dev/ttyUSB0`, because the latter can change when nodes are replugged.

**Hotplug.** Nodes that are plugged in after the container started are visible and usable. If a node is unplugged and plugged in again, the device is available to the server again; restart the server from the RotorHazard web page if it does not reconnect on its own.

**How it works (and why `--privileged` is not used).** The Compose file maps the host's `/dev` into the container and allows only serial devices (device classes `ttyUSB*` and `ttyACM*`) through `device_cgroup_rules`. The server process is a member of the `dialout` group (ID 20), which owns serial ports on Ubuntu and Debian. The group IDs of serial devices found at container start are added automatically.

> [!NOTE]
> The group memberships of the server process are fixed when the container starts. On standard Ubuntu and Debian every serial device belongs to `dialout` (always included), so devices plugged in later work. On a distribution where serial devices belong to a different group, restart the container once with the node plugged in (`docker compose restart`) or set `RH_EXTRA_GIDS` to the group ID shown by `ls -ln /dev/ttyUSB0`.

## Your Data

RotorHazard stores its event database, configuration (`config.json`), logs, backups and plugins in the **data directory**, which is `/data` inside the container. Compose keeps it in a Docker *volume* named `rotorhazard_rh-data`. The volume survives restarts, updates and `docker compose down`.

Check what is in there:

```
docker compose exec rotorhazard ls /data
```

You should see entries such as `config.json`, `database.db`, `logs`, `plugins` and `python`.

### Option: Store the Data in a Normal Folder

If you prefer to see and copy the data as an ordinary folder, replace the volume line in `compose.yaml`:

```
      - rh-data:/data
```

with

```
      - ./rh-data:/data
```

Then create the folder and make sure the container user can write to it. If you are the user with ID 1000 (the first user on most systems; check with `id -u`), no more is needed:

```
mkdir -p rh-data
docker compose up -d
```

For a different user ID, add `PUID` and `PGID` to `.env`, for example `PUID=1001` and `PGID=1001` (`id -u` and `id -g` show your values). The container then adjusts the ownership of the folder on start.

### Backup

Stop the server so the database is in a consistent state, copy the volume into a compressed archive in the current folder, and start again:

```
docker compose stop
docker run --rm -v rotorhazard_rh-data:/data:ro -v "$PWD":/backup alpine tar czf /backup/rh-data-backup.tar.gz -C /data .
docker compose start
ls -l rh-data-backup.tar.gz
```

The last command shows the archive file. Keep a copy somewhere safe, for example on another computer. (With the bind-mount variant, simply copy the `rh-data` folder.)

> [!TIP]
> RotorHazard can also export and archive events from its own web interface (see the [User Guide](User%20Guide.md)); that is a good additional safety net before an event.

### Restore

This replaces everything in the data volume with the contents of the archive:

```
docker compose down -v
docker compose create
docker run --rm -v rotorhazard_rh-data:/data -v "$PWD":/backup alpine tar xzf /backup/rh-data-backup.tar.gz -C /data
docker compose up -d
```

`docker compose down -v` deletes the old volume, `docker compose create` makes a new empty one, and the next command unpacks the archive into it.

### Moving an Existing Installation (`~/rh-data`) into the Container

If you already run RotorHazard natively and your data is in `~/rh-data`, copy it into the volume. First stop the native server, then:

```
docker compose create
docker run --rm -v ~/rh-data:/from:ro -v rotorhazard_rh-data:/to alpine cp -a /from/. /to/
docker compose up -d
```

Check that your files arrived:

```
docker compose exec rotorhazard ls /data
```

The serial port names in your `config.json` (for example `/dev/ttyUSB0` or `/dev/serial/by-id/...`) stay valid inside the container. Plugins that you installed natively are copied along; plugins that need extra Python packages may need to be reinstalled, see [Plugins and Their Dependencies](#plugins-and-their-dependencies).

## Updating, Pinning a Version, Rolling Back

**Update to the newest release**

Back up first (see [Backup](#backup)), then:

```
docker compose pull
docker compose up -d
```

`pull` downloads the new image; `up -d` recreates the container with it. Your data volume is kept. Check the result with `docker compose ps`. (For a locally built image, rebuild it as in the quick start step 3b, using a freshly downloaded copy of the source, and run `docker compose up -d`.)

**Pin a specific version**

Add the version to `.env`, so it only changes when you want it to:

```
RH_VERSION=4.6.0
```

Replace `4.6.0` with a version from the [Releases page](https://github.com/RotorHazard/RotorHazard/releases). `X.Y` (for example `4.6`) follows the latest patch release of that minor version. Then run `docker compose up -d`.

**Roll back**

Set `RH_VERSION` in `.env` to the previous version and run:

```
docker compose up -d
```

If the newer version already changed your database, restore the backup you took before updating (see [Restore](#restore)).

## Plugins and Their Dependencies

Plugins are installed from the RotorHazard web interface as usual (see [Plugins](Plugins.md)). They are stored in the data volume, in `/data/plugins`, so they survive updates.

Plugins that need additional Python packages are supported too. The packages are installed into `/data/python` (also in the data volume) and stay there when you update the image.

Known limitations:

* Packages in `/data/python` take precedence over the packages that come with the image. If a plugin installs a different version of a library that RotorHazard itself uses, it can shadow the image's version. RotorHazard then shows a warning about mismatching package versions. Remedy: delete the plugin packages and reinstall the plugins:

  ```
  docker compose stop
  docker compose run --rm --no-deps --entrypoint sh rotorhazard -c 'rm -rf /data/python/*'
  docker compose start
  ```

* When a new image uses a different Python version (this is mentioned in the release notes), the old packages are ignored and plugins with extra packages must be reinstalled.

## Troubleshooting

**Show the server log.** This is the first thing to look at for any problem:

```
docker compose logs --tail 100
```

Add `-f` to follow it live (press Ctrl+C to stop following).

**`Bind for 0.0.0.0:5000 failed: port is already allocated` (or `address already in use`).** Another program uses port 5000. Find it with `sudo ss -ltnp | grep :5000`, stop it, or [change the port](#configuration).

**`Permission denied` on `/dev/ttyUSB0` (or `/dev/ttyACM0`).** The server user cannot open the device. Check the group and mode of the device on the host:

```
ls -ln /dev/ttyUSB0
```

If the group ID (third column) is not `20`, the device belongs to a different group. Set `RH_EXTRA_GIDS` to that number in `.env` and run `docker compose up -d`. Also make sure you did not remove the `device_cgroup_rules` or the `/dev:/dev` volume from `compose.yaml`.

**The node is not detected.** Run `ls -l /dev/serial/by-id` on the host and `docker exec rotorhazard ls -l /dev/serial/by-id` in the container. If the host shows nothing, the problem is the cable, the adapter or the USB port (try another cable; some charge-only cables carry no data). If the host shows the device but the container does not, restart the container with `docker compose restart`. Then check the port configured in RotorHazard (see [Connecting USB Timer Nodes](#connecting-usb-timer-nodes)).

**The container restarts in a loop.** `docker compose ps` shows `Restarting`. Read the reason with:

```
docker compose logs --tail 50
```

Typical causes are a non-numeric `PUID`/`PGID` or a mistake in `compose.yaml`; the message is printed at the end of the log. Fix it and run `docker compose up -d`.

**Warning about package versions (`Try "pip install ...`).** A plugin installed a different version of a core package. See [Plugins and Their Dependencies](#plugins-and-their-dependencies).

**`docker: permission denied` / `Cannot connect to the Docker daemon`.** Your user is not (yet) in the `docker` group, or you have not logged in again since it was added. See [Installing Docker](#installing-docker-on-ubuntudebian), step 3, or prefix the command with `sudo`.

**`manifest unknown` / `pull access denied` when starting.** No image with that name and tag exists (yet). Check `RH_IMAGE` and `RH_VERSION`, or build the image locally as described in the quick start step 3b.

**Do not start the container with `--privileged`.** It is not needed and it is harmful: on a Raspberry Pi, RotorHazard would detect the Pi and switch to Raspberry Pi mode (GPIO, I2C, shutdown), but the Pi libraries are not in the image. The provided `compose.yaml` does not use it; keep it that way.

## Uninstall

Stop and remove the container and its network (data is kept):

```
cd ~/rotorhazard
docker compose down
```

To also **delete all RotorHazard data** (event database, configuration, plugins; this cannot be undone, so make a [backup](#backup) first):

```
docker compose down -v
```

Remove the image and the downloaded files.

> [!WARNING]
> If you store the data in a normal folder (`./rh-data:/data`, see [the bind-mount option](#option-store-the-data-in-a-normal-folder)), that folder lives inside `~/rotorhazard` and the command below deletes your event data too. Back it up or move `rh-data` out of the folder first.

```
docker rmi ghcr.io/rotorhazard/rotorhazard:latest
cd ~ && rm -rf ~/rotorhazard
```

(Use the image name and tag from your `.env` if you changed them, for example `docker rmi rotorhazard:local`. `docker image ls` shows the images on the computer.)
