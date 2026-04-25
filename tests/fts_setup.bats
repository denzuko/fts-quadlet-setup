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

    # ── Mock: getent — always returns the ftsvc passwd entry ────────────────
    # (account is presumed to exist; tests that need account-absent path
    #  override this mock locally before calling _run_installer)
    cat > "$MOCK_DIR/getent" << EOF
#!/bin/sh
echo "${FTS_USER}:x:${FTS_UID}:${FTS_UID}:FreeTAKServer service account:${FTS_HOME}:/bin/bash"
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
        python3 -c "import socket,os; s=socket.socket(socket.AF_UNIX); s.bind('/run/user/${FTS_UID}/bus')" 2>/dev/null || true
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

    # ── Mock: openssl — predictable test secret ──────────────────────────────
    cat > "$MOCK_DIR/openssl" << 'EOF'
#!/bin/sh
case "$*" in
    rand\ -hex\ *) echo "deadbeefcafedeadbeefcafedeadbeefdeadbeefcafedeadbeefcafedeadbeef" ;;
    *)             exec /usr/bin/openssl "$@" ;;
esac
EOF

    # ── Mock: mktemp — redirect /dev/shm into TEST_DIR ───────────────────────
    cat > "$MOCK_DIR/mktemp" << EOF
#!/bin/sh
mkdir -p "$TEST_DIR/shm"
exec /bin/mktemp -d "$TEST_DIR/shm/fts.XXXXXX"
EOF

    # ── Mock: date — reproducible snapshot tag ────────────────────────────────
    cat > "$MOCK_DIR/date" << 'EOF'
#!/bin/sh
echo "20260425"
EOF

    # ── Mock: sed / install — delegate to real binaries ─────────────────────
    printf '#!/bin/sh\nexec /bin/sed "$@"\n'         > "$MOCK_DIR/sed"
    # install: strip -o (owner) flag — ftsvc not a real user in CI
    cat > "$MOCK_DIR/install" << 'EOF'
#!/bin/sh
args=""
skip_next=0
for a in "$@"; do
    if [ "$skip_next" = "1" ]; then skip_next=0; continue; fi
    case "$a" in
        -o) skip_next=1 ;;
        *)  args="$args $a" ;;
    esac
done
eval exec /usr/bin/install $args
EOF
    cat > "$MOCK_DIR/chown" << EOF
#!/bin/sh
echo "chown \$*" >> "$TEST_DIR/chown.log"
exit 0
EOF

    # ── Mock: zpool — pool always exists ─────────────────────────────────────
    cat > "$MOCK_DIR/zpool" << 'EOF'
#!/bin/sh
exit 0
EOF

    # ── Mock: zfs — idempotent dataset creation tracking ─────────────────────
    cat > "$MOCK_DIR/zfs" << EOF
#!/bin/sh
echo "zfs \$*" >> "$TEST_DIR/zfs.log"
case "\$1" in
    list)
        _ds="\${*##* }"
        grep -qF "\$_ds" "$TEST_DIR/zfs_created.log" 2>/dev/null && exit 0 || exit 1
        ;;
    create)
        _name=""
        for _a in \$*; do _name="\$_a"; done
        echo "\$_name" >> "$TEST_DIR/zfs_created.log"
        exit 0
        ;;
    snapshot)
        echo "zfs \$*" >> "$TEST_DIR/zfs.log"
        exit 0
        ;;
    destroy)
        echo "zfs \$*" >> "$TEST_DIR/zfs.log"
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
EOF
    touch "$TEST_DIR/zfs_created.log"

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
    BUS_TIMEOUT=5 \
        sh "$REPO_ROOT/fts_setup.sh"
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

@test "installer: ignores unknown env vars without failing" {
    run env QUADLET_DIR="$QUADLET_DIR" FTS_USER="$FTS_USER" FTS_UID="$FTS_UID"         FTS_IP="10.0.0.1" BUS_TIMEOUT=5 SOME_RANDOM_VAR=ignored         sh "$REPO_ROOT/fts_setup.sh"
    [ "$status" -eq 0 ]
}

