#!/bin/sh
# fts_setup.sh — FreeTAKServer rootless quadlet installer v2.0.0
#
# Intended usage:
#   curl -fsSL https://denzuko.github.io/fts-quadlet-setup/fts_setup.sh | doas sh
#   curl -fsSL https://denzuko.github.io/fts-quadlet-setup/fts_setup.sh | doas env FTS_USER=freetak sh
#
# All tunables are environment variables. Defaults are chosen for the
# dapla.net stack; override anything at runtime — no flags, no prompts.
#
# Uninstall:
#   FTS_UNINSTALL=1 sh fts_setup.sh
#
# Requirements:
#   openssl, zfs/zpool, podman >= 4.4, systemd >= 252,
#   machinectl, useradd, loginctl, ip, awk

set -eu

# ---------------------------------------------------------------------------
# SECTION 1: Tunables  (all overridable via environment variables)
# ---------------------------------------------------------------------------
# Network
FTS_IP="${FTS_IP:-}"                    # VIP; auto-detected if unset

# Service account
FTS_USER="${FTS_USER:-ftsvc}"
FTS_UID="${FTS_UID:-2001}"

# ZFS
ZFS_POOL="${ZFS_POOL:-storage}"
FTS_VERSION="${FTS_VERSION:-2.0.0}"     # dataset snapshot tag

# Images
IMAGE_CORE="${IMAGE_CORE:-ghcr.io/freetakteam/freetakserver:latest}"
IMAGE_UI="${IMAGE_UI:-ghcr.io/freetakteam/ui:latest}"

# Secrets — generated with openssl if unset (stored in /dev/shm, not on disk)
FTS_UI_WSKEY="${FTS_UI_WSKEY:-}"
FTS_API_KEY="${FTS_API_KEY:-}"

# Ports (12-factor: all config from environment)
FTS_COT_PORT="${FTS_COT_PORT:-8087}"
FTS_COT_PORT_S="${FTS_COT_PORT_S:-8089}"
FTS_API_PORT="${FTS_API_PORT:-19023}"
FTS_HTTP_PORT="${FTS_HTTP_PORT:-8080}"
FTS_HTTPS_PORT="${FTS_HTTPS_PORT:-8443}"
FTS_FED_PORT="${FTS_FED_PORT:-9000}"
FTS_UI_PORT="${FTS_UI_PORT:-5000}"

# Behaviour
FTS_UNINSTALL="${FTS_UNINSTALL:-0}"
BUS_TIMEOUT="${BUS_TIMEOUT:-30}"

