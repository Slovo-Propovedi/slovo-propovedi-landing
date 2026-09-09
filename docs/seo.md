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
| `robots.txt` | `Allow: /` + `Sitemap: https://__LANDING_HOSTNAME__/sitemap.xml` |
| `sitemap.xml` | `<urlset>` в корне репо; хостнейм печётся из `__LANDING_HOSTNAME__` при сборке образа |
| Язык | `<html lang="ru">` |

### `sitemap.xml` — как добавлять страницы

Файл `sitemap.xml` в корне репо. Сейчас одна запись — главная. Плейсхолдер
`__LANDING_HOSTNAME__` в каждом `<loc>` заменяется на реальный хост при сборке
образа (Dockerfile `sed` по `index.html`, `robots.txt`, `sitemap.xml`). Локально
dev-server тоже подставляет хост.

**Новая страница лендинга → новый блок в `sitemap.xml`:**

```xml
<url>
  <loc>https://__LANDING_HOSTNAME__/новый-путь/</loc>
  <changefreq>monthly</changefreq>
</url>
```

`scripts/validate.mjs` требует: файл — валидный `<urlset>`, есть запись главной,
**каждый `<loc>` начинается с `https://__LANDING_HOSTNAME__/`** (литеральный хост
запрещён). Обновляй `sitemap.xml` в том же коммите, что и новую страницу.

### Пробелы (опциональные правки кода)

- [ ] **`<link rel="canonical" href="https://__LANDING_HOSTNAME__/">`** в `<head>`
      `index.html` — сейчас есть только `og:url`. Печётся тем же `sed`;
      добавить проверку в `scripts/validate.mjs`. При появлении второй страницы
      canonical станет обязателен на каждой.

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
| Яндекс.Вебмастер (приоритет — контент русский) | DNS TXT | ✅ подтверждён |
| Google Search Console (property: Domain — по DNS) | DNS TXT | ⬜ |
| Bing Webmaster Tools (питает DuckDuckGo) | Import from Google Search Console | ⬜ |

## Отправка sitemap

`sitemap.xml` появляется на проде только с релизом (тег `v*`) — сперва
`npm run bump-version` + push тега, потом заявка.

- **Google Search Console** → «Файлы Sitemap» → ввести **`sitemap.xml`**
  (путь относительно домена, без `https://` и без слэша впереди).
- **Яндекс.Вебмастер** → «Файлы Sitemap» → ввести **полный** URL
  `https://slovo-propovedi.ru/sitemap.xml`.
- **Bing** — подтянется вместе с импортом из Google Search Console.

> Если Google пишет «Файл Sitemap является страницей HTML» — значит запрос
> попал на `index.html` (файла ещё нет на проде / не тот путь). Проверь:
> `curl -sI https://slovo-propovedi.ru/sitemap.xml` → `content-type: text/xml`.

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
