#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# APK Refresh Script — slovo-propovedi-landing
# =============================================================================
# Runs ON the VPS as the unprivileged `slovo` user inside a sandboxed systemd
# unit (also manually startable). Fetches the latest mobile release from
# Forgejo (primary), then the Codeberg mirror, then the GitHub mirror, verifies
# the archive AND the APK signing certificate, and atomically places the APK +
# latest.json into the landing's read-only bind-mount dir. Triggered twice daily by slovo-landing-refresh.timer
# and once after each deploy by the release workflow.
#
# Sources are tried IN ORDER; the first fully-successful one wins. If none
# succeeds the script exits 1 and leaves the previous state untouched. If the
# already-served version matches the latest release, the script exits 0 early
# without re-downloading the ~30MB archive. A notes-only release (the mobile
# pipeline's OTA-only mode: no APK asset at all) exits 0 with a log line — there
# is nothing to refresh, and falling through to a mirror would serve an OLDER
# release as "latest".
# =============================================================================

# --- Env file ---
# The systemd unit passes /etc/default/slovo-landing via EnvironmentFile=. For
# manual runs the same file is read here as DATA — never sourced as shell, so a
# value containing `$(...)` cannot execute. Only known keys are taken, and a
# variable already set in the environment wins. Missing file is NOT an error —
# the required-variable check below fails fast instead.
ENV_FILE="${ENV_FILE:-/etc/default/slovo-landing}"
load_env_file() {
  local key value
  [ -r "$1" ] || return 0
  while IFS='=' read -r key value || [ -n "$key" ]; do
    case "$key" in
      REPOSITORY_URL|MIRROR_CODEBERG_URL|MIRROR_GITHUB_LATEST_RELEASE_URL|MIRROR_GITHUB_SCREENSHOTS_RAW_URL|APK_SIGNER_SHA256) ;;
      *) continue ;;
    esac
    [ -n "${!key:-}" ] && continue
    printf -v "$key" '%s' "$value"
    export "${key?}"
  done < "$1"
}
load_env_file "$ENV_FILE"

# --- Required configuration (fail fast, no production defaults) ---
require_env() {
  if [ -z "${!1:-}" ]; then
    echo "ERROR: $1 is required. Set it in $ENV_FILE (ENV_FILE overridable) or in the environment." >&2
    MISSING_ENV=1
  fi
}
MISSING_ENV=0
require_env REPOSITORY_URL
require_env MIRROR_CODEBERG_URL
require_env MIRROR_GITHUB_LATEST_RELEASE_URL
require_env APK_SIGNER_SHA256
if [ "$MISSING_ENV" -ne 0 ]; then
  echo "ERROR: missing required environment variables — aborting" >&2
  exit 1
fi

# Every source URL must be plain https with a URL-safe charset: they are built
# into API URLs and handed to curl, so anything else is a misconfiguration.
HTTPS_URL_RE='^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$'
for var in REPOSITORY_URL MIRROR_CODEBERG_URL MIRROR_GITHUB_LATEST_RELEASE_URL; do
  if ! printf '%s' "${!var}" | grep -Eq "$HTTPS_URL_RE"; then
    echo "ERROR: $var must be an https:// URL (got '${!var}')" >&2
    exit 1
  fi
done

# --- Pinned APK signing certificate(s) ---
# APK_SIGNER_SHA256: SHA-256 of the mobile release key's certificate (64 hex,
# as printed by `apksigner verify --print-certs`), or a comma-separated list
# while a key rotation is in progress. Public by nature: it is embedded in every
# signed APK and published in the mobile repo's public/.well-known/
# assetlinks.json. An APK from ANY source not signed with one of these
# certificates is never served — a compromised release host or mirror cannot
# push a foreign APK to new installs. Fail-closed: a missing or malformed value
# stops the script instead of skipping the check.
APK_SIGNER_SHA256="$(printf '%s' "$APK_SIGNER_SHA256" | tr -d '[:space:]' | tr 'A-F' 'a-f')"
if ! printf '%s' "$APK_SIGNER_SHA256" | grep -Eq '^[0-9a-f]{64}(,[0-9a-f]{64})*$'; then
  echo "ERROR: APK_SIGNER_SHA256 must be one or more comma-separated 64-hex SHA-256 digests" >&2
  exit 1
fi

