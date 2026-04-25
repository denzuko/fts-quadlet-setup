# fts-quadlet-setup

FreeTAKServer deployed as rootless Podman Quadlet units under systemd.
ZFS-backed, service-account-isolated, HAProxy-fronted on `*.tak.dapla.net`.

## Install

```sh
curl -fsSL https://denzuko.github.io/fts-quadlet-setup/fts_setup.sh | doas sh
```

Override any default at runtime via environment variables:

```sh
curl -fsSL https://denzuko.github.io/fts-quadlet-setup/fts_setup.sh \
    | doas env FTS_USER=freetak FTS_POOL=tank sh
```

## Uninstall

```sh
curl -fsSL https://denzuko.github.io/fts-quadlet-setup/fts_setup.sh \
    | doas env FTS_UNINSTALL=1 sh
```

## Configuration defaults

All tunables are environment variables. Pass at runtime to override.

| Variable | Default | Description |
|---|---|---|
| `FTS_IP` | auto-detected | Host VIP via `ip route` |
| `FTS_USER` | `ftsvc` | Service account name |
| `FTS_UID` | `2001` | Service account UID |
| `ZFS_POOL` | `storage` | ZFS pool name |
| `FTS_VERSION` | `2.0.0` | Release version tag (used on ZFS datasets) |
| `IMAGE_CORE` | `ghcr.io/freetakteam/freetakserver:latest` | Core image |
| `IMAGE_UI` | `ghcr.io/freetakteam/ui:latest` | UI image |
| `FTS_UI_WSKEY` | generated | WebSocket key — `openssl rand -hex 32` |
| `FTS_API_KEY` | generated | Bearer token — `openssl rand -hex 32` |
| `FTS_COT_PORT` | `8087` | CoT TCP |
| `FTS_COT_PORT_S` | `8089` | CoT SSL |
| `FTS_API_PORT` | `19023` | REST API |
| `FTS_HTTP_PORT` | `8080` | HTTP / data packages |
| `FTS_HTTPS_PORT` | `8443` | HTTPS |
| `FTS_FED_PORT` | `9000` | Federation |
| `FTS_UI_PORT` | `5000` | Web UI |
| `BUS_TIMEOUT` | `30` | D-Bus socket poll timeout (seconds) |
| `FTS_UNINSTALL` | `0` | Set to `1` to remove everything |

## Secrets

`FTS_UI_WSKEY` and `FTS_API_KEY` are generated with `openssl rand -hex 32` at install time. They are stored in a per-installation tmpfs namespace under `/dev/shm/fts-<user>.<random>/` and written into the quadlet env file. The `/dev/shm` directory is cleared on reboot by design. Copy the values from the secret namespace immediately after install if you need to record them.

## ZFS datasets

```
storage/containers/fts   mountpoint=/srv/fts        compression=lz4 atime=off
storage/users/ftsvc      mountpoint=/var/lib/ftsvc  compression=lz4 atime=off
```

Each dataset is tagged with `fts:version=<release>` and snapshotted at install as `@install-v<version>-<date>`.

## Operations

```sh
# Status
machinectl shell ftsvc@ -- systemctl --user status freetakserver.service

# Logs
machinectl shell ftsvc@ -- journalctl --user -u freetakserver.service -f

# Restart
machinectl shell ftsvc@ -- systemctl --user restart freetakserver-ui.service

# Image update
machinectl shell ftsvc@ -- podman auto-update
```

## HAProxy

See `examples/haproxy-fts.cfg` for additive stanzas to drop into the dapla.net HAProxy config. TCP passthrough is used for CoT SSL (8089) — HAProxy must not terminate TLS, as FTS manages its own PKI for ATAK client cert auth.

## Development

Lint and test run in CI on every push and PR. Fixes are submitted via pull request.

```sh
shellcheck -S style fts_setup.sh
bats tests/fts_setup.bats
```

## License

BSD 2-Clause — © 2026 Dwight Spencer / Da Planet Security
