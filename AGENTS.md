# AGENTS.md

Coding agent instructions for the **slovo-propovedi-landing** static site.

## Purpose

This repo is the landing page for the «Слово.Проповеди» Android app
(`ru.slovopropovedi`). It offers a direct APK download. It is a **fully static
site**: an `nginx:alpine` container serves `index.html` + assets on port 8080,
behind Traefik at `https://slovo-propovedi.ru`.

The APK files themselves are **not** in this repo or image. They live on the
host at `/slovo/landing/apk` and are bind-mounted read-only into the container
at `/usr/share/nginx/html/apk` by the systemd unit. `latest.json` (the download
metadata contract) is produced server-side and served from that same mount.

## Repository layout

```
index.html            # Landing page (Russian, lang="ru")
robots.txt            # Crawler rules
nginx.conf            # Server config: port 8080, APK MIME, security headers, CSP
Dockerfile            # nginx:alpine static image (no /apk placeholder — the
                      #   bind mount creates the mountpoint automatically)
assets/
  css/main.css        # All styles (no inline styles — CSP forbids them)
  js/main.js          # Vanilla JS: fetches /apk/latest.json, populates metadata
  fonts/*.woff2       # Self-hosted Unbounded + Onest (latin + cyrillic subsets)
  img/                # favicon.svg, qr.svg, og.png (social card, committed)
scripts/
  bump-version.mjs    # Version bump: package.json + CHANGELOG.md + index.html
                      #   ?v= cache-busting, commit -s, tag
  generate-qr.mjs     # Regenerates assets/img/qr.svg via npx qrcode
  generate-og.mjs     # Regenerates assets/img/og.png (rsvg-convert/ImageMagick)
  validate.mjs        # Consistency checks (extended: nginx headers, CSP, og:image)
  vps-deploy.sh       # Runs ON the VPS as root: builds/starts the container,
                      #   writes Traefik labels, installs refresh units
  vps-refresh-apk.sh  # Runs ON the VPS as root: fetches latest mobile release,
                      #   publishes APK + latest.json into the /apk bind mount
.forgejo/workflows/
  ci.yml              # Validate on push/PR to main
  release.yml         # Tag deploy: version check, SSH deploy, token provisioning,
                      #   APK refresh trigger, Forgejo release creation
  refresh-apk.yml     # Manual (workflow_dispatch) APK refresh trigger
.husky/commit-msg     # Enforces conventional commits
```

## Build, Lint, and Deploy Commands

```bash
# Install dev deps (husky) and set up hooks
npm install

# Sanity check that required files exist and are consistent
npm run validate

# Version bump — updates package.json + CHANGELOG.md + index.html ?v=,
# commits with signoff (-s) and tags v<version> automatically. Then push:
npm run bump-version <version|patch|minor|major>
git push --follow-tags origin main

# Regenerate the QR code (if the landing URL ever changes)
npm run generate-qr

# Regenerate the social-card image (needs rsvg-convert or ImageMagick)
npm run generate-og

# Build and run the image locally
docker build -t slovo-propovedi-landing .
docker run --rm -p 8080:8080 slovo-propovedi-landing
```

## APK serving

- `location ~* ^/apk/.+\.apk$` in `nginx.conf` maps the correct Android MIME
  type (`application/vnd.android.package-archive`), forces `Content-Disposition:
  attachment`, and caches immutably.
- `location = /apk/latest.json` serves the metadata contract with `no-cache`.
- The Dockerfile does **not** create `/usr/share/nginx/html/apk`; the systemd
  unit's read-only bind mount from `/slovo/landing/apk` creates the mountpoint
  automatically. **Do not COPY apk files into the image.**
- The dotfile-deny location (`location ~ /\.`) is deliberately the FIRST regex
  location so mid-copy partials (`/apk/.tmp-<pid>.apk`) and hidden files are
  never served by later-declared regexes.

## VPS deployment & APK refresh

- `scripts/vps-deploy.sh` runs on the VPS as root (triggered by the release
  workflow over SSH). It builds the image with buildx, writes Traefik labels
  (apex + www hostnames, www→apex redirect), starts the container, installs the
  refresh systemd units, and triggers one initial refresh.
- `scripts/vps-refresh-apk.sh` runs on the VPS as root, twice daily via
  `slovo-landing-refresh.timer` (04:30 / 16:30 UTC, randomized). It fetches the
  latest mobile release from Forgejo (primary) or GitHub (fallback), verifies
  the archive, and atomically publishes `slovo-propovedi-vX.Y.Z.apk` +
  `latest.json`. If the served version already matches the latest release it
  exits 0 early without re-downloading the ~30MB archive.
- Tokens for the release APIs live in `/slovo/landing/tokens` (root-owned
  0700 — the `slovo` user and container can never read them). The release
  workflow provisions them via stdin; the refresh script reads them as root.
- The refresh timer/units are installed by `vps-deploy.sh` and survive deploys
  (the script is copied into `$BASE_PATH`).

## Commit Convention

Conventional commits (enforced by `.husky/commit-msg`):

- `feat` - New feature
- `fix` - Bug fix
- `refactor` - Code change without feature/fix
- `docs` - Documentation only
- `style` - Formatting only
- `chore` - Maintenance tasks
- `build` - Build system changes
- `ci` - CI configuration changes
- `perf` - Performance improvements
- `revert` - Reverting changes

**Signoff (DCO) обязателен:** `git commit -s`. Максимальная длина заголовка —
100 символов.

## Code Style Guidelines

- **HTML/CSS/JS:** no inline `<script>` or `<style>` — the CSP is strict
  (`script-src 'self'; style-src 'self'`). All JS lives in `assets/js/main.js`,
  all CSS in `assets/css/main.css`.
- **No external runtime dependencies / CDN links** — the page must be 100%
  self-contained (fonts are committed as woff2).
- **JS (`main.js`):** vanilla, no frameworks. Guard clauses at the top of
  functions; parse the `latest.json` payload into trusted fields at the boundary
  (filename/downloadUrl are validated — the CTA must never point off-site).
- **nginx.conf / Dockerfile:** inline comments explain WHY, not WHAT.
- **Scripts (`.mjs`):** ESM (`import`), single quotes, no semicolons (match
  `bump-version.mjs`).

## Gotchas

1. **CSP forbids inline scripts/styles.** Never add `unsafe-inline`; keep all
   JS/CSS external. The QR is an `<img>` (or inline SVG element in HTML), which
   is fine.
2. **`bump-version.mjs` commits (`git commit -s`) AND tags (`git tag -a`)
   automatically.** Check `git diff --cached` before running; after, push
   manually with `git push --follow-tags origin main`. The script verifies the
   tag actually landed. It also rewrites the `?v=` cache-busting query on the
   css/js references in `index.html` — keep those references versioned.
3. **Stock nginx has no `.apk` MIME mapping** — the scoped `types { }` block in
   the `/apk` location is required or Android downloads will be served as
   `application/octet-stream`.
4. **`latest.json` is produced server-side** (not in this repo). The UI is built
   against its contract: `version`, `filename`, `size`, `sha256`, `date`,
   `downloadUrl`, `sourceUrl`.
5. **nginx `add_header` is not inherited** into a location that defines its own
   `add_header` — the security headers (incl. CSP) are repeated in every such
   location and must stay byte-identical (validate.mjs enforces this).
6. **The refresh script must never shadow `TMPDIR`** — it uses `WORKDIR` for its
   temp workspace so tools honouring the env var are not confused.
