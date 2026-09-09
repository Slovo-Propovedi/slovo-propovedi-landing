# SEO и индексация

Ранбук по заявке лендинга `https://slovo-propovedi.ru` в поисковики. Делается
один раз; статус отмечать здесь же.

## Что уже есть на странице (`index.html`)

| Элемент | Значение |
|---|---|
| `<title>` | «Слово.Проповеди — слушайте христианские проповеди на Android» |
| `<meta name="description">` | есть, ~250 симв. |
| Open Graph | `og:type`, `og:site_name`, `og:title`, `og:description`, `og:url`, `og:locale=ru_RU`, `og:image` (1200×630, `assets/img/og.png`), `og:image:alt` |
| Twitter Card | `summary_large_image` |
| `og:url` / `og:image` | абсолютные, хостнейм печётся из `__LANDING_HOSTNAME__` при сборке образа (Dockerfile `sed`) |
| `robots.txt` | `Allow: /` (в корне, отдаётся nginx) |
| Язык | `<html lang="ru">` |

### Пробелы (опциональные правки кода)

- [ ] **`<link rel="canonical" href="https://__LANDING_HOSTNAME__/">`** в `<head>`
      — сейчас есть только `og:url`. Печётся тем же `sed`, что и `og:url`;
      добавить проверку в `scripts/validate.mjs`.
- [ ] **`sitemap.xml`** (одна запись — главная). Для одностраничника ценность
      небольшая, но Яндекс/Google любят наличие карты. Реализация: статический
      `sitemap.xml` с `https://__LANDING_HOSTNAME__/`, `COPY` в Dockerfile,
      `sed` хостнейма, строка `Sitemap:` в `robots.txt`, чек в `validate.mjs`.

## Верификация в вебмастерах

**Рекомендуемый метод — DNS TXT-запись** (verified apex + `www` сразу, без правок
кода и без пересборки образа):

1. В вебмастере выбрать «подтверждение через DNS», скопировать TXT-значение.
2. Добавить TXT-запись в зону `slovo-propovedi.ru`.
3. Нажать «Подтвердить».

Альтернатива без DNS — **мета-тег** в `<head>` `index.html`
(`<meta name="yandex-verification" ...>` / `<meta name="google-site-verification" ...>`),
поедет на прод только с релизом (тег `v*`). HTML-файл в корне — хуже всего:
требует `COPY` в Dockerfile на каждый токен.

| Поисковик | Метод | Статус |
|---|---|---|
| Яндекс.Вебмастер (приоритет — контент русский) | HTML-файл `yandex_322942122d3b9266.html` (в корне репо, `COPY` в Dockerfile) | ⬜ подтвердить после релиза |
| Google Search Console (property: Domain — по DNS) | DNS TXT | ⬜ |
| Bing Webmaster Tools (питает DuckDuckGo) | Import from Google Search Console | ⬜ |

> Файл верификации едет на прод только с релизом (тег `v*`). Каждый
> `yandex_*.html` / `google*.html` в корне должен быть в `COPY` Dockerfile —
> это проверяет `scripts/validate.mjs`. Локально dev-server их тоже отдаёт.

## Отправка sitemap / URL

- Если добавлен `sitemap.xml` — отправить `https://slovo-propovedi.ru/sitemap.xml`
  в каждом вебмастере.
- Если нет — вручную добавить главную (`https://slovo-propovedi.ru/`) и запросить
  индексацию:
  - Google Search Console → «Проверка URL» → «Запросить индексирование».
  - Яндекс.Вебмастер → «Индексирование» → «Переобход страниц».

| Яндекс | Google | Bing |
|---|---|---|
| ⬜ | ⬜ | ⬜ |

## Бэклинки

Ключевой фактор для нового домена. Проставить ссылку на `slovo-propovedi.ru`:

- [ ] описание Android-приложения (Google Play / F-Droid / RuStore, если публикуется)
- [ ] репозиторий мобильного приложения `git.lightnode.ru/Slovo_Propovedi/slovo-propovedi-mobile` — README
- [ ] соцсети / каналы проекта, закреплённые сообщения
- [ ] тематические каталоги христианских приложений

## Не индексировать

`/apk/*.apk`, `/apk/latest.json`, `/screenshots/*` — это ассеты, не контент.
Отдельно закрывать не обязательно (единственная смысловая страница — главная), но
если понадобится — добавить `Disallow: /apk/` в `robots.txt`.

## Ожидания по срокам

- **Яндекс** — дни–недели после заявки.
- **Google** — недели.
- **DuckDuckGo** — только после попадания в индекс **Bing**.
- Новый домен без бэклинков индексируется 1–6 месяцев.
