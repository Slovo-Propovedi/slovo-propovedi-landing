#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# VPS Deployment Script — slovo-propovedi-landing
# =============================================================================
# Runs ON the VPS as root. Triggered by the Forgejo release workflow via SSH.
# Adapted from the slovo-propovedi-docs deploy script; every name is scoped to
# `slovo-landing` so it never collides with the PRODUCTION docs router on the
# shared Traefik instance.
#
# Usage:   DEPLOY_TAG=v1.0.0 LANDING_HOSTNAME=slovo-propovedi.ru bash vps-deploy.sh
#
# Scope: this script owns ONLY the slovo-landing container, its own
# `slovo-landing` Docker network, and the landing-specific APK/screenshot
# refresh units. All shared infrastructure — Docker, the `slovo` user/group,
# the buildx builder `slovo-constrained`, Traefik (`slovo-traefik.service`) and
# the `traefik` Docker network — is owned by the slovo-propovedi playbook.
# Missing infrastructure is a HARD ERROR here; it is never auto-provisioned.
# Run the playbook first:  just setup-all  (or: just setup-service <name>).
#
# Idempotent: safe to re-run. Handles both the first landing deploy and updates.
# =============================================================================

# --- Configuration (override via env) ---
DEPLOY_TAG="${DEPLOY_TAG:?ERROR: DEPLOY_TAG is required (e.g. v1.0.0)}"
LANDING_HOSTNAME="${LANDING_HOSTNAME:?ERROR: LANDING_HOSTNAME is required (e.g. slovo-propovedi.ru)}"
WWW_HOSTNAME="${WWW_HOSTNAME:-www.slovo-propovedi.ru}"
BASE_PATH="${BASE_PATH:-/slovo/landing}"
SRC_PATH="${SRC_PATH:-/slovo/landing/container-src}"
BUILDER_NAME="${BUILDER_NAME:-slovo-constrained}"
IMAGE_NAME="${IMAGE_NAME:-slovo-landing:latest}"
CONTAINER_PORT="${CONTAINER_PORT:-8080}"
CONTAINER_NETWORK="${CONTAINER_NETWORK:-slovo-landing}"
TRAEFIK_NETWORK="${TRAEFIK_NETWORK:-traefik}"
MEMORY_LIMIT="${MEMORY_LIMIT:-64m}"
STOP_GRACE="${STOP_GRACE:-3}"
TRAEFIK_SERVICE="${TRAEFIK_SERVICE:-slovo-traefik.service}"

# Shared infrastructure this deploy depends on but does NOT own (playbook-managed).
REQUIRED_SERVICES="$TRAEFIK_SERVICE"
REQUIRED_NETWORKS="$TRAEFIK_NETWORK"
# Hostname-only contract for the two baked hostnames. WEB_HOSTNAME feeds the
# /web 302 (https:// is prepended at bake time); LANDING_HOSTNAME feeds the
# og:url/og:image canonical URLs (and the existing Traefik labels). The bare
# hostname charset makes the metacharacters that used to break sed/nginx
# unrepresentable, so one validator below replaces the old shape + metachar
# guards on the web-app URL.
WEB_HOSTNAME="${WEB_HOSTNAME:-app.slovo-propovedi.ru}"

