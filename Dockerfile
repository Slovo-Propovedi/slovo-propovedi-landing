# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# Слово.Проповеди landing page — pure static site, no build stage needed.
# ---------------------------------------------------------------------------
FROM nginx:alpine

LABEL org.opencontainers.image.title="slovo-propovedi-landing" \
  org.opencontainers.image.description="Landing page for the Slovo Propovedi Android app with direct APK download"

# NOTE: /usr/share/nginx/html/apk is a read-only bind-mount from the host
# /slovo/landing/apk supplied by the systemd unit. Do NOT COPY apk files into
# the image. We only create the dir so the mount target exists and the path
# never 404s hard before the mount is attached.
RUN mkdir -p /usr/share/nginx/html/apk

COPY index.html robots.txt /usr/share/nginx/html/
COPY assets/ /usr/share/nginx/html/assets/
COPY nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:8080/ || exit 1
