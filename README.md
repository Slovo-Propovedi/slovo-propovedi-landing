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
2. Загружает последний релиз мобильного приложения: Forgejo (первичный), затем
   зеркало Codeberg, затем зеркало GitHub — первый успешный источник побеждает. Если уже обслуживаемая версия совпадает — выход 0 без
   повторной загрузки ~30MB архива. Если у последнего релиза вообще нет
   APK-ассета (JS-only релиз, доставляется по OTA) — выход 0 с поясняющей
   строкой в логе: обновлять нечего, а фолбэк на зеркало отдал бы более
   старую версию как «последнюю».
3. Проверяет архив (только https, лимит размера распаковки против zip-бомбы)
   и **подпись APK**: `apksigner` должен подтвердить подпись, а SHA-256
   сертификата — совпасть с закреплённым отпечатком release-ключа
   (`APK_SIGNER_SHA256` в скрипте; тот же, что в `public/.well-known/assetlinks.json`
   мобильного репозитория). APK с чужой подписью не публикуется ни из одного
   источника — взлом хоста релизов или зеркала не подсунет подделку новым
   пользователям. Отпечаток публичен, секретен только ключ; при смене ключа
   подписи обновить его вместе с `assetlinks.json`.
4. Извлекает APK, публикует `slovo-propovedi-vX.Y.Z.apk` и `latest.json`
   (версия, размер, SHA-256, дата) в `/slovo/landing/apk`, который nginx отдаёт
   с MIME-типом `application/vnd.android.package-archive`.
5. Страница показывает версию, размер и SHA-256 с кнопкой копирования и QR-кодом
   для скачивания с телефона.
6. Хранятся последние 3 версии (`KEEP_VERSIONS=3`); при ошибке сохраняется
   предыдущее состояние.

Ссылки на страницу релизов адаптивные: `assets/js/main.js` последовательно
проверяет доступность API Forgejo (`git.lightnode.ru`), затем Codeberg, затем
GitHub и подставляет первую ответившую страницу релизов в кнопки «Другие
версии» и «Релизы» (а также в резервный href кнопки скачивания, пока
`latest.json` не заменил его на APK). Проверка — GET с `cache: 'no-store'` и
таймаутом 4 с на источник; ответом считается любой HTTP-статус (404 — «релизов
ещё нет», хост жив), сбой — только сетевая ошибка или таймаут. Без JS и при
недоступности всех трёх хостов остаётся статическая ссылка Forgejo из
`index.html`. CSP (`nginx.conf`) разрешает `connect-src` только для этих трёх
хостов.

Оба скрипта обновления работают **не от root**: systemd-юниты запускают их от
пользователя `slovo` в песочнице (`ProtectSystem=strict`, запись только в свой
каталог `apk/` или `screenshots/`, `NoNewPrivileges`, без capabilities).
Конфигурация (`/etc/default/slovo-landing`) читается как данные
(`EnvironmentFile=`), а не исполняется как shell. Зависимости (`curl`, `jq`,
`unzip`, `apksigner`) ставит `vps-deploy.sh` от root.

Токены для API (если репозитории приватные или rate-limited) хранятся в
`/slovo/landing/tokens/` (root-only 0700) и передаются юнитам через systemd
`LoadCredential=` — сам пользователь `slovo` и контейнер прочитать их не могут.

## Скриншоты

Скриншоты **не хранятся в этом репозитории**. Скрипт
(`scripts/vps-refresh-screenshots.sh`) работает на VPS и выполняет следующее:

1. Дважды в день по таймеру `slovo-landing-refresh-shots.timer` (04:30 / 16:30 UTC,
   `RandomizedDelaySec=30m`), а также пост-деплой.
2. Получает git-дерево мобильного репозитория (Forgejo — первичный, затем
   зеркала Codeberg и GitHub) и выбирает канонические PNG из `assets/screenshots/`.
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
npm run dev                      # локальный просмотр на http://localhost:8377 (Node, читает .env; остановка Ctrl+C)
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

> **Граница ответственности.** `vps-deploy.sh` владеет только контейнером
> `slovo-landing`, его сетью `slovo-landing` и таймерами обновления APK/скриншотов.
> Общая инфра — Docker, пользователь `slovo`, buildx-билдер `slovo-constrained`,
> Traefik (`slovo-traefik.service`) и сеть `traefik` — принадлежит внешнему
> `slovo-propovedi-playbook` и должна быть развёрнута заранее (`just setup-all`).
> Скрипт её только проверяет и падает с ошибкой, если чего-то нет.

## Настройка нового VPS

1. Создайте репозиторий в организации Slovo_Propovedi на
   `git.lightnode.ru` и запушьте main.
2. Разверните общую инфру на VPS через `slovo-propovedi-playbook` (`just setup-all`) —
   Docker, пользователь `slovo`, buildx-билдер, Traefik.
3. Добавьте секреты (Settings → Actions → Secrets):

   | Секрет | Описание |
   |---|---|
   | `VPS_SSH_PRIVATE_KEY` | SSH-ключ (ed25519) для доступа к VPS |
   | `VPS_SSH_KNOWN_HOSTS` | Закреплённый ключ хоста VPS: вывод `ssh-keyscan <VPS_HOST> 2>/dev/null`, сверенный с отпечатками на сервере. Без него деплой падает: `ssh-keyscan` на каждом прогоне не используется, так как не защищает от подмены сервера |
   | `VPS_HOST` | Хостнейм или IP VPS |
   | `VPS_SSH_USER` | SSH-пользователь на VPS |
   | `REPOSITORY_API_TOKEN` | (опционально) API-токен инстанса с репозиториями |
   | `GITHUB_MIRROR_TOKEN` | (опционально) токен GitHub API |

   И переменные (Settings → Actions → Variables) — все обязательны, релиз
   проверяет их до деплоя (URL — только `https://`):

   | Переменная | Пример |
   |---|---|
   | `LANDING_HOSTNAME` / `WWW_HOSTNAME` | `slovo-propovedi.ru` / `www.slovo-propovedi.ru` |
   | `WEB_HOSTNAME` / `DOCS_HOSTNAME` | `app.slovo-propovedi.ru` / `docs.slovo-propovedi.ru` |
   | `REPOSITORY_URL` | `https://git.lightnode.ru` |
   | `MIRROR_CODEBERG_URL` | `https://codeberg.org` |
   | `MIRROR_GITHUB_LATEST_RELEASE_URL` | `https://api.github.com/repos/Slovo-Propovedi/slovo-propovedi-mobile/releases/latest` |
   | `MIRROR_GITHUB_SCREENSHOTS_RAW_URL` | `https://raw.githubusercontent.com/Slovo-Propovedi/slovo-propovedi-mobile/main/assets/screenshots` |

4. Раннер: `ubuntu-24.04`.
5. DNS: A-записи для apex (`slovo-propovedi.ru`) и `www` указывают на VPS.
6. Первый релиз — тег `v0.1.0`.

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
