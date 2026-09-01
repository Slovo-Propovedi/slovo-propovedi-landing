/* Слово.Проповеди — pre-paint theme application.
   Blocking script: sets data-theme on <html> before first paint.
   Read by assets/js/main.js which handles user switching. */

'use strict'
;(function () {
  const prefersDark = window.matchMedia('(prefers-color-scheme: dark)').matches
  let stored = null
  try { stored = localStorage.getItem('theme-mode') } catch {}
  // Parse, Don't Validate: accept only known literals; anything else
  // (corrupt, legacy, wrong type) falls back to 'system'.
  const mode = (stored === 'light' || stored === 'dark' || stored === 'system')
    ? stored
    : 'system'
  const theme = mode === 'light' ? 'light'
    : mode === 'dark' ? 'dark'
    : (prefersDark ? 'dark' : 'light')
  document.documentElement.dataset.theme = theme
  // Pre-paint the mobile browser chrome: main.js (end of body) also updates
  // this, but only here can it happen before first paint.
  const meta = document.querySelector('meta[name="theme-color"]')
  if (meta) meta.content = theme === 'dark' ? '#000' : '#fff'
})()
