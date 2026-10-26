#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Screenshots Refresh Script — slovo-propovedi-landing
# =============================================================================
# Runs ON the VPS as the unprivileged `slovo` user inside a sandboxed systemd
# unit (also manually startable). Polls the mobile repo's git tree (Forgejo,
# then the Codeberg mirror, then the GitHub mirror) for the canonical screenshots in assets/screenshots/, verifies each
# PNG (magic bytes + git-blob sha1), and atomically publishes them + a
# manifest.json into the landing's read-only bind-mount dir. Triggered twice
# daily by slovo-landing-refresh-shots.timer and once after each deploy.
#
# Sources are tried IN ORDER; the first fully-successful one wins. If none
# succeeds the script exits 1 and leaves the previous state untouched. If the
# already-served fingerprint matches the remote tree AND every listed file is
# present on disk, the script exits 0 early without re-downloading anything.
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
      REPOSITORY_URL|REPOSITORY_ORG|MIRROR_CODEBERG_URL|MIRROR_CODEBERG_ORG|MIRROR_GITHUB_ORG|MOBILE_REPOSITORY_NAME|APK_SIGNER_SHA256) ;;
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
require_env REPOSITORY_ORG
require_env MIRROR_CODEBERG_URL
require_env MIRROR_CODEBERG_ORG
require_env MIRROR_GITHUB_ORG
require_env MOBILE_REPOSITORY_NAME
if [ "$MISSING_ENV" -ne 0 ]; then
  echo "ERROR: missing required environment variables — aborting" >&2
  exit 1
fi

# Repository coordinates (Forgejo org variables, same contract as the image
# build): the hosts are bare https origins, the org/repo names plain slugs.
# They are built into API URLs and handed to curl, so anything else is a
# misconfiguration.
for var in REPOSITORY_URL MIRROR_CODEBERG_URL; do
  if ! printf '%s' "${!var}" | grep -Eq '^https://[A-Za-z0-9.-]+(:[0-9]+)?$'; then
    echo "ERROR: $var must be a bare https origin, no path (got '${!var}')" >&2
    exit 1
  fi
done
for var in REPOSITORY_ORG MIRROR_CODEBERG_ORG MIRROR_GITHUB_ORG MOBILE_REPOSITORY_NAME; do
  if ! printf '%s' "${!var}" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
    echo "ERROR: $var must be a plain org/repo slug (got '${!var}')" >&2
    exit 1
  fi
done

# --- Configuration (override via env) ---
SCREENSHOTS_DIR="${SCREENSHOTS_DIR:-/slovo/landing/screenshots}"
TIMEOUT="${TIMEOUT:-120}"

# Tree + raw endpoints of the mobile repo on each host. Codeberg runs Forgejo:
# same API shape as the primary repository; GitHub's hosts are fixed.
REPOSITORY_API="$REPOSITORY_URL/api/v1/repos/$REPOSITORY_ORG/$MOBILE_REPOSITORY_NAME/git/trees/main?recursive=true"
REPOSITORY_RAW="$REPOSITORY_URL/api/v1/repos/$REPOSITORY_ORG/$MOBILE_REPOSITORY_NAME/raw/assets/screenshots"
CODEBERG_API="$MIRROR_CODEBERG_URL/api/v1/repos/$MIRROR_CODEBERG_ORG/$MOBILE_REPOSITORY_NAME/git/trees/main?recursive=true"
CODEBERG_RAW="$MIRROR_CODEBERG_URL/api/v1/repos/$MIRROR_CODEBERG_ORG/$MOBILE_REPOSITORY_NAME/raw/assets/screenshots"
GITHUB_TREE_API="https://api.github.com/repos/$MIRROR_GITHUB_ORG/$MOBILE_REPOSITORY_NAME/git/trees/main?recursive=1"
GITHUB_RAW="https://raw.githubusercontent.com/$MIRROR_GITHUB_ORG/$MOBILE_REPOSITORY_NAME/main/assets/screenshots"

# https only, including every redirect, and an explicit User-Agent: GitHub's
# API requires one, and Codeberg rejects some browser-like agents that a
# local ~/.curlrc might inject.
CURL_PROTO=(--proto '=https' --proto-redir '=https' --user-agent 'slovo-propovedi-landing-refresh')

# --- Concurrency guard (single refresh at a time) ---
mkdir -p "$SCREENSHOTS_DIR"
exec 9>"$SCREENSHOTS_DIR/.sync.lock"
flock -n 9 || { echo "another screenshots refresh is running"; exit 0; }

# --- Stale temp cleanup + temp workspace ---
# NOTE: WORKDIR (not TMPDIR) to avoid shadowing the env var of the same name
# which some tools (e.g. mktemp) honour.
rm -f "$SCREENSHOTS_DIR"/.tmp-* 2>/dev/null || true
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# --- Prerequisites (idempotent) ---
# Installed by vps-deploy.sh (as root); this unprivileged script only checks.
for cmd in curl jq sha1sum sha256sum sort stat cmp; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: prerequisite '$cmd' is missing — re-run the landing deploy (vps-deploy.sh installs it)" >&2
    exit 1
  fi