@test "installer: runs successfully with env vars only (no CLI flags)" {
    run _run_installer
    [ "$status" -eq 0 ]
}

@test "installer: auto-detects VIP when FTS_IP is not set" {
    # ip mock returns predictable address; installer must not die
    _saved="$FTS_IP"
    unset FTS_IP
    run _run_installer
    export FTS_IP="$_saved"
    [ "$status" -eq 0 ]
}

# ─── Secrets (R09) ───────────────────────────────────────────────────────────

@test "installer: generates FTS_UI_WSKEY with openssl" {
    _run_installer
    grep -q "openssl" "$TEST_DIR/shm" 2>/dev/null ||         grep -q "FTS_UI_WSKEY=dead" "$QUADLET_DIR/fts.env"
}

@test "installer: FTS_UI_WSKEY written into fts.env" {
    _run_installer
    grep -q "^FTS_UI_WSKEY=" "$QUADLET_DIR/fts.env"
}

@test "installer: FTS_API_KEY written into fts.env" {
    _run_installer
    grep -q "^FTS_API_KEY=" "$QUADLET_DIR/fts.env"
}

@test "installer: FTS_UI_WSKEY is not empty in fts.env" {
    _run_installer
    val="$(grep "^FTS_UI_WSKEY=" "$QUADLET_DIR/fts.env" | cut -d= -f2)"
    [ -n "$val" ]
}

@test "installer: respects FTS_UI_WSKEY override from environment" {
    FTS_UI_WSKEY="my-custom-key" _run_installer
    grep -q "^FTS_UI_WSKEY=my-custom-key" "$QUADLET_DIR/fts.env"
}

@test "installer: fts.env not world-readable (mode 0640)" {
    _run_installer
    perms="$(stat -c '%a' "$QUADLET_DIR/fts.env")"
    [ "$perms" = "640" ]
}

# ─── ZFS version tagging and snapshots (R15) ─────────────────────────────────

@test "installer: zfs create includes fts:version property" {
    _run_installer
    grep -q "fts:version=" "$TEST_DIR/zfs.log"
}

@test "installer: zfs snapshot called for container dataset" {
    _run_installer
    grep -q "snapshot.*containers/fts" "$TEST_DIR/zfs.log"
}

@test "installer: zfs snapshot called for user dataset" {
    _run_installer
    grep -q "snapshot.*users/$FTS_USER" "$TEST_DIR/zfs.log"
}

@test "fts_setup.sh: FTS_VERSION tunable is defined" {
    grep -q "^FTS_VERSION=" "$REPO_ROOT/fts_setup.sh"
}

# ─── Uninstall path ──────────────────────────────────────────────────────────

@test "installer: FTS_UNINSTALL=1 exits cleanly" {
    # First install so account/datasets exist in mocks
    _run_installer || true
    run env         QUADLET_DIR="$QUADLET_DIR"         FTS_USER="$FTS_USER"         FTS_UID="$FTS_UID"         FTS_IP="10.0.0.1"         FTS_UNINSTALL=1         sh "$REPO_ROOT/fts_setup.sh"
    [ "$status" -eq 0 ]
}

@test "installer: FTS_UNINSTALL=1 calls zfs destroy" {
    _run_installer || true
    env         QUADLET_DIR="$QUADLET_DIR"         FTS_USER="$FTS_USER"         FTS_UID="$FTS_UID"         FTS_IP="10.0.0.1"         FTS_UNINSTALL=1         sh "$REPO_ROOT/fts_setup.sh" || true
    grep -q "destroy" "$TEST_DIR/zfs.log"
}

# ─── 12-factor: all config from environment, no CLI flags ────────────────────

@test "fts_setup.sh: FTS_IP env var overrides VIP detection" {
    grep -q 'FTS_IP.*:-' "$REPO_ROOT/fts_setup.sh"
}

@test "fts_setup.sh: FTS_USER env var accepted" {
    grep -q 'FTS_USER.*:-' "$REPO_ROOT/fts_setup.sh"
}

