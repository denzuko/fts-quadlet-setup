divert(-1)changequote(`[', `]')dnl
dnl summary.m4 — fts-quadlet-setup installer output templates
dnl Usage: printf '_macro()\n' | m4 -D VAR=val ... share/summary.m4 -
dnl changequote uses [ ] so m4 keywords inside define() bodies are inert.
define([_preflight],[
    IP:                    FTS_IP
    User:                  FTS_USER (uid FTS_UID)
    Pool:                  ZFS_POOL
    Container dataset:     DS_CONTAINER -> MNT_CONTAINER
    User dataset:          DS_USER -> MNT_USER
    Podman:                PODMAN_VER
])dnl
define([_header],[
==> FreeTAKServer FTS_VERSION deployment complete

    Service account:       FTS_USER (uid FTS_RUNTIME_UID)
    ZFS home:              DS_USER -> MNT_USER
    ZFS data:              DS_CONTAINER -> MNT_CONTAINER
    Quadlet dir:           QUADLET_DIR
    Secret namespace:      SHM_DIR
])dnl
define([_endpoints],[
    CoT TCP:               FTS_IP:FTS_COT_PORT
    CoT SSL:               FTS_IP:FTS_COT_PORT_S  (TLS at HAProxy)
    REST API:              http://FTS_IP:FTS_API_PORT
    Web UI:                http://FTS_IP:FTS_UI_PORT
    Federation:            FTS_IP:FTS_FED_PORT     (TLS at HAProxy)
])dnl
define([_ops],[
    Logs:   machinectl shell FTS_USER@ -- journalctl --user -u freetakserver.service -f
    Status: machinectl shell FTS_USER@ -- systemctl --user status freetakserver.service

    Secrets are in SHM_DIR -- copy them off before reboot
    (tmpfs -- contents are lost on reboot by design)
])dnl
divert(0)dnl
