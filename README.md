# m-dicail-deployment

Terraform configuration for an **existing VPS**: installs Docker, clones the backend, obtains a Let's Encrypt certificate, and runs the production Compose stack (Postgres + API + AI + nginx) with HTTPS and HTTP→HTTPS redirect.

Domain: **medicail.nf2.tech** (DNS on Cloudflare).

This does **not** provision a cloud server. You bring the VPS; Terraform configures it over SSH.

## Prerequisites

1. A Linux VPS (Debian/Ubuntu preferred) with outbound internet.
2. SSH access as `root` (or a user with passwordless `sudo`) using a private key.
3. Cloudflare DNS for `nf2.tech` configured as below (required before `terraform apply`).
4. [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5 on your local machine.
5. The backend git repo reachable from the VPS (`backend_repo_url`). Public HTTPS clone works out of the box. For a **private** backend, set `backend_git_token` in `terraform.tfvars` to a GitHub PAT with `contents:read` (classic or fine-grained). Terraform installs it on the VPS and git uses `Authorization: Bearer` — no interactive username prompt.

## Cloudflare DNS

In the Cloudflare dashboard for `nf2.tech`:

| Type | Name | Content | Proxy |
|------|------|---------|-------|
| A | `medicail` | your VPS public IP (`ssh_host`) | **DNS only** (grey cloud) for first certificate issue |
| AAAA | `medicail` | VPS IPv6 if you have one | same as A |

Optional later: turn the proxy **on** (orange cloud) after TLS is working on the origin.

Cloudflare SSL/TLS settings once the origin has a Let's Encrypt cert:

- Encryption mode: **Full (strict)**
- Avoid enabling "Always Use HTTPS" until the first Certbot run succeeds (it can block HTTP-01)

After apply, the API is at `https://medicail.nf2.tech`.

## Layout

```
m-dicail-deployment/
├── .github/
│   ├── actions/setup-vps-ssh/    # shared SSH agent setup for Actions
│   └── workflows/
│       ├── deploy.yml            # manual tag deploy (rewrites .env from Secrets)
│       ├── sync-env.yml          # push .env to VPS from GitHub Secrets
│       └── terraform-apply.yml   # bootstrap / infra re-sync (state via Actions artifact)
├── docker/
│   ├── docker-compose.prod.yml
│   └── nginx/                    # base nginx.conf + snippets; site conf rendered at deploy
├── scripts/
│   ├── lib/                      # shared bash (git auth, prod env, compose up)
│   ├── configure-host-firewall.sh
│   ├── deploy-backend-tag.sh
│   ├── ensure-site-tls.sh
│   └── render-env.sh             # canonical .env renderer (Actions + Terraform)
├── terraform/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── templates/                # deploy.sh, nginx-default.conf (__DOMAIN__, __CERT_NAME__)
└── terraform.tfvars.example
```

On the VPS, files land under `/opt/m-dicail` by default:

| Path | Role |
|------|------|
| `docker-compose.prod.yml` | Compose definition |
| `.env` | Secrets (mode 600) |
| `backend/` | Git clone used as Docker build context |
| `nginx/` | Prod nginx config with ACME + TLS redirect |
| `.generated/lib/` | Shared deploy helpers synced from this repo |

## Deploy (bootstrap with Terraform)

```bash
cd m-dicail-deployment/terraform
cp ../terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: ssh_host, acme_email, secrets, key path
# For a private backend: set backend_git_token to a PAT (contents:read)
# domain is already medicail.nf2.tech

terraform init
terraform plan
terraform apply
```

Useful outputs after apply:

- `health_url` — `https://medicail.nf2.tech/health`
- `api_base_url` — `https://medicail.nf2.tech/api`
- `docs_url` — `https://medicail.nf2.tech/docs`

## What apply does

1. Installs Docker Engine + Compose plugin (and Certbot) if missing.
2. Locks down the host firewall (`manage_firewall`): UFW default-deny with only SSH/80/443, plus DOCKER-USER iptables rules so published container ports cannot bypass UFW. Deploy fails if 5432/8000/8001 are still listening publicly.
3. Renders `.env` via `scripts/render-env.sh`, then syncs Compose, nginx, libs, and `.env` to `deploy_path`.
4. Clones or updates `m-dicail-backend` at `backend_ref`.
5. Obtains a Let's Encrypt cert for `medicail.nf2.tech` via Certbot **webroot** if nginx is already up, or **standalone** on first install.
6. Runs `docker compose up` (Postgres is not force-recreated; API/AI/nginx are). Postgres stays on an internal Docker network; API/AI only on the Compose network — not host-published.
7. Installs a daily renew cron that uses webroot (nginx stays up).
8. Smoke-checks `https://medicail.nf2.tech/health`.

Re-running `terraform apply` re-syncs artifacts and re-runs the deploy script when inputs or file contents change.

## Manual deploy from GitHub Actions

Recurring releases use a **manual** workflow in this repo. Creating a tag on `m-dicail-backend` does **not** deploy anything. You run Actions here and pass the tag.

Flow: bootstrap once with Terraform → tag + push on backend → run **Deploy backend tag** in this repo.

### Prerequisites

1. VPS already bootstrapped (`terraform apply` completed; Compose, TLS, and `.env` present under `/opt/m-dicail`).
2. This repository is on GitHub with Actions enabled.
3. SSH from GitHub Actions runners to the VPS (key in secrets; public key on the VPS).

### Create a release tag (backend repo)

In `m-dicail-backend` only:

```bash
git tag v1.2.0
git push origin v1.2.0
```

That push does not trigger a deploy.

### GitHub setup (`m-dicail-deployment`)

Open the deployment repo → **Settings** → **Secrets and variables** → **Actions**. Configure the secrets and variables listed under [Secrets](#secrets-terraform-and-github-actions) below.

#### SSH key on the VPS

Generate a dedicated key (or reuse the Terraform key):

```bash
ssh-keygen -t ed25519 -f ./gha-m-dicail-deploy -C "github-actions-m-dicail-deploy" -N ""
```

- Put the **private** key contents into secret `VPS_SSH_PRIVATE_KEY`.
- Append the **public** key to the VPS user's `~/.ssh/authorized_keys` (for `VPS_USER`, usually `root`).

Pin the host key:

```bash
ssh-keyscan -H YOUR_VPS_IP
```

Paste that output into secret `VPS_SSH_KNOWN_HOSTS`.

#### Cross-repo token (`BACKEND_READ_TOKEN`)

This deployment repo is separate from `m-dicail-backend`. The workflow checks that the tag exists on the backend repo before SSHing.

1. Create a fine-grained PAT (or classic PAT) with **read** access to `NoFastNoFun/m-dicail-backend` contents.
2. Store it as secret `BACKEND_READ_TOKEN` on `m-dicail-deployment`.

`BACKEND_READ_TOKEN` is used by Actions to verify the tag **and** is written to `/opt/m-dicail/.generated/backend-git-token` on the VPS so `git fetch`/`clone` of a private backend stays non-interactive. The same token (or a dedicated one) should also be set as `backend_git_token` for the initial Terraform bootstrap.

### Run a deploy

1. Tag and push on `m-dicail-backend` (see above).
2. In `m-dicail-deployment` → **Actions** → **Deploy backend tag** → **Run workflow**.
3. Enter the tag (e.g. `v1.2.0`) and confirm.
4. Watch the job; it fails immediately if the tag is missing on the backend repo.
5. Confirm `https://medicail.nf2.tech/health`.

The workflow syncs Compose, nginx (including proxy snippets), deploy libs, and scripts from this repo, **rewrites `/opt/m-dicail/.env` from GitHub Secrets** via `scripts/render-env.sh`, checks out the tag under `/opt/m-dicail/backend`, issues or reuses a Let's Encrypt cert for `DOMAIN`, runs `docker compose up` for api/ai/nginx, and smoke-checks health. It does not install Docker — that still comes from the initial Terraform bootstrap.

### Non-goals

- No auto-deploy when a backend tag is created.
- No image registry; images are still built on the VPS from the tagged source.
- Terraform remains for bootstrap / infra re-sync only; day-to-day releases use this Actions workflow.

## Secrets (Terraform and GitHub Actions)

**Never commit real values to git.** Only placeholders live in `terraform.tfvars.example`. Runtime secrets end up on the VPS in `/opt/m-dicail/.env` (mode `600`), not in the repo.

### Where secrets live

| Layer | What | Who reads it |
|-------|------|--------------|
| GitHub **Secrets** | Passwords, tokens, keys | Actions workflows only |
| GitHub **Variables** | Domain, ports, non-secret config | Actions workflows |
| VPS `/opt/m-dicail/.env` | Full runtime env for Docker | API container at boot |
| Local `terraform.tfvars` | Optional; gitignored | You, if you run Terraform locally |

**Deploy backend tag** and **Sync VPS environment** both render `.env` from GitHub Secrets (via `scripts/render-env.sh`) and upload it to the VPS. Tag deploy therefore needs the same app secrets as sync (including SMTP). Use **Sync VPS environment** when you only want to rotate secrets without rebuilding from a new tag.

### Recommended Actions flow

1. **First-time VPS bootstrap** — Actions → **Terraform apply** (installs Docker, TLS, clones backend, writes `.env`).
2. **Change secrets later** (SMTP, DB password, etc.) — Actions → **Sync VPS environment** (rewrites `.env`, optionally rebuilds API).
3. **Release a backend tag** — Actions → **Deploy backend tag** (syncs stack files, rewrites `.env`, rebuilds from the tag).

Configure **Settings → Secrets and variables → Actions** on the deployment repo:

**Secrets**

| Name | Purpose | Used by |
|------|---------|---------|
| `VPS_HOST` | VPS IP or hostname | all workflows |
| `VPS_USER` | SSH user (defaults to `root` if unset) | all workflows |
| `VPS_PORT` | SSH port (defaults to `22` if unset) | all workflows |
| `VPS_SSH_PRIVATE_KEY` | Private key for Actions → VPS | all workflows |
| `VPS_SSH_KNOWN_HOSTS` | Output of `ssh-keyscan -H <VPS_HOST>` (recommended) | all workflows |
| `SECRET_KEY` | JWT signing key | terraform-apply, deploy, sync-env |
| `POSTGRES_USER` | Postgres user | terraform-apply, deploy, sync-env |
| `POSTGRES_PASSWORD` | Postgres password | terraform-apply, deploy, sync-env |
| `POSTGRES_DB` | Postgres database name | terraform-apply, deploy, sync-env |
| `BACKEND_READ_TOKEN` | GitHub PAT with `contents:read` on backend repo | terraform-apply, deploy |
| `SMTP_USER` | Proton SMTP user | deploy, sync-env (and terraform-apply if set) |
| `SMTP_PASS` | Proton SMTP token | deploy, sync-env (and terraform-apply if set) |
| `NCBI_API_KEY` | Optional PubMed API key | deploy, sync-env, terraform-apply |
| `GROQ_API_KEY` | Groq API key for AI STT (apps/ai). POC sends consultation audio to Groq for post-recording enhance. | deploy, sync-env, terraform-apply |
| `FIREBASE_PROJECT_ID` | Optional Firebase project ID for FCM | deploy, sync-env, terraform-apply |
| `FIREBASE_CLIENT_EMAIL` | Optional Firebase service-account email | deploy, sync-env, terraform-apply |
| `FIREBASE_PRIVATE_KEY` | Optional Firebase service-account PEM (`\n` escaped) | deploy, sync-env, terraform-apply |

Without the three Firebase secrets, the API boots normally but skips FCM sends (Console campaigns still work from the app). Set them, then run **Sync VPS environment**.

**Variables**

| Name | Example | Purpose |
|------|---------|---------|
| `DOMAIN` | `medicail.nf2.tech` | Public hostname (must not be `*.nf2.dev`) |
| `ACME_EMAIL` | `ops@example.com` | Let's Encrypt contact (Terraform apply) |
| `DEPLOY_PATH` | `/opt/m-dicail` | Install path on VPS |
| `BACKEND_REPO` | `NoFastNoFun/m-dicail-backend` | `owner/repo` for tag verification |
| `BACKEND_REPO_URL` | `https://github.com/.../m-dicail-backend.git` | Backend clone URL |
| `BACKEND_REF` | `main` | Branch/tag for Terraform bootstrap |
| `SMTP_HOST` | `smtp.proton.me` | SMTP server |
| `SMTP_PORT` | `587` | SMTP port |
| `SMTP_FROM` | `Medicail <noreply@proton.me>` | From header |
| `NCBI_EMAIL` | `ops@example.com` | NCBI contact email |
| `WEBAUTHN_RP_NAME` | `Medicail` | Passkey display name |

`APP_PUBLIC_URL`, `APP_DEEPLINK_SCHEME` (default `medicail`), `WEBAUTHN_RP_ID`, and `WEBAUTHN_ORIGIN` are derived from `DOMAIN` / defaults by `scripts/render-env.sh`.

### Local Terraform (optional)

If you prefer local bootstrap instead of the **Terraform apply** workflow:

- Copy `terraform.tfvars.example` → `terraform/terraform.tfvars` (gitignored).
- Or export `TF_VAR_smtp_pass`, `TF_VAR_secret_key`, etc. without a file.

Do **not** commit `terraform.tfvars` or Terraform state files that contain secrets.

### Terraform state in GitHub Actions

The **Terraform apply** workflow stores `terraform.tfstate` as a GitHub Actions artifact (90-day retention, no locking). Always restore the latest artifact before a new apply. A missing artifact means an empty state and can re-run provisioners unexpectedly.

This VPS is temporary (through 1 Nov 2026) and must stay zero extra cost — no S3/remote backend. That artifact is acceptable here: bootstrap **once**, then use **Deploy backend tag** for releases. Avoid a second Terraform apply unless the box was wiped.

## TLS renewal

Certbot renews via webroot (`/.well-known/acme-challenge/`) without stopping nginx. Certificates live on the host under `/etc/letsencrypt` and are mounted into nginx.

Manual renew:

```bash
sudo certbot renew --webroot -w /var/www/certbot
sudo docker compose -f /opt/m-dicail/docker-compose.prod.yml exec -T nginx nginx -s reload
```

First issue for a **new hostname** (for example after `nf2.dev` → `nf2.tech`) also uses webroot while nginx is already serving. If Cloudflare "Always Use HTTPS" is on, HTTP-01 can fail; temporarily disable it or grey-cloud the record, then re-run deploy.

## Operations on the VPS

```bash
cd /opt/m-dicail
docker compose -f docker-compose.prod.yml ps
docker compose -f docker-compose.prod.yml logs -f api
docker compose -f docker-compose.prod.yml pull   # if using prebuilt images later
docker compose -f docker-compose.prod.yml up -d --build
```

## Notes

- Postgres is **not** published on the host in production (Compose `db` network is `internal: true`). API/AI use `expose` only — nginx is the sole public entry on 80/443.
- Local/dev `m-dicail-backend/docker-compose.yml` still publishes `5432` for local work; never run that compose file on the VPS.
- Host firewall: keep `manage_firewall = true` (default). Docker bypasses UFW INPUT for published ports; this deploy installs DOCKER-USER rules so only 80/443 stay reachable that way. `configure-host-firewall.sh` runs `ufw --force reset`, which wipes prior UFW rules before applying the lockdown.
- First certificate issuance needs the Cloudflare A record already pointing at the VPS and port 80 reachable (use grey cloud for that step).
