# docker-install-script

🇺🇸 English | 🇧🇷 [Português](README.pt-BR.md)

A single, idempotent Bash script that **installs Docker Engine from the official Docker repository** on Debian, Ubuntu and their derivatives — or, if Docker is already there, **checks every piece of the setup, fixes only what is missing and prints a report**.

## Quick start

On the Linux server, run:

```bash
curl -fsSL https://raw.githubusercontent.com/ivancarlosdepaula/docker-install-script/main/install.sh | bash
```

Report only (changes nothing):

```bash
curl -fsSL https://raw.githubusercontent.com/ivancarlosdepaula/docker-install-script/main/install.sh | bash -s -- --check
```

> Run it as your regular user (it will ask for your `sudo` password) or as `root`.
> If you run it as root and want a regular user added to the `docker` group, pass `--user NAME`.

## What it checks (and fixes)

| # | Item | Fix applied when missing |
|---|------|--------------------------|
| 1 | Supported OS (Debian / Ubuntu / derivatives via `ID_LIKE`) | — (aborts if unsupported) |
| 2 | systemd present | — (warning only) |
| 3 | Conflicting packages (`docker.io`, `docker-compose`, `podman-docker`, `containerd`, `runc`…) | Removes only the ones installed |
| 4 | Official Docker APT repository (`.list` or `.sources`) | Creates `/etc/apt/sources.list.d/docker.list` |
| 5 | Repository GPG key exists and is world-readable | Downloads it to `/etc/apt/keyrings/docker.asc` / `chmod a+r` |
| 6 | Packages `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin` | Installs only the missing ones |
| 7 | `docker` and `containerd` services enabled at boot and running | `systemctl enable` / `start` |
| 8 | `docker` group exists | `groupadd docker` |
| 9 | User belongs to the `docker` group | `usermod -aG docker USER` |
| 10 | `~/.docker` owned by the user | `chown -R` + `chmod -R g+rwx` |
| 11 | Docker daemon responding (shows Engine, Compose and Buildx versions) | — (result of the steps above) |

If everything is already fine, it says so and **changes nothing**. Running it again is always safe.

## Options

```text
-c, --check        Only check and print the report (no changes)
-u, --user NAME    User to add to the docker group (default: $SUDO_USER or current user)
-t, --test         Run "docker run --rm hello-world" at the end
    --report-dir D Report file directory (default: /tmp)
    --no-color     Disable colors
-v, --version      Show version
-h, --help         Show help
```

When piping through `curl`, pass options after `bash -s --`:

```bash
curl -fsSL https://raw.githubusercontent.com/ivancarlosdepaula/docker-install-script/main/install.sh | sudo bash -s -- --user deploy --test
```

Equivalent environment variables: `DOCKER_CHECK_ONLY=1`, `DOCKER_USER=name`, `DOCKER_RUN_TEST=1`, `REPORT_DIR=/path`, `NO_COLOR=1`.

**Exit code:** `0` = environment OK · `1` = pending items or an error occurred. Handy for automation and monitoring:

```bash
curl -fsSL https://raw.githubusercontent.com/ivancarlosdepaula/docker-install-script/main/install.sh | bash -s -- --check --no-color || echo "Docker needs attention"
```

## Report

The report is shown on screen and saved as plain text to `/tmp/docker-report-<host>-<date>.txt`:

```text
-----------------------------------------------------------------------
 ESTADO ATUAL
-----------------------------------------------------------------------
[  OK  ] Sistema operacional             Ubuntu 24.04 LTS (repo: ubuntu/noble, amd64)
[  OK  ] Pacotes conflitantes            nenhum instalado
[  OK  ] Repositório oficial do Docker   /etc/apt/sources.list.d/docker.list
[  OK  ] Pacote docker-ce                5:29.x
[ FALTA] Usuário no grupo 'docker'       ivan não pertence ao grupo
[  OK  ] Docker daemon                   respondendo (Engine 29.x | compose v5.x | buildx v0.x)

Resumo: 13 OK | 1 pendente(s) | 0 aviso(s)
```

> The script's console messages are in Brazilian Portuguese. `OK` = fine, `FALTA` = missing/pending, `AVISO` = warning.

## After installing

If your user was added to the `docker` group, log out and back in (or run `newgrp docker`) to use `docker` without `sudo`.

## Security note

Piping a script from the internet into `bash` runs it with your privileges. If you prefer to read it first:

```bash
curl -fsSL https://raw.githubusercontent.com/ivancarlosdepaula/docker-install-script/main/install.sh -o install.sh
less install.sh
bash install.sh
```

The script is wrapped in a `main` function that only runs on the last line, so an interrupted download never executes a partial script.

## Requirements

- Debian, Ubuntu or a derivative (Linux Mint, Pop!_OS, Zorin, etc.) on a release supported by Docker
- `root` access or `sudo`
- Internet access to `download.docker.com`
