#!/usr/bin/env node

// Validates the landing page is self-contained and consistent with the
// release contract. Pure Node, no dependencies. Run via `npm run validate`.
//
// Checks:
//   1. index.html — lang="ru", required element ids, forgejo releases fallback
//      link, and no external RESOURCE references (src / <link> href). Navigation
//      <a href> links are allowed; only resource-loading attributes are checked
//      so the page stays 100% self-contained (no CDN). og: meta uses `content`,
//      so it is naturally exempt.
//   2. assets/js/main.js exists and references latest.json.
//   3. QR + favicon exist; fonts dir has >= 8 .woff2.
//   4. nginx.conf — APK MIME, caching, JSON, hidden-file deny, and the security
//      headers REPEATED inside the /apk/ location (add_header inheritance fix).
//   5. CHANGELOG.md has a section for the current package.json version.
//   6. package-lock.json exists and its version matches package.json.

import { readFileSync, existsSync, readdirSync } from 'node:fs'

const failures = []
const ok = (msg) => console.log(`✓ ${msg}`)
const bad = (msg) => {
  failures.push(msg)
  console.error(`✗ ${msg}`)
}

const read = (path) => readFileSync(path, 'utf-8')

// --- 1. index.html ---
if (!existsSync('index.html')) {
  bad('index.html missing')
} else {
  const html = read('index.html')

  if (!/<html[^>]*\blang="ru"/.test(html)) bad('index.html: missing lang="ru"')

  for (const id of ['download-btn', 'meta-version', 'meta-size', 'meta-date', 'meta-sha256', 'sha-copy']) {
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
}

// --- 2. main.js ---
if (!existsSync('assets/js/main.js')) {
  bad('assets/js/main.js missing')
} else if (!read('assets/js/main.js').includes('latest.json')) {
  bad('assets/js/main.js: does not reference latest.json')
}

// --- 3. images + fonts ---
for (const file of ['assets/img/qr.svg', 'assets/img/favicon.svg']) {
  if (!existsSync(file)) bad(`${file} missing`)
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

  // add_header inheritance fix: the full security header set must be REPEATED
  // inside the /apk/ location block (nginx does not inherit add_header from the
  // server level once a location defines its own add_header).
  const apkLoc = nginx.match(/location ~\* \^\/apk\/\.\+\\.apk\$ \{([\s\S]*?)\n    \}/)
  if (!apkLoc) {
    bad('nginx.conf: /apk/ location block not found')
  } else {
    const body = apkLoc[1]
    for (const header of [
      'X-Frame-Options',
      'X-Content-Type-Options',
      'Referrer-Policy',
      'Permissions-Policy',
      'Content-Security-Policy',
    ]) {
      if (!body.includes(header)) {
        bad(`nginx.conf: /apk/ location missing security header ${header} (add_header inheritance fix)`)
      }
    }
  }
}

// --- 5 + 6. version consistency ---
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
}

if (failures.length > 0) {
  console.error(`\nValidation failed (${failures.length} issue(s))`)
  process.exit(1)
}

console.log('\n✓ All checks passed')
