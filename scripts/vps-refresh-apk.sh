#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# APK Refresh Script — slovo-propovedi-landing
# =============================================================================
# Runs ON the VPS as root (also manually startable). Fetches the latest mobile
# release from Forgejo (primary) or the GitHub mirror (fallback), verifies the
# archive, and atomically places the APK + latest.json into the landing's
# read-only bind-mount dir. Triggered twice daily by slovo-landing-refresh.timer
# and once after each deploy by the release workflow.
#
# Sources are tried IN ORDER; the first fully-successful one wins. If none
# succeeds the script exits 1 and leaves the previous state untouched. If the
# already-served version matches the latest release, the script exits 0 early
# without re-downloading the ~30MB archive.
# =============================================================================

# --- Configuration (override via env) ---
APK_DIR="${APK_DIR:-/slovo/landing/apk}"
KEEP_VERSIONS="${KEEP_VERSIONS:-3}"
TOKEN_DIR="${TOKEN_DIR:-/slovo/landing/tokens}"
TIMEOUT="${TIMEOUT:-120}"

FORGEJO_API="${FORGEJO_API:-https://git.lightnode.ru/api/v1/repos/Slovo_Propovedi/slovo-propovedi-mobile/releases/latest}"
GITHUB_API="${GITHUB_API:-https://api.github.com/repos/Slovo-Propovedi/slovo-propovedi-mobile/releases/latest}"

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

# --- Prerequisites (idempotent) ---
NEED_INSTALL=0
for cmd in curl jq unzip sha256sum sort; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    NEED_INSTALL=1
    break
  fi
done
if [ "$NEED_INSTALL" -eq 1 ]; then
  echo ">> Installing missing prerequisites..."
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl jq unzip coreutils
  for cmd in curl jq unzip sha256sum sort; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "ERROR: prerequisite '$cmd' still missing after install" >&2
      exit 1
    fi
  done
fi

# --- Token detection (never echoed) ---
FORGEJO_TOKEN=""
if [ -n "${FORGEJO_API_TOKEN:-}" ]; then
  FORGEJO_TOKEN="$(printf '%s' "$FORGEJO_API_TOKEN" | tr -d '\r\n')"
elif [ -r "$TOKEN_DIR/forgejo" ] && [ -s "$TOKEN_DIR/forgejo" ]; then
  FORGEJO_TOKEN="$(tr -d '\r\n' < "$TOKEN_DIR/forgejo")"
fi

GITHUB_TOKEN=""
if [ -n "${GITHUB_MIRROR_TOKEN:-}" ]; then
  GITHUB_TOKEN="$(printf '%s' "$GITHUB_MIRROR_TOKEN" | tr -d '\r\n')"
elif [ -r "$TOKEN_DIR/github" ] && [ -s "$TOKEN_DIR/github" ]; then
  GITHUB_TOKEN="$(tr -d '\r\n' < "$TOKEN_DIR/github")"
fi

# --- Global state set by a successful source ---
RELEASE_VERSION=""
RELEASE_HTML_URL=""
APK_SOURCE_FILE=""

# =============================================================================
# process_source <name> <api> <auth_header> <extra_header>
#   Fetches + validates the release, downloads the zip, unzips it, and locates
#   the single APK. On full success sets the globals above and returns 0;
#   otherwise logs why and returns non-zero so the next source is tried.
# =============================================================================
process_source() {
  local name="$1" api="$2" auth="$3" extra="$4"
  local http_code json_file
  json_file="$(mktemp)"

  # --- fetch release JSON ---
  # curl's -w '%{http_code}' prints "000" for a network failure and the real
  # code (e.g. "404") for an HTTP error even with -f, so the code alone
  # distinguishes the two cases.
  local curl_args=(-fsS --max-time "$TIMEOUT" -o "$json_file" -w '%{http_code}')
  if [ -n "$auth" ]; then curl_args+=(-H "$auth"); fi
  if [ -n "$extra" ]; then curl_args+=(-H "$extra"); fi
  curl_args+=("$api")

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
      echo "  [$name] auth required (HTTP $http_code) — provide a token in $TOKEN_DIR/forgejo (mode 600) or FORGEJO_API_TOKEN env"
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

  count="$(jq -e '[.assets[] | select(.name | test("^slovo-propovedi-v[0-9][^/]*\\.zip$"))] | length' "$json_file")" || {
    echo "  [$name] could not inspect assets"
    rm -f "$json_file"
    return 1
  }
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

  # --- download + verify size ---
  local download_file="$WORKDIR/release.zip"
  echo "  [$name] downloading $asset_name..."
  if ! curl -fsSL --max-time "$TIMEOUT" -o "$download_file" "$asset_url" 2>/dev/null; then
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

  # --- unzip into empty subdir (zip-slip safe) ---
  local exdir="$WORKDIR/extract"
  mkdir -p "$exdir"
  if ! unzip -q "$download_file" -d "$exdir"; then
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

  # --- success ---
  RELEASE_VERSION="$version"
  RELEASE_HTML_URL="$html_url"
  APK_SOURCE_FILE="$apk_file"
  echo "  [$name] OK: v$version ($asset_name)"
  return 0
}

# --- Try sources in order; first success wins ---
echo ">> Fetching latest mobile release..."
if process_source "forgejo-anon" "$FORGEJO_API" "" ""; then
  :
elif [ -n "$FORGEJO_TOKEN" ] && process_source "forgejo-token" "$FORGEJO_API" "Authorization: token $FORGEJO_TOKEN" ""; then
  :
elif process_source "github-anon" "$GITHUB_API" "" "Accept: application/vnd.github+json"; then
  :
elif [ -n "$GITHUB_TOKEN" ] && process_source "github-token" "$GITHUB_API" "Authorization: Bearer $GITHUB_TOKEN" "Accept: application/vnd.github+json"; then
  :
else
  echo "ERROR: no release source succeeded; leaving previous state untouched" >&2
  exit 1
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
