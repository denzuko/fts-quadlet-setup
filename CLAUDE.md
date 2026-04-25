# CLAUDE.md

Context file for [Claude Code](https://claude.ai/code) and Claude chat when
working with the `fts-quadlet-setup` repository.

---

## Project Overview

`fts-quadlet-setup` deploys [FreeTAKServer](https://github.com/FreeTAKTeam/FreeTakServer)
as a pair of rootful Podman Quadlet units managed by systemd. It is a sibling
project to [`pbx-quadlet-setup`](https://github.com/denzuko/pbx-quadlet-setup)
and follows identical conventions: POSIX sh bootstrapper, bats-core tests,
`$MOCK_DIR`-stubbed CI, no compose dependency.

**Operator:** Da Planet Security / Dwight Spencer (`denzuko@dapla.net`)
**License:** BSD 2-Clause
**Target OS:** Any systemd host with Podman ≥ 4.4 (RHEL 9, Fedora 39+, Debian 12+)

---

## Repository Layout

```
fts-quadlet-setup/
├── fts_setup.sh              # Bootstrapper — entry point for all installs
├── Makefile                  # lint / test / install / uninstall targets
├── containers/
│   ├── freetakserver.container     # FTS core Quadlet unit
│   └── freetakserver-ui.container  # FTS Web UI Quadlet unit
├── networks/
│   └── fts.network                 # Isolated bridge network
├── volumes/
│   ├── fts-data.volume             # Core persistent state
│   └── fts-ui-data.volume          # UI persistent state
├── env/
│   └── fts.env                     # Site-local operator configuration
└── tests/
    └── fts_setup.bats              # bats-core test suite
```

All quadlet files land in `/etc/containers/systemd/` on the target host.

---

## Key Conventions (match pbx-quadlet-setup exactly)

- **ZFS datasets:** Always provisioned before account creation. Convention:
  - `$POOL/containers/<name>` with `-o mountpoint=/srv/<name>`
  - `$POOL/users/<name>` with `-o mountpoint=/var/lib/<name>`
  - Properties: `compression=lz4`, `atime=off`
  - `useradd --no-create-home` — the ZFS dataset IS the home directory
- **Shell:** POSIX sh only in `fts_setup.sh` — no bashisms. Verify with
  `shellcheck -S style fts_setup.sh`.
- **Quadlet units:** systemd INI syntax. One `[Container]`, one `[Service]`,
  one `[Unit]`, one `[Install]` section per file.
- **Images:** GHCR only (`ghcr.io/freetakteam/`). Never `docker.io`.
- **Volumes:** Named Podman volumes via `.volume` units — no bind mounts to
  host paths in unit files.
- **Networking:** All inter-container traffic on `fts.network` bridge.
  Containers address each other by `ContainerName=`, not by IP.
- **Security:** `DropCapability=ALL` + `NoNewPrivileges=true` on every
  container unit. Volume mounts use `:Z` SELinux label.
- **Idempotency:** `fts_setup.sh` must be safe to re-run. `fts.env` is
  never overwritten if it already exists; only `FTS_IP=` line is stamped.
- **Tests:** All tests in `tests/fts_setup.bats`. Mock binaries go in
  `$MOCK_DIR` prepended to `$PATH`. No live podman, systemd, or network
  in tests. Run with `make test`.

---

## Common Tasks

### Run tests
```sh
make test
# or directly:
bats tests/fts_setup.bats
```

### Lint only
```sh
make lint
# expands to:
shellcheck -S style fts_setup.sh
```

### Deploy to a host
```sh
sudo make install IP=192.0.2.10
# or:
sudo FTS_IP=192.0.2.10 sh fts_setup.sh
```

### Check service status
```sh
systemctl status freetakserver.service freetakserver-ui.service
journalctl -u freetakserver.service -f
```

### Rotate secrets post-install
```sh
# Edit on target host:
$EDITOR /etc/containers/systemd/fts.env
# Change FTS_UI_WSKEY and FTS_API_KEY, then:
systemctl restart freetakserver-ui.service
```

---

## Port Reference

| Port  | Protocol | Purpose                     |
|-------|----------|-----------------------------|
| 8087  | TCP      | CoT TCP streaming (ATAK)    |
| 8089  | TCP      | CoT SSL streaming (ATAK)    |
| 8080  | TCP      | HTTP / data packages        |
| 8443  | TCP      | HTTPS                       |
| 19023 | TCP      | REST API                    |
| 9000  | TCP      | Server-to-server federation |
| 5000  | TCP      | Web UI                      |

---

## Adding a New Quadlet Unit

1. Create the file in `containers/`, `networks/`, or `volumes/`.
2. Add it to the `UNITS` list in `Makefile`.
3. Add `install -m 0644 "$SCRIPT_DIR/<path>" "$QUADLET_DIR/<file>"` to
   `fts_setup.sh`.
4. Write bats tests covering: file existence after install, required INI
   keys, security posture, any new ports.
5. Run `make test` before committing.

---

## What Claude Should Not Do

- Do not use `--create-home` with `useradd` — the ZFS dataset serves as home.
- Do not create datasets with `zfs create -p` when parent datasets need explicit creation.
- Do not use `docker-compose` or `podman-compose` — this project is
  quadlet-native.
- Do not use bash-specific syntax in `fts_setup.sh`.
- Do not add bind mounts to host paths in container units.
- Do not reference `docker.io` images.
- Do not write tests that require live podman, systemd, or network access.
- Do not modify `fts.env` content in tests — use `$TEST_DIR` copies only.
