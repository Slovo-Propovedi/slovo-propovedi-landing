# AGENTS.md

Coding agent instructions for the **slovo-propovedi-landing** static site.

## Purpose

This repo is the landing page for the «Слово.Проповеди» Android app
(`ru.slovopropovedi`). It offers a direct APK download plus a web-version
fallback link (`/web`, a 302 redirect to the web app). It is a **fully static
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
  bump-version.mjs    # Version bump: package.json + package-lock.json + CHANGELOG.md
                      #   + index.html ?v= cache-busting, commit -s, tag
  dev-server.mjs      # Zero-dependency Node dev server: .env support,
                      #   __LANDING_HOSTNAME__ substitution, /web 302
  generate-qr.mjs     # Regenerates assets/img/qr.svg via npx qrcode
  generate-og.mjs     # Regenerates assets/img/og.png (rsvg-convert/ImageMagick)
  validate.mjs        # Consistency checks (extended: nginx headers, CSP, og:image)
  vps-deploy.sh       # Runs ON the VPS as root: builds/starts the container,
                      #   writes Traefik labels, installs refresh units
  vps-refresh-apk.sh  # Runs ON the VPS as root: fetches latest mobile release,
                      #   publishes APK + latest.json into the /apk bind mount
  vps-refresh-screenshots.sh # Runs ON the VPS as root: polls the mobile repo
                      #   git tree, syncs screenshots + manifest.json into the
                      #   /screenshots bind mount
.forgejo/workflows/
  ci.yml              # Validate on push/PR to main
  release.yml         # Tag deploy: version check, SSH deploy, token provisioning,
                      #   APK refresh trigger, Forgejo release creation
  refresh-apk.yml     # Manual (workflow_dispatch) APK refresh trigger
docs/seo.md           # SEO / indexing runbook (webmaster verification, sitemap,
                      #   backlinks) + on-page SEO status and gaps
.husky/commit-msg     # Enforces conventional commits
```

## SEO / indexing

On-page SEO (title, description, Open Graph, `og:image`, Twitter Card,
`robots.txt`) already ships in `index.html` — hostnames in `og:url` / `og:image`
are baked from `__LANDING_HOSTNAME__` at image build. Verifying the domain in
Yandex / Google / Bing webmaster tools, submitting the sitemap and building
backlinks is a one-time manual runbook: **`docs/seo.md`**. Known gaps (no
`<link rel="canonical">`, no `sitemap.xml`) are tracked there.

## Build, Lint, and Deploy Commands

```bash
# Install dev deps (husky) and set up hooks
npm install

# Sanity check that required files exist and are consistent
npm run validate

# Version bump — updates package.json + package-lock.json + CHANGELOG.md +
# index.html ?v=, commits with signoff (-s) and tags v<version> automatically. Then push:
npm run bump-version <version|patch|minor|major>
git push --follow-tags origin main

# Regenerate the QR code (if the landing URL ever changes)
npm run generate-qr

# Regenerate the social-card image (needs rsvg-convert or ImageMagick)
npm run generate-og

# Local preview server (port 8377, Ctrl+C to stop). Node, zero deps:
# reads .env (see .env.example; precedence: env > .env > defaults),
# substitutes __LANDING_HOSTNAME__ into index.html on the fly, answers
# /web with the same 302 as prod, and serves only the files the
# production image contains.
npm run dev

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

## Screenshots serving

- Screenshots are **never committed to this repo**. `scripts/vps-refresh-screenshots.sh`
  polls the mobile repo's git tree (`assets/screenshots/`, branch `main`) twice
  daily via `slovo-landing-refresh-shots.timer` (04:30 / 16:30 UTC, randomized)
  and publishes verified PNGs + `manifest.json` into `/slovo/landing/screenshots`,
  bind-mounted read-only at `/usr/share/nginx/html/screenshots`.
- Every PNG is verified before publish: PNG magic bytes AND git-blob sha1
  (`sha1("blob <size>\0" + content)` must equal the tree sha). Filenames embed
  the blob sha prefix (`<stem>-<sha8>.png`) so nginx can cache them immutably.
- `manifest.json` is written LAST (the commit point) and is the gallery's
  contract: `fingerprint`, `updatedAt`, `sourceUrl`, `sourcePath`, `images`
  (each `{file, sha, size}`). The UI renders only from this manifest.
- The gallery must keep the credit line «Скриншоты: © 2026 Slovo.Propovedi,
  GPL-3.0-or-later» (REUSE.toml in the mobile repo covers `assets/**` as
  GPL-3.0-or-later).
- The dotfile-deny location also protects `/screenshots/.tmp-<pid>-*.png`
  mid-copy partials and the `.sync.lock` concurrency guard.

## VPS deployment & APK refresh

- `scripts/vps-deploy.sh` runs on the VPS as root (triggered by the release
  workflow over SSH). It builds the image with buildx, writes Traefik labels
  (apex + www hostnames, www→apex redirect), starts the container, installs the
  refresh systemd units, and triggers one initial refresh.
