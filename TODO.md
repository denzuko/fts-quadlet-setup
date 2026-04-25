# TODO

Open work items for fts-quadlet-setup.
Format: `[ ]` open · `[x]` done · `[-]` deferred

---

## v2.1 — Hardening

- [ ] PKI bootstrap — generate FTS CA and client certs; set `FTS_CLIENT_CERT_REQUIRED=True` automatically when certs are present
- [ ] Secrets rotation helper — re-run `gen_secret` for `FTS_UI_WSKEY` / `FTS_API_KEY`, patch live env file, restart UI service
- [ ] Podman secret backend — store generated secrets via `podman secret create` and reference with `Secret=` in quadlet units instead of plain env file
- [ ] SELinux `.te` policy module for FTS data volume label on RHEL/Fedora

## v2.1 — Networking

- [ ] Caddy reverse proxy quadlet — automatic TLS via ACME; remove direct host-port exposure for 8080/5000
- [ ] IPv6 dual-stack — `IPv6=true` and `Subnet=fd89:2::/64` in `fts.network`
- [ ] Federation peering example — two-node FTS setup, document 9000 port requirements

## v2.2 — Observability

- [ ] Prometheus sidecar quadlet exposing FTS REST API stats on port 9100
- [ ] Alloy/Loki log shipper quadlet for journald → Loki pipeline
- [ ] `OnFailure=` systemd unit firing webhook on service failure

## v2.2 — Ops

- [ ] `podman auto-update` weekly timer unit with journal notice on image change
- [ ] ZFS dataset snapshot pruning — keep last N `@install-*` snapshots, prune older ones
- [ ] `check-updates` target in CI comparing GHCR digest to deployed digest

## v3.0 — CI / Release

- [ ] GitHub Actions: automated release on tag push — build `_site/`, create GitHub release with notes from CHANGELOG
- [ ] Image digest pinning — replace `:latest` with digest refs; `make pin-digests` → update and PR
- [ ] CycloneDX SBOM generation for both pulled images
- [ ] Dependabot config for `peaceiris/actions-gh-pages` and `actions/checkout`

## Backlog

- [ ] FreeBSD jail port — replace Quadlet/systemd with `rc.d` service + `cbsd`
- [ ] Ansible role wrapping installer for fleet deployment
- [ ] `fts.pod` quadlet grouping both containers (blocked: AutoUpdate issues inside pods upstream)
