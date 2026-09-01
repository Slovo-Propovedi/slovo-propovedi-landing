#!/usr/bin/env node

import { readFileSync, writeFileSync } from 'node:fs'
import { execSync } from 'node:child_process'

const GREEN = '\x1b[32m'
const RED = '\x1b[31m'
const YELLOW = '\x1b[33m'
const RESET = '\x1b[0m'

const log = (message, color = '') => console.log(`${color}${message}${RESET}`)
const exitError = (message) => {
  log(message, RED)
  process.exit(1)
}

// --- Parse argument ---
const arg = process.argv[2]

if (!arg) {
  exitError('Usage: node scripts/bump-version.mjs <version|patch|minor|major>')
}

// Strip optional 'v' prefix (e.g. v1.2.3 → 1.2.3)
const versionArg = arg.startsWith('v') ? arg.slice(1) : arg

if (!/^\d+\.\d+\.\d+$/.test(versionArg) && !['patch', 'minor', 'major'].includes(versionArg)) {
  exitError(`Invalid argument: "${arg}". Use X.Y.Z, patch, minor, or major.`)
}

// --- Read current version from package.json ---
const pkgPath = 'package.json'
const pkg = JSON.parse(readFileSync(pkgPath, 'utf-8'))
const currentVersion = pkg.version

// --- Calculate new version ---
let newVersion

if (/^\d+\.\d+\.\d+$/.test(versionArg)) {
  newVersion = versionArg
} else {
  const [major, minor, patch] = currentVersion.split('.').map(Number)
  const bumps = {
    major: `${major + 1}.0.0`,
    minor: `${major}.${minor + 1}.0`,
    patch: `${major}.${minor}.${patch + 1}`,
  }
  newVersion = bumps[versionArg]
}

// --- Update files ---

// 1. package.json
pkg.version = newVersion
writeFileSync(pkgPath, `${JSON.stringify(pkg, null, 2)}\n`)
log('✓ Updated package.json', GREEN)

// 2. CHANGELOG.md — generate section from conventional commits
const changelogPath = 'CHANGELOG.md'

// Get commit messages since last version tag
const getCommitMessages = (range) => {
  const log = execSync(`git log ${range} --format=%s --no-merges`, { encoding: 'utf-8' }).trim()
  return log ? log.split('\n') : []
}

let commitMessages = []
try {
  commitMessages = getCommitMessages(`v${currentVersion}..HEAD`)
} catch {
  // v<currentVersion> tag is missing (version was bumped without tagging) — fall back to the
  // most recent reachable tag so the changelog is not silently empty
  let fallbackTag
  try {
    fallbackTag = execSync('git describe --tags --abbrev=0', { encoding: 'utf-8' }).trim()
  } catch {
    // No tags at all — nothing to compare against, keep the empty section
    fallbackTag = null
  }
  if (fallbackTag) {
    log(`⚠ v${currentVersion} tag not found — using ${fallbackTag} as changelog base`, YELLOW)
    commitMessages = getCommitMessages(`${fallbackTag}..HEAD`)
  }
}

// Categorize by conventional commit type
const typeMap = {
  feat: 'Added',
  fix: 'Fixed',
  refactor: 'Changed',
  perf: 'Changed',
}
const categories = { Added: [], Changed: [], Fixed: [] }

for (const msg of commitMessages) {
  const match = msg.match(/^(\w+)(?:\(.+\))?:\s*(.+)/)
  if (!match) continue
  const [, type, description] = match
  const category = typeMap[type]
  if (!category) continue // skip: chore, ci, docs, style, test, build
  const desc = description.charAt(0).toUpperCase() + description.slice(1)
  categories[category].push(desc)
}

// Build section text
const date = new Date().toISOString().slice(0, 10)
const sectionLines = [`## [${newVersion}] - ${date}`]
for (const [category, items] of Object.entries(categories)) {
  if (items.length === 0) continue
  sectionLines.push('', `### ${category}`, '')
  for (const item of items) sectionLines.push(`- ${item}`)
}
const section = sectionLines.join('\n') + '\n'

// Read existing CHANGELOG.md
let changelog = readFileSync(changelogPath, 'utf-8')

