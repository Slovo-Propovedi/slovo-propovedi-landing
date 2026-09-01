#!/usr/bin/env node

// Regenerates assets/img/qr.svg encoding the landing URL.
// Uses `npx qrcode` (fetched on demand) so qrcode is NOT a project dependency.
// Run: npm run generate-qr

import { execSync } from 'node:child_process'

const URL = 'https://slovo-propovedi.ru'
const OUT = 'assets/img/qr.svg'

execSync(`npx --yes qrcode@1.5.4 -t svg -o ${OUT} "${URL}"`, { stdio: 'inherit' })

// Re-theme the generated QR: background intentionally left white (matches the
// --qr-bg token) + near-black modules for maximum scan contrast.
const fs = await import('node:fs')
let svg = fs.readFileSync(OUT, 'utf-8')
svg = svg.replace('stroke="#000000"', 'stroke="#1a1a1a"')
fs.writeFileSync(OUT, svg)

console.log(`✓ Regenerated ${OUT} encoding ${URL}`)
