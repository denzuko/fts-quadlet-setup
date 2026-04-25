#!/usr/bin/env bats
## BATS Unit Tests — fts_setup.sh / FreeTAKServer Quadlet
## Run: bats tests/fts_setup.bats
## Requires: bats-core >= 1.7, shellcheck
##
## Tests validate:
##   1. fts_setup.sh passes shellcheck (style + error gates)
##   2. Unit file content correctness (all 7 quadlet files)
##   3. Installer behavior with stubbed system commands
##   4. Idempotent env file handling (no clobber on re-run)
##   5. IP injection into fts.env
##   6. Service dependency ordering
##   7. Security posture declarations in container units
##
## System-level operations (podman pull, systemctl, ip) are fully stubbed.
## No live network, no live podman, no live systemd required.

# ─── Fixtures ────────────────────────────────────────────────────────────────

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
    TEST_DIR="$(mktemp -d /tmp/fts-bats-XXXXXX)"
    MOCK_DIR="$TEST_DIR/mock_bin"
    QUADLET_DIR="$TEST_DIR/etc/containers/systemd"

    mkdir -p \
        "$QUADLET_DIR" \
        "$MOCK_DIR"

    # ── Mock binaries (deterministic, never touch the host) ──────────────────

    # podman: accepts pull, returns 0; any other subcommand also 0
    cat > "$MOCK_DIR/podman" << 'EOF'
#!/bin/sh
case "$1" in
    pull) echo "Pulling $2 (mock)" ;;
    --version) echo "podman version 4.9.0" ;;
esac
exit 0
EOF

    # systemctl: records calls so tests can assert on them
    cat > "$MOCK_DIR/systemctl" << EOF
#!/bin/sh
echo "systemctl \$*" >> "$TEST_DIR/systemctl.log"
exit 0
EOF

    # ip route get 1 — returns a deterministic host IP
    cat > "$MOCK_DIR/ip" << 'EOF'
#!/bin/sh
echo "1.0.0.0 via 192.0.2.1 dev eth0 src 192.0.2.50 uid 1000"
EOF

    # curl — smoke test probe: always healthy
    cat > "$MOCK_DIR/curl" << 'EOF'
#!/bin/sh
exit 0
EOF

    # install — real install semantics so unit files land in $QUADLET_DIR
    cat > "$MOCK_DIR/install" << 'EOF'
#!/bin/sh
exec /usr/bin/install "$@"
EOF

    # sed — real sed
    cat > "$MOCK_DIR/sed" << 'EOF'
