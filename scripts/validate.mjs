#!/usr/bin/env node

// Validates the landing page is self-contained and consistent with the
// release contract. Pure Node, no dependencies. Run via `npm run validate`.
//
// Checks:
//   1. index.html — lang="ru", required element ids, forgejo releases fallback
//      link, no external RESOURCE references, cache-busting ?v= matching
//      package.json, og:image + twitter:card meta.
//   2. assets/js/main.js exists and references latest.json.
//   3. QR + icon + og.png exist (icon.png and og.png verified as PNG by magic
//      bytes); fonts dir has >= 8 .woff2.
//   4. nginx.conf — APK MIME, caching, JSON, hidden-file deny FIRST, the
//      security headers REPEATED inside every add_header location, the six
//      CSP strings byte-identical with form-action 'none', and the screenshots
//      image + manifest locations present with the right caching.
//   5. CHANGELOG.md has a section for the current package.json version.
//   6. package-lock.json exists and its version matches package.json.
//   7. assets/js/theme-init.js exists and index.html ships the
//      <meta name="color-scheme" content="light dark"> pre-paint hint.

import { readFileSync, existsSync, readdirSync } from 'node:fs'

const failures = []
const ok = (msg) => console.log(`✓ ${msg}`)
const bad = (msg) => {
  failures.push(msg)
  console.error(`✗ ${msg}`)
}

const read = (path) => readFileSync(path, 'utf-8')

// index.html is read by sections 1, 6 and 7 — read it once at the top.
const html = existsSync('index.html') ? read('index.html') : null

const SECURITY_HEADERS = [
  'X-Frame-Options',
  'X-Content-Type-Options',
  'Referrer-Policy',
  'Permissions-Policy',
  'Content-Security-Policy',
]

// Returns null when the location body repeats the full security-header set,
// otherwise a human-readable reason (add_header inheritance fix: nginx does
// not inherit server-level add_header into a location that defines its own).
function requiresHeaders(locationBody) {
  for (const header of SECURITY_HEADERS) {
    if (!locationBody.includes(header)) {
      return `missing security header ${header} (add_header inheritance fix)`
    }
  }
  return null
}

// --- 1. index.html ---
if (!html) {
  bad('index.html missing')
} else {
  if (!/<html[^>]*\blang="ru"/.test(html)) bad('index.html: missing lang="ru"')

  for (const id of ['download-btn', 'meta-version', 'meta-size', 'meta-date', 'meta-sha256', 'sha-copy', 'screenshots-list']) {
    if (!new RegExp(`id="${id}"`).test(html)) bad(`index.html: missing id="${id}"`)
  }

  if (!/href="https:\/\/git\.lightnode\.ru\/Slovo_Propovedi\/slovo-propovedi-mobile\/releases"/.test(html)) {
    bad('index.html: missing forgejo releases fallback link')
  }

  // No external resource references: src attributes and <link> href attributes
  // must be relative. Navigation <a href> links are not resources and are allowed.
  const srcs = [...html.matchAll(/\bsrc="([^"]+)"/g)].map((m) => m[1])
  const linkHrefs = [...html.matchAll(/<link\b[^>]*\bhref="([^"]+)"/g)].map((m) => m[1])
  const external = [...srcs, ...linkHrefs].filter((u) => /^https?:\/\//.test(u))
  if (external.length > 0) {
    bad(`index.html: external resource link(s) found: ${external.join(', ')}`)
  }

  // og:image must be an absolute https URL pointing at the committed og.png
  const ogImage = html.match(/<meta property="og:image" content="([^"]+)">/)
  if (!ogImage) {
    bad('index.html: missing og:image meta')
  } else if (!/^https:\/\/slovo-propovedi\.ru\/assets\/img\/og\.png$/.test(ogImage[1])) {
    bad(`index.html: og:image must be an absolute https URL to /assets/img/og.png, got "${ogImage[1]}"`)
  }
  if (!/<meta property="og:image:width" content="1200">/.test(html)) bad('index.html: missing og:image:width 1200')
  if (!/<meta property="og:image:height" content="630">/.test(html)) bad('index.html: missing og:image:height 630')
  if (!/<meta property="og:image:alt"/.test(html)) bad('index.html: missing og:image:alt')
  if (!/<meta name="twitter:card" content="summary_large_image">/.test(html)) {
    bad('index.html: missing twitter:card summary_large_image')
  }
}

// --- 2. main.js ---
if (!existsSync('assets/js/main.js')) {
  bad('assets/js/main.js missing')
} else if (!read('assets/js/main.js').includes('latest.json')) {
  bad('assets/js/main.js: does not reference latest.json')
}

