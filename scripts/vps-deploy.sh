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
# Idempotent: safe to re-run. Handles both first deploy and updates.
# Prerequisites (created by the provisioning playbook):
#   - `slovo` system user exists
#   - Docker buildx builder `slovo-constrained` exists
#   - Traefik reverse proxy is running (slovo-traefik.service)
# =============================================================================

# --- Configuration (override via env) ---
DEPLOY_TAG="${DEPLOY_TAG:?ERROR: DEPLOY_TAG is required (e.g. v1.0.0)}"
LANDING_HOSTNAME="${LANDING_HOSTNAME:?ERROR: LANDING_HOSTNAME is required (e.g. slovo-propovedi.ru)}"
WWW_HOSTNAME="${WWW_HOSTNAME:-www.slovo-propovedi.ru}"
BASE_PATH="${BASE_PATH:-/slovo/landing}"
SRC_PATH="${SRC_PATH:-/slovo/landing/container-src}"
BUILDER_NAME="${BUILDER_NAME:-slovo-constrained}"
BUILDX_MEMORY="${BUILDX_MEMORY:-1g}"
BUILDX_CPU_QUOTA="${BUILDX_CPU_QUOTA:-80000}"
IMAGE_NAME="${IMAGE_NAME:-slovo-landing:latest}"
CONTAINER_PORT="${CONTAINER_PORT:-8080}"
CONTAINER_NETWORK="${CONTAINER_NETWORK:-slovo-landing}"
TRAEFIK_NETWORK="${TRAEFIK_NETWORK:-traefik}"
MEMORY_LIMIT="${MEMORY_LIMIT:-64m}"
STOP_GRACE="${STOP_GRACE:-3}"
TRAEFIK_SERVICE="${TRAEFIK_SERVICE:-slovo-traefik.service}"
ACME_EMAIL="${ACME_EMAIL:-}"
TRAEFIK_IMAGE="${TRAEFIK_IMAGE:-traefik:v3.4}"
TRAEFIK_BASE_PATH="${TRAEFIK_BASE_PATH:-/slovo/traefik}"
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

# --- Ensure prerequisites ---
echo ">> Ensuring prerequisites..."

# Docker — auto-install if missing
if ! command -v docker >/dev/null 2>&1; then
  echo "  Docker: missing -> installing..."
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
  echo "  Docker: installed"
else
  echo "  Docker: OK"
fi

# slovo user + group — create if missing (matches playbook slovo-base role)
if ! getent group slovo >/dev/null 2>&1; then
  echo "  slovo group: missing -> creating..."
  groupadd --system slovo
fi
if ! id -u slovo >/dev/null 2>&1; then
  echo "  slovo user: missing -> creating..."
  useradd --system --no-create-home --shell /sbin/nologin --home /slovo --gid slovo slovo
fi
SLOVO_UID=$(id -u slovo)
SLOVO_GID=$(id -g slovo)
echo "  slovo user: OK (uid=$SLOVO_UID, gid=$SLOVO_GID)"

# buildx builder — create if missing (matches playbook slovo-buildx role)
if ! docker buildx inspect "$BUILDER_NAME" >/dev/null 2>&1; then
  echo "  buildx builder '$BUILDER_NAME': missing -> creating..."
  docker buildx create \
    --name "$BUILDER_NAME" \
    --driver docker-container \
    --driver-opt memory="$BUILDX_MEMORY" \
    --driver-opt cpu-quota="$BUILDX_CPU_QUOTA" \
    --bootstrap
fi
echo "  buildx builder: OK ($BUILDER_NAME)"

# traefik Docker network — create if missing
if ! docker network inspect "$TRAEFIK_NETWORK" >/dev/null 2>&1; then
  echo "  traefik network: missing -> creating..."
  docker network create "$TRAEFIK_NETWORK"
fi
echo "  traefik network: OK ($TRAEFIK_NETWORK)"

