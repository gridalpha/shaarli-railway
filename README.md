# Shaarli on Railway

A one-layer image on top of the official [`ghcr.io/shaarli/shaarli`](https://github.com/shaarli/Shaarli/pkgs/container/shaarli)
that makes [Shaarli](https://github.com/shaarli/Shaarli) — the database-free personal
bookmarking service — deployable on Railway with no manual setup step: the
administrator account exists before the container ever accepts a request.

## Why this layer exists

Shaarli has **no environment-variable configuration path at all**. Everything lives in
`data/config.json.php`, which its web installer writes on first visit — and whoever
loads the page first becomes the administrator. Five gaps, all closed at boot:

| Gap | Closed by |
|---|---|
| The install wizard hands the first visitor the admin account, on a public URL | `bootstrap.php` writes the configuration before anything listens, so `InstallController` throws `AlreadyInstalledException` on every request |
| The admin credential is a derived trio — `sha1(password . login . salt)` against a salt generated at install time — which no Railway variable can express | `bootstrap.php` computes it from `SHAARLI_PASSWORD` |
| Shaarli keys its session on `REMOTE_ADDR` plus the whole `X-Forwarded-For` string; behind Railway's edge both rotate per request, so no login survives its own redirect | nginx collapses the header to its leftmost entry with `more_set_input_headers`, and `REMOTE_ADDR` is rewritten to the same value in `fastcgi.conf` |
| Upstream's compose gives this one container two volumes, and Railway allows one | the mount goes on `data/`; the thumbnail cache moves below it through `resource.thumbnails_cache` |
| The year-long stay-signed-in cookie is set through the four-argument `setcookie()`, so it carries no `Secure`, `HttpOnly` or `SameSite` | one asserted `sed` in the build, plus `session.cookie_*` for the session cookie |

Two smaller ones: nginx's baked `listen 80` is re-rendered from `$PORT`, and php-fpm's
master error log is pointed at stderr so a fatal reaches `railway logs`.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `SHAARLI_PASSWORD` | — | **Required.** Password for the first administrator, minimum 8 characters. Read only while the instance has no configuration; change it afterwards in *Tools → Change password*. |
| `SHAARLI_USERNAME` | `admin` | Administrator login name. Same first-boot-only rule. |
| `SHAARLI_TITLE` | `Shaarli` | Page title. Editable later under *Tools → Configure*. |
| `SHAARLI_TIMEZONE` | `UTC` | Any tz database name, e.g. `Europe/Paris`. Unknown values fall back to `UTC`. |
| `SHAARLI_LANGUAGE` | `auto` | One of `auto`, `de`, `en`, `fr`, `jp`, `ru`, `zh_CN`. |
| `SHAARLI_FORCE_LOGIN` | `false` | `true` makes the whole instance private — anonymous visitors see only the login page. |
| `SHAARLI_DEFAULT_PRIVATE_LINKS` | `false` | `true` marks new bookmarks private unless you say otherwise. |
| `SHAARLI_ENABLE_API` | `true` | Shaarli's REST API, used by its mobile and browser clients. |
| `SHAARLI_THUMBNAILS_MODE` | `all` | `all`, `common` (a handful of known video and image hosts) or `none`. |
| `SHAARLI_CHECK_UPDATES` | `true` | Tell a signed-in administrator when a newer Shaarli is released. |
| `SHAARLI_BAN_AFTER` | `4` | Failed logins from one address before it is banned. |
| `SHAARLI_BAN_DURATION` | `1800` | Ban length in seconds. |
| `SHAARLI_SESSION_PROTECTION_DISABLED` | `false` | Escape hatch. Leave it off — the header rewrite above is what makes the protection work here. |
| `PORT` | `8080` | Port nginx serves on. Railway sets it. |

Every one of these is read **once**, while the instance has no configuration file.
That is deliberate: it keeps a redeploy from reverting whatever the operator has since
changed in the admin UI. To reset a lost password, delete `config.json.php` from the
volume and redeploy.

## Topology

One service, one volume, no database — Shaarli stores its bookmarks in a PHP flat
file guarded by an `flock` on the container's own `init.php`, so **it runs at one
replica**. The volume must be mounted at `/var/www/shaarli/data`; the entrypoint warns
loudly in the deploy log if it is anywhere else.

| | |
|---|---|
| Volume | `/var/www/shaarli/data` (bookmarks, configuration, thumbnails under `.cache/thumbnails`) |
| Health check | `/healthz` — asserts the volume is mounted, writable, and carries a seeded configuration |
| Public domain | yes, targeting `$PORT` |

## Image tag

Pinned to `ghcr.io/shaarli/shaarli:release`, upstream's floating alias for the newest
release. `latest` is **not** the stable line: `.github/workflows/docker-latest.yml`
pushes it on every commit to `master`, with the version string replaced by the commit
hash.
