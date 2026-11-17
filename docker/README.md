# Docker

This folder contains everything needed to run RotorHazard in Docker: the `Dockerfile`, the container `entrypoint.sh`, the end-user Compose file `compose.yaml` and the developer Compose file `compose.dev.yaml`. To run RotorHazard on a Linux computer with USB timer nodes, follow the [Docker user guide](../doc/Docker.md); it starts from zero and explains installation, configuration, data backup and updates.

To work on the RotorHazard code in a container, see the [Docker Development Guide](../doc/Docker%20Development.md). The helper scripts in `scripts/` (`rh-dev.sh` for Linux/WSL2, `rh-dev.cmd` and `rh-dev.ps1` for Windows) wrap the daily commands such as start, restart, tests and USB attach; `tests/` contains the image smoke and entrypoint tests (run by CI) and the `rh-dev` script tests (`test_rh-dev.sh` runs in CI; `rh-dev.Tests.ps1` is a Pester suite you run on Windows).