done

# --- Global state set by a successful source ---
TREE_FILE=""      # path to the filtered+validated "path:sha" list (sorted)
RAW_BASE=""       # URL prefix for raw screenshot downloads
RAW_SUFFIX=""     # per-source query suffix (Forgejo needs ?ref=main)

# =============================================================================
# fetch_tree <name> <api> <auth> <extra> <raw_base> <raw_suffix>
#   Fetches the recursive git tree, filters to canonical screenshot PNGs under
#   assets/screenshots/, and validates every path at the boundary (fail-closed:
#   any unexpected entry aborts this source). On success writes the sorted
#   "path:sha" list to $TREE_FILE and sets $RAW_BASE/$RAW_SUFFIX, returning 0.
# =============================================================================
fetch_tree() {
  local name="$1" api="$2" auth="$3" extra="$4" raw_base="$5" raw_suffix="$6"
  local http_code json_file
  json_file="$(mktemp)"

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
    # Public repositories need no auth: 401/403 means rate-limited or blocked.
    echo "  [$name] HTTP $http_code (rate-limited or forbidden)"
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

  # Fail-closed: any non-PNG blob under assets/screenshots/ is unexpected and
  # aborts this source (the gallery must never render a non-canonical file).
  local unexpected
  unexpected="$(jq -r '
    .tree[]
    | select(.type == "blob")
    | select(.path | startswith("assets/screenshots/"))
    | select(.path | test("^assets/screenshots/[A-Za-z0-9_][A-Za-z0-9._-]*\\.png$") | not)
    | .path
  ' "$json_file")"
  if [ -n "$unexpected" ]; then
    echo "  [$name] unexpected non-PNG entry under assets/screenshots/: $unexpected"
    rm -f "$json_file"
    return 1
  fi

  local list_file="$WORKDIR/tree-$name.tsv"
  # sort -V keeps the tree list, the fingerprint input and manifest.json in
  # natural numeric order (…, 9, 10, 11) instead of lexicographic (10 before 2).
  jq -r '
    .tree[]
    | select(.type == "blob")
    | select(.path | test("^assets/screenshots/[A-Za-z0-9_][A-Za-z0-9._-]*\\.png$"))
    | select(.sha | test("^[0-9a-f]{40}$"))
    | [.path, .sha] | join(":")
  ' "$json_file" | sort -V > "$list_file"
  rm -f "$json_file"

  TREE_FILE="$list_file"
  RAW_BASE="$raw_base"
  RAW_SUFFIX="$raw_suffix"
  return 0
}

# --- Try sources in order; first success wins ---
echo ">> Fetching mobile repo screenshot tree..."
if fetch_tree "forgejo-anon" "$REPOSITORY_API" "" "" "$REPOSITORY_RAW" "?ref=main"; then
  :
elif fetch_tree "codeberg-anon" "$CODEBERG_API" "" "" "$CODEBERG_RAW" "?ref=main"; then
  :
elif fetch_tree "github-anon" "$GITHUB_TREE_API" "" "Accept: application/vnd.github+json" "$GITHUB_RAW" ""; then
  :
else
  echo "ERROR: no screenshot source succeeded; leaving previous state untouched" >&2
  exit 1
fi

# --- Guard against a mid-delete/empty tree (keep-last-good) ---
# A suspiciously small set means the repo is mid-change; refuse to clobber the
# gallery and keep the previous (last-good) state.
count="$(wc -l < "$TREE_FILE")"
if [ "$count" -lt 5 ]; then
  echo "ERROR: only $count screenshot(s) found in the winning source (expected >= 5); refusing to clobber the gallery" >&2
  exit 1
fi

# --- Fingerprint of the sorted "path:sha" list ---
FINGERPRINT="$(sha256sum "$TREE_FILE" | awk '{print $1}')"

# --- Prune stale files (non-dotfiles not in the new set) ---
# Runs on BOTH paths (sync and up-to-date) so the gallery self-heals: a stale
# file left by an interrupted earlier run is removed even when nothing changed.
prune_stale() {
  declare -A EXPECTED
  while IFS=: read -r path sha; do
    stem="${path##*/}"
    stem="${stem%.png}"
    EXPECTED["$stem-${sha:0:8}.png"]=1
  done < "$TREE_FILE"
  for f in "$SCREENSHOTS_DIR"/*.png; do
    [ -e "$f" ] || continue
    base="${f##*/}"
    if [ -z "${EXPECTED[$base]:-}" ]; then
      rm -f "$f"
      echo "  removed $base"
    fi
  done
}

