# fts-quadlet-setup

Podman Quadlet deployment of [FreeTAKServer](https://github.com/FreeTAKTeam/FreeTakServer)
following the conventions established in [pbx-quadlet-setup](https://github.com/denzuko/pbx-quadlet-setup).

## Layout

```
fts-quadlet-setup/
├── fts_setup.sh              # Bootstrap installer (mirrors pbx_setup.sh)
├── containers/
│   ├── freetakserver.container     # FTS core quadlet unit
│   └── freetakserver-ui.container  # FTS web UI quadlet unit
├── networks/
│   └── fts.network                 # Isolated bridge network
├── volumes/
│   ├── fts-data.volume             # Core persistent data
│   └── fts-ui-data.volume          # UI persistent data
└── env/
    └── fts.env                     # Site-local configuration
```

## Testing

```sh
# Lint only
make lint

# Full suite (lint + bats)
make test

# Direct bats invocation
bats tests/fts_setup.bats

# Verbose output per-test
bats --tap tests/fts_setup.bats
```

**Requirements:** `bats-core >= 1.7`, `shellcheck`. No live podman or systemd needed — all system calls are stubbed via `$MOCK_DIR` on `$PATH`.

Test coverage spans 10 categories (50+ assertions):

1. `shellcheck` lint at both error and style severity
2. Network unit content (NetworkName, Driver, subnet)
3. Volume unit content (VolumeName declarations)
4. Core container unit (image ref, ports, volume mount, health check, security posture)
5. UI container unit (Requires= ordering, DNS-name upstream, volume, hardening)
6. `fts.env` defaults (all required keys present)
7. Installer behavior (file placement, IP injection, systemctl calls)
8. Idempotency (operator edits to `fts.env` survive re-runs)
9. No Docker Hub references (GHCR only)
10. SELinux `:Z` volume labels

## Quick Start

```sh
# Clone and deploy
git clone https://github.com/denzuko/fts-quadlet-setup
cd fts-quadlet-setup

# Install (auto-detects external IP)
FTS_IP=192.0.2.10 sudo sh fts_setup.sh

# Or explicit flag
sudo sh fts_setup.sh --ip 192.0.2.10
```

## Ports

| Service         | Port  | Protocol | Purpose                     |
|----------------|-------|----------|-----------------------------|
| CoT TCP         | 8087  | TCP      | ATAK client streaming       |
| CoT SSL         | 8089  | TCP      | ATAK SSL streaming          |
| HTTP/data pkgs  | 8080  | TCP      | Data package server         |
| HTTPS           | 8443  | TCP      | HTTPS                       |
| REST API        | 19023 | TCP      | REST API / management       |
| Federation      | 9000  | TCP      | Server-to-server federation |
| Web UI          | 5000  | TCP      | Browser management UI       |

## Post-Install

Edit `/etc/containers/systemd/fts.env` and set:

```sh
FTS_UI_WSKEY=<random-string>
FTS_API_KEY=<bearer-token>
```

Then restart the UI:

```sh
systemctl restart freetakserver-ui.service
```

## Management

```sh
# Status
systemctl status freetakserver.service freetakserver-ui.service

# Logs
journalctl -u freetakserver.service -f
journalctl -u freetakserver-ui.service -f

# Restart
systemctl restart freetakserver.service

# Auto-update images (podman-auto-update must be running)
podman auto-update --dry-run
```

## Security Notes

- Both containers run with `DropCapability=ALL` and `NoNewPrivileges=true`
- Inter-container traffic stays on the `fts` bridge (10.89.2.0/24), off the host network stack
- `fts.env` is installed mode 0640 — restrict to root + a service group as appropriate
- Set `FTS_CLIENT_CERT_REQUIRED=True` in `fts.env` for production TAK PKI enforcement
- Rotate `FTS_UI_WSKEY` and `FTS_API_KEY` before going live
