# Changelog

All notable changes to fts-quadlet-setup are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [2.0.2] — 2026-04-25

### Changed
- Summary output replaced with inline m4 template (`share/summary.m4`)
- `render()` helper in `fts_setup.sh` pipes `_macro()` through `m4 -D` flags — no temp files, no build step
- `m4` added to preflight `need` checks
- Four macros: `_preflight` (startup), `_header`, `_endpoints`, `_ops` (final summary)
- `changequote([\`[\`], [\`]\`])` prevents label strings from being substituted by m4
- 12 new bats assertions covering macro definitions, rendering, changequote correctness, and absence of bare `printf` summary blocks

## [2.0.1] — 2026-04-25

### Fixed
- `examples/haproxy-fts.cfg`: HAProxy terminates TLS for all services. CoT SSL (8089) and federation (9000) frontends now use `ssl crt /etc/haproxy/certs/dapla_stack.pem` on bind; backend server lines remain plain (no `ssl` keyword). CoT TCP (8087) stays plain passthrough — no TLS in that protocol. `FTS_CLIENT_CERT_REQUIRED=False` required since client cert auth is handled externally.
- QA rule R08 inverted: was "no TLS termination at HAProxy"; now "HAProxy terminates ALL TLS, containers receive plain"
- `tests/fts_setup.bats`: R08 tests updated — assert `ssl crt` on CoT SSL and federation bind lines; assert no double-TLS on backend server lines
- `docs/index.html`: ports table, compliance table, and QA prompt R08 updated
- `CLAUDE.md`: HAProxy TLS model clarified

## [2.0.0] — 2026-04-25

### Added
- Secrets generated with `openssl rand -hex 32`; stored in `/dev/shm/fts-<user>.<random>/` (tmpfs namespace via `mktemp -d`)
- VIP auto-detection via `ip route` — no `--ip` flag required
- `FTS_UNINSTALL=1` path: stops services, removes OCI images/volumes/networks, deletes service account, destroys ZFS datasets
- All tunables overridable as runtime environment variables (12-factor config); no CLI flags
- ZFS dataset version tagging with `fts:version=<release>` property
- ZFS install snapshot: `@install-v<version>-<date>` on both datasets at install time
- `FTS_VERSION` tunable propagated into dataset tags and env file header
- Smoke test uses `FTS_API_PORT` variable instead of hardcoded port

### Changed
- Removed Makefile — installer is the authoritative deployment path
- Removed `docs/fts_setup.sh` duplicate — CI copies `fts_setup.sh` to `_site/` at build time
- Removed stray root-level `index.html` (old bad-style version)
- Removed all `--flag` argument parsing from installer; env vars only
- Secrets (`FTS_UI_WSKEY`, `FTS_API_KEY`) no longer in `env/fts.env` template — generated at install
- `env/fts.env` is now a template with no secrets; live copy is written by installer
- CI workflow: `lint` → `test` → `pages` (no Makefile dependency)
- Section numbering updated: 14 sections (added secrets, VIP, uninstall)
- README rewritten: defaults table, secrets lifecycle, ZFS dataset docs, no Makefile references

### Fixed
- `tests/fts_setup.bats`: systemctl mock now creates real unix socket (python3) so `[ -S ]` poll passes
- `tests/fts_setup.bats`: `BUS_TIMEOUT=5` in `_run_installer` — tests no longer wait 30s
- `tests/fts_setup.bats`: `install -o` mock strips owner flag (CI has no `ftsvc` user)
- `tests/fts_setup.bats`: `zfs`/`zpool` mocks promoted to main `setup()` (all installer tests need them)
- `tests/fts_setup.bats`: `chown` mock added to `setup()`
- `tests/fts_setup.bats`: useradd tests override `getent` to absent path

## [1.0.0] — 2026-04-24

### Added
- Initial release: rootless Podman Quadlets, ZFS datasets, useradd service account, machinectl delegation, linger, HAProxy `*.tak.dapla.net` vhosts, 60+ bats tests, GitHub Pages + CI

[2.0.0]: https://github.com/denzuko/fts-quadlet-setup/compare/v1.0.0...v2.0.0
[1.0.0]: https://github.com/denzuko/fts-quadlet-setup/releases/tag/v1.0.0
