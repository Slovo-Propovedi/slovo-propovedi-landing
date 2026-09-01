/* Слово.Проповеди — landing page behaviour.
   Vanilla JS, no frameworks. Populates download metadata from /apk/latest.json
   and adjusts the CTA for Android devices. */

'use strict'

const RELEASES_URL = 'https://git.lightnode.ru/Slovo_Propovedi/slovo-propovedi-mobile/releases'

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

  const btn = $('download-btn')
  btn.href = release.downloadUrl
  btn.setAttribute('download', release.filename)

  // SHA copy is only meaningful once real metadata is rendered.
  $('sha-copy').disabled = false
}

/* --- Gentle notice when metadata cannot be fetched --- */
function showNotice(message) {
  const note = $('download-note')
  note.textContent = message
  note.hidden = false
}

/* --- Android UA detection adjusts the CTA copy --- */
function isAndroid() {
  return /android/i.test(navigator.userAgent)
}

function adjustCtaForAndroid() {
  if (isAndroid()) {
    $('download-btn').textContent = 'Установить приложение'
  }
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
    showNotice(`Не удалось получить данные о версии. Скачайте APK со страницы релизов: ${RELEASES_URL}`)
    console.warn(error)
  }
}

/* --- Parse the screenshots manifest into trusted fields --- */
const SCREENSHOT_FILE_RE = /^[A-Za-z0-9_][A-Za-z0-9._-]*\.png$/
const SHA40_RE = /^[0-9a-f]{40}$/i

function parseScreenshotsManifest(data) {
  if (!data || typeof data !== 'object') throw new Error('manifest.json: payload is not an object')
  const { images } = data
  if (!Array.isArray(images)) throw new Error('manifest.json: images is not an array')
  // Fail-closed: any malformed entry rejects the whole manifest so the gallery
  // never renders a file that could point outside the /screenshots mount.
  return images.map((entry, index) => {
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

adjustCtaForAndroid()
setupShaCopy()
setupThemeToggle()
loadRelease()
loadScreenshots()