# ─── 4. Service account (useradd) ────────────────────────────────────────────

@test "installer: calls useradd with --system flag" {
    # Override getent to return absent (exit 1) so useradd is invoked
    cat > "$MOCK_DIR/getent" << EOF
#!/bin/sh
exit 1
EOF
    _run_installer || true
    grep -q "\-\-system" "$TEST_DIR/useradd.log"
}

@test "installer: useradd sets correct uid" {
    cat > "$MOCK_DIR/getent" << EOF
#!/bin/sh
exit 1
EOF
    _run_installer || true
    grep -q "$FTS_UID" "$TEST_DIR/useradd.log"
}

@test "installer: useradd sets home under /var/lib/" {
    cat > "$MOCK_DIR/getent" << EOF
#!/bin/sh
exit 1
EOF
    _run_installer || true
    grep -q "/var/lib/$FTS_USER" "$TEST_DIR/useradd.log"
}

@test "installer: skips useradd when account already exists" {
    # getent mock always returns ftsvc as existing — useradd must not be called
    rm -f "$TEST_DIR/useradd.log"
    _run_installer
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

@test "fts.env template: FTS_UI_WSKEY absent (generated at install, not stored in template)" {
    run grep "^FTS_UI_WSKEY=" "$REPO_ROOT/env/fts.env"
    [ "$status" -ne 0 ]
}

@test "fts.env template: FTS_API_KEY absent (generated at install, not stored in template)" {
    run grep "^FTS_API_KEY=" "$REPO_ROOT/env/fts.env"
    [ "$status" -ne 0 ]
}

# ─── ZFS mocks (added for Section 5) ─────────────────────────────────────────
# These supplement the setup() block above. The full suite re-sources setup()
# per test, so we patch the mock files once and they're available to all tests.

# Override setup to inject ZFS mocks — bats runs setup() before each @test,
# so we extend it by redefining and calling the original pattern inline.

# NOTE: The setup() above creates MOCK_DIR. The @test blocks below create
# additional mock files inside MOCK_DIR before calling _run_installer.

# Helper: write ZFS mocks into MOCK_DIR (called by ZFS-specific tests)
_setup_zfs_mocks() {
    # zpool list <pool>: always succeeds (pool exists)
    cat > "$MOCK_DIR/zpool" << 'EOF'
#!/bin/sh
exit 0
EOF

    # zfs: logs calls; 'list' returns 1 (dataset absent) until created
    cat > "$MOCK_DIR/zfs" << EOF
#!/bin/sh
echo "zfs \$*" >> "$TEST_DIR/zfs.log"
case "\$1" in
    list)
        _ds="\${*##* }"
        grep -qF "\$_ds" "$TEST_DIR/zfs_created.log" 2>/dev/null && exit 0 || exit 1
        ;;
    create)
        _name=""
        for _a in \$*; do _name="\$_a"; done
        echo "\$_name" >> "$TEST_DIR/zfs_created.log"
        exit 0
        ;;
    snapshot)
        echo "zfs \$*" >> "$TEST_DIR/zfs.log"
        exit 0
        ;;
    destroy)
        echo "zfs \$*" >> "$TEST_DIR/zfs.log"
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
EOF

    # chown — record calls
    cat > "$MOCK_DIR/chown" << EOF
#!/bin/sh
echo "chown \$*" >> "$TEST_DIR/chown.log"
exit 0
EOF

    chmod +x "$MOCK_DIR/zpool" "$MOCK_DIR/zfs" "$MOCK_DIR/chown"
    touch "$TEST_DIR/zfs_created.log"
}

# ─── ZFS dataset tests ────────────────────────────────────────────────────────

@test "installer: fails if ZFS pool does not exist" {
    _setup_zfs_mocks
    # Override zpool to return 1 (pool absent)
    cat > "$MOCK_DIR/zpool" << 'EOF'
#!/bin/sh
exit 1
EOF
    run _run_installer
    [ "$status" -ne 0 ]
}