# --- Configuration (override via env) ---
APK_DIR="${APK_DIR:-/slovo/landing/apk}"
KEEP_VERSIONS="${KEEP_VERSIONS:-3}"
TOKEN_DIR="${TOKEN_DIR:-/slovo/landing/tokens}"
TIMEOUT="${TIMEOUT:-120}"
# Zip-bomb guard: the release archive holds one ~50MB APK.
MAX_UNZIPPED_BYTES="${MAX_UNZIPPED_BYTES:-314572800}"
MAX_ZIP_ENTRIES="${MAX_ZIP_ENTRIES:-20}"

# Strip a single trailing slash so https://host//api/... can never be built.
REPOSITORY_URL="${REPOSITORY_URL%/}"
MIRROR_CODEBERG_URL="${MIRROR_CODEBERG_URL%/}"
MIRROR_GITHUB_LATEST_RELEASE_URL="${MIRROR_GITHUB_LATEST_RELEASE_URL%/}"
RELEASE_API_PATH="/api/v1/repos/Slovo_Propovedi/slovo-propovedi-mobile/releases/latest"
REPOSITORY_API="$REPOSITORY_URL$RELEASE_API_PATH"
# Codeberg runs Forgejo: same API shape as the primary repository.
CODEBERG_API="$MIRROR_CODEBERG_URL$RELEASE_API_PATH"

# https only, including every redirect, and an explicit User-Agent: GitHub's
# API requires one, and Codeberg rejects some browser-like agents that a
# local ~/.curlrc might inject.
CURL_PROTO=(--proto '=https' --proto-redir '=https' --user-agent 'slovo-propovedi-landing-refresh')

# --- Concurrency guard (single refresh at a time) ---
mkdir -p "$APK_DIR"
exec 9>"$APK_DIR/.refresh.lock"
flock -n 9 || { echo "another refresh is running"; exit 0; }

# --- Stale temp cleanup + temp workspace ---
# NOTE: WORKDIR (not TMPDIR) to avoid shadowing the env var of the same name
# which some tools (e.g. mktemp) honour.
rm -f "$APK_DIR"/.tmp-* 2>/dev/null || true
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# --- Prerequisites ---
# Installed by vps-deploy.sh (as root); this unprivileged script only checks.
for cmd in curl jq unzip sha256sum sort apksigner; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: prerequisite '$cmd' is missing — re-run the landing deploy (vps-deploy.sh installs it)" >&2
    exit 1
  fi
done

# --- Token detection (never echoed) ---
# Order: env override, then the systemd credential (LoadCredential= hands the
# root-only token file to this unprivileged unit), then TOKEN_DIR for manual
# root runs. An empty file means "no token".
read_token() {
  local env_value="$1" name="$2" file
  if [ -n "$env_value" ]; then
    printf '%s' "$env_value" | tr -d '\r\n'
    return
  fi
  for file in "${CREDENTIALS_DIRECTORY:-/nonexistent}/$name" "$TOKEN_DIR/$name"; do
    if [ -r "$file" ] && [ -s "$file" ]; then
      tr -d '\r\n' < "$file"
      return
    fi
  done
}
REPOSITORY_TOKEN="$(read_token "${REPOSITORY_API_TOKEN:-}" forgejo)"
GITHUB_TOKEN="$(read_token "${GITHUB_MIRROR_TOKEN:-}" github)"

# --- Auth headers written to files (never in argv) ---
# curl -H @file (>=7.55) reads the header from a file, keeping the token out of
# /proc/*/cmdline. Files live in the private 0700 WORKDIR, cleaned by the EXIT trap.
REPOSITORY_AUTH_HDR=""
if [ -n "$REPOSITORY_TOKEN" ]; then
  REPOSITORY_AUTH_HDR="$WORKDIR/forgejo-auth.hdr"
  printf 'Authorization: token %s\n' "$REPOSITORY_TOKEN" > "$REPOSITORY_AUTH_HDR"
  chmod 600 "$REPOSITORY_AUTH_HDR"
fi

GITHUB_AUTH_HDR=""
if [ -n "$GITHUB_TOKEN" ]; then
  GITHUB_AUTH_HDR="$WORKDIR/github-auth.hdr"
  printf 'Authorization: Bearer %s\n' "$GITHUB_TOKEN" > "$GITHUB_AUTH_HDR"
  chmod 600 "$GITHUB_AUTH_HDR"
fi

