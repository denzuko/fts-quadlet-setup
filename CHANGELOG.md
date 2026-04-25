# Changelog

All notable changes to fts-quadlet-setup are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.0.0] — 2026-04-24

### Added

- `fts_setup.sh` — POSIX sh bootstrapper mirroring `pbx-quadlet-setup/pbx_setup.sh` conventions
  - `--ip` flag and `$FTS_IP` env var for site-local IP injection
  - Auto-detection fallback via `ip route get 1`
  - Idempotent: preserves operator edits to `fts.env` on re-runs
  - Smoke test loop against REST API `/SystemStatus/getStatus` after start
- `containers/freetakserver.container` — Podman Quadlet unit for FTS core
  - GHCR image (`ghcr.io/freetakteam/freetakserver:latest`)
  - `AutoUpdate=registry` for unattended image tracking
  - All six TAK ports published: CoT TCP (8087), CoT SSL (8089), HTTP (8080), HTTPS (8443), REST API (19023), Federation (9000)
  - Health check via REST API status endpoint
  - `DropCapability=ALL` + `NoNewPrivileges=true` security posture
  - SELinux `:Z` volume label on data mount
- `containers/freetakserver-ui.container` — Podman Quadlet unit for FTS Web UI
  - `Requires=freetakserver.service` enforces correct start order
  - Inter-container DNS name (`FTS_IP=freetakserver`) avoids hardcoded IPs
  - UI port 5000 published to host
  - Same hardening posture as core container
- `networks/fts.network` — isolated bridge network (`10.89.2.0/24`)
- `volumes/fts-data.volume` — named volume for core state (DB, certs, data packages)
- `volumes/fts-ui-data.volume` — named volume for UI state
- `env/fts.env` — site-local configuration with all FTS environment variables
- `tests/fts_setup.bats` — bats-core test suite (50+ assertions, 10 categories)
  - ShellCheck lint at error and style severity
  - All unit file content validated without live system resources
  - Installer behavioral tests with fully stubbed `$MOCK_DIR`
  - Idempotency, IP injection, dependency ordering, GHCR-only image ref checks
- `Makefile` — `lint`, `test`, `install`, `uninstall`, `help` targets
- `CLAUDE.md` — Claude Code context file for AI-assisted development
- `LICENSE` — BSD 2-Clause

[1.0.0]: https://github.com/denzuko/fts-quadlet-setup/releases/tag/v1.0.0
