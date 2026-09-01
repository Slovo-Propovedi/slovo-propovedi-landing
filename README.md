# Слово.Проповеди — Landing page

Лендинг для Android-приложения «[Слово.Проповеди](https://git.lightnode.ru/Slovo_Propovedi/slovo-propovedi-mobile)» —
прямая загрузка APK без магазинов.
Работает на <https://slovo-propovedi.ru>.

## Как работает загрузка APK

APK-файлы не хранятся в этом репозитории. Скрипт обновления
(`scripts/vps-refresh-apk.sh`) работает на VPS и выполняет следующее:

1. Дважды в день по таймеру `slovo-landing-refresh.timer` (04:30 / 16:30 UTC,
   `RandomizedDelaySec=30m`), а также пост-деплой и вручную через
   `refresh-apk.yml` (workflow_dispatch).
2. Загружает последний релиз мобильного приложения с Forgejo (первичный) или
   GitHub (резервный). Если уже обслуживаемая версия совпадает — выход 0 без
   повторной загрузки ~30MB архива.
3. Извлекает APK, публикует `slovo-propovedi-vX.Y.Z.apk` и `latest.json`
   (версия, размер, SHA-256, дата) в `/slovo/landing/apk`, который nginx отдаёт
   с MIME-типом `application/vnd.android.package-archive`.
4. Страница показывает версию, размер и SHA-256 с кнопкой копирования и QR-кодом
   для скачивания с телефона.
5. Хранятся последние 3 версии (`KEEP_VERSIONS=3`); при ошибке сохраняется
   предыдущее состояние.

Токены для API (если репозитории приватные или rate-limited) хранятся в
`/slovo/landing/tokens/` (root-only 0700).

## Скриншоты

Скриншоты **не хранятся в этом репозитории**. Скрипт
(`scripts/vps-refresh-screenshots.sh`) работает на VPS и выполняет следующее:

1. Дважды в день по таймеру `slovo-landing-refresh-shots.timer` (04:30 / 16:30 UTC,
   `RandomizedDelaySec=30m`), а также пост-деплой.
2. Получает git-дерево мобильного репозитория (Forgejo — первичный, GitHub —
   резервный) и выбирает канонические PNG из `assets/screenshots/`.
3. Проверяет каждый файл: магические байты PNG и git-blob sha1
   (`sha1("blob <size>\0" + содержимое)` должен совпасть с sha из дерева).
4. Публикует файлы с именами `<stem>-<sha8>.png` (sha в имени → immutable-кеш)
   и `manifest.json` (fingerprint, updatedAt, sourceUrl, sourcePath, images)
   в `/slovo/landing/screenshots`, который nginx отдаёт как `/screenshots`.
5. Если fingerprint уже совпадает с удалённым деревом — выход 0 без повторной
   загрузки и перезаписи (устаревшие файлы всё равно удаляются — галерея
   самовосстанавливается).
   При ошибке сохраняется предыдущее состояние (keep-last-good).

Страница показывает галерею из `manifest.json` с обязательной строкой
«Скриншоты: © 2026 Slovo.Propovedi, GPL-3.0-or-later» (лицензия GPL-3.0-or-later
из REUSE.toml мобильного репозитория).

## Разработка

### Запуск локально

```bash
docker build -t slovo-propovedi-landing .
docker run --rm -p 8080:8080 \
  -v /path/to/apk+latest.json:/usr/share/nginx/html/apk:ro \
  slovo-propovedi-landing
```

Для локального тестирования положите APK и `latest.json` в директорию
`test-apk/` (gitignored).

### npm-команды

```bash
npm ci                           # установка зависимостей (husky)
npm run validate                 # проверка согласованности файлов (CI parity)
npm run generate-qr              # пересоздать assets/img/qr.svg (DOMAIN-PINNED к https://slovo-propovedi.ru)
npm run generate-og              # пересоздать assets/img/og.png (нужен rsvg-convert или ImageMagick)
npm run dev                      # локальный просмотр на http://localhost:8377 (остановка Ctrl+C)
```

## Процесс релиза

1. **Bump версии:**
   ```bash
   npm run bump-version <version|patch|minor|major>
   ```
   Скрипт обновляет `package.json`, `CHANGELOG.md`, `package-lock.json` и
   `?v=` cache-busting в `index.html` (включая `theme-init.js`), коммитит с
   DCO signoff и создаёт тег `vX.Y.Z`.

2. **Пush:**
   ```bash
   git push --follow-tags origin main
   ```

3. **CI проверяет** (`ci.yml`): `npm run validate` на ubuntu-24.04.

4. **Тег запускает `release.yml`:**
   - Проверяет согласованность версий (tag vs package.json).
   - Ждёт прохождения CI на закоммиченном коммите.
   - Передаёт исходный код на VPS через tar+ssh.
   - Запускает `scripts/vps-deploy.sh` (buildx-сборка, read-only контейнер за
     Traefik с apex + www хостами и www→apex редиректом, LE-сертификат).
   - Прокидывает опциональные токены и запускает обновление APK.
   - Создаёт Forgejo Release с секцией из CHANGELOG.md.

## Настройка нового VPS

1. Создайте репозиторий в организации Slovo_Propovedi на
   `git.lightnode.ru` и запушьте main.
2. Добавьте секреты (Settings → Actions → Secrets):

   | Секрет | Описание |
   |---|---|
   | `VPS_SSH_PRIVATE_KEY` | SSH-ключ (ed25519) для доступа к VPS |
   | `VPS_HOST` | Хостнейм или IP VPS |
   | `VPS_SSH_USER` | SSH-пользователь на VPS |
   | `ACME_EMAIL` | Email для Let's Encrypt |
   | `FORGEJO_API_TOKEN` | (опционально) токен Forgejo API |
   | `GITHUB_MIRROR_TOKEN` | (опционально) токен GitHub API |

3. Раннер: `ubuntu-24.04`.
4. DNS: A-записи для apex (`slovo-propovedi.ru`) и `www` указывают на VPS.
5. Первый релиз — тег `v0.1.0`.

## Лицензия

Приложение распространяется под лицензией **GPL-3.0-or-later** — см.
[репозиторий мобильного приложения](https://git.lightnode.ru/Slovo_Propovedi/slovo-propovedi-mobile).

## Атрибуция

- **Иконка приложения** (`assets/img/icon.png`, логотип в шапке) — это иконка
  приложения «Слово.Проповеди», скопированная без изменений из мобильного
  репозитория. Распространяется под **GPL-3.0-or-later** (та же лицензия, что и
  у ассетов приложения).
- **Иконки интерфейса** — Ionicons v5 (<https://ionicons.com>), © Ionic — MIT
  (<https://github.com/ionic-team/ionicons/blob/main/LICENSE>).
