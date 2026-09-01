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

adjustCtaForAndroid()
setupShaCopy()
loadRelease()
