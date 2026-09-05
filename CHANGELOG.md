# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.5.0] - 2026-09-05

### Added

- Platform-aware hero CTA (web version on iOS and desktop)

## [0.4.1] - 2026-09-05

### Fixed

- Address review nits — docs accuracy, BOM stripping, execFileSync, EOF newline

## [0.4.0] - 2026-09-05

### Added

- Local dev server with .env support replacing python http.server
- Drive /web and landing URLs from hostname env vars, open /web in new tab
- Add web-app fallback link via /web redirect (WEB_APP_URL)

### Fixed

- Harden WEB_APP_URL validation and add build-time nginx check

## [0.3.0] - 2026-09-01

### Added

- Brand identity, light/dark/system themes, and site polish

### Fixed

- Use the real app icon instead of the traced SVG

## [0.2.0] - 2026-09-01

### Added

- Screenshots gallery synced from mobile repo

### Fixed

- Harden screenshots validation, docs, and manifest-failure UX

## [0.1.0] - 2026-09-01

### Added

- Static landing page for the «Слово.Проповеди» Android app with direct APK download
- Self-hosted Cyrillic-capable typography (Unbounded display + Onest body) with latin/cyrillic subsets
- Ink-navy + gold manuscript-inspired theme with layered radial-gradient and grain atmosphere
- Staggered hero reveal animation (CSS-only, respects `prefers-reduced-motion`)
- Download metadata block populated from `/apk/latest.json` (version, size, date, SHA-256 with copy button)
- Android UA detection to switch CTA copy between «Установить приложение» and «Скачать APK»
- QR code block encoding `https://slovo-propovedi.ru` for on-phone download
- Feature cards, install instructions for Android 8+, and footer with docs/repo/license links
- nginx config with APK MIME mapping, security headers, and strict CSP (no inline scripts/styles)
- Dockerfile (nginx:alpine) with read-only `/apk` bind-mount placeholder and healthcheck
- Version bump script (`bump-version.mjs`) and QR regeneration script (`generate-qr.mjs`)

[0.5.0]: https://git.lightnode.ru/Slovo_Propovedi/slovo-propovedi-landing/src/tag/v0.5.0
[0.4.1]: https://git.lightnode.ru/Slovo_Propovedi/slovo-propovedi-landing/src/tag/v0.4.1
[0.4.0]: https://git.lightnode.ru/Slovo_Propovedi/slovo-propovedi-landing/src/tag/v0.4.0
[0.3.0]: https://git.lightnode.ru/Slovo_Propovedi/slovo-propovedi-landing/src/tag/v0.3.0
[0.2.0]: https://git.lightnode.ru/Slovo_Propovedi/slovo-propovedi-landing/src/tag/v0.2.0
[0.1.0]: https://git.lightnode.ru/Slovo_Propovedi/slovo-propovedi-landing/src/tag/v0.1.0
