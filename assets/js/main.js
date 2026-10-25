/* Слово.Проповеди — landing page behaviour.
   Vanilla JS, no frameworks. Populates download metadata from /apk/latest.json
   and adjusts the hero CTA for the visitor's platform: Android visitors see
   the APK download; iOS and desktop visitors see the web-app link. */

'use strict'

/* --- Adaptive releases link: Forgejo → Codeberg → GitHub ---
   The static hrefs in index.html point at the Forgejo releases page, so
   no-JS visitors (and visitors whose probes all fail) get the primary host.
   At boot we probe each host in priority order and upgrade the release links
   to the first one that answers. A fetch that RESOLVES counts as responding:
   any HTTP status is fine (404 just means "no releases yet", the host is up);
   only network errors and timeouts are failures. */
const RELEASES_FALLBACK_URL = 'https://git.lightnode.ru/Slovo_Propovedi/slovo-propovedi-mobile/releases'
const RELEASE_SOURCES = [
  {
    api: 'https://git.lightnode.ru/api/v1/repos/Slovo_Propovedi/slovo-propovedi-mobile/releases/latest',
    page: 'https://git.lightnode.ru/Slovo_Propovedi/slovo-propovedi-mobile/releases',
  },
  {
    api: 'https://codeberg.org/api/v1/repos/Slovo_Propovedi/slovo-propovedi-mobile/releases/latest',
    page: 'https://codeberg.org/Slovo_Propovedi/slovo-propovedi-mobile/releases',
  },
  {
    api: 'https://api.github.com/repos/Slovo-Propovedi/slovo-propovedi-mobile/releases/latest',
    page: 'https://github.com/Slovo-Propovedi/slovo-propovedi-mobile/releases',
  },
]
const RELEASE_PROBE_TIMEOUT = 4000

// Current releases page; showNotice reads it at the moment the notice shows,
// so the message is correct whether loadRelease wins or loses the race.
let resolvedReleasesUrl = RELEASES_FALLBACK_URL

const $ = (id) => document.getElementById(id)

/* --- Parse the latest.json payload into trusted fields --- */
const APK_FILENAME_RE = /^[\w.\-]+\.apk$/
const APK_DOWNLOAD_URL_RE = /^\/apk\/[\w.\-]+\.apk$/

function parseRelease(data) {
  if (!data || typeof data !== 'object') throw new Error('latest.json: payload is not an object')
  const { version, filename, size, sha256, date, downloadUrl } = data
  if (typeof version !== 'string' || !version) throw new Error('latest.json: missing version')
  // filename is used verbatim as the download attribute and must never carry a
  // path separator or whitespace (trust-chain: the CTA points wherever it says).
  if (typeof filename !== 'string' || !APK_FILENAME_RE.test(filename)) {
    throw new Error('latest.json: invalid filename')
  }
  if (typeof size !== 'number' || size < 0) throw new Error('latest.json: invalid size')
  if (typeof sha256 !== 'string' || !/^[0-9a-f]{64}$/i.test(sha256)) throw new Error('latest.json: invalid sha256')
  if (typeof date !== 'string' || Number.isNaN(Date.parse(date))) throw new Error('latest.json: invalid date')
  // downloadUrl must be a same-origin path under the /apk mount; anything else
  // (absolute URLs, other origins, non-strings) falls back to the derived path.
  const trustedDownloadUrl =
    typeof downloadUrl === 'string' && APK_DOWNLOAD_URL_RE.test(downloadUrl)
      ? downloadUrl
      : `/apk/${filename}`
  return { version, filename, size, sha256, date, downloadUrl: trustedDownloadUrl }
}

/* --- Pure formatters --- */
function formatSize(bytes) {
  return `${(bytes / (1024 * 1024)).toLocaleString('ru-RU', { maximumFractionDigits: 1 })} МБ`
}

function formatDate(iso) {
  return new Date(iso).toLocaleDateString('ru-RU', { day: 'numeric', month: 'long', year: 'numeric' })
}

