#!/usr/bin/env bash
# Shared helpers for VPS deploy scripts. Source after setting LOG_PREFIX, DEPLOY_PATH, COMPOSE_FILE.

: "${LOG_PREFIX:=m-dicail}"
: "${DEPLOY_PATH:=/opt/m-dicail}"
: "${COMPOSE_FILE:=${DEPLOY_PATH}/docker-compose.prod.yml}"
: "${FIREWALL_SCRIPT:=${DEPLOY_PATH}/.generated/configure-host-firewall.sh}"

log() {
  echo "[${LOG_PREFIX}] $*"
}

die() {
  log "ERROR: $*"
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

# Domain name change because it expired and me (Ethan) am too lazy to spend 40 € on it again
reject_expired_domain() {
  local domain="${1:-${DOMAIN:-}}"
  if [[ "${domain}" == *".nf2.dev" ]]; then
    die "DOMAIN=${domain} uses expired nf2.dev; set DOMAIN=medicail.nf2.tech (GitHub variable or terraform domain)"
  fi
}

# Read a key from DEPLOY_PATH/.env without printing the value.
env_file_value() {
  local key="$1"
  local line=""
  [[ -f "${DEPLOY_PATH}/.env" ]] || return 0
  line="$(awk -F= -v k="${key}" 'BEGIN{found=0} $1==k && !found {sub(/^[^=]*=/, ""); print; found=1}' "${DEPLOY_PATH}/.env" | tr -d '\r')"
  line="${line#\"}"
  line="${line%\"}"
  line="${line#\'}"
  line="${line%\'}"
  printf '%s' "${line}"
}

require_prod_env() {
  local key val missing=()
  [[ -f "${DEPLOY_PATH}/.env" ]] || die "missing ${DEPLOY_PATH}/.env"

  for key in SECRET_KEY POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB APP_PUBLIC_URL SMTP_HOST SMTP_PORT SMTP_USER SMTP_PASS WEBAUTHN_RP_ID WEBAUTHN_ORIGIN; do
    val="$(env_file_value "${key}")"
    if [[ -z "${val}" ]]; then
      missing+=("${key}")
    fi
  done
  if [[ -z "$(env_file_value SMTP_FROM)" && -z "$(env_file_value SMTP_USER)" ]]; then
    missing+=("SMTP_FROM")
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    die "production .env missing: ${missing[*]}. The API exits on empty SMTP/WebAuthn/APP_PUBLIC_URL when NODE_ENV=production (nginx then 502s). Run GitHub Actions → Sync VPS environment or Deploy backend tag after setting the required secrets. Set DOMAIN=medicail.nf2.tech first."
  fi
  log "Production .env has required keys (values not printed)"
}

stop_insecure_published_stacks() {
  command -v docker >/dev/null 2>&1 || return 0
  local id name ports
  while IFS=$'\t' read -r id name ports; do
    [[ -n "${id}" ]] || continue
    if echo "${ports}" | grep -Eq '0\.0\.0\.0:(5432|8000|8001)->|:::(5432|8000|8001)->'; then
      log "Stopping container with public app/db ports: ${name} (${ports})"
      docker stop "${id}" >/dev/null 2>&1 || true
      docker rm "${id}" >/dev/null 2>&1 || true
    fi
  done < <(docker ps --format '{{.ID}}\t{{.Names}}\t{{.Ports}}' 2>/dev/null || true)
}

# Start postgres, recreate api/ai/nginx, re-apply DOCKER-USER, assert firewall.
start_compose_stack() {
  local assert_firewall="${1:-true}"
  log "Building and starting Docker Compose stack"
  cd "${DEPLOY_PATH}"

  docker compose -f "${COMPOSE_FILE}" up -d postgres
  local i
  for i in $(seq 1 30); do
    if docker compose -f "${COMPOSE_FILE}" exec -T postgres pg_isready >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done

  docker compose -f "${COMPOSE_FILE}" up -d --build --remove-orphans --force-recreate --no-deps api ai
  docker compose -f "${COMPOSE_FILE}" up -d --force-recreate --no-deps nginx

  if [[ -x /usr/local/sbin/m-dicail-docker-user-fw ]]; then
    /usr/local/sbin/m-dicail-docker-user-fw || true
  fi
  if [[ "${assert_firewall}" == "true" && -f "${FIREWALL_SCRIPT}" ]]; then
    chmod 755 "${FIREWALL_SCRIPT}"
    ASSERT_ONLY=true bash "${FIREWALL_SCRIPT}"
  fi
}
