#!/usr/bin/env bats
## BATS Unit Tests — fts_setup.sh (rootless, service account)
## Run: bats tests/fts_setup.bats
## Requires: bats-core >= 1.7, shellcheck
##
## Tests validate:
##   1.  fts_setup.sh passes shellcheck (error + style)
##   2.  Script refuses to run as non-root
##   3.  Script fails on unknown flags
##   4.  Service account creation via useradd
##   5.  Linger enablement via loginctl
##   6.  user@UID.service start via systemctl
##   7.  Session bus polling logic
##   8.  Image pull in rootless store (as service account)
##   9.  Unit file installation to user quadlet dir
##   10. fts.env idempotency and IP stamping
##   11. systemctl --user daemon-reload + service enable
##   12. Unit file content (ports, images, WantedBy, security posture)
##   13. EnvironmentFile uses %h (home-relative), not /etc/
##   14. WantedBy=default.target (not multi-user.target) in all units
##   15. No docker.io references; GHCR only
##   16. SELinux :Z labels on volume mounts

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

# ─── Fixtures ────────────────────────────────────────────────────────────────

setup() {
    TEST_DIR="$(mktemp -d /tmp/fts-bats-XXXXXX)"
    MOCK_DIR="$TEST_DIR/mock_bin"
    FTS_USER="ftsvc"
    FTS_UID="2001"
    FTS_HOME="$TEST_DIR/home/$FTS_USER"
    QUADLET_DIR="$FTS_HOME/.config/containers/systemd"

    mkdir -p \
        "$MOCK_DIR" \
        "$FTS_HOME/.config/containers/systemd"

    # ── Mock: id — return uid 0 (root) so root-check passes ─────────────────
    cat > "$MOCK_DIR/id" << EOF
#!/bin/sh
case "\$*" in
    *-u*) echo 0 ;;
    *)    echo "uid=0(root) gid=0(root)" ;;
esac
EOF

    # ── Mock: useradd — records invocation, creates home dir ─────────────────
    cat > "$MOCK_DIR/useradd" << EOF
#!/bin/sh
echo "useradd \$*" >> "$TEST_DIR/useradd.log"
mkdir -p "$FTS_HOME"
exit 0
EOF

    # ── Mock: getent — simulates passwd entry for ftsvc ──────────────────────
    cat > "$MOCK_DIR/getent" << EOF
#!/bin/sh
if [ "\$1" = "passwd" ] && [ "\$2" = "$FTS_USER" ]; then
    echo "${FTS_USER}:x:${FTS_UID}:${FTS_UID}:FreeTAKServer service account:${FTS_HOME}:/bin/bash"
elif [ "\$1" = "passwd" ] && [ -z "\${2:-}" ]; then
    echo "${FTS_USER}:x:${FTS_UID}:${FTS_UID}:FreeTAKServer service account:${FTS_HOME}:/bin/bash"
fi
exit 0
EOF

    # ── Mock: loginctl — enable-linger succeeds; show-user returns Linger=yes
    cat > "$MOCK_DIR/loginctl" << EOF
#!/bin/sh
echo "loginctl \$*" >> "$TEST_DIR/loginctl.log"
case "\$*" in
    *show-user*) echo "Linger=yes" ;;
esac
exit 0
EOF

    # ── Mock: systemctl — records calls; start user@UID creates bus socket ───
    cat > "$MOCK_DIR/systemctl" << EOF
#!/bin/sh
echo "systemctl \$*" >> "$TEST_DIR/systemctl.log"
# Simulate bus socket creation when user manager is started
case "\$*" in
    *"user@${FTS_UID}.service"*)
        mkdir -p "/run/user/${FTS_UID}"
        touch "/run/user/${FTS_UID}/bus"
        ;;
esac
exit 0
EOF

    # ── Mock: machinectl — captures commands; executes safe subset ───────────
    cat > "$MOCK_DIR/machinectl" << EOF
#!/bin/sh
echo "machinectl \$*" >> "$TEST_DIR/machinectl.log"
# For mkdir -p calls, actually create the directory
case "\$*" in
    *"mkdir -p"*)
        eval "\$(echo "\$*" | grep -o 'mkdir -p [^ ]*')" 2>/dev/null || true
        ;;
esac
exit 0
EOF

    # ── Mock: podman ─────────────────────────────────────────────────────────
    cat > "$MOCK_DIR/podman" << 'EOF'
