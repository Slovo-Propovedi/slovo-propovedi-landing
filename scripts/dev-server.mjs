#!/usr/bin/env node

// Local development server for the landing page.
// Zero dependencies (node:http, node:fs, node:path). Mirrors the production
// nginx container's html/ contents: serves only index.html, robots.txt,
// sitemap.xml and /assets/*, answers /web with the same 302 redirect, and
// substitutes __LANDING_HOSTNAME__ into index.html / robots.txt / sitemap.xml.

import { createServer } from 'node:http'
import { readFileSync, existsSync } from 'node:fs'
import { join, resolve, normalize, extname, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const ENV_PATH = join(ROOT, '.env')

const HOSTNAME_PATTERN = /^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$/
const HOSTNAME_CONTRACT = 'hostname only: no protocol, no path, no trailing slash, no port'

const DEFAULTS = {
  WEB_HOSTNAME: 'app.slovo-propovedi.ru',
  LANDING_HOSTNAME: 'slovo-propovedi.ru',
  DOCS_HOSTNAME: 'docs.slovo-propovedi.ru',
  PORT: 8377,
}

const MIME_TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
  '.woff2': 'font/woff2',
  '.txt': 'text/plain; charset=utf-8',
  '.webmanifest': 'application/manifest+json',
}

// --- Config resolution (dotenv convention) ---

// Parse a dotenv-style file into a plain object. Blank lines and full-line
// comments are skipped; values may be wrapped in matching quotes. A malformed
// line fails fast with the file and line number.
function parseDotenv(text, filePath) {
  // Strip a leading UTF-8 BOM so Windows-authored .env files parse correctly.
  if (text.charCodeAt(0) === 0xFEFF) text = text.slice(1)
  const vars = {}
  const lines = text.split('\n')
  for (let index = 0; index < lines.length; index++) {
    const line = lines[index].trim()
    if (line === '' || line.startsWith('#')) continue
    const eq = line.indexOf('=')
    if (eq === -1) {
      throw new Error(`${filePath}:${index + 1}: expected KEY=VALUE, got "${line}"`)
    }
    const key = line.slice(0, eq).trim()
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) {
      throw new Error(`${filePath}:${index + 1}: invalid variable name "${key}"`)
    }
    let value = line.slice(eq + 1).trim()
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1)
    }
    vars[key] = value
  }
  return vars
}

function parsePort(value) {
  const port = Number(value)
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error(`PORT must be an integer between 1 and 65535, got "${value}"`)
  }
  return port
}

// Resolve the effective config: real environment wins over .env, which wins
// over hardcoded defaults. Returns { webHostname, landingHostname, port, sources }.
function resolveConfig() {
  const dotenv = existsSync(ENV_PATH)
    ? parseDotenv(readFileSync(ENV_PATH, 'utf-8'), ENV_PATH)
    : {}

  const pick = (name) => {
    if (process.env[name] !== undefined) return { value: process.env[name], source: 'environment' }
    if (dotenv[name] !== undefined) return { value: dotenv[name], source: '.env' }
    return { value: DEFAULTS[name], source: 'default' }
  }

  const web = pick('WEB_HOSTNAME')
  const landing = pick('LANDING_HOSTNAME')
  const docs = pick('DOCS_HOSTNAME')
  const port = pick('PORT')

  return {
    webHostname: web.value,
    landingHostname: landing.value,
    docsHostname: docs.value,
    port: parsePort(port.value),
    sources: {
      WEB_HOSTNAME: web.source,
      LANDING_HOSTNAME: landing.source,
      DOCS_HOSTNAME: docs.source,
      PORT: port.source,
    },
  }
}

function validateHostname(value, name, source) {
  if (!HOSTNAME_PATTERN.test(value)) {
    throw new Error(
      `${name} (from ${source}) is invalid: "${value}" — ${HOSTNAME_CONTRACT}`
    )
  }
}

function loadConfig() {
  try {
    const config = resolveConfig()
    validateHostname(config.webHostname, 'WEB_HOSTNAME', config.sources.WEB_HOSTNAME)
    validateHostname(config.landingHostname, 'LANDING_HOSTNAME', config.sources.LANDING_HOSTNAME)
    validateHostname(config.docsHostname, 'DOCS_HOSTNAME', config.sources.DOCS_HOSTNAME)
    return config
  } catch (err) {
    console.error(err.message)
    process.exit(1)
  }
}

const CONFIG = loadConfig()

// --- Request handling ---

