# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.2.0]: https://git.lightnode.ru/Slovo_Propovedi/slovo-propovedi-landing/src/tag/v0.2.0
[0.1.0]: https://git.lightnode.ru/Slovo_Propovedi/slovo-propovedi-landing/src/tag/v0.1.0
