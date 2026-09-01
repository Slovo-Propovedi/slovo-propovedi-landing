#!/usr/bin/env node

// Regenerates assets/img/qr.svg encoding the landing URL.
// Uses `npx qrcode` (fetched on demand) so qrcode is NOT a project dependency.
// Run: npm run generate-qr

import { execSync } from 'node:child_process'

const URL = 'https://slovo-propovedi.ru'
const OUT = 'assets/img/qr.svg'

execSync(`npx --yes qrcode@1.5.4 -t svg -o ${OUT} "${URL}"`, { stdio: 'inherit' })

// Re-theme the generated QR: cream card background + ink-navy modules so it
// matches the manuscript palette while keeping high contrast for scanning.
const fs = await import('node:fs')
let svg = fs.readFileSync(OUT, 'utf-8')
svg = svg.replace('fill="#ffffff"', 'fill="#f6ecd4"').replace('stroke="#000000"', 'stroke="#1a1f2e"')
fs.writeFileSync(OUT, svg)

console.log(`✓ Regenerated ${OUT} encoding ${URL}`)