// Map a decoded URL pathname to a response target. Traversal attempts that
// escape the repo root are forbidden (403); dotfiles and anything outside the
// production file set are not found (404).
function resolvePublicPath(pathname) {
  const resolved = normalize(join(ROOT, pathname))
  const insideRoot = resolved === ROOT || resolved.startsWith(ROOT + '/')
  if (!insideRoot) return { kind: 'forbidden' }

  const relative = resolved === ROOT ? '' : resolved.slice(ROOT.length + 1)
  if (relative.split('/').some((segment) => segment.startsWith('.'))) {
    return { kind: 'notFound' }
  }
  if (relative === '' || relative === 'index.html') return { kind: 'index' }
  // robots.txt and sitemap.xml carry the __LANDING_HOSTNAME__ placeholder,
  // baked at image build — substitute it here too.
  if (relative === 'robots.txt') {
    return { kind: 'templated', path: resolved, type: 'text/plain; charset=utf-8' }
  }
  if (relative === 'sitemap.xml') {
    return { kind: 'templated', path: resolved, type: 'application/xml; charset=utf-8' }
  }
  if (relative.startsWith('assets/')) {
    return { kind: 'file', path: resolved }
  }
  return { kind: 'notFound' }
}

function sendBody(res, status, body, contentType) {
  res.writeHead(status, {
    'Content-Type': contentType,
    'Content-Length': Buffer.byteLength(body),
    'Cache-Control': 'no-cache',
  })
  if (res.req.method === 'HEAD') {
    res.end()
    return
  }
  res.end(body)
}

function sendStatus(res, status, message) {
  sendBody(res, status, message, 'text/plain; charset=utf-8')
}

function redirectToWeb(res) {
  res.writeHead(302, {
    Location: `https://${CONFIG.webHostname}`,
    'Cache-Control': 'no-cache',
  })
  res.end()
}

function serveIndex(res) {
  let html
  try {
    html = readFileSync(join(ROOT, 'index.html'), 'utf-8')
  } catch {
    sendStatus(res, 404, 'Not Found')
    return
  }
  const body = html
    .replaceAll('__LANDING_HOSTNAME__', CONFIG.landingHostname)
    .replaceAll('__DOCS_HOSTNAME__', CONFIG.docsHostname)
  sendBody(res, 200, body, 'text/html; charset=utf-8')
}

function serveTemplated(res, filePath, contentType) {
  let text
  try {
    text = readFileSync(filePath, 'utf-8')
  } catch {
    sendStatus(res, 404, 'Not Found')
    return
  }
  sendBody(res, 200, text.replaceAll('__LANDING_HOSTNAME__', CONFIG.landingHostname), contentType)
}

function serveStatic(res, filePath) {
  let data
  try {
    data = readFileSync(filePath)
  } catch {
    sendStatus(res, 404, 'Not Found')
    return
  }
  sendBody(res, 200, data, MIME_TYPES[extname(filePath)] || 'application/octet-stream')
}

function serve(req, res) {
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    sendStatus(res, 405, 'Method Not Allowed')
    return
  }

  let pathname
  try {
    pathname = decodeURIComponent(req.url.split('?')[0])
  } catch {
    sendStatus(res, 400, 'Bad Request')
    return
  }

  if (pathname === '/web') {
    redirectToWeb(res)
    return
  }

  const target = resolvePublicPath(pathname)
  if (target.kind === 'forbidden') {
    sendStatus(res, 403, 'Forbidden')
    return
  }
  if (target.kind === 'notFound') {
    sendStatus(res, 404, 'Not Found')
    return
  }
  if (target.kind === 'index') {
    serveIndex(res)
    return
  }
  if (target.kind === 'templated') {
    serveTemplated(res, target.path, target.type)
    return
  }
  serveStatic(res, target.path)
}

// --- Startup ---

function printBanner() {
  console.log(`Dev server listening on http://127.0.0.1:${CONFIG.port}`)
  console.log(`  WEB_HOSTNAME=${CONFIG.webHostname} (${CONFIG.sources.WEB_HOSTNAME})`)
  console.log(`  LANDING_HOSTNAME=${CONFIG.landingHostname} (${CONFIG.sources.LANDING_HOSTNAME})`)
  console.log(`  DOCS_HOSTNAME=${CONFIG.docsHostname} (${CONFIG.sources.DOCS_HOSTNAME})`)
  console.log(`  /web redirects to https://${CONFIG.webHostname}`)
}

const server = createServer(serve)
server.listen(CONFIG.port, '127.0.0.1', printBanner)
server.on('error', (err) => {
  if (err.code === 'EADDRINUSE') {
    console.error(`Port ${CONFIG.port} is busy — set PORT=... to use another port`)
  } else {
    console.error(`Failed to start dev server: ${err.message}`)
  }
  process.exit(1)
})
