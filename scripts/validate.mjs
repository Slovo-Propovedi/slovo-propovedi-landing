#!/usr/bin/env node

// Minimal sanity check for the landing page. Extended by the CI task later.
// Verifies the files the page depends on actually exist so a broken build
// fails fast instead of shipping a 404.

import { existsSync } from 'node:fs'

const REQUIRED = [
  'index.html',
  'robots.txt',
  'nginx.conf',
  'Dockerfile',
  'assets/css/main.css',
  'assets/js/main.js',
  'assets/img/favicon.svg',
  'assets/img/qr.svg',
]

const missing = REQUIRED.filter((file) => !existsSync(file))

if (missing.length > 0) {
  console.error(`✗ Missing required files:\n  ${missing.join('\n  ')}`)
  process.exit(1)
}

console.log('✓ All required landing files present')
