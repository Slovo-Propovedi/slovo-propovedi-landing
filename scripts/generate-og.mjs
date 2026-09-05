#!/usr/bin/env node

// Generates assets/img/og.png (1200x630) for social sharing cards.
// Builds an SVG on-brand with the landing page (black card, brand orange
// #f16031 accent, white Unbounded wordmark, Onest tagline) and rasterizes it.
//
// Rasterizer preference:
//   1. rsvg-convert (librsvg) — best text/font support via pango+fontconfig
//   2. ImageMagick `convert` — fallback
// If neither is available the script fails loudly; the PNG is committed so CI
// never needs to re-generate it.
//
// Run: npm run generate-og

import { execFileSync } from 'node:child_process'
import { mkdtempSync, writeFileSync, rmSync, existsSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const FONTS_DIR = join(ROOT, 'assets', 'fonts')
const OUT = join(ROOT, 'assets', 'img', 'og.png')

// The landing hostname comes from LANDING_HOSTNAME (default slovo-propovedi.ru).
const LANDING_HOSTNAME = process.env.LANDING_HOSTNAME || 'slovo-propovedi.ru'

const WIDTH = 1200
const HEIGHT = 630

// --- Build the SVG (on-brand: black card + orange accent + white wordmark) ---
const svg = `<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="${WIDTH}" height="${HEIGHT}" viewBox="0 0 ${WIDTH} ${HEIGHT}">
  <defs>
    <radialGradient id="orangeGlow" cx="88%" cy="-12%" r="85%">
      <stop offset="0%" stop-color="#f16031" stop-opacity="0.42"/>
      <stop offset="55%" stop-color="#f16031" stop-opacity="0.12"/>
      <stop offset="100%" stop-color="#f16031" stop-opacity="0"/>
    </radialGradient>
    <radialGradient id="deepGlow" cx="-8%" cy="92%" r="75%">
      <stop offset="0%" stop-color="#d1542a" stop-opacity="0.5"/>
      <stop offset="55%" stop-color="#d1542a" stop-opacity="0.14"/>
      <stop offset="100%" stop-color="#d1542a" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="orangeRule" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0%" stop-color="#ff8a3d"/>
      <stop offset="100%" stop-color="#f16031"/>
    </linearGradient>
  </defs>

  <rect width="${WIDTH}" height="${HEIGHT}" fill="#000"/>
  <rect width="${WIDTH}" height="${HEIGHT}" fill="url(#orangeGlow)"/>
  <rect width="${WIDTH}" height="${HEIGHT}" fill="url(#deepGlow)"/>

  <!-- orange rule under the wordmark -->
  <rect x="80" y="352" width="420" height="6" rx="3" fill="url(#orangeRule)"/>

  <!-- wordmark -->
  <text x="80" y="300" font-family="Unbounded" font-weight="700" font-size="82" fill="#ffffff">Слово.Проповеди</text>

  <!-- tagline -->
  <text x="80" y="410" font-family="Onest" font-size="34" fill="#d4d4d4">Слушайте христианские проповеди на вашем устройстве</text>

  <!-- domain -->
  <text x="80" y="480" font-family="Onest" font-weight="600" font-size="30" fill="#f16031">${LANDING_HOSTNAME}</text>

  <!-- QR motif (decorative, suggests the on-page QR) -->
  <g transform="translate(930, 400)">
    <rect x="0" y="0" width="190" height="190" rx="14" fill="#ffffff"/>
    <g fill="#f16031">
      <rect x="18" y="18" width="44" height="44" rx="6"/>
      <rect x="30" y="30" width="20" height="20" rx="3" fill="#ffffff"/>
      <rect x="128" y="18" width="44" height="44" rx="6"/>
      <rect x="140" y="30" width="20" height="20" rx="3" fill="#ffffff"/>
      <rect x="18" y="128" width="44" height="44" rx="6"/>
      <rect x="30" y="140" width="20" height="20" rx="3" fill="#ffffff"/>
      <rect x="80" y="80" width="16" height="16" rx="3"/>
      <rect x="104" y="80" width="16" height="16" rx="3"/>
      <rect x="80" y="104" width="16" height="16" rx="3"/>
      <rect x="104" y="104" width="16" height="16" rx="3"/>
      <rect x="80" y="128" width="16" height="16" rx="3"/>
      <rect x="128" y="104" width="16" height="16" rx="3"/>
      <rect x="128" y="128" width="16" height="16" rx="3"/>
      <rect x="104" y="152" width="16" height="16" rx="3"/>
      <rect x="128" y="152" width="16" height="16" rx="3"/>
      <rect x="152" y="128" width="16" height="16" rx="3"/>
      <rect x="152" y="152" width="16" height="16" rx="3"/>
    </g>
  </g>
</svg>
`

// --- Rasterize ---
const tmp = mkdtempSync(join(tmpdir(), 'og-'))
const svgPath = join(tmp, 'og.svg')
writeFileSync(svgPath, svg)

const findBin = (name) => {
  try {
    execFileSync('which', [name], { stdio: 'pipe' })
    return name
  } catch {
    return null
  }
}

const rsvg = findBin('rsvg-convert')
const convert = findBin('convert')

if (rsvg) {
  // Register the repo's self-hosted woff2 fonts with fontconfig so the
  // wordmark/tagline render in Unbounded/Onest rather than a fallback face.
  const fontsConf = join(tmp, 'fonts.conf')
  writeFileSync(
    fontsConf,
    `<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <dir>${FONTS_DIR}</dir>
  <cachedir>${join(tmp, 'fontcache')}</cachedir>
</fontconfig>
`
  )
  execFileSync(rsvg, ['-w', String(WIDTH), '-h', String(HEIGHT), svgPath, '-o', OUT], {
    env: { ...process.env, FONTCONFIG_FILE: fontsConf },
    stdio: 'inherit',
  })
} else if (convert) {
  execFileSync(convert, ['-background', 'none', '-density', '150', svgPath, '-resize', `${WIDTH}x${HEIGHT}!`, OUT], {
    stdio: 'inherit',
  })
} else {
  rmSync(tmp, { recursive: true, force: true })
  throw new Error(
    'No SVG rasterizer available (rsvg-convert or ImageMagick convert). ' +
      'Install librsvg2-bin or imagemagick, then re-run `npm run generate-og`.'
  )
}

rmSync(tmp, { recursive: true, force: true })

if (!existsSync(OUT)) {
  throw new Error(`Rasterizer reported success but ${OUT} was not created`)
}

console.log(`✓ Regenerated ${OUT} (${WIDTH}x${HEIGHT})`)