/* --- Render metadata into the DOM --- */
function renderRelease(release) {
  $('meta-version').textContent = release.version
  $('meta-size').textContent = formatSize(release.size)
  $('meta-date').textContent = formatDate(release.date)
  const sha = $('meta-sha256')
  sha.textContent = release.sha256
  sha.title = release.sha256

  // On Android the primary button is the APK download; on iOS/desktop the
  // alt-line link below the button carries the APK link instead.
  const apkLink = IS_ANDROID ? $('download-btn') : $('alt-link')
  apkLink.href = release.downloadUrl
  apkLink.setAttribute('download', release.filename)

  // SHA copy is only meaningful once real metadata is rendered.
  $('sha-copy').disabled = false
}

/* --- Gentle notice when metadata cannot be fetched --- */
function showNotice(message) {
  const note = $('download-note')
  note.textContent = message
  note.hidden = false
}

/* --- Adaptive releases link resolution (see RELEASE_SOURCES above) --- */
async function probeReleaseHost(source) {
  const controller = new AbortController()
  // ~4s per source: enough for a slow host, short enough to move on quickly.
  const timer = setTimeout(function () { controller.abort() }, RELEASE_PROBE_TIMEOUT)
  try {
    await fetch(source.api, { cache: 'no-store', signal: controller.signal })
    return true
  } catch (error) {
    console.warn(error)
    return false
  } finally {
    clearTimeout(timer)
  }
}

function applyReleasesUrl(url) {
  resolvedReleasesUrl = url
  // Anchors still carrying the static fallback href: the «Другие версии»
  // button, the footer «Релизы» link, and download-btn only while latest.json
  // has not replaced it with the APK link (the non-Android CTA points at /web).
  document.querySelectorAll(`a[href="${RELEASES_FALLBACK_URL}"]`).forEach(function (link) {
    link.href = url
  })
}

async function resolveReleasesUrl() {
  for (const source of RELEASE_SOURCES) {
    if (await probeReleaseHost(source)) {
      applyReleasesUrl(source.page)
      return
    }
  }
  // All probes failed — keep the static primary fallback.
}

/* --- Platform detection (once at boot, reused in renderRelease) --- */
const IS_ANDROID = /android/i.test(navigator.userAgent)

/* --- Platform-aware CTA: swap button & alt-line for non-Android visitors --- */
function adjustCtaForPlatform() {
  // Static HTML is the Android/no-JS variant — nothing to do.
  if (IS_ANDROID) return

  const btn = $('download-btn')
  const btnLabel = $('download-btn-label')
  const iconDl = $('icon-download')
  const iconWeb = $('icon-web')
  const altLead = $('alt-lead')
  const altLink = $('alt-link')

  // Primary button → web-app link
  btn.href = '/web'
  btn.target = '_blank'
  btn.rel = 'noopener'
  btn.removeAttribute('download')
  btnLabel.textContent = 'Открыть веб-версию'
  // toggleAttribute (not the .hidden property): `hidden` as an IDL reflector
  // lives on HTMLElement and is not inherited by SVG elements, so a plain
  // assignment would never reach the attribute the CSS guard matches on.
  iconDl.toggleAttribute('hidden', true)
  iconWeb.toggleAttribute('hidden', false)

  // Alt line → APK download (swapped roles)
  altLead.textContent = 'Хотите установить приложение на Android?'
  altLink.textContent = 'Скачайте APK'
  // Safe fallback until latest.json loads; renderRelease overwrites with the
  // real download URL.
  altLink.href = resolvedReleasesUrl
  altLink.setAttribute('download', '')
  altLink.removeAttribute('target')
  altLink.removeAttribute('rel')
}

