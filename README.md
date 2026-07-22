# m-dicail-deployment

Terraform configuration for an **existing VPS**: installs Docker, clones the backend, obtains a Let's Encrypt certificate, and runs the production Compose stack (Postgres + API + AI + nginx) with HTTPS and HTTP→HTTPS redirect.

This does **not** provision a cloud server. You bring the VPS; Terraform configures it over SSH.

## Prerequisites

1. A Linux VPS (Debian/Ubuntu preferred) with outbound internet.
2. SSH access as `root` (or a user with passwordless `sudo`) using a private key.
3. A DNS **A** (and optional **AAAA**) record for your domain pointing at the VPS public IP. Let's Encrypt validation will fail without this.
4. [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5 on your local machine.
5. The backend git repo reachable from the VPS (`backend_repo_url`). Public HTTPS clone works out of the box; private repos need credentials or a deploy key on the VPS.

## Layout

```
m-dicail-deployment/
├── docker/
│   ├── docker-compose.prod.yml   # prod stack (Postgres not published)
│   └── nginx/                    # base nginx.conf; site conf rendered by Terraform
├── terraform/
│   ├── main.tf                   # SSH provisioners + deploy
│   ├── variables.tf
│   ├── outputs.tf
│   └── templates/                # .env, deploy.sh, nginx site conf
└── terraform.tfvars.example
```

On the VPS, files land under `/opt/m-dicail` by default:

| Path | Role |
|------|------|
| `docker-compose.prod.yml` | Compose definition |
| `.env` | Secrets (mode 600) |
| `backend/` | Git clone used as Docker build context |
| `nginx/` | Prod nginx config with ACME + TLS redirect |

## Deploy

```bash
cd m-dicail-deployment/terraform
cp ../terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: ssh_host, domain, acme_email, secrets, key path

terraform init
terraform plan
terraform apply
```

Useful outputs after apply:

- `health_url` — `https://<domain>/health`
- `api_base_url` — `https://<domain>/api`
- `docs_url` — `https://<domain>/docs`

## What apply does

1. Installs Docker Engine + Compose plugin (and Certbot) if missing.
2. Optionally enables UFW for ports 22, 80, and 443 (`manage_firewall`).
3. Syncs Compose, nginx, and `.env` to `deploy_path`.
4. Clones or updates `m-dicail-backend` at `backend_ref`.
5. Obtains a Let's Encrypt cert via Certbot **standalone** (port 80 must be free for the first issue).
6. Runs `docker compose up -d --build`.
7. Installs a daily renew cron that stops nginx briefly, renews, then starts nginx again.
8. Smoke-checks `https://<domain>/health`.

Re-running `terraform apply` re-syncs artifacts and re-runs the deploy script when inputs or file contents change.

## Secrets

- Do **not** commit `terraform/terraform.tfvars` or Terraform state if they contain secrets.
- Prefer strong random values for `secret_key` and `postgres_password`.
- You can also pass sensitive values via environment variables, e.g. `TF_VAR_secret_key`, `TF_VAR_postgres_password`.

## TLS renewal

Certbot runs daily via `/etc/cron.d/m-dicail-certbot` → `/usr/local/bin/m-dicail-certbot-renew`. The renew wrapper stops the nginx container for the standalone challenge, then starts it again. Certificates live on the host under `/etc/letsencrypt` and are mounted into nginx.

Manual renew:

```bash
sudo /usr/local/bin/m-dicail-certbot-renew
```

## Operations on the VPS

```bash
cd /opt/m-dicail
docker compose -f docker-compose.prod.yml ps
docker compose -f docker-compose.prod.yml logs -f api
docker compose -f docker-compose.prod.yml pull   # if using prebuilt images later
docker compose -f docker-compose.prod.yml up -d --build
```

## Notes

- Postgres is **not** published on the host in production (Compose internal network only).
- Local/dev nginx in `m-dicail-backend` keeps HTTP→HTTPS redirect commented out; production redirect lives in this deployment package.
- First certificate issuance requires DNS already pointing at the VPS and port 80 reachable from the public internet.
