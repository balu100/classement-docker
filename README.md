# Classement — Self-hosted Docker

Run [Classement](https://classement.org/) with its Angular frontend and Symfony API on a single origin, backed by MariaDB. The application is built from the upstream source repositories; this project supplies the Docker and web-server configuration.

> Unofficial deployment configuration. It is not affiliated with the Classement maintainers and does not include the official site's database or uploaded content.

## Source code

- **Frontend:** [Zefling/classement-client](https://github.com/Zefling/classement-client) ([original repository](https://git.ikilote.net/classement/classement))
- **Backend:** [Zefling/classement-server](https://github.com/Zefling/classement-server) ([original repository](https://git.ikilote.net/classement/serveur))

The Docker build changes only the Angular production API base path to `/` so that browser requests use the locally hosted `/api/...` endpoints. **The Symfony PHP source, Doctrine entities, and upstream migrations are not patched.** Apache configuration, PHP settings, and SPA routing are maintained separately.

## Services

| Service | Purpose |
| --- | --- |
| `web` | Apache, PHP 8.4, Symfony API, and compiled Angular frontend |
| `migrate` | One-shot Doctrine database migrations, using the same application image |
| `init-uploads` | One-shot ownership initialization for the persistent uploads volume |
| `db` | MariaDB 10.11, with persistent storage |
| `mailpit` | Local SMTP inbox for sign-up and password-reset emails |

The web application and API share the same host and port. No additional reverse proxy or startup shell script is required. A separate HTTPS reverse proxy, such as Caddy, is optional.

## Requirements

- Docker Engine or Docker Desktop with the **Docker Compose v2** plugin and BuildKit support.
- Internet access during the image build to fetch upstream Git repositories and application dependencies.
- Free ports **8080** (application) and **8025** (Mailpit UI), or different ports configured in `.env`.

## Quick start

### 1. Create the environment file

From the project directory:

**PowerShell 7:**

```powershell
Copy-Item .env.example .env
```

**Linux/macOS:**

```bash
cp .env.example .env
```

Open `.env` and set all four required secrets:

```dotenv
DB_PASSWORD=<random-hex-value>
DB_ROOT_PASSWORD=<different-random-hex-value>
APP_SECRET=<different-random-hex-value>
PREFERENCES_KEY=<different-random-hex-value>
```

Generate each value independently (32 random bytes / 64 hexadecimal characters):

**PowerShell 7:**

```powershell
[Convert]::ToHexString([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
```

**Linux/macOS with OpenSSL:**

```bash
openssl rand -hex 32
```

Use distinct values and store `.env` securely. Hexadecimal values are suitable for `DB_PASSWORD`, which is also embedded in the application's database connection URL. **Keep these secrets unchanged when upgrading an existing installation**; changing `PREFERENCES_KEY` makes existing encrypted preferences unreadable.

### 2. Build and start

```bash
docker compose config --quiet
docker compose up -d --build
docker compose ps --all
```

Expected service states:

- `db`: healthy
- `mailpit`: healthy
- `init-uploads`: **Exited (0)** (normal: fixes ownership of the image volume)
- `migrate`: **Exited (0)** (normal for this one-shot job)
- `web`: running, then healthy

The `web`, `migrate`, and `init-uploads` services share the locally built `classement-web:local` image. The first startup builds it locally rather than pulling it from a registry.

### 3. Open the application

- **Classement:** http://localhost:8080
- **Mailpit inbox:** http://127.0.0.1:8025

Create an account in Classement. The confirmation email is delivered to Mailpit; open the message in its web UI and follow the activation link before signing in. Mailpit is for local testing and does **not** deliver mail to external inboxes.

## Configuration

The included `.env.example` documents all configuration options. Common settings:

| Variable | Purpose | Default |
| --- | --- | --- |
| `PUBLIC_URL` | Browser-facing origin, without a trailing slash | `http://localhost:8080` |
| `PUBLIC_HOST` | Hostname and optional port accepted by the backend | `localhost:8080` |
| `WEB_BIND` | Host interface for the application port | `127.0.0.1` |
| `WEB_PORT` | Host port for the application | `8080` |
| `MAIL_UI_PORT` | Host port for Mailpit's web UI | `8025` |
| `MAILER_DSN` | SMTP transport used by Symfony | `smtp://mailpit:1025` |
| `CLIENT_REPO`, `CLIENT_REF` | Frontend Git repository and branch/tag | Upstream GitHub mirror, `master` |
| `SERVER_REPO`, `SERVER_REF` | Backend Git repository and branch/tag | Upstream GitHub mirror, `main` |
| `UPSTREAM_REFRESH` | Build-cache key for fetching newer source revisions | `initial` |
| `TMDB_API_KEY` | Optional TMDb API Read Access Token | Empty |
| `OAUTH_*` | Optional Discord, Facebook, and Google integration credentials | Empty |
| `APACHE_TRUSTED_PROXY_CIDR` | Proxy peer allowed to indicate an original HTTPS request | `127.0.0.1/32` |
| `SYMFONY_TRUSTED_PROXIES` | Proxy IPs trusted by Symfony | Empty |

Configure OAuth or TMDb only if needed. The `TMDB_API_KEY` expects a **TMDb API Read Access Token** for Bearer authentication.

### Sending real email

The default Mailpit configuration is suitable for local testing only. For external delivery, configure `MAILER_DSN` with a working SMTP relay. The upstream application uses `no-reply@ikilote.net` as the sender for certain emails; the deployment does not patch this PHP code. Use a relay that is authorized to send those messages and can rewrite the sender if needed, or obtain a configurable sender from upstream. Verify deliverability before using the service publicly.

Do not publish the Mailpit UI without adding appropriate access controls. Its host port is bound to loopback by default.

## HTTPS with Caddy (optional)

The Compose stack includes Apache but **does not deploy Caddy**. If Caddy runs on the same host, a minimal Caddyfile site is:

```caddyfile
tiers.example.com {
    reverse_proxy 127.0.0.1:8080
}
```

Configure the public origin in `.env`:

```dotenv
PUBLIC_URL=https://tiers.example.com
PUBLIC_HOST=tiers.example.com
WEB_BIND=127.0.0.1
WEB_PORT=8080
```

The upstream PHP URL helper checks the `HTTPS` server variable directly. Apache therefore sets this variable when it receives `X-Forwarded-Proto: https` **from an explicitly trusted proxy peer**. Symfony's proxy settings alone do not change that particular PHP helper.

For host-to-container traffic through a Docker-published port, the immediate peer seen by Apache may be the Docker bridge gateway rather than `127.0.0.1`. Identify it:

```bash
docker network inspect classement_default --format '{{(index .IPAM.Config 0).Gateway}}'
```

If the output is, for example, `172.19.0.1`, configure the actual peer in `.env`:

```dotenv
APACHE_TRUSTED_PROXY_CIDR=172.19.0.1/32
SYMFONY_TRUSTED_PROXIES=172.19.0.1
```

Then apply the environment change:

```bash
docker compose up -d --force-recreate web
```

The gateway address above is **only an example**. Only trust the real proxy peer. Keep the published application port restricted to a trusted interface; Docker port forwarding may make different host-side connections appear to originate from the same bridge gateway. Ensure Caddy replaces untrusted incoming forwarding headers. Do not use `0.0.0.0/0` as a trusted proxy range.

If Caddy runs in Docker, connect the proxy and `web` to a suitable shared network and use the service address instead of Caddy-container `127.0.0.1`. Configure the trusted proxy IP/network for that topology.

Verify that generated image links begin with the public **`https://`** origin after HTTPS is enabled.

## Health checks and diagnostics

Check service status and logs:

```bash
docker compose ps --all
docker compose logs --tail 100 web
docker compose logs --tail 100 migrate
```

Verify the API on a local installation:

```bash
curl -fsS http://localhost:8080/api/test
```

Check Doctrine migration status:

```bash
docker compose exec -T web php bin/console doctrine:migrations:status --no-interaction
```

The expected migration status is **no pending migrations**. The `init-uploads` service gives the runtime user permission to create directories in the persistent image volume before `migrate` and `web` start. The `migrate` service must finish successfully before `web` starts. The `/api/test` healthcheck verifies basic application availability; it does not replace functional tests for sign-up, login, uploads, or third-party integrations.

If creating a tier list with uploaded images fails with `Unable to create .../public/images/~tmp/`, verify permissions **as the Apache user**, not root:

```bash
docker compose exec --user 33:33 web sh -c 'test -w /var/www/classement/public/images && echo writable'
```

The `init-uploads` one-shot service automatically fixes ownership of the volume root on startup; it runs `chown` directly and does not need a shell script. To repair older uploads that have incorrect file or subdirectory ownership, adjust them once, after making a backup:

```bash
docker compose run --rm --no-deps --user 0:0 --entrypoint chown web -R 33:33 /var/www/classement/public/images
```

To check uploads, create a tier list with a locally uploaded image, then inspect the image's URL and response type. A saved local image should return the expected image content type (typically `image/webp`). External image URLs included in imported tier lists are not automatically copied into the local image volume.

## Updating

Upstream code is cloned **during the image build**, not when a container starts. Docker may cache those Git clone layers. To request newer commits from the configured upstream branches, change `UPSTREAM_REFRESH` in `.env` to a new value, for example:

```dotenv
UPSTREAM_REFRESH=refresh-001
```

Then rebuild and deploy:

```bash
docker compose build --pull web
docker compose up -d
docker compose ps --all
```

The `migrate` service runs upstream Doctrine migrations for the deployed application version. Confirm that it exits successfully. Review upstream changes and back up persistent data **before** updating. New database migrations may not be reversible merely by restoring the previous application image.

`CLIENT_REF` and `SERVER_REF` accept branches or tags supported by `git clone --branch`. Where stable upstream tags exist, pinning them offers more predictable builds. The frontend repository does not ship a committed npm lockfile, so dependency resolution is not fully reproducible even with a fixed source revision.

To update the separately pulled MariaDB and Mailpit images:

```bash
docker compose pull db mailpit
docker compose up -d
```

Review release notes before changing MariaDB major versions.

## Data and backups

Docker named volumes persist across ordinary restarts and container recreation:

| Volume | Data |
| --- | --- |
| `classement_database` | MariaDB database |
| `classement_images` | Locally uploaded image files |
| `classement_mailpit_data` | Captured test emails |

Back up the database and image files, plus a secure copy of `.env`. For example:

```bash
docker compose exec -T db sh -c 'MYSQL_PWD="$MARIADB_PASSWORD" mariadb-dump --single-transaction --quick -u"$MARIADB_USER" "$MARIADB_DATABASE" > /tmp/classement.sql'
docker compose cp db:/tmp/classement.sql ./classement.sql
docker compose cp web:/var/www/classement/public/images ./images-backup
```

Verify the resulting files. These commands create separate logical/file backups, not an atomic snapshot; coordinate writes when taking consistency-critical backups.

**`docker compose down -v` removes Compose-managed named volumes and their data.** Ordinary `docker compose down` does not remove named volumes.

## Design principles

- Use upstream application source and migrations as provided; do not carry application-specific PHP fixes.
- Keep the Angular frontend and Symfony API on a single origin.
- Configure deployment concerns using Docker, Apache, PHP, and environment variables.
- Use Compose commands directly; no custom launcher, updater, or container entrypoint shell scripts.
- Keep persistent data independent of rebuilt application images.

Upstream application bugs and behavior remain upstream concerns. This repository provides a self-hosted deployment environment, not a separate application fork.