# Traefik service — auto-provision if missing
if ! systemctl is-active --quiet "$TRAEFIK_SERVICE" 2>/dev/null; then
  echo "  Traefik ($TRAEFIK_SERVICE): missing -> provisioning..."

  # ACME email is required for Let's Encrypt certificate registration
  if [ -z "$ACME_EMAIL" ]; then
    echo "ERROR: Traefik is not running and ACME_EMAIL is not set."
    echo ""
    echo "       To auto-provision Traefik, provide your Let's Encrypt email:"
    echo "         ACME_EMAIL=you@example.com bash /tmp/vps-deploy.sh"
    echo ""
    echo "       In the Forgejo workflow, add ACME_EMAIL as a repo secret."
    echo ""
    echo "       If Traefik is already running under a different service name,"
    echo "       set TRAEFIK_SERVICE=<name> and re-run this deploy."
    exit 1
  fi

  # Create Traefik directories
  mkdir -p "$TRAEFIK_BASE_PATH/config" "$TRAEFIK_BASE_PATH/acme"

  # Write Traefik static configuration
  cat > "$TRAEFIK_BASE_PATH/config/traefik.yml" <<TRAEFIK_YML
entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: web-secure
          scheme: https
  web-secure:
    address: ":443"

certificatesResolvers:
  default:
    acme:
      email: $ACME_EMAIL
      storage: /etc/traefik/acme/acme.json
      httpChallenge:
        entryPoint: web

providers:
  docker:
    endpoint: unix:///var/run/docker.sock
    exposedByDefault: false
    network: traefik

log:
  level: INFO
TRAEFIK_YML

  # ACME storage file (Traefik requires 600 permissions)
  touch "$TRAEFIK_BASE_PATH/acme/acme.json"
  chmod 600 "$TRAEFIK_BASE_PATH/acme/acme.json"

  # Pull Traefik image
  echo "  Pulling $TRAEFIK_IMAGE..."
  docker pull "$TRAEFIK_IMAGE"

  # Write Traefik systemd service
  cat > "/etc/systemd/system/$TRAEFIK_SERVICE" <<TRAEFIK_SVC
[Unit]
Description=slovo-traefik
Requires=docker.service
After=docker.service
DefaultDependencies=no

[Service]
Type=simple
Environment="HOME=/root"
ExecStartPre=-/usr/bin/env sh -c '/usr/bin/env docker stop -t 30 slovo-traefik 2>/dev/null || true'
ExecStartPre=-/usr/bin/env sh -c '/usr/bin/env docker rm slovo-traefik 2>/dev/null || true'
ExecStartPre=/usr/bin/env docker create \\
    --rm \\
    --name=slovo-traefik \\
    --log-driver=none \\
    --publish=80:80 \\
    --publish=443:443 \\
    --mount type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock \\
    --mount type=bind,src=$TRAEFIK_BASE_PATH/config,dst=/etc/traefik \\
    --mount type=bind,src=$TRAEFIK_BASE_PATH/acme,dst=/etc/traefik/acme \\
    --network=traefik \\
    --label traefik.enable=false \\
    $TRAEFIK_IMAGE
ExecStart=/usr/bin/env docker start --attach slovo-traefik
ExecStop=-/usr/bin/env sh -c '/usr/bin/env docker stop -t 30 slovo-traefik 2>/dev/null || true'
Restart=always
RestartSec=5
SyslogIdentifier=slovo-traefik

[Install]
WantedBy=multi-user.target
TRAEFIK_SVC

  systemctl daemon-reload
  systemctl enable --now "$TRAEFIK_SERVICE"

  # Wait for Traefik to become active
  echo "  Waiting for Traefik to start..."
  for _ in $(seq 1 15); do
    if systemctl is-active --quiet "$TRAEFIK_SERVICE" 2>/dev/null; then
      break
    fi
    sleep 2
  done

  if ! systemctl is-active --quiet "$TRAEFIK_SERVICE" 2>/dev/null; then
    echo "ERROR: Traefik failed to start."
    systemctl status "$TRAEFIK_SERVICE" --no-pager -l || true
    exit 1
  fi
  echo "  Traefik: provisioned ($TRAEFIK_SERVICE active)"
else
  echo "  Traefik: OK ($TRAEFIK_SERVICE active)"
fi

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
