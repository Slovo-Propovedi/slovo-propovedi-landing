#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Screenshots Refresh Script — slovo-propovedi-landing
# =============================================================================
# Runs ON the VPS as root (also manually startable). Polls the mobile repo's
# git tree for the canonical screenshots in assets/screenshots/, verifies each
# PNG (magic bytes + git-blob sha1), and atomically publishes them + a
# manifest.json into the landing's read-only bind-mount dir. Triggered twice
# daily by slovo-landing-refresh-shots.timer and once after each deploy.
#
# Sources are tried IN ORDER; the first fully-successful one wins. If none
# succeeds the script exits 1 and leaves the previous state untouched. If the
# already-served fingerprint matches the remote tree AND every listed file is
# present on disk, the script exits 0 early without re-downloading anything.
# =============================================================================

# --- Configuration (override via env) ---
SCREENSHOTS_DIR="${SCREENSHOTS_DIR:-/slovo/landing/screenshots}"
TOKEN_DIR="${TOKEN_DIR:-/slovo/landing/tokens}"
TIMEOUT="${TIMEOUT:-120}"

FORGEJO_API="${FORGEJO_API:-https://git.lightnode.ru/api/v1/repos/Slovo_Propovedi/slovo-propovedi-mobile/git/trees/main?recursive=true}"
FORGEJO_RAW="${FORGEJO_RAW:-https://git.lightnode.ru/api/v1/repos/Slovo_Propovedi/slovo-propovedi-mobile/raw/assets/screenshots}"
GITHUB_API="${GITHUB_API:-https://api.github.com/repos/Slovo-Propovedi/slovo-propovedi-mobile/git/trees/main?recursive=1}"
GITHUB_RAW="${GITHUB_RAW:-https://raw.githubusercontent.com/Slovo-Propovedi/slovo-propovedi-mobile/main/assets/screenshots}"

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
NEED_INSTALL=0
for cmd in curl jq sha1sum sha256sum sort stat cmp; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    NEED_INSTALL=1
    break
  fi
done
if [ "$NEED_INSTALL" -eq 1 ]; then
  echo ">> Installing missing prerequisites..."
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl jq coreutils
  for cmd in curl jq sha1sum sha256sum sort stat cmp; do
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

# --- Auth headers written to files (never in argv) ---
# curl -H @file (>=7.55) reads the header from a file, keeping the token out of
# /proc/*/cmdline. Files live in the private 0700 WORKDIR, cleaned by the EXIT trap.
FORGEJO_AUTH_HDR=""
if [ -n "$FORGEJO_TOKEN" ]; then
  FORGEJO_AUTH_HDR="$WORKDIR/forgejo-auth.hdr"
  printf 'Authorization: token %s\n' "$FORGEJO_TOKEN" > "$FORGEJO_AUTH_HDR"
  chmod 600 "$FORGEJO_AUTH_HDR"
fi

GITHUB_AUTH_HDR=""
if [ -n "$GITHUB_TOKEN" ]; then
  GITHUB_AUTH_HDR="$WORKDIR/github-auth.hdr"
  printf 'Authorization: Bearer %s\n' "$GITHUB_TOKEN" > "$GITHUB_AUTH_HDR"
  chmod 600 "$GITHUB_AUTH_HDR"
fi

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
  jq -r '
    .tree[]
    | select(.type == "blob")
    | select(.path | test("^assets/screenshots/[A-Za-z0-9_][A-Za-z0-9._-]*\\.png$"))
    | [.path, .sha] | join(":")
  ' "$json_file" | sort > "$list_file"
  rm -f "$json_file"

  TREE_FILE="$list_file"
  RAW_BASE="$raw_base"
  RAW_SUFFIX="$raw_suffix"
  return 0
}

# --- Try sources in order; first success wins ---
echo ">> Fetching mobile repo screenshot tree..."
if fetch_tree "forgejo-anon" "$FORGEJO_API" "" "" "$FORGEJO_RAW" "?ref=main"; then
  :
elif [ -n "$FORGEJO_TOKEN" ] && fetch_tree "forgejo-token" "$FORGEJO_API" "@$FORGEJO_AUTH_HDR" "" "$FORGEJO_RAW" "?ref=main"; then
  :
elif fetch_tree "github-anon" "$GITHUB_API" "" "Accept: application/vnd.github+json" "$GITHUB_RAW" ""; then
  :
elif [ -n "$GITHUB_TOKEN" ] && fetch_tree "github-token" "$GITHUB_API" "@$GITHUB_AUTH_HDR" "Accept: application/vnd.github+json" "$GITHUB_RAW" ""; then
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
# nothing changed — exit 0 with zero writes (stale files still pruned).
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
  if ! curl -fsSL --max-time "$TIMEOUT" -o "$local_file" "$RAW_BASE/$stem.png$RAW_SUFFIX" 2>/dev/null; then
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
  --arg sourceUrl "https://git.lightnode.ru/Slovo_Propovedi/slovo-propovedi-mobile" \
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