/* --- Copy SHA-256 to clipboard with feedback --- */
function setupShaCopy() {
  const button = $('sha-copy')
  const sha = $('meta-sha256')
  if (!button || !sha) return

  // aria-live on the button itself: its text swaps between the label and the
  // feedback, so screen readers announce the change without a separate region.
  button.setAttribute('aria-live', 'polite')
  button.disabled = true

  button.addEventListener('click', async () => {
    const value = sha.title || sha.textContent
    try {
      await navigator.clipboard.writeText(value)
      button.textContent = 'Скопировано ✓'
    } catch {
      button.textContent = 'Ошибка'
    }
    setTimeout(() => {
      button.textContent = 'Копировать'
    }, 2000)
  })
}

/* --- Theme toggle --- */
function applyTheme(mode) {
  // Parse, Don't Validate: accept only known literals at the boundary.
  const parsed = (mode === 'light' || mode === 'dark' || mode === 'system')
    ? mode
    : 'system'
  const prefersDark = window.matchMedia('(prefers-color-scheme: dark)').matches
  const theme = parsed === 'light' ? 'light'
    : parsed === 'dark' ? 'dark'
    : (prefersDark ? 'dark' : 'light')
  document.documentElement.dataset.theme = theme
  const meta = document.querySelector('meta[name="theme-color"]')
  if (meta) meta.content = theme === 'dark' ? '#000' : '#fff'
  const buttons = document.querySelectorAll('.theme-toggle button[data-mode]')
  buttons.forEach(function (btn) {
    btn.setAttribute('aria-pressed', String(btn.dataset.mode === parsed))
  })
}

function setupThemeToggle() {
  const buttons = document.querySelectorAll('.theme-toggle button[data-mode]')
  if (!buttons.length) return

  // Parse, Don't Validate: read localStorage once at boot; corrupt or
  // unknown values fall back to 'system'.
  let persistedMode = 'system'
  try {
    const stored = localStorage.getItem('theme-mode')
    if (stored === 'light' || stored === 'dark' || stored === 'system') {
      persistedMode = stored
    }
  } catch {}
  applyTheme(persistedMode)

  buttons.forEach(function (btn) {
    btn.addEventListener('click', function () {
      const mode = btn.dataset.mode
      persistedMode = mode
      try { localStorage.setItem('theme-mode', mode) } catch {}
      applyTheme(mode)
    })
  })

  window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', function () {
    if (persistedMode === 'system') applyTheme('system')
  })
}

/* --- Boot --- */
async function loadRelease() {
  try {
    const response = await fetch('/apk/latest.json', { cache: 'no-store' })
    if (!response.ok) throw new Error(`latest.json: HTTP ${response.status}`)
    const release = parseRelease(await response.json())
    renderRelease(release)
  } catch (error) {
    // Keep the no-JS fallback href (releases page) and inform the visitor.
    showNotice(`Не удалось получить данные о версии. Скачайте APK со страницы релизов: ${resolvedReleasesUrl}`)
    console.warn(error)
  }
}

/* --- Parse the screenshots manifest into trusted fields --- */
const SCREENSHOT_FILE_RE = /^[A-Za-z0-9_][A-Za-z0-9._-]*\.png$/
const SHA40_RE = /^[0-9a-f]{40}$/i
// The manifest order is not guaranteed natural (old manifests are lexicographic,
// and `sort -V` / ICU collation can disagree), so the gallery enforces natural
// order (…, 9, 10, 11) itself.
const SCREENSHOT_ORDER = new Intl.Collator('en', { numeric: true, sensitivity: 'base' })

function parseScreenshotsManifest(data) {
  if (!data || typeof data !== 'object') throw new Error('manifest.json: payload is not an object')
  const { images } = data
  if (!Array.isArray(images)) throw new Error('manifest.json: images is not an array')
  // Fail-closed: any malformed entry rejects the whole manifest so the gallery
  // never renders a file that could point outside the /screenshots mount.
  return images
    .map((entry, index) => {
      if (!entry || typeof entry !== 'object') throw new Error(`manifest.json: images[${index}] is not an object`)
      const { file, sha, size } = entry
      if (typeof file !== 'string' || !SCREENSHOT_FILE_RE.test(file)) {
        throw new Error(`manifest.json: images[${index}] invalid file`)
      }
      if (typeof sha !== 'string' || !SHA40_RE.test(sha)) {
        throw new Error(`manifest.json: images[${index}] invalid sha`)
      }
      if (typeof size !== 'number' || !Number.isFinite(size) || size <= 0) {
        throw new Error(`manifest.json: images[${index}] invalid size`)
      }
      return { file, sha, size }
    })
    .sort((a, b) => SCREENSHOT_ORDER.compare(a.file, b.file))
}

