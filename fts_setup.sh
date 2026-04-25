#!/bin/sh
# fts_setup.sh — FreeTAKServer rootless quadlet installer
# Mirrors pbx_setup.sh conventions from denzuko/pbx-quadlet-setup:
#   - POSIX sh (no bashisms)
#   - Dedicated service account (useradd --system) with lingering
#   - Rootless Podman Quadlets via machinectl shell
#   - User-scoped unit files in ~/.config/containers/systemd/
#   - systemctl --user for all service management
#   - Idempotent: safe to re-run
#
# Usage (run as root):
#   FTS_IP=192.0.2.10 sh fts_setup.sh
#   sh fts_setup.sh --ip 192.0.2.10
#
# Requirements:
#   - podman >= 4.4   (quadlet generator built-in)
#   - systemd >= 252  (user-scoped quadlet support)
#   - machinectl      (systemd-container or systemd package)
#   - useradd         (shadow-utils / passwd)

set -eu

# ---------------------------------------------------------------------------
# SECTION 1: Tunables
# ---------------------------------------------------------------------------
FTS_IP="${FTS_IP:-}"
FTS_USER="${FTS_USER:-ftsvc}"
FTS_UID="${FTS_UID:-2001}"
IMAGE_CORE="ghcr.io/freetakteam/freetakserver:latest"
IMAGE_UI="ghcr.io/freetakteam/ui:latest"
BUS_TIMEOUT=30

# ---------------------------------------------------------------------------
# SECTION 2: Helpers
# ---------------------------------------------------------------------------
log()  { printf '==> %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 not found — install it first"; }

# Run a command as the FTS service account via machinectl
as_fts() { machinectl shell "${FTS_USER}@" /bin/sh -c "$*"; }

# ---------------------------------------------------------------------------
# SECTION 3: Argument parsing
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --ip)   FTS_IP="$2";   shift 2 ;;
        --user) FTS_USER="$2"; shift 2 ;;
        --uid)  FTS_UID="$2";  shift 2 ;;
        *) die "Unknown option: $1 (valid: --ip, --user, --uid)" ;;
    esac
done

if [ -z "$FTS_IP" ]; then
    printf 'FTS_IP not set — auto-detecting via ip route... '
    FTS_IP="$(ip route get 1 | awk '{print $7; exit}')"
    echo "$FTS_IP"
fi

log "FreeTAKServer rootless quadlet installer"
printf '    %-14s %s\n' "FTS_IP:"   "$FTS_IP"
printf '    %-14s %s\n' "FTS_USER:" "$FTS_USER"
printf '    %-14s %s\n' "FTS_UID:"  "$FTS_UID"

# ---------------------------------------------------------------------------
# SECTION 4: Preflight checks
# ---------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "Must run as root (installer creates the service account)"

need useradd
need machinectl
need loginctl
need systemctl
need podman
need curl

podman_ver="$(podman --version | awk '{print $3}')"
printf '    %-14s %s\n' "podman:" "$podman_ver"

# ---------------------------------------------------------------------------
# SECTION 5: Service account creation
# ---------------------------------------------------------------------------
log "SECTION 5: Service account"

if getent passwd "$FTS_USER" >/dev/null 2>&1; then
    log "Account $FTS_USER already exists — skipping creation"
else
    log "Creating system account $FTS_USER (uid $FTS_UID)"
    useradd \
        --system \
        --uid      "$FTS_UID" \
        --create-home \
        --home-dir "/var/lib/$FTS_USER" \
        --shell    /bin/bash \
        --comment  "FreeTAKServer service account" \
        "$FTS_USER"
    log "Account $FTS_USER created"
fi

FTS_HOME="$(getent passwd "$FTS_USER" | cut -d: -f6)"
FTS_RUNTIME_UID="$(getent passwd "$FTS_USER" | cut -d: -f3)"
QUADLET_DIR="$FTS_HOME/.config/containers/systemd"

printf '    %-14s %s\n' "home:"    "$FTS_HOME"
printf '    %-14s %s\n' "uid:"     "$FTS_RUNTIME_UID"
printf '    %-14s %s\n' "quadlet:" "$QUADLET_DIR"

# ---------------------------------------------------------------------------
# SECTION 6: Linger — survive without active login session
# ---------------------------------------------------------------------------
log "SECTION 6: Linger"

loginctl enable-linger "$FTS_USER"
loginctl show-user "$FTS_USER" 2>/dev/null | grep -q "Linger=yes" \
    || die "Linger not active for $FTS_USER — check systemd-logind"