# ---------------------------------------------------------------------------
# SECTION 2: Helpers
# ---------------------------------------------------------------------------
log()  { printf '==> %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 not found — install it first"; }

# Render a named m4 template macro from share/summary.m4
# Usage: render <macro_name>
render() {
    printf '%s\n' "_$1()" | m4 \
        -D "FTS_VERSION=${FTS_VERSION}" \
        -D "FTS_USER=${FTS_USER}" \
        -D "FTS_UID=${FTS_UID}" \
        -D "FTS_RUNTIME_UID=${FTS_RUNTIME_UID:-$FTS_UID}" \
        -D "FTS_IP=${FTS_IP}" \
        -D "FTS_COT_PORT=${FTS_COT_PORT}" \
        -D "FTS_COT_PORT_S=${FTS_COT_PORT_S}" \
        -D "FTS_API_PORT=${FTS_API_PORT}" \
        -D "FTS_UI_PORT=${FTS_UI_PORT}" \
        -D "FTS_FED_PORT=${FTS_FED_PORT}" \
        -D "ZFS_POOL=${ZFS_POOL}" \
        -D "DS_CONTAINER=${DS_CONTAINER:-${ZFS_POOL}/containers/fts}" \
        -D "DS_USER=${DS_USER:-${ZFS_POOL}/users/${FTS_USER}}" \
        -D "MNT_CONTAINER=${MNT_CONTAINER:-/srv/fts}" \
        -D "MNT_USER=${MNT_USER:-/var/lib/${FTS_USER}}" \
        -D "QUADLET_DIR=${QUADLET_DIR:-}" \
        -D "SHM_DIR=${SHM_DIR:-}" \
        -D "PODMAN_VER=${podman_ver:-}" \
        "${SCRIPT_DIR}/share/summary.m4" -
}
as_fts() { machinectl shell "${FTS_USER}@" /bin/sh -c "$*"; }

# Create a ZFS dataset idempotently with standard properties + version tag
# Usage: zfs_ensure <dataset> <mountpoint>
zfs_ensure() {
    _ds="$1"
    _mp="$2"
    if zfs list "$_ds" >/dev/null 2>&1; then
        log "Dataset $_ds already exists — skipping"
    else
        log "Creating ZFS dataset $_ds (mountpoint=$_mp)"
        zfs create \
            -o mountpoint="$_mp" \
            -o compression=lz4 \
            -o atime=off \
            -o "fts:version=${FTS_VERSION}" \
            "$_ds"
        log "Dataset $_ds created (fts:version=${FTS_VERSION})"
    fi
    unset _ds _mp
}

# Generate a secret with openssl, store in /dev/shm namespace
# Usage: gen_secret <varname>
# Sets the named variable to a 32-byte hex string; writes to shm namespace
gen_secret() {
    _var="$1"
    _val="$(openssl rand -hex 32)"
    eval "${_var}=\${_val}"
    printf '%s\n' "$_val" > "${SHM_DIR}/${_var}"
    chmod 0600 "${SHM_DIR}/${_var}"
    log "Generated ${_var} (stored in ${SHM_DIR}/${_var})"
    unset _var _val
}

# ---------------------------------------------------------------------------
# SECTION 3: Preflight checks
# ---------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "Must run as root"

need m4
need openssl
need zfs
need useradd
need machinectl
need loginctl
need systemctl
need podman
need curl
need ip
need awk

zpool list "$ZFS_POOL" >/dev/null 2>&1 \
    || die "ZFS pool '$ZFS_POOL' not found — set ZFS_POOL=<name>"

# ---------------------------------------------------------------------------
# SECTION 4: VIP detection
# ---------------------------------------------------------------------------
if [ -z "$FTS_IP" ]; then
    FTS_IP="$(ip route get 1 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')"
    [ -n "$FTS_IP" ] || die "VIP auto-detection failed — set FTS_IP=<address>"
    log "VIP auto-detected: $FTS_IP"
fi

# Derived names — computed after all env is settled
DS_CONTAINER="${ZFS_POOL}/containers/fts"
DS_USER="${ZFS_POOL}/users/${FTS_USER}"
MNT_CONTAINER="/srv/fts"
MNT_USER="/var/lib/${FTS_USER}"

podman_ver="$(podman --version | awk '{print $3}')"
log "FreeTAKServer rootless quadlet installer v${FTS_VERSION}"
render preflight

# ---------------------------------------------------------------------------
# SECTION 5: Uninstall path
# ---------------------------------------------------------------------------
if [ "$FTS_UNINSTALL" = "1" ]; then
    log "Uninstalling FreeTAKServer"

    # Stop and disable user services
    as_fts "systemctl --user disable --now freetakserver.service freetakserver-ui.service" 2>/dev/null || true

    # Remove OCI images, volumes, networks
    as_fts "podman stop freetakserver freetakserver-ui 2>/dev/null; podman rm freetakserver freetakserver-ui 2>/dev/null; true"
    as_fts "podman volume rm fts-data fts-ui-data 2>/dev/null; true"
    as_fts "podman network rm fts 2>/dev/null; true"
    as_fts "podman rmi ${IMAGE_CORE} ${IMAGE_UI} 2>/dev/null; true"

    # Remove quadlet unit files
    _fts_home="$(getent passwd "$FTS_USER" 2>/dev/null | cut -d: -f6)" || true
    if [ -n "$_fts_home" ]; then
        rm -rf "${_fts_home}/.config/containers/systemd"
    fi

    # Disable linger
    loginctl disable-linger "$FTS_USER" 2>/dev/null || true

    # Remove service account
    userdel "$FTS_USER" 2>/dev/null || true

    # Destroy ZFS datasets (children first)
    for _ds in "$DS_USER" "$DS_CONTAINER" \
               "${ZFS_POOL}/users" "${ZFS_POOL}/containers"; do
        if zfs destroy "$_ds" 2>/dev/null; then log "Destroyed $_ds"; fi
    done

    # Wipe shm namespace
    rm -rf "/dev/shm/fts-${FTS_USER}" 2>/dev/null || true

    log "Uninstall complete"
    exit 0
fi

# ---------------------------------------------------------------------------
# SECTION 6: Secrets — generate with openssl, store in /dev/shm namespace
# ---------------------------------------------------------------------------
log "SECTION 6: Secrets"

# Per-installation shm namespace (isolated per service account)
SHM_DIR="$(mktemp -d "/dev/shm/fts-${FTS_USER}.XXXXXX")"
chmod 0700 "$SHM_DIR"
log "Secret namespace: $SHM_DIR"

# Generate any secrets that were not passed in via environment
[ -n "$FTS_UI_WSKEY" ] || gen_secret FTS_UI_WSKEY
[ -n "$FTS_API_KEY"  ] || gen_secret FTS_API_KEY

# ---------------------------------------------------------------------------
# SECTION 7: ZFS datasets
# ---------------------------------------------------------------------------
log "SECTION 7: ZFS datasets"

for _parent in "${ZFS_POOL}/containers" "${ZFS_POOL}/users"; do
    zfs list "$_parent" >/dev/null 2>&1 || zfs create -o "fts:version=${FTS_VERSION}" "$_parent"
done
unset _parent

zfs_ensure "$DS_CONTAINER" "$MNT_CONTAINER"
zfs_ensure "$DS_USER"      "$MNT_USER"

# Snapshot datasets at install (version-tagged)
_snap_tag="install-v${FTS_VERSION}-$(date +%Y%m%d)"
zfs snapshot "${DS_CONTAINER}@${_snap_tag}" 2>/dev/null || true
zfs snapshot "${DS_USER}@${_snap_tag}"      2>/dev/null || true
unset _snap_tag

# ---------------------------------------------------------------------------
# SECTION 8: Service account
# ---------------------------------------------------------------------------
log "SECTION 8: Service account"

if getent passwd "$FTS_USER" >/dev/null 2>&1; then
    log "Account $FTS_USER already exists — skipping creation"
else
    useradd \
        --system \
        --uid      "$FTS_UID" \
        --no-create-home \
        --home-dir "$MNT_USER" \
        --shell    /bin/bash \
        --comment  "FreeTAKServer service account" \
        "$FTS_USER"
    chown "${FTS_UID}:${FTS_UID}" "$MNT_USER"
    log "Account $FTS_USER created"
fi

FTS_HOME="$(getent passwd "$FTS_USER" | cut -d: -f6)"
FTS_RUNTIME_UID="$(getent passwd "$FTS_USER" | cut -d: -f3)"
QUADLET_DIR="$FTS_HOME/.config/containers/systemd"

# ---------------------------------------------------------------------------
# SECTION 9: Linger
# ---------------------------------------------------------------------------
log "SECTION 9: Linger"

loginctl enable-linger "$FTS_USER"
loginctl show-user "$FTS_USER" 2>/dev/null | grep -q "Linger=yes" \
    || die "Linger not active for $FTS_USER — check systemd-logind"

# ---------------------------------------------------------------------------
# SECTION 10: User manager startup
# ---------------------------------------------------------------------------
log "SECTION 10: User manager"

systemctl start "user@${FTS_RUNTIME_UID}.service" \
    || die "Failed to start user@${FTS_RUNTIME_UID}.service"

_elapsed=0
until [ -S "/run/user/${FTS_RUNTIME_UID}/bus" ]; do
    [ "$_elapsed" -ge "$BUS_TIMEOUT" ] \
        && die "Timed out after ${BUS_TIMEOUT}s waiting for D-Bus socket"
    sleep 1
    _elapsed=$((_elapsed + 1))
done
log "Session bus ready (${_elapsed}s)"
unset _elapsed

# ---------------------------------------------------------------------------
# SECTION 11: Image pull (rootless store)
# ---------------------------------------------------------------------------
log "SECTION 11: Pulling images (rootless store)"
as_fts "podman pull $IMAGE_CORE"
as_fts "podman pull $IMAGE_UI"

# ---------------------------------------------------------------------------
# SECTION 12: Install quadlet unit files + env
# ---------------------------------------------------------------------------
log "SECTION 12: Installing quadlet unit files"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
as_fts "mkdir -p $QUADLET_DIR"

_install_unit() {
    _src="$1"
    _dst="$QUADLET_DIR/$(basename "$_src")"
    install -m 0644 -o "$FTS_USER" "$_src" "$_dst"
    printf '    wrote %s\n' "$_dst"
}

_install_unit "$SCRIPT_DIR/networks/fts.network"
_install_unit "$SCRIPT_DIR/volumes/fts-data.volume"
_install_unit "$SCRIPT_DIR/volumes/fts-ui-data.volume"
_install_unit "$SCRIPT_DIR/containers/freetakserver.container"
_install_unit "$SCRIPT_DIR/containers/freetakserver-ui.container"

# Write env file — generated fresh on install, never clobber if exists
_env_dst="$QUADLET_DIR/fts.env"
if [ ! -f "$_env_dst" ]; then
    install -m 0640 -o "$FTS_USER" /dev/null "$_env_dst"
    cat > "$_env_dst" << ENV
# fts.env — generated by fts_setup.sh v${FTS_VERSION} on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Managed by: fts_setup.sh — do not edit FTS_IP, FTS_UI_WSKEY, or FTS_API_KEY by hand
FTS_IP=${FTS_IP}
FTS_COT_PORT=${FTS_COT_PORT}
FTS_COT_PORT_S=${FTS_COT_PORT_S}
FTS_API_PORT=${FTS_API_PORT}
FTS_HTTP_PORT=${FTS_HTTP_PORT}
FTS_HTTPS_PORT=${FTS_HTTPS_PORT}
FTS_FED_PORT=${FTS_FED_PORT}
FTS_UI_PORT=${FTS_UI_PORT}
FTS_UI_WSKEY=${FTS_UI_WSKEY}
FTS_API_KEY=${FTS_API_KEY}
FTS_LOG_LEVEL=${FTS_LOG_LEVEL:-INFO}
FTS_CLIENT_CERT_REQUIRED=${FTS_CLIENT_CERT_REQUIRED:-False}
FTS_DB_PATH=/opt/FTSData/FTSDataBase.db
FTS_UI_SQLALCHEMY_DATABASE_URI=sqlite:////home/freetak/data/FTSServer-UI.db
ENV
    chmod 0640 "$_env_dst"
    log "Wrote $FTS_USER env file (secrets in $SHM_DIR)"
else
    # Idempotent re-run: stamp IP only, preserve generated secrets
    sed -i "s|^FTS_IP=.*|FTS_IP=${FTS_IP}|" "$_env_dst"
    log "fts.env exists — stamped FTS_IP, preserved secrets"
fi
unset _env_dst

# ---------------------------------------------------------------------------
# SECTION 13: Reload user daemon + enable services
# ---------------------------------------------------------------------------
log "SECTION 13: Reload and enable"

as_fts "systemctl --user daemon-reload"
as_fts "systemctl --user enable --now freetakserver.service"
as_fts "systemctl --user enable --now freetakserver-ui.service"

# ---------------------------------------------------------------------------
# SECTION 14: Smoke test
# ---------------------------------------------------------------------------
log "SECTION 14: REST API readiness (up to 90s)"

_tries=0
until curl -sf "http://localhost:${FTS_API_PORT}/SystemStatus/getStatus" >/dev/null 2>&1; do
    _tries=$((_tries + 1))
    if [ "$_tries" -ge 18 ]; then
        printf 'WARNING: API not responding after 90s\n' >&2
        printf '  Logs: machinectl shell %s@ -- journalctl --user -u freetakserver.service\n' \
            "$FTS_USER" >&2
        break
    fi
    sleep 5
done
unset _tries

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
render header
render endpoints
render ops