#!/bin/sh
case "$1" in
    pull)    echo "Pulling $2 (mock)" ;;
    --version) echo "podman version 4.9.0" ;;
esac
exit 0
EOF

    # ── Mock: ip route ───────────────────────────────────────────────────────
    cat > "$MOCK_DIR/ip" << 'EOF'
#!/bin/sh
echo "1.0.0.0 via 192.0.2.1 dev eth0 src 192.0.2.50 uid 1000"
EOF

    # ── Mock: curl — smoke test always healthy ────────────────────────────────
    cat > "$MOCK_DIR/curl" << 'EOF'
#!/bin/sh
exit 0
EOF

    # ── Mock: sed / install — delegate to real binaries ─────────────────────
    printf '#!/bin/sh\nexec /bin/sed "$@"\n'         > "$MOCK_DIR/sed"
    printf '#!/bin/sh\nexec /usr/bin/install "$@"\n' > "$MOCK_DIR/install"

    chmod +x "$MOCK_DIR"/*
    export PATH="$MOCK_DIR:$PATH"

    # Expose to installer
    export FTS_USER FTS_UID FTS_HOME QUADLET_DIR
    export FTS_IP="10.0.0.1"
}

teardown() {
    rm -rf "$TEST_DIR"
    rm -f "/run/user/${FTS_UID}/bus" 2>/dev/null || true
}

# Run installer — override QUADLET_DIR so files land in temp dir
_run_installer() {
    QUADLET_DIR="$QUADLET_DIR" \
    FTS_USER="$FTS_USER" \
    FTS_UID="$FTS_UID" \
    FTS_IP="${FTS_IP:-10.0.0.1}" \
        sh "$REPO_ROOT/fts_setup.sh" \
            --ip "${FTS_IP:-10.0.0.1}" \
            --user "$FTS_USER" \
            --uid  "$FTS_UID"
}

# ─── 1. ShellCheck ───────────────────────────────────────────────────────────

@test "shellcheck: fts_setup.sh passes at error severity" {
    run shellcheck -S error "$REPO_ROOT/fts_setup.sh"
    [ "$status" -eq 0 ]
}

@test "shellcheck: fts_setup.sh passes at style severity" {
    run shellcheck -S style "$REPO_ROOT/fts_setup.sh"
    [ "$status" -eq 0 ]
}

# ─── 2. Root guard ───────────────────────────────────────────────────────────

@test "installer: exits non-zero when run as non-root" {
    # Replace id mock to return uid 1000
    cat > "$MOCK_DIR/id" << 'EOF'
#!/bin/sh
case "$*" in
    *-u*) echo 1000 ;;
    *)    echo "uid=1000(user) gid=1000(user)" ;;
esac
EOF
    run sh "$REPO_ROOT/fts_setup.sh" --ip 10.0.0.1 --user ftsvc --uid 2001
    [ "$status" -ne 0 ]
}

# ─── 3. Argument handling ────────────────────────────────────────────────────

@test "installer: exits non-zero on unknown flag" {
    run sh "$REPO_ROOT/fts_setup.sh" --no-such-flag
    [ "$status" -ne 0 ]
}

@test "installer: accepts --ip --user --uid without error" {
    run _run_installer
    [ "$status" -eq 0 ]
}

# ─── 4. Service account (useradd) ────────────────────────────────────────────

@test "installer: calls useradd with --system flag" {
    _run_installer
    grep -q "\-\-system" "$TEST_DIR/useradd.log"
}

@test "installer: useradd sets correct uid" {
    _run_installer
    grep -q "\-\-uid.*$FTS_UID\|$FTS_UID.*\-\-uid" "$TEST_DIR/useradd.log"
}

@test "installer: useradd sets home under /var/lib/" {
    _run_installer
    grep -q "/var/lib/$FTS_USER" "$TEST_DIR/useradd.log"
}

@test "installer: skips useradd when account already exists" {
    # getent already returns the user — useradd.log should NOT be created
    rm -f "$TEST_DIR/useradd.log"
    _run_installer
    # useradd is called only when account does not exist;
    # since mock getent always returns user, useradd should not run
    [ ! -f "$TEST_DIR/useradd.log" ]
}

# ─── 5. Linger ───────────────────────────────────────────────────────────────

@test "installer: calls loginctl enable-linger for service account" {
    _run_installer
    grep -q "enable-linger.*$FTS_USER\|enable-linger $FTS_USER" "$TEST_DIR/loginctl.log"
}

# ─── 6 & 7. User manager + bus polling ──────────────────────────────────────

@test "installer: starts user@UID.service" {
    _run_installer
    grep -q "user@${FTS_UID}.service" "$TEST_DIR/systemctl.log"
}

# ─── 8. Image pull via machinectl ────────────────────────────────────────────

@test "installer: pulls core image via machinectl shell" {
    _run_installer
    grep -q "podman pull.*freetakserver\|freetakserver.*pull" "$TEST_DIR/machinectl.log"
}

@test "installer: pulls UI image via machinectl shell" {
    _run_installer
    grep -q "podman pull.*ui\|ui.*pull" "$TEST_DIR/machinectl.log"
}

# ─── 9. Unit file installation ───────────────────────────────────────────────

@test "installer: writes fts.network to user quadlet dir" {
    _run_installer
    [ -f "$QUADLET_DIR/fts.network" ]
}

@test "installer: writes fts-data.volume to user quadlet dir" {
    _run_installer
    [ -f "$QUADLET_DIR/fts-data.volume" ]
}

@test "installer: writes fts-ui-data.volume to user quadlet dir" {
    _run_installer
    [ -f "$QUADLET_DIR/fts-ui-data.volume" ]
}

@test "installer: writes freetakserver.container to user quadlet dir" {
    _run_installer
    [ -f "$QUADLET_DIR/freetakserver.container" ]
}

@test "installer: writes freetakserver-ui.container to user quadlet dir" {
    _run_installer
    [ -f "$QUADLET_DIR/freetakserver-ui.container" ]
}

@test "installer: writes fts.env to user quadlet dir" {
    _run_installer
    [ -f "$QUADLET_DIR/fts.env" ]
}

# ─── 10. fts.env idempotency and IP stamping ─────────────────────────────────

@test "installer: stamps --ip value into fts.env" {
    FTS_IP="10.9.8.7" _run_installer
    grep -q "^FTS_IP=10\.9\.8\.7" "$QUADLET_DIR/fts.env"
}

@test "installer: does not clobber existing fts.env on re-run" {
    _run_installer
    echo "OPERATOR_SENTINEL=keep_me" >> "$QUADLET_DIR/fts.env"
    _run_installer
    grep -q "^OPERATOR_SENTINEL=keep_me" "$QUADLET_DIR/fts.env"
}

# ─── 11. systemctl --user calls ──────────────────────────────────────────────

@test "installer: calls systemctl --user daemon-reload via machinectl" {
    _run_installer
    grep -q "daemon-reload" "$TEST_DIR/machinectl.log"
}

@test "installer: enables freetakserver.service in user scope" {
    _run_installer
    grep -q "freetakserver\.service" "$TEST_DIR/machinectl.log"
}

@test "installer: enables freetakserver-ui.service in user scope" {
    _run_installer
    grep -q "freetakserver-ui\.service" "$TEST_DIR/machinectl.log"
}

# ─── 12. Unit file content — core container ──────────────────────────────────

@test "freetakserver.container: references ghcr.io image" {
    grep -q "^Image=ghcr\.io/freetakteam/freetakserver" \
        "$REPO_ROOT/containers/freetakserver.container"
}

@test "freetakserver.container: AutoUpdate=registry" {
    grep -q "^AutoUpdate=registry" \
        "$REPO_ROOT/containers/freetakserver.container"
}

@test "freetakserver.container: publishes CoT TCP 8087" {
    grep -q "^PublishPort=8087:8087" \
        "$REPO_ROOT/containers/freetakserver.container"
}

@test "freetakserver.container: publishes CoT SSL 8089" {
    grep -q "^PublishPort=8089:8089" \
        "$REPO_ROOT/containers/freetakserver.container"
}

@test "freetakserver.container: publishes REST API 19023" {
    grep -q "^PublishPort=19023:19023" \
        "$REPO_ROOT/containers/freetakserver.container"
}

@test "freetakserver.container: publishes Federation 9000" {
    grep -q "^PublishPort=9000:9000" \
        "$REPO_ROOT/containers/freetakserver.container"
}

@test "freetakserver.container: DropCapability=ALL" {
    grep -q "^DropCapability=ALL" \
        "$REPO_ROOT/containers/freetakserver.container"
}

@test "freetakserver.container: NoNewPrivileges=true" {
    grep -q "^NoNewPrivileges=true" \
        "$REPO_ROOT/containers/freetakserver.container"
}

@test "freetakserver.container: has health check" {
    grep -q "^HealthCmd=" \
        "$REPO_ROOT/containers/freetakserver.container"
}

@test "freetakserver.container: Restart=on-failure" {
    grep -q "^Restart=on-failure" \
        "$REPO_ROOT/containers/freetakserver.container"
}

@test "freetakserver.container: volume mount has :Z SELinux label" {
    grep -q ":/opt/FTSData:Z" \
        "$REPO_ROOT/containers/freetakserver.container"
}

# ─── 13. EnvironmentFile uses %h (user-relative path) ────────────────────────

@test "freetakserver.container: EnvironmentFile uses %h specifier" {
    grep -q "^EnvironmentFile=%h/" \
        "$REPO_ROOT/containers/freetakserver.container"
}

@test "freetakserver-ui.container: EnvironmentFile uses %h specifier" {
    grep -q "^EnvironmentFile=%h/" \
        "$REPO_ROOT/containers/freetakserver-ui.container"
}

@test "freetakserver.container: EnvironmentFile does NOT use /etc/ path" {
    run grep "^EnvironmentFile=/etc/" \
        "$REPO_ROOT/containers/freetakserver.container"
    [ "$status" -ne 0 ]
}

# ─── 14. WantedBy=default.target (user scope, not multi-user.target) ─────────

@test "freetakserver.container: WantedBy=default.target" {
    grep -q "^WantedBy=default\.target" \
        "$REPO_ROOT/containers/freetakserver.container"
}

@test "freetakserver-ui.container: WantedBy=default.target" {
    grep -q "^WantedBy=default\.target" \
        "$REPO_ROOT/containers/freetakserver-ui.container"
}

@test "freetakserver.container: does NOT have WantedBy=multi-user.target" {
    run grep "^WantedBy=multi-user\.target" \
        "$REPO_ROOT/containers/freetakserver.container"
    [ "$status" -ne 0 ]
}

# ─── 15. GHCR only — no docker.io ────────────────────────────────────────────

@test "freetakserver.container: no docker.io reference" {
    run grep "docker\.io" "$REPO_ROOT/containers/freetakserver.container"
    [ "$status" -ne 0 ]
}

@test "freetakserver-ui.container: no docker.io reference" {
    run grep "docker\.io" "$REPO_ROOT/containers/freetakserver-ui.container"
    [ "$status" -ne 0 ]
}

# ─── 16. UI-specific content ─────────────────────────────────────────────────

@test "freetakserver-ui.container: Requires=freetakserver.service" {
    grep -q "^Requires=freetakserver\.service" \
        "$REPO_ROOT/containers/freetakserver-ui.container"
}

@test "freetakserver-ui.container: addresses core by container DNS name" {
    grep -q "FTS_IP=freetakserver" \
        "$REPO_ROOT/containers/freetakserver-ui.container"
}

@test "freetakserver-ui.container: publishes UI port 5000" {
    grep -q "^PublishPort=5000:5000" \
        "$REPO_ROOT/containers/freetakserver-ui.container"
}

@test "freetakserver-ui.container: volume mount has :Z label" {
    grep -q ":Z" \
        "$REPO_ROOT/containers/freetakserver-ui.container"
}

@test "freetakserver-ui.container: AutoUpdate=registry" {
    grep -q "^AutoUpdate=registry" \
        "$REPO_ROOT/containers/freetakserver-ui.container"
}

# ─── 17. Dependency ordering ─────────────────────────────────────────────────

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

# ─── 18. fts.env content ─────────────────────────────────────────────────────

@test "fts.env: defines FTS_IP placeholder" {
    grep -q "^FTS_IP=" "$REPO_ROOT/env/fts.env"
}

@test "fts.env: FTS_COT_PORT defaults to 8087" {
    grep -q "^FTS_COT_PORT=8087" "$REPO_ROOT/env/fts.env"
}

@test "fts.env: FTS_API_PORT defaults to 19023" {
    grep -q "^FTS_API_PORT=19023" "$REPO_ROOT/env/fts.env"
}

@test "fts.env: FTS_UI_WSKEY placeholder present" {
    grep -q "^FTS_UI_WSKEY=" "$REPO_ROOT/env/fts.env"
}

@test "fts.env: FTS_API_KEY placeholder present" {
    grep -q "^FTS_API_KEY=" "$REPO_ROOT/env/fts.env"
}