log "Linger enabled for $FTS_USER"

# ---------------------------------------------------------------------------
# SECTION 7: Start user manager (user@UID.service)
# ---------------------------------------------------------------------------
log "SECTION 7: User manager"

systemctl start "user@${FTS_RUNTIME_UID}.service" \
    || die "Failed to start user@${FTS_RUNTIME_UID}.service"

log "Polling for session bus at /run/user/${FTS_RUNTIME_UID}/bus ..."
_elapsed=0
until [ -S "/run/user/${FTS_RUNTIME_UID}/bus" ]; do
    if [ "$_elapsed" -ge "$BUS_TIMEOUT" ]; then
        die "Timed out after ${BUS_TIMEOUT}s waiting for /run/user/${FTS_RUNTIME_UID}/bus"
    fi
    sleep 1
    _elapsed=$((_elapsed + 1))
done
log "Session bus ready (${_elapsed}s)"
unset _elapsed

# ---------------------------------------------------------------------------
# SECTION 8: Image pull (rootless store, under service account)
# ---------------------------------------------------------------------------
log "SECTION 8: Pulling container images (rootless store)"
as_fts "podman pull $IMAGE_CORE"
as_fts "podman pull $IMAGE_UI"

# ---------------------------------------------------------------------------
# SECTION 9: Install quadlet unit files
# ---------------------------------------------------------------------------
log "SECTION 9: Installing quadlet unit files"

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

# Env file — never clobber operator edits (idempotent)
_env_dst="$QUADLET_DIR/fts.env"
if [ ! -f "$_env_dst" ]; then
    install -m 0640 -o "$FTS_USER" "$SCRIPT_DIR/env/fts.env" "$_env_dst"
    log "Wrote fts.env"
else
    log "fts.env already present — preserving operator config"
fi

# Always stamp FTS_IP (safe on re-run)
sed -i "s|^FTS_IP=.*|FTS_IP=${FTS_IP}|" "$_env_dst"
log "FTS_IP=${FTS_IP} written to fts.env"
unset _env_dst

# ---------------------------------------------------------------------------
# SECTION 10: Reload user systemd and enable services
# ---------------------------------------------------------------------------
log "SECTION 10: Reloading user daemon and enabling services"

as_fts "systemctl --user daemon-reload"
as_fts "systemctl --user enable --now freetakserver.service"
as_fts "systemctl --user enable --now freetakserver-ui.service"

# ---------------------------------------------------------------------------
# SECTION 11: Smoke test
# ---------------------------------------------------------------------------
log "SECTION 11: REST API readiness (up to 90s)"

_tries=0
until curl -sf "http://localhost:19023/SystemStatus/getStatus" >/dev/null 2>&1; do
    _tries=$((_tries + 1))
    if [ "$_tries" -ge 18 ]; then
        printf 'WARNING: API not responding after 90s\n' >&2
        printf '  Check: machinectl shell %s@ -- journalctl --user -u freetakserver.service\n' \
            "$FTS_USER" >&2
        break
    fi
    sleep 5
done
unset _tries

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n'
log "FreeTAKServer deployment complete"
printf '\n'
printf '    %-22s %s\n' "Service account:"  "$FTS_USER (uid $FTS_RUNTIME_UID)"
printf '    %-22s %s\n' "Quadlet dir:"      "$QUADLET_DIR"
printf '    %-22s %s\n' "CoT TCP:"          "$FTS_IP:8087"
printf '    %-22s %s\n' "CoT SSL:"          "$FTS_IP:8089"
printf '    %-22s %s\n' "REST API:"         "http://$FTS_IP:19023"
printf '    %-22s %s\n' "Web UI:"           "http://$FTS_IP:5000"
printf '    %-22s %s\n' "Federation:"       "$FTS_IP:9000"
printf '\n'
printf '    Logs:   machinectl shell %s@ -- journalctl --user -u freetakserver.service -f\n' \
    "$FTS_USER"
printf '    Status: machinectl shell %s@ -- systemctl --user status freetakserver.service\n' \
    "$FTS_USER"
printf '\n'
printf '    IMPORTANT: Rotate FTS_UI_WSKEY and FTS_API_KEY in:\n'
printf '               %s/fts.env\n' "$QUADLET_DIR"
printf '               then: machinectl shell %s@ -- systemctl --user restart freetakserver-ui.service\n' \
    "$FTS_USER"
