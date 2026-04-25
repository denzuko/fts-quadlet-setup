#!/bin/sh
# fts_setup.sh — FreeTAKServer quadlet installer
# Mirrors pbx_setup.sh conventions from denzuko/pbx-quadlet-setup:
#   - POSIX sh (no bashisms)
#   - Idempotent: safe to re-run
#   - Drops unit files then daemon-reload
#   - Operator sets FTS_IP before running, or passes via env
#
# Usage:
#   FTS_IP=192.0.2.10 sh fts_setup.sh
#   sh fts_setup.sh --ip 192.0.2.10
#
# Requirements: podman >= 4.4, systemd >= 252

set -eu

# ---------------------------------------------------------------------------
# Tunables — override via environment or --ip flag
# ---------------------------------------------------------------------------
FTS_IP="${FTS_IP:-}"
QUADLET_DIR="${QUADLET_DIR:-/etc/containers/systemd}"
IMAGE_CORE="ghcr.io/freetakteam/freetakserver:latest"
IMAGE_UI="ghcr.io/freetakteam/ui:latest"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --ip) FTS_IP="$2"; shift 2 ;;
        --quadlet-dir) QUADLET_DIR="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$FTS_IP" ]; then
    printf 'FTS_IP not set. Attempting auto-detect via ip route... '
    FTS_IP="$(ip route get 1 | awk '{print $7; exit}')"
    echo "$FTS_IP"
fi

echo "==> FreeTAKServer quadlet installer"
echo "    QUADLET_DIR : $QUADLET_DIR"
echo "    FTS_IP      : $FTS_IP"

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: $1 not found" >&2; exit 1; }; }
need podman
need systemctl
need curl

podman_ver="$(podman --version | awk '{print $3}')"
echo "    podman      : $podman_ver"

# ---------------------------------------------------------------------------
# Pull images (fail fast before writing unit files)
# ---------------------------------------------------------------------------
echo "==> Pulling container images"
podman pull "$IMAGE_CORE"
podman pull "$IMAGE_UI"

# ---------------------------------------------------------------------------
# Install unit files
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> Installing quadlet unit files to $QUADLET_DIR"
install -d "$QUADLET_DIR"

# Network
install -m 0644 "$SCRIPT_DIR/networks/fts.network" "$QUADLET_DIR/fts.network"

# Volumes
install -m 0644 "$SCRIPT_DIR/volumes/fts-data.volume"    "$QUADLET_DIR/fts-data.volume"
install -m 0644 "$SCRIPT_DIR/volumes/fts-ui-data.volume" "$QUADLET_DIR/fts-ui-data.volume"

# Containers
install -m 0644 "$SCRIPT_DIR/containers/freetakserver.container"    "$QUADLET_DIR/freetakserver.container"
install -m 0644 "$SCRIPT_DIR/containers/freetakserver-ui.container" "$QUADLET_DIR/freetakserver-ui.container"

# Env file — only write if not already present (idempotent, preserve operator edits)
if [ ! -f "$QUADLET_DIR/fts.env" ]; then
    install -m 0640 "$SCRIPT_DIR/env/fts.env" "$QUADLET_DIR/fts.env"
    echo "    Wrote $QUADLET_DIR/fts.env"
else
    echo "    fts.env already present — skipping (preserving operator config)"
fi

# Stamp the external IP into the env file
sed -i "s|^FTS_IP=.*|FTS_IP=${FTS_IP}|" "$QUADLET_DIR/fts.env"
echo "    FTS_IP set to $FTS_IP in fts.env"

# ---------------------------------------------------------------------------
# Reload systemd and enable services
# ---------------------------------------------------------------------------
echo "==> Reloading systemd"
systemctl daemon-reload

echo "==> Enabling and starting FreeTAKServer services"
systemctl enable --now freetakserver.service
systemctl enable --now freetakserver-ui.service

# ---------------------------------------------------------------------------
# Smoke test
# ---------------------------------------------------------------------------
echo "==> Waiting for API readiness (up to 90s)..."
tries=0
until curl -sf "http://localhost:19023/SystemStatus/getStatus" >/dev/null 2>&1; do
    tries=$((tries + 1))
    if [ $tries -ge 18 ]; then
        echo "WARNING: API not responding after 90s — check: journalctl -u freetakserver.service" >&2
        break
    fi
    sleep 5
done

echo ""
echo "==> FreeTAKServer deployment complete"
echo ""
echo "    CoT TCP  : $FTS_IP:8087"
echo "    CoT SSL  : $FTS_IP:8089"
echo "    REST API : http://$FTS_IP:19023"
echo "    Web UI   : http://$FTS_IP:5000"
echo "    Federation: $FTS_IP:9000"
echo ""
echo "    Logs: journalctl -u freetakserver.service -f"
echo "    Status: systemctl status freetakserver.service freetakserver-ui.service"
echo ""
echo "    IMPORTANT: Change FTS_UI_WSKEY and FTS_API_KEY in $QUADLET_DIR/fts.env"
echo "               then: systemctl restart freetakserver-ui.service"