// --- 3. images + fonts ---
for (const file of ['assets/img/qr.svg', 'assets/img/icon.png']) {
  if (!existsSync(file)) bad(`${file} missing`)
}
if (!existsSync('assets/img/icon.png')) {
  bad('assets/img/icon.png missing')
} else {
  // PNG magic bytes: 89 50 4E 47 0D 0A 1A 0A
  const head = readFileSync('assets/img/icon.png').subarray(0, 8)
  const isPng = Buffer.compare(head, Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) === 0
  if (!isPng) bad('assets/img/icon.png: not a PNG (magic bytes mismatch)')
}
if (!existsSync('assets/img/og.png')) {
  bad('assets/img/og.png missing')
} else {
  // PNG magic bytes: 89 50 4E 47 0D 0A 1A 0A
  const head = readFileSync('assets/img/og.png').subarray(0, 8)
  const isPng = Buffer.compare(head, Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) === 0
  if (!isPng) bad('assets/img/og.png: not a PNG (magic bytes mismatch)')
}
const woff2 = existsSync('assets/fonts')
  ? readdirSync('assets/fonts').filter((f) => f.endsWith('.woff2'))
  : []
if (woff2.length < 8) bad(`assets/fonts: expected >= 8 .woff2 files, found ${woff2.length}`)

