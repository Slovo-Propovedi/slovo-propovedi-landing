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
Dockerfile            # nginx:alpine static image + /apk mount placeholder
assets/
  css/main.css        # All styles (no inline styles — CSP forbids them)
  js/main.js          # Vanilla JS: fetches /apk/latest.json, populates metadata
  fonts/*.woff2       # Self-hosted Unbounded + Onest (latin + cyrillic subsets)
  img/                # favicon.svg, qr.svg (themed QR of the landing URL)
scripts/
  bump-version.mjs    # Version bump: package.json + CHANGELOG.md, commit -s, tag
  generate-qr.mjs     # Regenerates assets/img/qr.svg via npx qrcode
  validate.mjs        # Minimal file-presence sanity check (extended by CI task)
.husky/commit-msg     # Enforces conventional commits
```

## Build, Lint, and Deploy Commands

```bash
# Install dev deps (husky) and set up hooks
npm install

# Sanity check that required files exist
npm run validate

# Version bump — updates package.json + CHANGELOG.md, commits with signoff (-s)
# and tags v<version> automatically. Then push manually:
npm run bump-version <version|patch|minor|major>
git push --follow-tags origin main

# Regenerate the QR code (if the landing URL ever changes)
npm run generate-qr

# Build and run the image locally
docker build -t slovo-propovedi-landing .
docker run --rm -p 8080:8080 slovo-propovedi-landing
```

## APK serving

- `location ~* ^/apk/.+\.apk$` in `nginx.conf` maps the correct Android MIME
  type (`application/vnd.android.package-archive`), forces `Content-Disposition:
  attachment`, and caches immutably.
- `location = /apk/latest.json` serves the metadata contract with `no-cache`.
- The Dockerfile creates `/usr/share/nginx/html/apk` as a placeholder; the
  systemd unit overlays it with a read-only bind-mount from `/slovo/landing/apk`.
  **Do not COPY apk files into the image.**

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
  functions; parse the `latest.json` payload into trusted fields at the boundary.
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
   tag actually landed.
3. **Stock nginx has no `.apk` MIME mapping** — the scoped `types { }` block in
   the `/apk` location is required or Android downloads will be served as
   `application/octet-stream`.
4. **`latest.json` is produced server-side** (not in this repo). The UI is built
   against its contract: `version`, `filename`, `size`, `sha256`, `date`,
   `downloadUrl`, `sourceUrl`.
