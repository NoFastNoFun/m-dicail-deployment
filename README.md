# m-dicail-deployment

Terraform configuration for an **existing VPS**: installs Docker, clones the backend, obtains a Let's Encrypt certificate, and runs the production Compose stack (Postgres + API + AI + nginx) with HTTPS and HTTP→HTTPS redirect.

Domain: **medicail.nf2.tech** (DNS on Cloudflare).

This does **not** provision a cloud server. You bring the VPS; Terraform configures it over SSH.

## Prerequisites

1. A Linux VPS (Debian/Ubuntu preferred) with outbound internet.
2. SSH access as `root` (or a user with passwordless `sudo`) using a private key.
3. Cloudflare DNS for `nf2.dev` configured as below (required before `terraform apply`).
4. [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5 on your local machine.
5. The backend git repo reachable from the VPS (`backend_repo_url`). Public HTTPS clone works out of the box. For a **private** backend, set `backend_git_token` in `terraform.tfvars` to a GitHub PAT with `contents:read` (classic or fine-grained). Terraform installs it on the VPS and git uses `Authorization: Bearer` — no interactive username prompt.

## Cloudflare DNS

In the Cloudflare dashboard for `nf2.dev`:

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
├── .github/workflows/
│   ├── deploy.yml                # manual tag deploy (workflow_dispatch)
│   ├── sync-env.yml              # push .env to VPS from GitHub Secrets
│   └── terraform-apply.yml       # bootstrap / infra re-sync without local tfvars
├── docker/
│   ├── docker-compose.prod.yml   # prod stack (Postgres not published)
│   └── nginx/                    # base nginx.conf; site conf rendered by Terraform
├── scripts/
│   ├── configure-host-firewall.sh  # UFW + DOCKER-USER lockdown (80/443/SSH only)
│   └── deploy-backend-tag.sh     # VPS tag checkout + compose rebuild (used by Actions)
├── terraform/
│   ├── main.tf                   # SSH provisioners + deploy
│   ├── variables.tf
│   ├── outputs.tf
│   └── templates/                # .env, deploy.sh, nginx-default.conf (__DOMAIN__)
└── terraform.tfvars.example
```

On the VPS, files land under `/opt/m-dicail` by default:

| Path | Role |
|------|------|
| `docker-compose.prod.yml` | Compose definition |
| `.env` | Secrets (mode 600) |
| `backend/` | Git clone used as Docker build context |
| `nginx/` | Prod nginx config with ACME + TLS redirect |

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
3. Syncs Compose, nginx, and `.env` to `deploy_path`.
4. Clones or updates `m-dicail-backend` at `backend_ref`.
5. Obtains a Let's Encrypt cert for `medicail.nf2.tech` via Certbot **standalone** (port 80 must be free for the first issue).
6. Runs `docker compose up -d --build` (Postgres on an internal Docker network; API/AI only on the Compose network — not host-published).
7. Installs a daily renew cron that stops nginx briefly, renews, then starts nginx again.
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

Open the deployment repo → **Settings** → **Secrets and variables** → **Actions**.

**Secrets**

| Name | Purpose |
|------|---------|
| `VPS_HOST` | VPS IP or hostname (**required**) |
| `VPS_USER` | SSH user (defaults to `root` if unset) |
| `VPS_PORT` | SSH port (defaults to `22` if unset) |
| `VPS_SSH_PRIVATE_KEY` | Private key used by Actions to SSH into the VPS (PEM / OpenSSH format, full file contents) |
| `VPS_SSH_KNOWN_HOSTS` | Output of `ssh-keyscan -H <VPS_HOST>` (recommended; pins host key) |
| `BACKEND_READ_TOKEN` | PAT or fine-grained token with `contents:read` on `NoFastNoFun/m-dicail-backend` (required if the backend repo is private; recommended for rate limits even if public) |

**Variables**

| Name | Example / default | Purpose |
|------|-------------------|---------|
| `DEPLOY_PATH` | `/opt/m-dicail` | Install path on the VPS |
| `BACKEND_REPO` | `NoFastNoFun/m-dicail-backend` | `owner/repo` used to verify the tag via GitHub API |
| `BACKEND_REPO_URL` | `https://github.com/NoFastNoFun/m-dicail-backend.git` | Git URL cloned/fetched on the VPS |
| `DOMAIN` | `medicail.nf2.tech` | Used for the post-deploy health check |

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

The workflow syncs `docker-compose.prod.yml` and `nginx/nginx.conf` from this repo, copies `scripts/deploy-backend-tag.sh` to the VPS, checks out that tag under `/opt/m-dicail/backend`, runs `docker compose up -d --build`, and smoke-checks health. It does not create `.env`, issue TLS certificates, or install Docker — those still come from the initial Terraform bootstrap.

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

The **Deploy backend tag** workflow does **not** read app secrets. It reuses the existing `.env` on the VPS. Tag deploys alone cannot set SMTP or `SECRET_KEY`.

### If you do not have secrets locally (recommended)

Use GitHub Actions on `m-dicail-deployment`:

1. **First-time VPS bootstrap** — Actions → **Terraform apply** (installs Docker, TLS, clones backend, writes `.env`).
2. **Change secrets later** (SMTP, DB password, etc.) — Actions → **Sync VPS environment** (rewrites `.env`, optionally rebuilds API).
3. **Release a backend tag** — Actions → **Deploy backend tag** (unchanged).

Configure **Settings → Secrets and variables → Actions** on the deployment repo:

**Secrets (required for bootstrap / env sync)**

| Name | Purpose |
|------|---------|
| `VPS_HOST` | VPS IP or hostname |
| `VPS_SSH_PRIVATE_KEY` | SSH key for Actions → VPS |
| `VPS_SSH_KNOWN_HOSTS` | Output of `ssh-keyscan -H <VPS_HOST>` (recommended) |
| `SECRET_KEY` | JWT signing key |
| `POSTGRES_USER` | Postgres user |
| `POSTGRES_PASSWORD` | Postgres password |
| `POSTGRES_DB` | Postgres database name |
| `BACKEND_READ_TOKEN` | GitHub PAT with `contents:read` on backend repo |
| `SMTP_USER` | Proton SMTP user (required for password-reset mail) |
| `SMTP_PASS` | Proton SMTP token (required for password-reset mail) |
| `NCBI_API_KEY` | Optional PubMed API key |

**Variables (non-secret defaults)**

| Name | Example | Purpose |
|------|---------|---------|
| `DOMAIN` | `medicail.nf2.tech` | Public hostname |
| `ACME_EMAIL` | `ops@example.com` | Let's Encrypt contact (Terraform apply only) |
| `DEPLOY_PATH` | `/opt/m-dicail` | Install path on VPS |
| `BACKEND_REPO_URL` | `https://github.com/.../m-dicail-backend.git` | Backend clone URL |
| `BACKEND_REF` | `main` | Branch/tag for Terraform bootstrap |
| `SMTP_HOST` | `smtp.proton.me` | SMTP server |
| `SMTP_PORT` | `587` | SMTP port |
| `SMTP_FROM` | `Medicail <noreply@proton.me>` | From header |
| `NCBI_EMAIL` | `ops@example.com` | NCBI contact email |
| `WEBAUTHN_RP_NAME` | `Medicail` | Passkey display name |

`APP_PUBLIC_URL`, `WEBAUTHN_RP_ID`, and `WEBAUTHN_ORIGIN` are derived from `DOMAIN` automatically.

Optional: `VPS_USER` (default `root`), `VPS_PORT` (default `22`).

### Local Terraform (optional)

If you prefer local bootstrap instead of the **Terraform apply** workflow:

- Copy `terraform.tfvars.example` → `terraform/terraform.tfvars` (gitignored).
- Or export `TF_VAR_smtp_pass`, `TF_VAR_secret_key`, etc. without a file.

Do **not** commit `terraform.tfvars` or Terraform state files that contain secrets.

## TLS renewal

Certbot runs daily via `/etc/cron.d/m-dicail-certbot` → `/usr/local/bin/m-dicail-certbot-renew`. The renew wrapper stops the nginx container for the standalone challenge, then starts it again. Certificates live on the host under `/etc/letsencrypt` and are mounted into nginx.

Manual renew:

```bash
sudo /usr/local/bin/m-dicail-certbot-renew
```

If the Cloudflare record is proxied (orange cloud), renewals that use HTTP-01 can fail. Keep the record **DNS only**, or switch Certbot to DNS-01 with a Cloudflare API token later.

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
- Host firewall: keep `manage_firewall = true` (default). Docker bypasses UFW INPUT for published ports; this deploy installs DOCKER-USER rules so only 80/443 stay reachable that way.
- First certificate issuance needs the Cloudflare A record already pointing at the VPS and port 80 reachable (use grey cloud for that step).
