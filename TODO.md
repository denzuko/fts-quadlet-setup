# TODO

Tracked work items for fts-quadlet-setup.
Format: `[ ]` open · `[x]` done · `[-]` deferred/won't-do

---

## v1.0.0 — Done

- [x] ZFS datasets: `storage/containers/fts` + `storage/users/ftsvc`
- [x] Rootless service account via `useradd --system --no-create-home`
- [x] Linger + machinectl + user-scoped quadlets

## v1.1 — Hardening & TLS

- [ ] **PKI bootstrap** — generate FTS certificate authority and client certs in `fts_setup.sh`
      and inject `FTS_CLIENT_CERT_REQUIRED=True` automatically when certs are present
- [ ] **mTLS enforcement gate** — bats test that verifies `FTS_CLIENT_CERT_REQUIRED` is
      not `False` when cert files exist under the data volume mount path
- [ ] **Secrets management** — replace plain-text `FTS_UI_WSKEY` / `FTS_API_KEY` in
      `fts.env` with a Podman secret reference (`Secret=` quadlet key) pulled from
      `podman secret create`
- [ ] **SELinux policy** — write a minimal `.te` module for the FTS data volume label
      so `DropCapability=ALL` survives a `restorecon` pass on RHEL/Fedora hosts

## v1.1 — Networking

- [ ] **Caddy reverse proxy quadlet** — add `caddy.container` fronting ports 8080/5000
      with automatic TLS via ACME; remove direct host-port exposure for those two services
- [ ] **IPv6 dual-stack** — add `IPv6=true` and a `Subnet=fd89:2::/64` to `fts.network`
- [ ] **Federation peering example** — document and test a two-node FTS federation
      setup using the `9000` port and a second quadlet instance

## v1.2 — Observability

- [ ] **Prometheus scrape target** — add `prophile`-style metrics exporter sidecar
      quadlet that exposes FTS REST API stats on port `9100` for scraping
- [ ] **Loki log shipping** — add `alloy.container` quadlet shipping journald logs
      from both FTS units to a Loki endpoint via `journald` input
- [ ] **Healthcheck alerting** — systemd `OnFailure=` unit that fires a webhook
      (configurable via `fts.env`) when either FTS service enters failed state

## v1.2 — Ops

- [ ] **`podman auto-update` timer** — install a systemd timer unit that runs
      `podman auto-update` weekly and sends a journal notice on image change
- [ ] **ZFS dataset option** — detect ZFS and optionally create
      `rpool/data/fts-data` + `rpool/data/fts-ui-data` datasets with
      `compression=lz4` before volume creation
- [ ] **Unattended upgrade gate** — add a `make check-updates` target that
      polls GHCR for a newer digest and prints a diff of the changelog

## v1.3 — CI

- [ ] **GitHub Actions workflow** — `lint-and-test.yml` running `make test`
      on push/PR for Fedora 41 and Debian 12 runners
- [ ] **Container image digest pinning** — replace `:latest` tags with digest
      refs in unit files and provide a `make pin-digests` target to refresh them
- [ ] **SBOM generation** — `make sbom` target using `syft` to produce a
      CycloneDX SBOM for the two pulled images
- [ ] **Release automation** — `make release VERSION=x.y.z` target that bumps
      CHANGELOG, tags, and calls `gh release create`

## Backlog / Under Consideration

- [ ] Helm-style templating via `envsubst` or `m4` for multi-site deployments
- [ ] `fts.pod` quadlet grouping both containers under a single Podman pod
      (blocked: `AutoUpdate` inside pods has known issues upstream)
- [ ] Ansible role wrapping `fts_setup.sh` for fleet deployments
- [ ] FreeBSD jail port (replace Quadlet with `rc.d` service + `cbsd`)
