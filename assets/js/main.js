/* Слово.Проповеди — landing page behaviour.
   Vanilla JS, no frameworks. Populates download metadata from /apk/latest.json
   and adjusts the CTA for Android devices. */

'use strict'

const RELEASES_URL = 'https://git.lightnode.ru/Slovo_Propovedi/slovo-propovedi-mobile/releases'

const $ = (id) => document.getElementById(id)

/* --- Parse the latest.json payload into trusted fields --- */
function parseRelease(data) {
  if (!data || typeof data !== 'object') throw new Error('latest.json: payload is not an object')
  const { version, filename, size, sha256, date, downloadUrl } = data
  if (typeof version !== 'string' || !version) throw new Error('latest.json: missing version')
  if (typeof filename !== 'string' || !filename) throw new Error('latest.json: missing filename')
  if (typeof size !== 'number' || size < 0) throw new Error('latest.json: invalid size')
  if (typeof sha256 !== 'string' || !/^[0-9a-f]{64}$/i.test(sha256)) throw new Error('latest.json: invalid sha256')
  if (typeof date !== 'string' || Number.isNaN(Date.parse(date))) throw new Error('latest.json: invalid date')
  return { version, filename, size, sha256, date, downloadUrl: downloadUrl || `/apk/${filename}` }
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

  button.addEventListener('click', async () => {
    const value = sha.title || sha.textContent
    try {
      await navigator.clipboard.writeText(value)
      button.textContent = 'Скопировано ✓'
      button.setAttribute('aria-pressed', 'true')
    } catch {
      button.textContent = 'Ошибка'
    }
    setTimeout(() => {
      button.textContent = 'Копировать'
      button.removeAttribute('aria-pressed')
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
    showNotice('Не удалось получить данные о версии. Скачайте APK со страницы релизов.')
    console.warn(error)
  }
}

adjustCtaForAndroid()
setupShaCopy()
loadRelease()
