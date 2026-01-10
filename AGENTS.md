# Repository Guidelines

## Project Structure & Module Organization
- `docker-compose.yml` defines the full multi-service stack (Traefik, OpenWebUI, n8n, LiteLLM, Postgres, etc.).
- `deploy.sh`, `teardown.sh`, `migrate.sh` are the primary lifecycle scripts.
- `portal/` contains the Nginx landing page; the UI lives in `portal/html/index.html`.
- `traefik/` holds proxy configuration and TLS assets (`traefik/traefik.yml`, `traefik/dynamic/tls.yml`).
- `litellm/config.yaml` maps model names to Bedrock IDs.
- `database/` includes DB init scripts and server metadata.
- `dns/dnsmasq.conf` supports `*.pluto.local` resolution.

## Build, Test, and Development Commands
- `./deploy.sh` boots the stack, creates certs, and updates `/etc/hosts` for `*.pluto.local`.
- `./teardown.sh` stops containers; `./teardown.sh --all` also removes data volumes.
- `./migrate.sh backup` and `./migrate.sh restore <file>` export/import all volumes.
- `docker compose ps` is the quickest health check after a deploy.

## Coding Style & Naming Conventions
- Shell scripts use Bash with 4-space indentation and verbose, sectioned comments.
- HTML/CSS in `portal/html/index.html` uses 4-space indentation; keep class names descriptive.
- Prefer lowercase, kebab-case filenames for new assets (example: `portal/html/new-section.html`).
- No formatter is configured; keep edits minimal and consistent with surrounding code.

## Testing Guidelines
- No automated test framework is present in this repo.
- Validate changes by running `./deploy.sh` and confirming service URLs respond.
- When changing config, note the impacted service and port (example: `litellm.pluto.local:4000`).

## Commit & Pull Request Guidelines
- This checkout has no Git history, so no commit conventions are observable.
- Use concise, imperative commit messages if you initialize Git (example: `Add LiteLLM model mapping`).
- PRs should include: summary, affected services, config changes, and new/updated docs.
- Include screenshots only for Portal UI changes in `portal/html/index.html`.

## Security & Configuration Tips
- `.env` is gitignored; document required keys in `README.md` if you add new settings.
- `deploy.sh` writes to `/etc/hosts` and generates self-signed certs; warn users in changes.