#!/bin/sh
exec /bin/sed "$@"
EOF

    chmod +x "$MOCK_DIR"/*
    export PATH="$MOCK_DIR:$PATH"

    # Expose dirs to the installer
    export QUADLET_DIR
    export FTS_IP="10.0.0.1"
}

teardown() {
    rm -rf "$TEST_DIR"
}

# Run the installer in a subshell with overridden QUADLET_DIR
_run_installer() {
    QUADLET_DIR="$QUADLET_DIR" FTS_IP="${FTS_IP:-10.0.0.1}" \
        sh "$REPO_ROOT/fts_setup.sh" --quadlet-dir "$QUADLET_DIR" --ip "${FTS_IP:-10.0.0.1}"
}

# ─── 1. Lint / ShellCheck ────────────────────────────────────────────────────

@test "shellcheck: fts_setup.sh passes at error severity" {
    run shellcheck -S error "$REPO_ROOT/fts_setup.sh"
    [ "$status" -eq 0 ]
}

@test "shellcheck: fts_setup.sh passes at style severity" {
    run shellcheck -S style "$REPO_ROOT/fts_setup.sh"
    [ "$status" -eq 0 ]
}

# ─── 2. Unit file content — network ──────────────────────────────────────────

@test "fts.network: declares NetworkName=fts" {
    grep -q "^NetworkName=fts" "$REPO_ROOT/networks/fts.network"
}

@test "fts.network: uses bridge driver" {
    grep -q "^Driver=bridge" "$REPO_ROOT/networks/fts.network"
}

@test "fts.network: has [Network] section" {
    grep -q "^\[Network\]" "$REPO_ROOT/networks/fts.network"
}

# ─── 3. Unit file content — volumes ──────────────────────────────────────────

@test "fts-data.volume: has VolumeName=fts-data" {
    grep -q "^VolumeName=fts-data" "$REPO_ROOT/volumes/fts-data.volume"
}

@test "fts-ui-data.volume: has VolumeName=fts-ui-data" {
    grep -q "^VolumeName=fts-ui-data" "$REPO_ROOT/volumes/fts-ui-data.volume"
}

# ─── 4. Unit file content — freetakserver.container ──────────────────────────

@test "freetakserver.container: references ghcr.io image" {
    grep -q "^Image=ghcr.io/freetakteam/freetakserver" \
        "$REPO_ROOT/containers/freetakserver.container"
}

@test "freetakserver.container: has AutoUpdate=registry" {
    grep -q "^AutoUpdate=registry" \
        "$REPO_ROOT/containers/freetakserver.container"
}

@test "freetakserver.container: mounts fts-data volume" {
    grep -q "^Volume=fts-data\.volume:/opt/FTSData" \
        "$REPO_ROOT/containers/freetakserver.container"
}

@test "freetakserver.container: uses fts network" {
    grep -q "^Network=fts\.network" \
        "$REPO_ROOT/containers/freetakserver.container"
}

@test "freetakserver.container: publishes CoT TCP port 8087" {
    grep -q "^PublishPort=8087:8087" \
        "$REPO_ROOT/containers/freetakserver.container"
}

@test "freetakserver.container: publishes CoT SSL port 8089" {
    grep -q "^PublishPort=8089:8089" \
        "$REPO_ROOT/containers/freetakserver.container"
}

@test "freetakserver.container: publishes REST API port 19023" {
    grep -q "^PublishPort=19023:19023" \
        "$REPO_ROOT/containers/freetakserver.container"
}

@test "freetakserver.container: publishes Federation port 9000" {
    grep -q "^PublishPort=9000:9000" \
        "$REPO_ROOT/containers/freetakserver.container"
}

@test "freetakserver.container: has DropCapability=ALL (hardened)" {
    grep -q "^DropCapability=ALL" \
        "$REPO_ROOT/containers/freetakserver.container"
}

@test "freetakserver.container: has NoNewPrivileges=true (hardened)" {
    grep -q "^NoNewPrivileges=true" \
        "$REPO_ROOT/containers/freetakserver.container"
}

@test "freetakserver.container: EnvironmentFile points to fts.env" {
    grep -q "^EnvironmentFile=.*fts\.env" \
        "$REPO_ROOT/containers/freetakserver.container"
}

@test "freetakserver.container: has [Install] WantedBy for boot" {
    grep -q "^WantedBy=multi-user\.target" \
        "$REPO_ROOT/containers/freetakserver.container"
}

@test "freetakserver.container: has health check command" {
    grep -q "^HealthCmd=" \
        "$REPO_ROOT/containers/freetakserver.container"
}

@test "freetakserver.container: health check targets REST API port 19023" {
    grep -q "19023" "$REPO_ROOT/containers/freetakserver.container"
}

@test "freetakserver.container: Restart=on-failure in [Service]" {
    grep -q "^Restart=on-failure" \
        "$REPO_ROOT/containers/freetakserver.container"
}

# ─── 5. Unit file content — freetakserver-ui.container ───────────────────────

@test "freetakserver-ui.container: references ghcr.io ui image" {
    grep -q "^Image=ghcr.io/freetakteam/ui" \
        "$REPO_ROOT/containers/freetakserver-ui.container"
}

@test "freetakserver-ui.container: Requires= core service" {
    grep -q "^Requires=freetakserver\.service" \
        "$REPO_ROOT/containers/freetakserver-ui.container"
}

@test "freetakserver-ui.container: After= includes core service" {
    grep -q "freetakserver\.service" \
        "$REPO_ROOT/containers/freetakserver-ui.container"
}

@test "freetakserver-ui.container: uses fts network (inter-container comms)" {
    grep -q "^Network=fts\.network" \
        "$REPO_ROOT/containers/freetakserver-ui.container"
}

@test "freetakserver-ui.container: connects to core by container DNS name" {
    # UI must address core as 'freetakserver', not an IP
    grep -q "FTS_IP=freetakserver" \
        "$REPO_ROOT/containers/freetakserver-ui.container"
}

@test "freetakserver-ui.container: publishes UI port 5000" {
    grep -q "^PublishPort=5000:5000" \
        "$REPO_ROOT/containers/freetakserver-ui.container"
}

@test "freetakserver-ui.container: mounts fts-ui-data volume" {
    grep -q "^Volume=fts-ui-data\.volume:" \
        "$REPO_ROOT/containers/freetakserver-ui.container"
}

@test "freetakserver-ui.container: has DropCapability=ALL (hardened)" {
    grep -q "^DropCapability=ALL" \
        "$REPO_ROOT/containers/freetakserver-ui.container"
}

@test "freetakserver-ui.container: has NoNewPrivileges=true (hardened)" {
    grep -q "^NoNewPrivileges=true" \
        "$REPO_ROOT/containers/freetakserver-ui.container"
}

@test "freetakserver-ui.container: has AutoUpdate=registry" {
    grep -q "^AutoUpdate=registry" \
        "$REPO_ROOT/containers/freetakserver-ui.container"
}

# ─── 6. fts.env content ───────────────────────────────────────────────────────

@test "fts.env: defines FTS_IP placeholder" {
    grep -q "^FTS_IP=" "$REPO_ROOT/env/fts.env"
}

@test "fts.env: defines FTS_COT_PORT=8087" {
    grep -q "^FTS_COT_PORT=8087" "$REPO_ROOT/env/fts.env"
}

@test "fts.env: defines FTS_API_PORT=19023" {
    grep -q "^FTS_API_PORT=19023" "$REPO_ROOT/env/fts.env"
}

@test "fts.env: defines FTS_UI_WSKEY placeholder (must be changed)" {
    grep -q "^FTS_UI_WSKEY=" "$REPO_ROOT/env/fts.env"
}

@test "fts.env: defines FTS_API_KEY placeholder (must be changed)" {
    grep -q "^FTS_API_KEY=" "$REPO_ROOT/env/fts.env"
}

@test "fts.env: FTS_LOG_LEVEL defaults to INFO" {
    grep -q "^FTS_LOG_LEVEL=INFO" "$REPO_ROOT/env/fts.env"
}

@test "fts.env: FTS_CLIENT_CERT_REQUIRED defaults to False" {
    grep -q "^FTS_CLIENT_CERT_REQUIRED=False" "$REPO_ROOT/env/fts.env"
}

# ─── 7. Installer behavioral tests ───────────────────────────────────────────

@test "installer: exits non-zero on unknown flag" {
    run sh "$REPO_ROOT/fts_setup.sh" --no-such-flag
    [ "$status" -ne 0 ]
}

@test "installer: writes fts.network to QUADLET_DIR" {
    _run_installer
    [ -f "$QUADLET_DIR/fts.network" ]
}

@test "installer: writes fts-data.volume to QUADLET_DIR" {
    _run_installer
    [ -f "$QUADLET_DIR/fts-data.volume" ]
}

@test "installer: writes fts-ui-data.volume to QUADLET_DIR" {
    _run_installer
    [ -f "$QUADLET_DIR/fts-ui-data.volume" ]
}

@test "installer: writes freetakserver.container to QUADLET_DIR" {
    _run_installer
    [ -f "$QUADLET_DIR/freetakserver.container" ]
}

@test "installer: writes freetakserver-ui.container to QUADLET_DIR" {
    _run_installer
    [ -f "$QUADLET_DIR/freetakserver-ui.container" ]
}

@test "installer: writes fts.env to QUADLET_DIR" {
    _run_installer
    [ -f "$QUADLET_DIR/fts.env" ]
}

@test "installer: stamps --ip value into fts.env FTS_IP" {
    FTS_IP="10.9.8.7"
    _run_installer
    grep -q "^FTS_IP=10\.9\.8\.7" "$QUADLET_DIR/fts.env"
}

@test "installer: idempotent — does not clobber existing fts.env" {
    # Pre-populate env with a sentinel operator value
    _run_installer
    echo "OPERATOR_SECRET=mysecret" >> "$QUADLET_DIR/fts.env"

    # Re-run installer
    _run_installer

    # Operator line must survive
    grep -q "^OPERATOR_SECRET=mysecret" "$QUADLET_DIR/fts.env"
}

@test "installer: calls systemctl daemon-reload" {
    _run_installer
    grep -q "daemon-reload" "$TEST_DIR/systemctl.log"
}

@test "installer: enables freetakserver.service" {
    _run_installer
    grep -q "freetakserver.service" "$TEST_DIR/systemctl.log"
}

@test "installer: enables freetakserver-ui.service" {
    _run_installer
    grep -q "freetakserver-ui.service" "$TEST_DIR/systemctl.log"
}

@test "installer: auto-detects IP when FTS_IP is not set" {
    # ip mock returns 192.0.2.50 via awk extraction
    unset FTS_IP
    run sh "$REPO_ROOT/fts_setup.sh" --quadlet-dir "$QUADLET_DIR"
    # Should not fail on missing FTS_IP — auto-detect path
    [ "$status" -eq 0 ]
}

# ─── 8. Dependency ordering ───────────────────────────────────────────────────

@test "freetakserver.container: After= includes fts-data-volume.service" {
    grep -q "fts-data-volume\.service" \
        "$REPO_ROOT/containers/freetakserver.container"
}

@test "freetakserver.container: After= includes fts-network.service" {
    grep -q "fts-network\.service" \
        "$REPO_ROOT/containers/freetakserver.container"
}

@test "freetakserver-ui.container: After= includes fts-ui-data-volume.service" {
    grep -q "fts-ui-data-volume\.service" \
        "$REPO_ROOT/containers/freetakserver-ui.container"
}

# ─── 9. No docker-hub references (GHCR only) ─────────────────────────────────

@test "freetakserver.container: no docker.io image reference" {
    run grep "docker\.io" "$REPO_ROOT/containers/freetakserver.container"
    [ "$status" -ne 0 ]
}

@test "freetakserver-ui.container: no docker.io image reference" {
    run grep "docker\.io" "$REPO_ROOT/containers/freetakserver-ui.container"
    [ "$status" -ne 0 ]
}

# ─── 10. Selinux volume label ─────────────────────────────────────────────────

@test "freetakserver.container: volume mount has :Z SELinux label" {
    grep -q ":/opt/FTSData:Z" \
        "$REPO_ROOT/containers/freetakserver.container"
}

@test "freetakserver-ui.container: volume mount has :Z SELinux label" {
    grep -q ":Z" \
        "$REPO_ROOT/containers/freetakserver-ui.container"
}