// Derive repo URL from git remote for link reference. Never crash mid-run
// after package.json/CHANGELOG were mutated: fall back to the canonical URL.
let repoUrl = 'https://git.lightnode.ru/Slovo_Propovedi/slovo-propovedi-landing'
try {
  const remote = execSync('git remote get-url origin', { encoding: 'utf-8' }).trim()
  if (remote) {
    repoUrl = remote
      .replace(/^ssh:\/\/git@/, 'https://')
      .replace(/^git@([^:]+):/, 'https://$1/')
      .replace(/\.git$/, '')
  }
} catch {
  log('⚠ Could not read git remote origin — using default repo URL', YELLOW)
}
const linkRef = `[${newVersion}]: ${repoUrl}/src/tag/v${newVersion}`

// Guard: version must not already exist in changelog
if (changelog.includes(`## [${newVersion}]`)) {
  exitError(`Version ${newVersion} already exists in CHANGELOG.md`)
}

// Insert section after the intro paragraph (after the semver.org line),
// before the first existing version entry
changelog = changelog.replace(
  /(and this project adheres to \[Semantic Versioning\]\([^)]+\)\.\n)/,
  `$1\n${section}`
)

// Insert link reference before the first existing link reference line
if (!changelog.includes(`[${newVersion}]:`)) {
  changelog = changelog.replace(/^(\[.+?\]:)/m, `${linkRef}\n$1`)
}

writeFileSync(changelogPath, changelog)
log('✓ Updated CHANGELOG.md', GREEN)

// 3. index.html — bump the ?v= cache-busting query on the css/js references
// (idempotent: re-running with the same version leaves the file unchanged).
const indexPath = 'index.html'
const indexHtml = readFileSync(indexPath, 'utf-8')
const bumpedHtml = indexHtml.replace(
  /(\/assets\/(?:css\/main\.css|js\/main\.js))(?:\?v=[0-9]+\.[0-9]+\.[0-9]+)?/g,
  `$1?v=${newVersion}`
)
writeFileSync(indexPath, bumpedHtml)
log('✓ Updated index.html cache-busting (?v=)', GREEN)

// 4. package-lock.json — keep root and workspace version in sync with package.json
const lockPath = 'package-lock.json'
let lock

try {
  lock = JSON.parse(readFileSync(lockPath, 'utf-8'))
} catch (err) {
  exitError(`Failed to read or parse ${lockPath}: ${err.message}`)
}

if (lock.version === newVersion && (!lock.packages || !lock.packages[''] || lock.packages[''].version === newVersion)) {
  log(`>> ${lockPath} already at ${newVersion} — skipping`, YELLOW)
} else {
  lock.version = newVersion
  if (lock.packages && lock.packages['']) {
    lock.packages[''].version = newVersion
  }
  writeFileSync(lockPath, `${JSON.stringify(lock, null, 2)}\n`)
  log(`>> ${lockPath} → ${newVersion}`, GREEN)
}

// --- Git operations ---
log('\n→ Staging all changes...', YELLOW)
execSync('git add -A', { cwd: process.cwd() })

log('→ Committing...', YELLOW)
execSync(`git commit -s -m "chore: bump version to ${newVersion}"`, { cwd: process.cwd() })

log('→ Tagging...', YELLOW)
execSync(`git tag -a v${newVersion} -m "v${newVersion}"`, { cwd: process.cwd() })

// Verify the tag actually landed: `git tag -a` has been observed to exit 0
// without an error yet leave the ref missing.
try {
  execSync(`git rev-parse --verify -q v${newVersion}`, { cwd: process.cwd() })
} catch {
  exitError(`Tag v${newVersion} was not created despite 'git tag' reporting success. Run 'git tag -a v${newVersion} -m "v${newVersion}"' manually and verify with 'git tag -l'.`)
}

// --- Summary ---
log('\n══════════════════════════════════════', GREEN)
log('  Version bump complete!', GREEN)
log(`  ${currentVersion} → ${newVersion}`, GREEN)
log(`  Tag: v${newVersion}`, GREEN)
log('══════════════════════════════════════', GREEN)
log('  Reminder:  git push --follow-tags origin main', YELLOW)
log('══════════════════════════════════════\n', GREEN)