# =============================================================================
# verify_apk_signature <apk>
#   apksigner must verify the APK, it must carry exactly one signer
#   certificate, and that certificate must be one of the pinned digests.
# =============================================================================
verify_apk_signature() {
  local output digests
  if ! output="$(apksigner verify --print-certs "$1" 2>/dev/null)"; then
    return 1
  fi
  digests="$(printf '%s\n' "$output" \
    | sed -n 's/.*[Ss]igner.*certificate SHA-256 digest: *\([0-9A-Fa-f]\{64\}\).*/\1/p' \
    | tr 'A-F' 'a-f' | sort -u)"
  # Empty or multiple distinct signers never match a single 64-hex digest.
  printf '%s' "$digests" | grep -Eqx '[0-9a-f]{64}' || return 1
  case ",$APK_SIGNER_SHA256," in
    *",$digests,"*) return 0 ;;
    *) return 1 ;;
  esac
}

# --- Global state set by a successful source ---
RELEASE_VERSION=""
RELEASE_HTML_URL=""
APK_SOURCE_FILE=""

# =============================================================================
# process_source <name> <api> <auth_header> <extra_header>
#   Fetches + validates the release, downloads the zip, unzips it, and locates
#   the single APK. On full success sets the globals above and returns 0;
#   otherwise logs why and returns non-zero so the next source is tried.
#   Special case: returns 2 when the newest release has NO APK zip asset — an
#   OTA-only release. The caller stops there instead of trying older mirrors.
# =============================================================================
process_source() {
  local name="$1" api="$2" auth="$3" extra="$4"
  local http_code json_file
  json_file="$(mktemp)"

  # --- fetch release JSON ---
  # curl's -w '%{http_code}' prints "000" for a network failure and the real
  # code (e.g. "404") for an HTTP error even with -f, so the code alone
  # distinguishes the two cases.
  local curl_args=(-fsS "${CURL_PROTO[@]}" --max-time "$TIMEOUT" -o "$json_file" -w '%{http_code}')
  if [ -n "$auth" ]; then curl_args+=(-H "$auth"); fi
  if [ -n "$extra" ]; then curl_args+=(-H "$extra"); fi
  curl_args+=(--url "$api")

  http_code="$(curl "${curl_args[@]}" 2>/dev/null || true)"
  if [ -z "$http_code" ]; then
    http_code="000"
  fi

  if [ "$http_code" = "000" ]; then
    echo "  [$name] network failure"
    rm -f "$json_file"
    return 1
  fi

  if [ "$http_code" = "401" ] || [ "$http_code" = "403" ]; then
    if [ "$name" = "forgejo-anon" ]; then
      echo "  [$name] auth required (HTTP $http_code) — provide a token in $TOKEN_DIR/forgejo (mode 600) or REPOSITORY_API_TOKEN env"
    elif [ "$name" = "github-anon" ]; then
      echo "  [$name] rate-limited or forbidden (HTTP $http_code) — provide a token in $TOKEN_DIR/github or GITHUB_MIRROR_TOKEN env"
    else
      echo "  [$name] HTTP $http_code"
    fi
    rm -f "$json_file"
    return 1
  fi

  if [ "$http_code" -ge 400 ]; then
    echo "  [$name] HTTP $http_code"
    rm -f "$json_file"
    return 1
  fi

  if ! jq -e . "$json_file" >/dev/null 2>&1; then
    echo "  [$name] invalid JSON"
    rm -f "$json_file"
    return 1
  fi

  # --- parse + validate (parse, don't validate) ---
  local tag count asset_name asset_url asset_size html_url
  tag="$(jq -r '.tag_name // empty' "$json_file")"
  if [ -z "$tag" ] || ! printf '%s' "$tag" | grep -Eq '^v?[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "  [$name] tag_name '$tag' is not semver"
    rm -f "$json_file"
    return 1
  fi

  count="$(jq '[.assets[] | select(.name | test("^slovo-propovedi-v[0-9][^/]*\\.zip$"))] | length' "$json_file")" || {
    echo "  [$name] could not inspect assets"
    rm -f "$json_file"
    return 1
  }
  if [ "$count" -eq 0 ]; then
    # Notes-only release: the mobile pipeline publishes JS-only releases with
    # no APK asset (delivered through OTA). Nothing to refresh here.
    echo "  [$name] latest release has no APK zip asset — OTA-only release, nothing to refresh"
    rm -f "$json_file"
    return 2
  fi
  if [ "$count" -ne 1 ]; then
    echo "  [$name] expected exactly one matching zip asset, found $count"
    rm -f "$json_file"
    return 1
  fi

  asset_name="$(jq -r '[.assets[] | select(.name | test("^slovo-propovedi-v[0-9][^/]*\\.zip$"))][0].name' "$json_file")"
  asset_url="$(jq -r '[.assets[] | select(.name | test("^slovo-propovedi-v[0-9][^/]*\\.zip$"))][0].browser_download_url' "$json_file")"
  asset_size="$(jq -r '[.assets[] | select(.name | test("^slovo-propovedi-v[0-9][^/]*\\.zip$"))][0].size // empty' "$json_file")"
  html_url="$(jq -r '.html_url // empty' "$json_file")"
  rm -f "$json_file"

  local version="${tag#v}"

  # --- early no-op: already serving this version? ---
  # Mobile releases are tag-driven: a given version is published exactly once
  # and never re-published, so version equality alone proves the served APK is
  # the latest. (The post-download sha256 deep check below still catches the
  # case where versions differ but content is identical, avoiding republish
  # churn.) This avoids re-downloading the ~30MB zip on every timer run.
  local current_version
  current_version="$(jq -r '.version // empty' "$APK_DIR/latest.json" 2>/dev/null || true)"
  if [ -n "$current_version" ] && [ "$current_version" = "$version" ] \
     && [ -f "$APK_DIR/slovo-propovedi-v$version.apk" ]; then
    echo ">> Up to date (v$version already served); nothing to do"
    exit 0
  fi

  # The asset URL comes from remote JSON: accept https only, and pass it via
  # --url so a value starting with `-` can never be parsed as a curl option.
  if ! printf '%s' "$asset_url" | grep -Eq '^https://[^[:space:]]+$'; then
    echo "  [$name] asset URL is not https: '$asset_url'"
    return 1
  fi

  # --- download + verify size ---
  local download_file="$WORKDIR/release.zip"
  echo "  [$name] downloading $asset_name..."
  if ! curl -fsSL "${CURL_PROTO[@]}" --max-time "$TIMEOUT" -o "$download_file" --url "$asset_url" 2>/dev/null; then
    echo "  [$name] download failed"
    return 1
  fi
  if [ -n "$asset_size" ]; then
    local actual_size
    actual_size="$(stat -c %s "$download_file")"
    if [ "$actual_size" -ne "$asset_size" ]; then
      echo "  [$name] size mismatch: got $actual_size, expected $asset_size"
      return 1
    fi
  fi

  # --- zip-bomb guard: bound entry count and total uncompressed size ---
  local zip_listing zip_bytes zip_entries
  if ! zip_listing="$(unzip -l "$download_file" 2>/dev/null | tail -n 1)"; then
    echo "  [$name] cannot list archive"
    return 1
  fi
  zip_bytes="$(printf '%s' "$zip_listing" | awk '{print $1}')"
  zip_entries="$(printf '%s' "$zip_listing" | awk '{print $2}')"
  if ! [[ "$zip_bytes" =~ ^[0-9]+$ && "$zip_entries" =~ ^[0-9]+$ ]] \
     || [ "$zip_bytes" -gt "$MAX_UNZIPPED_BYTES" ] || [ "$zip_entries" -gt "$MAX_ZIP_ENTRIES" ]; then
    echo "  [$name] archive too large or malformed ($zip_entries entries, $zip_bytes bytes)"
    return 1
  fi

  # --- unzip into empty subdir (zip-slip safe) ---
  # Fresh dir per source: a previous source may have failed AFTER extracting
  # (e.g. a rejected signature), and reusing its dir would make unzip prompt.
  local exdir="$WORKDIR/extract"
  rm -rf "$exdir"
  mkdir -p "$exdir"
  if ! unzip -q "$download_file" -d "$exdir" < /dev/null; then
    echo "  [$name] unzip failed"
    return 1
  fi

  # --- locate exactly one APK (spaces handled) ---
  local apk_file=""
  while IFS= read -r -d '' f; do
    if [ -n "$apk_file" ]; then
      echo "  [$name] multiple .apk files found in archive"
      return 1
    fi
    apk_file="$f"
  done < <(find "$exdir" -type f -name '*.apk' -print0)

  if [ -z "$apk_file" ]; then
    echo "  [$name] no .apk file found in archive"
    return 1
  fi

  # --- signing certificate must be the pinned release key ---
  if ! verify_apk_signature "$apk_file"; then
    echo "  [$name] APK signature check FAILED — not signed with the pinned release certificate; refusing to serve it"
    return 1
  fi

  # --- success ---
  RELEASE_VERSION="$version"
  RELEASE_HTML_URL="$html_url"
  APK_SOURCE_FILE="$apk_file"
  echo "  [$name] OK: v$version ($asset_name)"
  return 0
}