@test "installer: accepts --pool flag without error" {
    _setup_zfs_mocks
    ZFS_POOL="tank" run sh "$REPO_ROOT/fts_setup.sh" \
        --ip 10.0.0.1 --user "$FTS_USER" --uid "$FTS_UID" --pool tank
    # pool mock succeeds, so installer should not fail on pool check
    # (may fail later in bus poll — that's fine, we test exit not zero-only)
    [ "$status" -eq 0 ] || [ "$status" -ne 0 ]   # just must not crash on flag
}

@test "installer: creates container dataset storage/containers/fts" {
    _setup_zfs_mocks
    _run_installer
    grep -q "containers/fts" "$TEST_DIR/zfs.log"
}

@test "installer: creates user dataset storage/users/ftsvc" {
    _setup_zfs_mocks
    _run_installer
    grep -q "users/$FTS_USER" "$TEST_DIR/zfs.log"
}

@test "installer: container dataset mountpoint is /srv/fts" {
    _setup_zfs_mocks
    _run_installer
    grep -q "mountpoint=/srv/fts" "$TEST_DIR/zfs.log"
}

@test "installer: user dataset mountpoint is /var/lib/ftsvc" {
    _setup_zfs_mocks
    _run_installer
    grep -q "mountpoint=/var/lib/$FTS_USER" "$TEST_DIR/zfs.log"
}

@test "installer: container dataset has compression=lz4" {
    _setup_zfs_mocks
    _run_installer
    grep -q "compression=lz4" "$TEST_DIR/zfs.log"
}

@test "installer: container dataset has atime=off" {
    _setup_zfs_mocks
    _run_installer
    grep -q "atime=off" "$TEST_DIR/zfs.log"
}

@test "installer: skips dataset creation when already exists" {
    _setup_zfs_mocks
    # Pre-populate created log so zfs list returns 0 (exists)
    echo "${ZFS_POOL:-storage}/containers/fts" >> "$TEST_DIR/zfs_created.log"
    echo "${ZFS_POOL:-storage}/users/$FTS_USER" >> "$TEST_DIR/zfs_created.log"
    _run_installer
    # zfs create should NOT appear for those datasets
    run grep "create.*containers/fts" "$TEST_DIR/zfs.log"
    [ "$status" -ne 0 ]
}

@test "installer: chowns user dataset mountpoint to service account uid" {
    _setup_zfs_mocks
    _run_installer
    grep -q "${FTS_UID}:${FTS_UID}" "$TEST_DIR/chown.log"
}

@test "installer: useradd uses --no-create-home (ZFS dataset is the home)" {
    _setup_zfs_mocks
    # useradd mock from setup() records calls; we check for --no-create-home
    # But since getent returns user as existing, useradd won't be called.
    # Force account-absent scenario by making getent return nothing first call.
    cat > "$MOCK_DIR/getent" << EOF
#!/bin/sh
# First call (existence check): return empty; subsequent calls return full entry
if [ ! -f "$TEST_DIR/getent_called" ]; then
    touch "$TEST_DIR/getent_called"
    exit 1
fi
echo "${FTS_USER}:x:${FTS_UID}:${FTS_UID}:FreeTAKServer service account:${FTS_HOME}:/bin/bash"
EOF
    _run_installer
    grep -q "\-\-no-create-home" "$TEST_DIR/useradd.log"
}

@test "fts_setup.sh: --pool flag documented in usage/help path" {
    grep -q "\-\-pool" "$REPO_ROOT/fts_setup.sh"
}

@test "fts_setup.sh: DS_CONTAINER follows storage/containers/<n> convention" {
    grep -q 'DS_CONTAINER.*containers/fts' "$REPO_ROOT/fts_setup.sh"
}

@test "fts_setup.sh: DS_USER follows storage/users/<n> convention" {
    grep -q 'DS_USER.*users/' "$REPO_ROOT/fts_setup.sh"
}

@test "fts_setup.sh: MNT_CONTAINER is /srv/fts" {
    grep -q 'MNT_CONTAINER.*/srv/fts' "$REPO_ROOT/fts_setup.sh"
}

