# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# Слово.Проповеди landing page — pure static site, no build stage needed.
# ---------------------------------------------------------------------------
FROM nginx:alpine

LABEL org.opencontainers.image.title="slovo-propovedi-landing" \
  org.opencontainers.image.description="Landing page for the Slovo Propovedi Android app with direct APK download"

# NOTE: /usr/share/nginx/html/apk is a read-only bind-mount from the host
# /slovo/landing/apk supplied by the systemd unit. Do NOT COPY apk files into
# the image. Docker creates the mountpoint automatically when the bind mount is
# attached, so no placeholder dir is needed here.

# Web-app URL baked at build time; overridable per-deploy via --build-arg.
# The container rootfs is read-only in production, so runtime templating is not
# an option — the value is sed-ed into nginx.conf below.
ARG WEB_APP_URL=https://app.slovo-propovedi.ru

COPY index.html robots.txt /usr/share/nginx/html/
COPY assets/ /usr/share/nginx/html/assets/
COPY nginx.conf /etc/nginx/conf.d/default.conf

# A direct `docker build --build-arg WEB_APP_URL=<bad>` bypasses the deploy-script
# guard, so re-guard the metacharacters here: each corrupts sed/nginx silently
# (see vps-deploy.sh for the per-class WHY).
RUN case "$WEB_APP_URL" in \
    *[\'\"\;\&\|\$\\]* ) echo "ERROR: WEB_APP_URL contains a forbidden character (one of: & | \\ ; \" ' \$): $WEB_APP_URL" >&2; exit 1 ;; \
    esac

# Replace the __WEB_APP_URL__ placeholder in nginx.conf with the baked URL.
# `|` as the sed delimiter so the URL's `/` needs no escaping.
# `nginx -t` turns any nginx-parse class failure (e.g. a stray `;`) into a BUILD
# failure instead of a runtime outage after the container is recreated.
RUN sed -i "s|__WEB_APP_URL__|${WEB_APP_URL}|g" /etc/nginx/conf.d/default.conf && nginx -t

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:8080/ || exit 1