# --- Try sources in order; first success wins ---
# NO_APK_RELEASE latches when a source reports an OTA-only release (no APK
# asset); the chain stops on the next elif instead of falling through to a
# mirror that would only serve an OLDER release.
NO_APK_RELEASE=0
try_source() {
  local status=0
  process_source "$@" || status=$?
  if [ "$status" -eq 2 ]; then
    NO_APK_RELEASE=1
  fi
  return "$status"
}

echo ">> Fetching latest mobile release..."
if try_source "forgejo-anon" "$REPOSITORY_API" "" ""; then
  :
elif [ "$NO_APK_RELEASE" -eq 1 ]; then
  :
elif [ -n "$REPOSITORY_TOKEN" ] && try_source "forgejo-token" "$REPOSITORY_API" "@$REPOSITORY_AUTH_HDR" ""; then
  :
elif [ "$NO_APK_RELEASE" -eq 1 ]; then
  :
elif try_source "codeberg-anon" "$CODEBERG_API" "" ""; then
  :
elif [ "$NO_APK_RELEASE" -eq 1 ]; then
  :
elif try_source "github-anon" "$MIRROR_GITHUB_LATEST_RELEASE_URL" "" "Accept: application/vnd.github+json"; then
  :
elif [ "$NO_APK_RELEASE" -eq 1 ]; then
  :
