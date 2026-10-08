#!/usr/bin/env node

// Regenerates assets/img/qr.svg encoding the landing URL.
// Uses `npx qrcode` (fetched on demand) so qrcode is NOT a project dependency.
// Run: npm run generate-qr
// The landing hostname comes from LANDING_HOSTNAME (required);
// the https:// prefix is added here.

import { execFileSync } from 'node:child_process'

const LANDING_HOSTNAME = process.env.LANDING_HOSTNAME
if (!LANDING_HOSTNAME) {
  throw new Error('LANDING_HOSTNAME is required (e.g. LANDING_HOSTNAME=example.com npm run generate-qr)')
}
const URL = `https://${LANDING_HOSTNAME}`
const OUT = 'assets/img/qr.svg'

execFileSync('npx', ['--yes', 'qrcode@1.5.4', '-t', 'svg', '-o', OUT, URL], { stdio: 'inherit' })

// Re-theme the generated QR: background intentionally left white (matches the
// --qr-bg token) + near-black modules for maximum scan contrast.
const fs = await import('node:fs')
let svg = fs.readFileSync(OUT, 'utf-8')
svg = svg.replace('stroke="#000000"', 'stroke="#1a1a1a"')
fs.writeFileSync(OUT, svg)

console.log(`✓ Regenerated ${OUT} encoding ${URL}`)