// --- 4. nginx.conf ---
if (!existsSync('nginx.conf')) {
  bad('nginx.conf missing')
} else {
  const nginx = read('nginx.conf')

  for (const needle of [
    'application/vnd.android.package-archive',
    'immutable',
    'no-cache',
    'application/json',
    'deny all',
  ]) {
    if (!nginx.includes(needle)) bad(`nginx.conf: missing "${needle}"`)
  }

  // Extract every location block (closing brace at 4-space indent).
  const locations = [...nginx.matchAll(/location\s+([^{]+)\{([\s\S]*?)\n    \}/g)].map((m) => ({
    selector: m[1].trim(),
    body: m[2],
  }))
  if (locations.length === 0) bad('nginx.conf: no location blocks found')

  // add_header inheritance fix: the full security header set must be REPEATED
  // inside every location that declares its own add_header.
  const headerLocations = locations.filter((loc) => loc.body.includes('add_header'))
  if (headerLocations.length < 5) {
    bad(`nginx.conf: expected >= 5 locations with add_header, found ${headerLocations.length}`)
  }
  for (const loc of headerLocations) {
    const reason = requiresHeaders(loc.body)
    if (reason) bad(`nginx.conf: location ${loc.selector} ${reason}`)
  }

  // The six CSP strings (server level + the five repeating locations) must
  // be byte-identical and hardened with form-action 'none'.
  const cspStrings = [...nginx.matchAll(/add_header Content-Security-Policy "([^"]+)"/g)].map((m) => m[1])
  if (cspStrings.length !== 6) {
    bad(`nginx.conf: expected exactly 6 CSP strings (server + 5 locations), found ${cspStrings.length}`)
  } else {
    const [first, ...rest] = cspStrings
    if (rest.some((csp) => csp !== first)) {
      bad('nginx.conf: CSP strings are not byte-identical across server + locations')
    }
    if (!first.includes("form-action 'none'")) {
      bad("nginx.conf: CSP missing form-action 'none'")
    }
  }

  // Dotfile-deny must be the FIRST regex location so /apk/.tmp-*.apk,
  // /screenshots/.tmp-*.png and /assets/.secret.js are never served by
  // later-declared regexes.
  const denyIndex = nginx.indexOf('location ~ /\\.')
  const apkIndex = nginx.indexOf('location ~* ^/apk/')
  const shotsIndex = nginx.indexOf('location ~* ^/screenshots/')
  const assetIndex = nginx.indexOf('location ~* \\.(?:js|css|png|svg|ico|woff2)')
  if (denyIndex === -1) {
    bad('nginx.conf: dotfile-deny location (~ /\\.) not found')
  } else if (apkIndex === -1 || shotsIndex === -1 || assetIndex === -1) {
    bad('nginx.conf: apk, screenshots, or asset regex location not found')
  } else if (denyIndex > apkIndex || denyIndex > shotsIndex || denyIndex > assetIndex) {
    bad('nginx.conf: dotfile-deny location must appear BEFORE the apk, screenshots, and asset regex locations')
  }

  // Screenshots manifest location must exist and be served fresh (no-cache).
  if (!/location = \/screenshots\/manifest\.json \{[\s\S]*?Cache-Control "no-cache"/.test(nginx)) {
    bad('nginx.conf: screenshots manifest location missing no-cache')
  }

  // Screenshots image location must cache immutably (filenames embed the blob
  // sha, so a changed image is a new URL and old ones can be cached forever).
  const shotsImageLoc = locations.find((loc) => loc.selector.startsWith('~* ^/screenshots/'))
  if (!shotsImageLoc || !shotsImageLoc.body.includes('Cache-Control "public, max-age=31536000, immutable"')) {
    bad('nginx.conf: screenshots image location missing immutable Cache-Control')
  }
}

// --- 5 + 6. version consistency + cache-busting ---
if (!existsSync('package.json')) {
  bad('package.json missing')
} else {
  const pkg = JSON.parse(read('package.json'))

  if (!existsSync('CHANGELOG.md')) {
    bad('CHANGELOG.md missing')
  } else if (!read('CHANGELOG.md').includes(`## [${pkg.version}]`)) {
    bad(`CHANGELOG.md: missing section for version ${pkg.version}`)
  }

  if (!existsSync('package-lock.json')) {
    bad('package-lock.json missing')
  } else {
    const lock = JSON.parse(read('package-lock.json'))
    if (lock.version !== pkg.version) {
      bad(`package-lock.json: version ${lock.version} != package.json ${pkg.version}`)
    }
  }

  // Cache-busting: index.html must reference css/js with ?v=<package version>
  if (html) {
    for (const asset of ['/assets/css/main.css', '/assets/js/main.js', '/assets/js/theme-init.js']) {
      const ref = html.match(new RegExp(`${asset.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\?v=([0-9]+\\.[0-9]+\\.[0-9]+)`))
      if (!ref) {
        bad(`index.html: missing cache-busting ?v= on ${asset}`)
      } else if (ref[1] !== pkg.version) {
        bad(`index.html: ${asset} ?v=${ref[1]} != package.json version ${pkg.version}`)
      }
    }
  }
}

// --- 7. theme-init.js invariants ---
if (!existsSync('assets/js/theme-init.js')) {
  bad('assets/js/theme-init.js missing')
}

if (html) {
  if (!/<meta name="color-scheme" content="light dark">/.test(html)) {
    bad('index.html: missing <meta name="color-scheme" content="light dark">')
  }
}

// --- 8. Web-app fallback (/web redirect) ---
// WEB_APP_URL is baked into nginx.conf at image build (Dockerfile sed), so the
// placeholder must appear exactly once there and the deploy script must wire
// the build-arg + validation guard. index.html links to the RELATIVE /web.
if (existsSync('nginx.conf')) {
  const nginx = read('nginx.conf')
  const placeholderCount = (nginx.match(/__WEB_APP_URL__/g) || []).length
  if (placeholderCount !== 1) {
    bad(`nginx.conf: expected exactly 1 __WEB_APP_URL__ placeholder, found ${placeholderCount}`)
  }
  if (!/location = \/web \{[\s\S]*?return 302 __WEB_APP_URL__;/.test(nginx)) {
    bad('nginx.conf: /web location must return 302 to __WEB_APP_URL__')
  }
}

if (!existsSync('Dockerfile')) {
  bad('Dockerfile missing')
} else {
  const dockerfile = read('Dockerfile')
  if (!/ARG WEB_APP_URL=https:\/\/app\.slovo-propovedi\.ru/.test(dockerfile)) {
    bad('Dockerfile: missing ARG WEB_APP_URL default')
  }
  if (!/RUN sed -i "s\|__WEB_APP_URL__\|\$\{WEB_APP_URL\}\|g"/.test(dockerfile)) {
    bad('Dockerfile: missing sed RUN replacing __WEB_APP_URL__')
  }
  if (!dockerfile.includes('nginx -t')) {
    bad('Dockerfile: missing build-time nginx -t config check')
  }
}

if (html && !/<a[^>]*href="\/web"/.test(html)) {
  bad('index.html: missing href="/web" link')
}

if (existsSync('scripts/vps-deploy.sh')) {
  const deploy = read('scripts/vps-deploy.sh')
  if (!deploy.includes('--build-arg WEB_APP_URL=')) {
    bad('scripts/vps-deploy.sh: missing --build-arg WEB_APP_URL=')
  }
  if (!/=~ \^https:\/\//.test(deploy)) {
    bad('scripts/vps-deploy.sh: missing WEB_APP_URL validation guard')
  }
  if (!deploy.includes('forbidden character')) {
    bad('scripts/vps-deploy.sh: missing WEB_APP_URL metacharacter rejection guard')
  }
}

if (failures.length > 0) {
  console.error(`\nValidation failed (${failures.length} issue(s))`)
  process.exit(1)
}

console.log('\n✓ All checks passed')