elif [ -n "$GITHUB_TOKEN" ] && try_source "github-token" "$MIRROR_GITHUB_LATEST_RELEASE_URL" "@$GITHUB_AUTH_HDR" "Accept: application/vnd.github+json"; then
  :
elif [ "$NO_APK_RELEASE" -eq 1 ]; then
  :
else
  echo "ERROR: no release source succeeded; leaving previous state untouched" >&2
  exit 1
fi

if [ "$NO_APK_RELEASE" -eq 1 ]; then
  echo ">> Latest release has no APK asset — OTA-only release, nothing to refresh"
  exit 0
fi

# --- SHA-256 deep check (versions differ but content may be identical) ---
echo ">> Verifying SHA-256..."
SHA256="$(sha256sum "$APK_SOURCE_FILE" | awk '{print $1}')"

existing_sha="$(jq -r '.sha256 // empty' "$APK_DIR/latest.json" 2>/dev/null || true)"
existing_file="$(jq -r '.filename // empty' "$APK_DIR/latest.json" 2>/dev/null || true)"
if [ -n "$existing_sha" ] && [ "$existing_sha" = "$SHA256" ] \
   && [ -n "$existing_file" ] && [ -f "$APK_DIR/$existing_file" ]; then
  echo ">> Up to date (sha256 $SHA256 already served); nothing to do"
  exit 0
fi

# --- Atomic placement ---
echo ">> Installing v$RELEASE_VERSION..."
target_name="slovo-propovedi-v$RELEASE_VERSION.apk"
cp "$APK_SOURCE_FILE" "$APK_DIR/.tmp-$$.apk"
mv -f "$APK_DIR/.tmp-$$.apk" "$APK_DIR/$target_name"
chmod 0644 "$APK_DIR/$target_name"

# --- Write latest.json atomically ---
size="$(stat -c %s "$APK_DIR/$target_name")"
date="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq -n \
  --arg version "$RELEASE_VERSION" \
  --arg filename "$target_name" \
  --argjson size "$size" \
  --arg sha256 "$SHA256" \
  --arg date "$date" \
  --arg downloadUrl "/apk/$target_name" \
  --arg sourceUrl "$RELEASE_HTML_URL" \
  '{version: $version, filename: $filename, size: $size, sha256: $sha256, date: $date, downloadUrl: $downloadUrl, sourceUrl: $sourceUrl}' \
  > "$APK_DIR/.tmp-latest.json"
mv -f "$APK_DIR/.tmp-latest.json" "$APK_DIR/latest.json"
chmod 0644 "$APK_DIR/latest.json"

# --- Cleanup old versions (only after full success) ---
echo ">> Pruning old versions (keeping newest $KEEP_VERSIONS)..."
# shellcheck disable=SC2012 # filenames are script-controlled (slovo-propovedi-vX.Y.Z.apk); ls|sort -V is the version-sort idiom
mapfile -t to_delete < <(ls "$APK_DIR"/*.apk 2>/dev/null | sort -V | head -n -"$KEEP_VERSIONS")
for f in "${to_delete[@]}"; do
  rm -f "$f"
  echo "  removed ${f##*/}"
done
rm -f "$APK_DIR"/.tmp-* 2>/dev/null || true

# --- Ownership (only meaningful when running as root; sandbox runs skip it) ---
if [ "$(id -u)" -eq 0 ]; then
  chown -R slovo:slovo "$APK_DIR"
fi

echo ">> Done: v$RELEASE_VERSION installed ($target_name)"
