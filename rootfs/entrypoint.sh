#!/bin/sh
# Prepare the volume, seed Shaarli's configuration, render nginx's port, then hand
# over to the image's own s6 supervisor.
set -eu

log() { echo "[entrypoint] $*"; }

PORT="${PORT:-8080}"
APP_DIR=/var/www/shaarli
DATA_DIR="$APP_DIR/data"
THUMB_DIR="$DATA_DIR/.cache/thumbnails"
RUN_USER=nginx
RUN_UID=100

case "$PORT" in
    ''|*[!0-9]*) log "PORT must be a number, got '$PORT'"; exit 1 ;;
esac

# --- volume layout -----------------------------------------------------------
# Upstream's compose gives this one container two volumes, data/ and cache/, and
# Railway volumes are strictly 1:1. The mount goes on data/ — Shaarli's own state,
# including its configuration file — and the thumbnail cache moves below it through
# `resource.thumbnails_cache`, so one volume persists both. Shaarli has no
# "the data directory must be empty" guard, so the lost+found every Railway volume
# ships is harmless here.
if [ -n "${RAILWAY_VOLUME_MOUNT_PATH:-}" ] && [ "$RAILWAY_VOLUME_MOUNT_PATH" != "$DATA_DIR" ]; then
    log "WARNING: the volume is mounted at $RAILWAY_VOLUME_MOUNT_PATH; Shaarli reads $DATA_DIR"
    log "WARNING: bookmarks will not survive a redeploy until the mount path is $DATA_DIR"
fi

mkdir -p "$DATA_DIR" "$THUMB_DIR" "$APP_DIR/tmp" "$APP_DIR/pagecache"

# A fresh Railway volume arrives root-owned. Recurse only when the owner disagrees,
# so a large thumbnail cache is not re-walked on every boot.
if [ "$(stat -c %u "$DATA_DIR")" != "$RUN_UID" ]; then
    log "taking ownership of $DATA_DIR"
    chown -R "$RUN_USER:$RUN_USER" "$DATA_DIR"
fi
chown "$RUN_USER:$RUN_USER" "$THUMB_DIR" "$THUMB_DIR/.." "$APP_DIR/tmp" "$APP_DIR/pagecache"

# --- configuration -----------------------------------------------------------
# Runs before anything listens, so Shaarli's install wizard — which hands the first
# visitor the administrator account — is never reachable on the public URL.
SHAARLI_THUMBNAILS_DIR="$THUMB_DIR" php84 /usr/local/share/shaarli/bootstrap.php
chown "$RUN_USER:$RUN_USER" "$DATA_DIR/config.json.php"

# --- nginx -------------------------------------------------------------------
# Railway probes the port it is told about; the image bakes `listen 80`.
sed "s|\${PORT}|$PORT|g" /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf
if grep -q '\${' /etc/nginx/nginx.conf; then
    log "nginx.conf still holds an unsubstituted placeholder"
    exit 1
fi
nginx -t
rm -f /var/run/nginx.pid

log "serving on port $PORT, state in $DATA_DIR"
exec /usr/bin/s6-svscan /etc/services.d
