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

# Hostnames baked at build time; REQUIRED via --build-arg (no defaults — the
# build fails without them, so a prod host can never be assumed).
# The container rootfs is read-only in production, so runtime templating is not
# an option — the values are sed-ed into nginx.conf + index.html below.
# WEB_HOSTNAME feeds the /web 302 (https:// is prepended at bake time);
# LANDING_HOSTNAME feeds the og:url/og:image canonical URLs;
# DOCS_HOSTNAME feeds the footer "API" link.
ARG WEB_HOSTNAME
ARG LANDING_HOSTNAME
ARG DOCS_HOSTNAME
# Mobile repository coordinates (Forgejo org variables) feed the release links
# in index.html, the release-host probes in main.js and the CSP connect-src in
# nginx.conf. REPOSITORY_URL / MIRROR_CODEBERG_URL are bare https origins
# (no path); the org/repo names are plain slugs.
ARG REPOSITORY_URL
ARG REPOSITORY_ORG
ARG MIRROR_CODEBERG_URL
ARG MIRROR_CODEBERG_ORG
ARG MIRROR_GITHUB_ORG
ARG MOBILE_REPOSITORY_NAME

COPY index.html robots.txt sitemap.xml /usr/share/nginx/html/
COPY assets/ /usr/share/nginx/html/assets/
COPY nginx.conf /etc/nginx/conf.d/default.conf

# Guard: both ARGs must be a bare hostname — no protocol/scheme, no path, no
# trailing slash, no port. The bare-hostname charset makes the metacharacters
# that used to break sed/nginx (`& \ | ; " ' $`) structurally unrepresentable,
# so this single check replaces the old shape + metacharacter guards. An empty
# value (which would otherwise bake an invalid https://) is rejected here too.
RUN set -e; \
    if [ -z "$WEB_HOSTNAME" ] || ! printf '%s' "$WEB_HOSTNAME" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$|^[A-Za-z0-9]$'; then \
      echo "ERROR: WEB_HOSTNAME must be a bare hostname (no protocol/scheme, no path, no trailing slash, no port): '$WEB_HOSTNAME'" >&2; \
      exit 1; \
    fi; \
    if [ -z "$LANDING_HOSTNAME" ] || ! printf '%s' "$LANDING_HOSTNAME" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$|^[A-Za-z0-9]$'; then \
      echo "ERROR: LANDING_HOSTNAME must be a bare hostname (no protocol/scheme, no path, no trailing slash, no port): '$LANDING_HOSTNAME'" >&2; \
      exit 1; \
    fi; \
    if [ -z "$DOCS_HOSTNAME" ] || ! printf '%s' "$DOCS_HOSTNAME" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$|^[A-Za-z0-9]$'; then \
      echo "ERROR: DOCS_HOSTNAME must be a bare hostname (no protocol/scheme, no path, no trailing slash, no port): '$DOCS_HOSTNAME'" >&2; \
      exit 1; \
    fi; \
    for pair in "REPOSITORY_URL=$REPOSITORY_URL" "MIRROR_CODEBERG_URL=$MIRROR_CODEBERG_URL"; do \
      name="${pair%%=*}"; value="${pair#*=}"; \
      if ! printf '%s' "$value" | grep -Eq '^https://[A-Za-z0-9.-]+(:[0-9]+)?$'; then \
        echo "ERROR: $name must be a bare https origin (https://host, no path, no trailing slash): '$value'" >&2; \
        exit 1; \
      fi; \
    done; \
    for pair in "REPOSITORY_ORG=$REPOSITORY_ORG" "MIRROR_CODEBERG_ORG=$MIRROR_CODEBERG_ORG" "MIRROR_GITHUB_ORG=$MIRROR_GITHUB_ORG" "MOBILE_REPOSITORY_NAME=$MOBILE_REPOSITORY_NAME"; do \
      name="${pair%%=*}"; value="${pair#*=}"; \
      if ! printf '%s' "$value" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then \
        echo "ERROR: $name must be a plain org/repo slug ([A-Za-z0-9._-]): '$value'" >&2; \
        exit 1; \
      fi; \
    done

# Replace the hostname placeholders with the baked values.
# `|` as the sed delimiter. `nginx -t` turns any nginx-parse failure into a
# BUILD failure instead of a runtime outage after the container is recreated.
RUN sed -i "s|__WEB_HOSTNAME__|${WEB_HOSTNAME}|g" /etc/nginx/conf.d/default.conf && nginx -t
RUN sed -i \
      -e "s|__LANDING_HOSTNAME__|${LANDING_HOSTNAME}|g" \
      -e "s|__DOCS_HOSTNAME__|${DOCS_HOSTNAME}|g" \
      /usr/share/nginx/html/index.html /usr/share/nginx/html/robots.txt /usr/share/nginx/html/sitemap.xml
# Repository coordinates: CSP connect-src (nginx.conf), release links
# (index.html) and release-host probes (main.js). The validated charsets above
# keep every value free of sed/HTML/JS metacharacters. A placeholder left
# behind fails the build.
RUN sed -i \
      -e "s|__REPOSITORY_URL__|${REPOSITORY_URL}|g" \
      -e "s|__REPOSITORY_ORG__|${REPOSITORY_ORG}|g" \
      -e "s|__MIRROR_CODEBERG_URL__|${MIRROR_CODEBERG_URL}|g" \
      -e "s|__MIRROR_CODEBERG_ORG__|${MIRROR_CODEBERG_ORG}|g" \
      -e "s|__MIRROR_GITHUB_ORG__|${MIRROR_GITHUB_ORG}|g" \
      -e "s|__MOBILE_REPOSITORY_NAME__|${MOBILE_REPOSITORY_NAME}|g" \
      /etc/nginx/conf.d/default.conf /usr/share/nginx/html/index.html /usr/share/nginx/html/assets/js/main.js \
    && nginx -t \
    && ! grep -lE '__[A-Z_]+__' /etc/nginx/conf.d/default.conf /usr/share/nginx/html/index.html \
         /usr/share/nginx/html/assets/js/main.js /usr/share/nginx/html/robots.txt /usr/share/nginx/html/sitemap.xml

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:8080/ || exit 1
