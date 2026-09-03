#!/usr/bin/env bash
set -euo pipefail

# Renders nginx site config for DOMAIN and obtains a Let's Encrypt cert if missing.
# During a domain cutover, keeps serving an existing cert so nginx can stay up
# while HTTP-01 webroot issues the new name (works with Cloudflare orange-cloud).

DEPLOY_PATH="${DEPLOY_PATH:-/opt/m-dicail}"
DOMAIN="${DOMAIN:-medicail.nf2.tech}"
ACME_EMAIL="${ACME_EMAIL:-}"
TEMPLATE="${DEPLOY_PATH}/nginx/nginx-default.conf.tpl"
OUTPUT="${DEPLOY_PATH}/nginx/conf.d/default.conf"
COMPOSE_FILE="${DEPLOY_PATH}/docker-compose.prod.yml"
ENV_FILE="${DEPLOY_PATH}/.env"

log() {
  echo "[m-dicail-tls] $*"
}

die() {
  log "ERROR: $*"
  exit 1
}

live_cert_ok() {
  local name="$1"
  [[ -f "/etc/letsencrypt/live/${name}/fullchain.pem" && -f "/etc/letsencrypt/live/${name}/privkey.pem" ]]
}

first_existing_cert_name() {
  local dir name
  [[ -d /etc/letsencrypt/live ]] || return 0
  shopt -s nullglob
  for dir in /etc/letsencrypt/live/*/; do
    name="$(basename "${dir}")"
    [[ "${name}" == "README" ]] && continue
    if live_cert_ok "${name}"; then
      printf '%s' "${name}"
      return 0
    fi
  done
  return 0
}

nginx_running() {
  docker compose -f "${COMPOSE_FILE}" ps --status running 2>/dev/null | grep -q nginx
}

render_nginx() {
  local cert_name="$1"
  [[ -f "${TEMPLATE}" ]] || die "missing nginx template ${TEMPLATE}"
  mkdir -p "$(dirname "${OUTPUT}")"
  rm -f "${DEPLOY_PATH}/nginx/conf.d/"*.conf "${DEPLOY_PATH}/nginx/conf.d/"*.conf.bak || true
  sed -e "s/__DOMAIN__/${DOMAIN}/g" -e "s/__CERT_NAME__/${cert_name}/g" "${TEMPLATE}" > "${OUTPUT}"
  if grep -q '__DOMAIN__\|__CERT_NAME__' "${OUTPUT}"; then
    die "nginx render left placeholders in ${OUTPUT}"
  fi
  log "Wrote ${OUTPUT} (server_name=${DOMAIN} cert=${cert_name})"
}

guess_acme_email() {
  printf '%s' "${ACME_EMAIL}"
}

obtain_certificate() {
  mkdir -p /var/www/certbot /etc/letsencrypt
  if live_cert_ok "${DOMAIN}"; then
    log "TLS certificate already present for ${DOMAIN}"
    return 0
  fi

  command -v certbot >/dev/null 2>&1 || die "certbot is not installed"

  local email extra=(--non-interactive --agree-tos --keep-until-expiring -d "${DOMAIN}")
  email="$(guess_acme_email)"
  if [[ -n "${email}" ]]; then
    extra+=(--email "${email}")
  else
    extra+=(--register-unsafely-without-email)
  fi

  if nginx_running; then
    log "Obtaining Let's Encrypt cert for ${DOMAIN} via webroot (nginx stays up)"
    certbot certonly --webroot -w /var/www/certbot "${extra[@]}" || return 1
  else
    log "Obtaining Let's Encrypt cert for ${DOMAIN} via standalone"
    if [[ -f "${COMPOSE_FILE}" ]]; then
      (cd "${DEPLOY_PATH}" && docker compose -f "${COMPOSE_FILE}" stop nginx) || true
    fi
    certbot certonly --standalone "${extra[@]}" || return 1
  fi
}

set_env_key() {
  local key="$1"
  local value="$2"
  local tmp
  [[ -f "${ENV_FILE}" ]] || return 0
  tmp="$(mktemp)"
  if grep -q "^${key}=" "${ENV_FILE}"; then
    awk -v k="${key}" -v v="${value}" 'BEGIN{p=0} $0 ~ "^"k"=" {print k"="v; p=1; next} {print} END{if(!p) print k"="v}' "${ENV_FILE}" > "${tmp}"
  else
    cat "${ENV_FILE}" > "${tmp}"
    printf '\n%s=%s\n' "${key}" "${value}" >> "${tmp}"
  fi
  cat "${tmp}" > "${ENV_FILE}"
  rm -f "${tmp}"
  chmod 600 "${ENV_FILE}"
}

patch_env_domain() {
  [[ -f "${ENV_FILE}" ]] || return 0
  set_env_key APP_PUBLIC_URL "https://${DOMAIN}"
  set_env_key WEBAUTHN_RP_ID "${DOMAIN}"
  set_env_key WEBAUTHN_ORIGIN "https://${DOMAIN}"
  set_env_key CORS_ORIGINS "https://${DOMAIN}"
  if ! grep -q '^SMTP_PORT=' "${ENV_FILE}"; then
    set_env_key SMTP_PORT "587"
  fi
  log "Aligned APP_PUBLIC_URL / WebAuthn / CORS in ${ENV_FILE} to ${DOMAIN}"
}

main() {
  [[ -n "${DOMAIN}" ]] || die "DOMAIN is empty"
  mkdir -p "${DEPLOY_PATH}/nginx/conf.d" /var/www/certbot

  local existing=""
  existing="$(first_existing_cert_name || true)"

  if live_cert_ok "${DOMAIN}"; then
    render_nginx "${DOMAIN}"
  elif [[ -n "${existing}" ]]; then
    log "No cert for ${DOMAIN} yet; temporarily using existing cert ${existing}"
    render_nginx "${existing}"
  else
    log "No TLS cert on this host yet"
  fi

  if ! obtain_certificate; then
    log "WARN: certbot failed for ${DOMAIN}. Cloudflare orange-cloud + Always Use HTTPS blocks HTTP-01."
    log "WARN: grey-cloud medicail, disable Always Use HTTPS, then re-run."
    if [[ -z "${existing}" ]]; then
      die "no certificate available; nginx cannot start"
    fi
  fi

  if live_cert_ok "${DOMAIN}"; then
    render_nginx "${DOMAIN}"
  elif [[ -n "${existing}" ]]; then
    render_nginx "${existing}"
  else
    die "no certificate for ${DOMAIN} and no fallback cert"
  fi

  patch_env_domain
}

main "$@"