/* --- Caption map keyed by stem (may drift; the fallback always applies) --- */
const SCREENSHOT_CAPTIONS = {
  'about-screen': 'О приложении',
  'fullscreen-player': 'Плеер на весь экран',
  'history-screen': 'История прослушивания',
  'listen-screen-dark': 'Слушать (тёмная тема)',
  'listen-screen-white': 'Слушать (светлая тема)',
  'menu-in-fullscreen-player': 'Меню в полноэкранном плеере',
  'more-screen': 'Ещё',
  'playlist-in-bottomsheet': 'Плейлист в нижней панели',
  'playlist-screen-dark': 'Плейлист (тёмная тема)',
  'playlists-list-screen': 'Список плейлистов',
  'search-screen-dark': 'Поиск (тёмная тема)',
  'settings-screen': 'Настройки',
  'share-screen': 'Поделиться',
}

function screenshotSrc(file) {
  return `/screenshots/${file}`
}

function screenshotAlt(file) {
  // Manifest filenames are <stem>-<sha8>.png; strip the sha suffix to recover
  // the original stem the caption map is keyed by.
  const stem = file.replace(/-[0-9a-fA-F]{8}\.png$/, '')
  return SCREENSHOT_CAPTIONS[stem] || 'Скриншот интерфейса'
}

/* --- Render the gallery into the DOM (createElement/textContent only) --- */
function renderScreenshots(images) {
  const list = $('screenshots-list')
  if (!list) return
  const fragment = document.createDocumentFragment()
  for (const entry of images) {
    const li = document.createElement('li')
    li.className = 'screenshot-item'

    const frame = document.createElement('figure')
    frame.className = 'screenshot-frame'

    const img = document.createElement('img')
    img.className = 'screenshot-img'
    img.src = screenshotSrc(entry.file)
    img.alt = screenshotAlt(entry.file)
    img.loading = 'lazy'
    img.decoding = 'async'
    // Intrinsic size matches the mobile repo's canonical screenshot resolution
    // (assets/screenshots/*.png, 1080×2340) — update both if that ever changes.
    img.width = 1080
    img.height = 2340
    // Fade the frame in once the image is ready (reduced-motion handled in CSS)
    const reveal = () => frame.classList.add('is-loaded')
    img.addEventListener('load', reveal, { once: true })
    img.addEventListener('error', reveal, { once: true })

    frame.appendChild(img)
    li.appendChild(frame)
    fragment.appendChild(li)
  }
  list.appendChild(fragment)
}

/* --- Boot --- */
async function loadScreenshots() {
  try {
    const response = await fetch('/screenshots/manifest.json', { cache: 'no-store' })
    if (!response.ok) throw new Error(`manifest.json: HTTP ${response.status}`)
    renderScreenshots(parseScreenshotsManifest(await response.json()))
    // Gallery rendered — reveal the section and its nav link.
    const section = $('screenshots')
    const nav = $('nav-screenshots')
    if (section) section.hidden = false
    if (nav) nav.hidden = false
  } catch (error) {
    // Fail-closed: hide the whole section and its nav link so there is no empty
    // gallery or dead anchor when the manifest cannot be fetched.
    const section = $('screenshots')
    const nav = $('nav-screenshots')
    if (section) section.hidden = true
    if (nav) nav.hidden = true
    console.warn(error)
  }
}

adjustCtaForPlatform()
setupShaCopy()
setupThemeToggle()
loadRelease()
loadScreenshots()
// Non-blocking: links keep the static Forgejo fallback until a probe resolves.
resolveReleasesUrl()