# --- Early no-op: already serving this exact set? ---
# If the manifest fingerprint matches AND every listed file exists on disk,
# no re-download or rewrite; stale files still pruned (self-heal).
existing_fp="$(jq -r '.fingerprint // empty' "$SCREENSHOTS_DIR/manifest.json" 2>/dev/null || true)"
if [ -n "$existing_fp" ] && [ "$existing_fp" = "$FINGERPRINT" ]; then
  all_present=1
  while IFS=: read -r path sha; do
    stem="${path##*/}"
    stem="${stem%.png}"
    if [ ! -f "$SCREENSHOTS_DIR/$stem-${sha:0:8}.png" ]; then
      all_present=0
      break
    fi
  done < "$TREE_FILE"
  if [ "$all_present" -eq 1 ]; then
    echo ">> Screenshots up to date (fingerprint ${FINGERPRINT:0:8}); nothing to do"
    prune_stale
    exit 0
  fi
fi

# --- Download + verify + publish each changed file ---
echo ">> Syncing $count screenshots..."
while IFS=: read -r path sha; do
  stem="${path##*/}"
  stem="${stem%.png}"
  sha8="${sha:0:8}"
  target="$SCREENSHOTS_DIR/$stem-$sha8.png"

  if [ -f "$target" ]; then
    echo "  unchanged: $stem-$sha8.png"
    continue
  fi

  echo "  downloading: $stem-$sha8.png"
  local_file="$WORKDIR/$stem-$sha8.png"
  if ! curl -fsSL "${CURL_PROTO[@]}" --max-time "$TIMEOUT" -o "$local_file" --url "$RAW_BASE/$stem.png$RAW_SUFFIX" 2>/dev/null; then
    echo "ERROR: download failed for $stem.png" >&2
    exit 1
  fi

  # Verify PNG magic bytes (89 50 4E 47 0D 0A 1A 0A)
  if ! cmp -s <(printf '\x89PNG\r\n\x1a\n') <(head -c 8 "$local_file"); then
    echo "ERROR: $stem.png is not a PNG (magic bytes mismatch)" >&2
    exit 1
  fi

  # Verify git-blob sha1: sha1("blob <size>\0" + content) must equal the tree sha
  size="$(stat -c %s "$local_file")"
  actual_sha="$( { printf 'blob %s\0' "$size"; cat "$local_file"; } | sha1sum | awk '{print $1}' )"
  if [ "$actual_sha" != "$sha" ]; then
    echo "ERROR: $stem.png blob sha1 mismatch (got $actual_sha, expected $sha)" >&2
    exit 1
  fi

  # Publish atomically (dot-prefixed partial hidden by nginx dotfile-deny)
  cp "$local_file" "$SCREENSHOTS_DIR/.tmp-$$-$stem-$sha8.png"
  mv -f "$SCREENSHOTS_DIR/.tmp-$$-$stem-$sha8.png" "$target"
  chmod 0644 "$target"
done < "$TREE_FILE"

# --- Prune stale files (only after ALL new files verified + published) ---
echo ">> Pruning stale screenshots..."
prune_stale

# --- Write manifest.json atomically LAST (the commit point) ---
# A crash before this mv leaves the old manifest consistent with the old files.
echo ">> Writing manifest.json..."
images_tsv="$WORKDIR/images.tsv"
: > "$images_tsv"
while IFS=: read -r path sha; do
  stem="${path##*/}"
  stem="${stem%.png}"
  sha8="${sha:0:8}"
  size="$(stat -c %s "$SCREENSHOTS_DIR/$stem-$sha8.png")"
  printf '%s\t%s\t%s\n' "$stem-$sha8.png" "$sha" "$size" >> "$images_tsv"
done < "$TREE_FILE"

updated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq -n \
  --arg fingerprint "$FINGERPRINT" \
  --arg updatedAt "$updated_at" \
  --arg sourceUrl "$REPOSITORY_URL/$REPOSITORY_ORG/$MOBILE_REPOSITORY_NAME" \
  --arg sourcePath "assets/screenshots" \
  --argjson images "$(jq -Rs '
    split("\n")
    | map(select(length > 0))
    | map(split("\t") | {file: .[0], sha: .[1], size: (.[2] | tonumber)})
  ' "$images_tsv")" \
  '{fingerprint: $fingerprint, updatedAt: $updatedAt, sourceUrl: $sourceUrl, sourcePath: $sourcePath, images: $images}' \
  > "$SCREENSHOTS_DIR/.tmp-$$-manifest.json"
mv -f "$SCREENSHOTS_DIR/.tmp-$$-manifest.json" "$SCREENSHOTS_DIR/manifest.json"
chmod 0644 "$SCREENSHOTS_DIR/manifest.json"

# --- Ownership (only meaningful when running as root; sandbox runs skip it) ---
if [ "$(id -u)" -eq 0 ]; then
  chown -R slovo:slovo "$SCREENSHOTS_DIR"
fi

echo ">> Done: $count screenshots synced"