# LC_ALL=C keeps the character ranges ASCII-deterministic: in ru_RU.UTF-8 the
# collation range would not span letters and every valid hostname would be
# rejected. Validates both hostnames once; validating LANDING_HOSTNAME here
# additionally protects the existing Traefik labels usage.
require_valid_hostname() {
  local name="$1" value="$2"
  if ! (export LC_ALL=C; [[ "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]); then
    echo "ERROR: $name must be a bare hostname (no protocol, no path, no trailing slash, no port): $value" >&2
    exit 1
  fi
}
require_valid_hostname WEB_HOSTNAME "$WEB_HOSTNAME"
require_valid_hostname LANDING_HOSTNAME "$LANDING_HOSTNAME"

# --- Banner ---
echo "==============================================================="
echo "  VPS deployment"
echo "  Tag:      $DEPLOY_TAG"
echo "  Hostname: $LANDING_HOSTNAME (www -> $WWW_HOSTNAME)"
echo "==============================================================="

# --- Verify prerequisites (playbook-owned; never auto-provisioned) ---
# This script owns ONLY the slovo-landing container and the slovo-landing
# network (created in step 4), plus the landing-specific refresh units.
# Everything checked below is provisioned by the slovo-propovedi playbook
# (`just setup-all`). Anything missing fails fast with a clear message instead
# of a half-provisioned box or a crash-looping service.
echo ">> Verifying prerequisites..."

fail_missing() {
  echo "ERROR: $1" >&2
  echo "       Shared infrastructure is owned by the slovo-propovedi playbook." >&2
  echo "       Provision it first:  just setup-all   (or: just setup-service <name>)" >&2
  exit 1
}

# Docker
command -v docker >/dev/null 2>&1 || fail_missing "Docker is not installed."
systemctl is-active --quiet docker || fail_missing "Docker service is not running."
echo "  Docker: OK"

# slovo user + group (playbook slovo-base role).
# uid/gid are system-assigned, so capture them dynamically like the playbook does.
getent group slovo >/dev/null 2>&1 || fail_missing "Group 'slovo' does not exist (playbook slovo-base role)."
id -u slovo >/dev/null 2>&1 || fail_missing "User 'slovo' does not exist (playbook slovo-base role)."
SLOVO_UID=$(id -u slovo)
SLOVO_GID=$(id -g slovo)
echo "  slovo user: OK (uid=$SLOVO_UID, gid=$SLOVO_GID)"

# buildx builder (playbook slovo-buildx role)
docker buildx inspect "$BUILDER_NAME" >/dev/null 2>&1 \
  || fail_missing "buildx builder '$BUILDER_NAME' does not exist (playbook slovo-buildx role)."
echo "  buildx builder: OK ($BUILDER_NAME)"

# Traefik fronts this service. If it runs under a different unit name, set
# TRAEFIK_SERVICE=<name>.
# shellcheck disable=SC2086 # word splitting of the space-separated list is intended
for svc in $REQUIRED_SERVICES; do
  systemctl is-active --quiet "$svc" 2>/dev/null \
    || fail_missing "Required service '$svc' is not running."
done
echo "  services: OK ($REQUIRED_SERVICES)"

# Shared Docker networks the container attaches to at runtime (step 6). The
# slovo-landing network itself is this script's own and is created in step 4.
# shellcheck disable=SC2086 # word splitting of the space-separated list is intended
for net in $REQUIRED_NETWORKS; do
  docker network inspect "$net" >/dev/null 2>&1 \
    || fail_missing "Required Docker network '$net' does not exist."
done
echo "  networks: OK ($REQUIRED_NETWORKS)"

# --- 1. Create paths ---
echo ">> Ensuring paths exist..."
mkdir -p "$BASE_PATH" "$SRC_PATH" "$BASE_PATH/apk" "$BASE_PATH/screenshots"
chown slovo:slovo "$BASE_PATH" "$SRC_PATH" "$BASE_PATH/apk" "$BASE_PATH/screenshots"
chmod 0750 "$BASE_PATH" "$SRC_PATH"
chmod 0755 "$BASE_PATH/apk" "$BASE_PATH/screenshots"
# Tokens dir: root-only (refresh reads as root; slovo user cannot read tokens — intentional)
install -d -m 0700 -o root -g root "$BASE_PATH/tokens"

# --- 2. Verify source code ---
# Source code is transferred by the Forgejo workflow (tar+ssh) before this
# script runs. No git operations needed — the runner already checked out the tag.
echo ">> Verifying source code at $SRC_PATH..."
if [ ! -f "$SRC_PATH/Dockerfile" ]; then
  echo "ERROR: No source code found at $SRC_PATH."
  echo "       The workflow should transfer the code before running this script."
  exit 1
fi
chown -R slovo:slovo "$SRC_PATH"

# --- 3. Write Traefik labels ---
# NOTE: with --label-file the `$1`/`$2` in the redirect regex are LITERAL —
# do NOT use `$$` escaping (that is docker-compose-only).
echo ">> Writing Traefik labels..."
{
  printf 'traefik.enable=true\n'
  printf 'traefik.docker.network=%s\n' "$TRAEFIK_NETWORK"
  printf 'traefik.http.services.slovo-landing.loadbalancer.server.port=%s\n' "$CONTAINER_PORT"
  # shellcheck disable=SC2016 # literal backticks are Traefik label syntax
  printf 'traefik.http.routers.slovo-landing.rule=Host(`%s`) || Host(`%s`)\n' "$LANDING_HOSTNAME" "$WWW_HOSTNAME"
  printf 'traefik.http.routers.slovo-landing.service=slovo-landing\n'
  printf 'traefik.http.routers.slovo-landing.entrypoints=web-secure\n'
  printf 'traefik.http.routers.slovo-landing.tls=true\n'
  printf 'traefik.http.routers.slovo-landing.tls.certResolver=default\n'
  printf 'traefik.http.routers.slovo-landing.middlewares=slovo-landing-www-to-apex\n'
  printf 'traefik.http.middlewares.slovo-landing-www-to-apex.redirectregex.regex=https://www\\.([^/]+)/(.*)\n'
  # shellcheck disable=SC2016 # literal $1/$2 are Traefik replacement back-references
  printf 'traefik.http.middlewares.slovo-landing-www-to-apex.redirectregex.replacement=https://$1/$2\n'
  printf 'traefik.http.middlewares.slovo-landing-www-to-apex.redirectregex.permanent=true\n'
} > "$BASE_PATH/labels"
chown slovo:slovo "$BASE_PATH/labels"
chmod 0640 "$BASE_PATH/labels"

# --- 4. Create Docker network (if missing) ---
echo ">> Ensuring Docker network '$CONTAINER_NETWORK'..."
docker network inspect "$CONTAINER_NETWORK" >/dev/null 2>&1 \
  || docker network create "$CONTAINER_NETWORK"

# --- 5. Build Docker image ---
echo ">> Building Docker image (this may take a minute)..."
docker buildx build \
  --builder="$BUILDER_NAME" \
  --load \
  --tag="$IMAGE_NAME" \
  --build-arg WEB_HOSTNAME="$WEB_HOSTNAME" \
  --build-arg LANDING_HOSTNAME="$LANDING_HOSTNAME" \
  "$SRC_PATH"

# --- 6. Write systemd unit ---
echo ">> Writing systemd unit..."
cat > /etc/systemd/system/slovo-landing.service <<EOF
[Unit]
Description=slovo-landing
Requires=docker.service
After=docker.service
Wants=$TRAEFIK_SERVICE
After=$TRAEFIK_SERVICE
DefaultDependencies=no

[Service]
Type=simple
Environment="HOME=/root"
ExecStartPre=-/usr/bin/env docker rm -f slovo-landing
ExecStartPre=/usr/bin/env docker create \\
    --name=slovo-landing \\
    --log-driver=none \\
    --user=$SLOVO_UID:$SLOVO_GID \\
    --cap-drop=ALL \\
    --read-only \\
    --tmpfs /tmp:rw,noexec,nosuid,size=16m,uid=$SLOVO_UID,gid=$SLOVO_GID,mode=1777 \\
    --tmpfs /var/cache/nginx:rw,noexec,nosuid,size=16m,uid=$SLOVO_UID,gid=$SLOVO_GID,mode=0700 \\
    --tmpfs /run:rw,noexec,nosuid,size=8m,uid=$SLOVO_UID,gid=$SLOVO_GID,mode=0755 \\
    --network=$CONTAINER_NETWORK \\
    --label-file=$BASE_PATH/labels \\
    --memory=$MEMORY_LIMIT \\
    --mount type=bind,src=$BASE_PATH/apk,dst=/usr/share/nginx/html/apk,ro \\
    --mount type=bind,src=$BASE_PATH/screenshots,dst=/usr/share/nginx/html/screenshots,ro \\
    $IMAGE_NAME
ExecStartPre=/usr/bin/env docker network connect $TRAEFIK_NETWORK slovo-landing
ExecStart=/usr/bin/env docker start --attach slovo-landing
ExecStop=-/usr/bin/env docker stop -t $STOP_GRACE slovo-landing
Restart=always
RestartSec=30
SyslogIdentifier=slovo-landing

[Install]
WantedBy=multi-user.target
EOF

# --- 7. Reload and restart ---
echo ">> Reloading systemd and restarting service..."
systemctl daemon-reload
systemctl restart slovo-landing.service

# --- 8. Verify ---
sleep 2
if systemctl is-active --quiet slovo-landing.service; then
  echo "[OK] slovo-landing.service is running"
  echo "[OK] Deployment of $DEPLOY_TAG complete"
  echo "     Site: https://$LANDING_HOSTNAME"
else
  echo "ERROR: slovo-landing.service failed to start"
  systemctl status slovo-landing.service --no-pager -l || true
  exit 1
fi

# --- 9. Install APK refresh units ---
# The refresh script ships inside the freshly-deployed container-src; install it
# into the persistent BASE_PATH so it survives future deploys that replace src.
echo ">> Installing APK refresh units..."
install -m 0750 "$SRC_PATH/scripts/vps-refresh-apk.sh" "$BASE_PATH/vps-refresh-apk.sh"

cat > /etc/systemd/system/slovo-landing-refresh.service <<EOF
[Unit]
Description=Refresh slovo-landing APK from the latest mobile release
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$BASE_PATH/vps-refresh-apk.sh
EOF

cat > /etc/systemd/system/slovo-landing-refresh.timer <<EOF
[Unit]
Description=Twice-daily APK refresh for slovo-landing

[Timer]
OnCalendar=*-*-* 04,16:30:00
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now slovo-landing-refresh.timer
echo "[OK] slovo-landing-refresh.timer enabled (twice daily)"

# --- 9b. Install screenshots refresh units ---
# Same pattern as the APK refresh: the script ships in container-src and is
# installed into the persistent BASE_PATH so it survives future deploys.
echo ">> Installing screenshots refresh units..."
install -m 0750 "$SRC_PATH/scripts/vps-refresh-screenshots.sh" "$BASE_PATH/vps-refresh-screenshots.sh"

cat > /etc/systemd/system/slovo-landing-refresh-shots.service <<EOF
[Unit]
Description=Refresh slovo-landing screenshots from the mobile repo
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$BASE_PATH/vps-refresh-screenshots.sh
EOF

cat > /etc/systemd/system/slovo-landing-refresh-shots.timer <<EOF
[Unit]
Description=Twice-daily screenshots refresh for slovo-landing

[Timer]
OnCalendar=*-*-* 04,16:30:00
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now slovo-landing-refresh-shots.timer
echo "[OK] slovo-landing-refresh-shots.timer enabled (twice daily)"

# --- 10. Initial refresh ---
echo ">> Triggering initial APK refresh..."
systemctl start slovo-landing-refresh.service || echo "  WARN: initial APK refresh failed; timer will retry"
echo ">> Triggering initial screenshots refresh..."
systemctl start slovo-landing-refresh-shots.service || echo "  WARN: initial screenshots refresh failed; timer will retry"

# --- 11. Cleanup ---
rm -f /tmp/vps-deploy.sh
echo ">> Done."