- **Boundary:** the script owns only the `slovo-landing` container, its
  `slovo-landing` network and the refresh units. Shared infra (Docker, the
  `slovo` user, the `slovo-constrained` buildx builder, Traefik and the
  `traefik` network) is owned by the external `slovo-propovedi-playbook`
  (`just setup-all`); the script only verifies it and fails fast if it is
  missing — it never auto-provisions it.
- `scripts/vps-refresh-apk.sh` runs on the VPS as root, twice daily via
  `slovo-landing-refresh.timer` (04:30 / 16:30 UTC, randomized). It fetches the
  latest mobile release from Forgejo (primary) or GitHub (fallback), verifies
  the archive, and atomically publishes `slovo-propovedi-vX.Y.Z.apk` +
  `latest.json`. If the served version already matches the latest release it
  exits 0 early without re-downloading the ~30MB archive.
- `scripts/vps-refresh-screenshots.sh` runs on the VPS as root, twice daily via
  `slovo-landing-refresh-shots.timer` (same cadence). It polls the mobile repo
  git tree, verifies each PNG, and atomically publishes the gallery +
  `manifest.json`. If the served fingerprint already matches the remote tree it
  exits 0 early without re-downloading or rewriting anything (stale files are
  still pruned, so the gallery self-heals).
- The screenshots bind mount (`/slovo/landing/screenshots` →
  `/usr/share/nginx/html/screenshots`, read-only) is added to the container
  unit by `vps-deploy.sh`, next to the `/apk` mount.
- Tokens for the release APIs live in `/slovo/landing/tokens` (root-owned
  0700 — the `slovo` user and container can never read them). The release
  workflow provisions them via stdin; the refresh script reads them as root.
- The refresh timer/units are installed by `vps-deploy.sh` and survive deploys
  (the script is copied into `$BASE_PATH`).

## Web-app fallback (`/web`)

- The landing links to the **relative** path `/web` (never the absolute URL),
  opening in a new tab (`target="_blank" rel="noopener"`). nginx answers it
  with a `302` redirect to the web app.
- The target hostname comes from `WEB_HOSTNAME` (Forgejo repo variable,
  optional). Flow: release.yml env → SSH inline env → `vps-deploy.sh`
  (validates a bare hostname, defaults to `app.slovo-propovedi.ru`) →
  `--build-arg WEB_HOSTNAME=...` → Dockerfile `sed` replaces the
  `__WEB_HOSTNAME__` placeholder in nginx.conf at image build, with the
  `https://` prefix added at bake time → nginx serves
  `location = /web { return 302 https://<host>; }`.
- `WEB_HOSTNAME` (and `LANDING_HOSTNAME`) are **hostname-only** by contract:
  no protocol/scheme, no `://`, no path, no trailing slash, no port. The bare
  hostname charset (`[A-Za-z0-9.-]`, no leading/trailing `-`/`.`) makes the
  metacharacters that used to break sed/nginx — `& \ | ; " ' $` — structurally
  unrepresentable, so the old separate metacharacter guard is subsumed.
- Both hostnames are validated in `vps-deploy.sh` (`require_valid_hostname`,
  `LC_ALL=C` so the ranges are ASCII-deterministic in ru_RU.UTF-8) and
  re-guarded in the Dockerfile (empty/invalid value → BUILD failure), then
  `nginx -t` runs after the sed so a bad baked value fails loudly at BUILD
  time, never at runtime.
- `LANDING_HOSTNAME` (Forgejo repo variable, still required for Traefik labels)
  feeds the landing's own canonical URLs — `og:url`/`og:image` in index.html
  via the `__LANDING_HOSTNAME__` placeholder, `https://` prepended at bake time.
- The values are baked at **build time** because the container rootfs is
  read-only in production — runtime templating is not an option.
  `vps-deploy.sh` rebuilds the image on every deploy, so a changed variable
  takes effect on the next release.
- `302` (not `301`) is deliberate: browsers must not pin the redirect forever,
  so a changed `WEB_HOSTNAME` applies immediately.

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
   css/js references in `index.html` and syncs the version in
   `package-lock.json` (root + `packages[""]`) — keep those references
   versioned.
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
7. **`__WEB_HOSTNAME__`/`__LANDING_HOSTNAME__` placeholders are replaced at
   image build** — never commit a real hostname there; keep `/web` links
   relative. Both are hostname-only by contract (no protocol, path, trailing
   slash or port), and the bare-hostname charset makes the metacharacters that
   broke the old `WEB_APP_URL` scheme (`& \ | ; " ' $`) unrepresentable.
   `vps-deploy.sh` validates both via `require_valid_hostname` (`LC_ALL=C`),
   and the Dockerfile re-guards + runs `nginx -t` so a bad value fails at BUILD
   time, never at runtime. Defaults live in the Dockerfile ARGs (both vars); in the deploy
   script `WEB_HOSTNAME` has a default and `LANDING_HOSTNAME` is required.
   Forgejo vars are `WEB_HOSTNAME` and `LANDING_HOSTNAME`.