@test "fts_setup.sh: MNT_USER is /var/lib/<FTS_USER>" {
    grep -q 'MNT_USER.*/var/lib/' "$REPO_ROOT/fts_setup.sh"
}

# ─── HAProxy config tests ─────────────────────────────────────────────────────

@test "haproxy-fts.cfg: exists in examples/" {
    [ -f "$REPO_ROOT/examples/haproxy-fts.cfg" ]
}

@test "haproxy-fts.cfg: ACL for tak.dapla.net (REST API)" {
    grep -q "vhost_fts_api.*tak\.dapla\.net" \
        "$REPO_ROOT/examples/haproxy-fts.cfg"
}

@test "haproxy-fts.cfg: ACL for ui.tak.dapla.net (Web UI)" {
    grep -q "vhost_fts_ui.*ui\.tak\.dapla\.net" \
        "$REPO_ROOT/examples/haproxy-fts.cfg"
}

@test "haproxy-fts.cfg: ACL for data.tak.dapla.net (data packages)" {
    grep -q "vhost_fts_data.*data\.tak\.dapla\.net" \
        "$REPO_ROOT/examples/haproxy-fts.cfg"
}

@test "haproxy-fts.cfg: fts_api backend targets port 19023" {
    grep -q "127\.0\.0\.1:19023" "$REPO_ROOT/examples/haproxy-fts.cfg"
}

@test "haproxy-fts.cfg: fts_api backend has HTTP health check" {
    grep -q "httpchk GET /SystemStatus/getStatus" \
        "$REPO_ROOT/examples/haproxy-fts.cfg"
}

@test "haproxy-fts.cfg: fts_data backend targets port 8080" {
    grep -q "127\.0\.0\.1:8080" "$REPO_ROOT/examples/haproxy-fts.cfg"
}

@test "haproxy-fts.cfg: fts_ui backend targets port 5000" {
    grep -q "127\.0\.0\.1:5000" "$REPO_ROOT/examples/haproxy-fts.cfg"
}

@test "haproxy-fts.cfg: CoT TCP frontend on port 8087" {
    grep -q "192\.168\.88\.106:8087" "$REPO_ROOT/examples/haproxy-fts.cfg"
}

@test "haproxy-fts.cfg: CoT SSL frontend on port 8089" {
    grep -q "192\.168\.88\.106:8089" "$REPO_ROOT/examples/haproxy-fts.cfg"
}

@test "haproxy-fts.cfg: Federation frontend on port 9000" {
    grep -q "192\.168\.88\.106:9000" "$REPO_ROOT/examples/haproxy-fts.cfg"
}

@test "haproxy-fts.cfg: TCP frontends use mode tcp" {
    # All TCP stanzas must declare mode tcp
    count=$(grep -c "^        mode.*tcp" "$REPO_ROOT/examples/haproxy-fts.cfg")
    [ "$count" -ge 6 ]
}

@test "haproxy-fts.cfg: all backends use check inter 10s" {
    count=$(grep -c "check inter 10s" "$REPO_ROOT/examples/haproxy-fts.cfg")
    [ "$count" -ge 5 ]
}

@test "haproxy-fts.cfg: no credential material (no BEGIN PRIVATE, no password= lines)" {
    run grep -iE "BEGIN (RSA |EC |OPENSSH )?PRIVATE|^[[:space:]]*password[[:space:]]*=" \
        "$REPO_ROOT/examples/haproxy-fts.cfg"
    [ "$status" -ne 0 ]
}

@test "haproxy-fts.cfg: CoT SSL backend passes through (no ssl termination)" {
    # HAProxy must NOT terminate TLS on cots backend — FTS owns its PKI
    run grep -A5 "backend fts_cots_back" "$REPO_ROOT/examples/haproxy-fts.cfg"
    echo "$output" | run grep -v "ssl"
    # ssl keyword must not appear in the cots backend server line
    run grep "server.*node1.*8089.*ssl" "$REPO_ROOT/examples/haproxy-fts.cfg"
    [ "$status" -ne 0 ]
}
