#!/usr/bin/env bash
set -euo pipefail

# Runs on the VPS after Terraform bootstrap. Checks out a backend git tag and rebuilds Compose.
# Required env: BACKEND_TAG
# Optional env: DEPLOY_PATH, BACKEND_REPO_URL, DOMAIN, BACKEND_GIT_TOKEN

DEPLOY_PATH="${DEPLOY_PATH:-/opt/m-dicail}"
BACKEND_REPO_URL="${BACKEND_REPO_URL:-https://github.com/NoFastNoFun/m-dicail-backend.git}"
DOMAIN="${DOMAIN:-medicail.nf2.tech}"
BACKEND_TAG="${BACKEND_TAG:-}"

COMPOSE_FILE="${DEPLOY_PATH}/docker-compose.prod.yml"
BACKEND_DIR="${DEPLOY_PATH}/backend"
TOKEN_FILE="${DEPLOY_PATH}/.generated/backend-git-token"
FIREWALL_SCRIPT="${DEPLOY_PATH}/.generated/configure-host-firewall.sh"
MANAGE_FIREWALL="${MANAGE_FIREWALL:-true}"
SSH_PORT="${SSH_PORT:-22}"
LOG_PREFIX="m-dicail-deploy"

LIB_DIR="${DEPLOY_PATH}/.generated/lib"
# shellcheck source=lib/common.sh
source "${LIB_DIR}/common.sh"
# shellcheck source=lib/git-backend.sh
source "${LIB_DIR}/git-backend.sh"

# Never use SSH for GitHub on the VPS (avoids host-key prompts / deploy keys).
unset GIT_SSH_COMMAND || true

normalize_tag() {
  local tag="$1"
  tag="${tag#refs/tags/}"
  printf '%s' "$tag"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "this script expects root (or passwordless sudo as root)"
  fi
}

require_bootstrap() {
  mkdir -p "${DEPLOY_PATH}"

  [[ -f "${COMPOSE_FILE}" ]] || die "missing ${COMPOSE_FILE}; GitHub Actions should sync it from the deployment repo, or run terraform apply once"
  [[ -f "${DEPLOY_PATH}/.env" ]] || die "missing ${DEPLOY_PATH}/.env; bootstrap the VPS once with: cd terraform && terraform apply"
  [[ -f "${DEPLOY_PATH}/nginx/nginx.conf" ]] || log "WARN: missing ${DEPLOY_PATH}/nginx/nginx.conf (nginx may fail until terraform apply or Actions sync)"
  [[ -f "${DEPLOY_PATH}/nginx/nginx-default.conf.tpl" ]] || die "missing ${DEPLOY_PATH}/nginx/nginx-default.conf.tpl; sync the nginx template from the deployment repo"
  [[ -f "${DEPLOY_PATH}/nginx/snippets/proxy-headers.conf" ]] || die "missing ${DEPLOY_PATH}/nginx/snippets/proxy-headers.conf; sync nginx snippets from the deployment repo"

  require_cmd docker
  docker compose version >/dev/null 2>&1 || die "docker compose plugin required (install via terraform apply or install Docker on the VPS)"
  require_cmd git
  require_cmd curl
}

sync_backend_tag() {
  local tag="$1"
  local clean_url auth_url

  export GIT_TERMINAL_PROMPT=0
  clean_url="$(https_github_url "${BACKEND_REPO_URL}")"
  BACKEND_REPO_URL="${clean_url}"
  auth_url="$(github_authed_url "${clean_url}")"
  log "Backend git over HTTPS + PAT (x-access-token): ${BACKEND_REPO_URL}"

  if [[ -d "${BACKEND_DIR}/.git" ]]; then
    log "Fetching tags in ${BACKEND_DIR}"
    git -C "${BACKEND_DIR}" remote set-url origin "${auth_url}"
    git -C "${BACKEND_DIR}" -c credential.helper= -c core.askPass= fetch --all --tags --prune
    git_cleanup_remote "${BACKEND_DIR}" "${clean_url}"
  else
    log "Cloning backend from ${BACKEND_REPO_URL}"
    rm -rf "${BACKEND_DIR}"
    git -c credential.helper= -c core.askPass= clone "${auth_url}" "${BACKEND_DIR}"
    git_cleanup_remote "${BACKEND_DIR}" "${clean_url}"
    git -C "${BACKEND_DIR}" remote set-url origin "${auth_url}"
    git -C "${BACKEND_DIR}" -c credential.helper= -c core.askPass= fetch --all --tags --prune
    git_cleanup_remote "${BACKEND_DIR}" "${clean_url}"
  fi

  if ! git -C "${BACKEND_DIR}" rev-parse "refs/tags/${tag}" >/dev/null 2>&1; then
    die "tag '${tag}' not found in ${BACKEND_REPO_URL} (after fetch)"
  fi

  log "Checking out tag ${tag} (detached HEAD)"
  git -C "${BACKEND_DIR}" checkout --detach "refs/tags/${tag}"
  git -C "${BACKEND_DIR}" reset --hard "refs/tags/${tag}"

  log "Backend at $(git -C "${BACKEND_DIR}" rev-parse --short HEAD) (${tag})"
}

configure_firewall() {
  if [[ ! -f "${FIREWALL_SCRIPT}" ]]; then
    log "WARN: missing ${FIREWALL_SCRIPT}; run terraform apply to install host firewall lockdown"
    return 0
  fi
  chmod 755 "${FIREWALL_SCRIPT}"
  env MANAGE_FIREWALL="${MANAGE_FIREWALL}" SSH_PORT="${SSH_PORT}" bash "${FIREWALL_SCRIPT}"
}

dump_api_failure() {
  docker compose -f "${COMPOSE_FILE}" ps || true
  docker compose -f "${COMPOSE_FILE}" logs --tail=120 api || true
}

health_check() {
  local i
  log "Waiting for api via nginx upstream http://api:8000/health"
  for i in $(seq 1 36); do
    if docker compose -f "${COMPOSE_FILE}" exec -T nginx wget -qO- --timeout=3 http://api:8000/health 2>/dev/null | grep -q ok; then
      log "Upstream /health ok"
      if curl -fsSk --max-time 5 --resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}/health" | grep -q ok; then
        log "Local HTTPS /health passed"
        return 0
      fi
      log "WARN: api is up but local HTTPS /health failed (nginx/TLS)"
    fi
    if docker compose -f "${COMPOSE_FILE}" ps api 2>/dev/null | grep -qi restarting; then
      log "api container is restarting — not waiting out Cloudflare 502s"
      dump_api_failure
      die "api crash-loop. Look for 'Production env missing:' in the api logs above. If SMTP_* are listed, run GitHub Actions → Sync VPS environment, then recreate the api container."
    fi
    sleep 5
  done
  log "Health check failed after retries"
  dump_api_failure
  exit 1
}

main() {
  require_root
  reject_expired_domain "${DOMAIN}"

  [[ -n "${BACKEND_TAG}" ]] || die "BACKEND_TAG is required"

  local tag
  tag="$(normalize_tag "${BACKEND_TAG}")"
  [[ -n "${tag}" ]] || die "BACKEND_TAG is empty after normalization"

  require_bootstrap
  stop_insecure_published_stacks
  configure_firewall
  sync_backend_tag "${tag}"
  if [[ -f "${DEPLOY_PATH}/.generated/ensure-site-tls.sh" ]]; then
    chmod 755 "${DEPLOY_PATH}/.generated/ensure-site-tls.sh"
    env DOMAIN="${DOMAIN}" ACME_EMAIL="${ACME_EMAIL:-}" DEPLOY_PATH="${DEPLOY_PATH}" \
      bash "${DEPLOY_PATH}/.generated/ensure-site-tls.sh"
  else
    log "WARN: missing ${DEPLOY_PATH}/.generated/ensure-site-tls.sh; nginx/TLS will not be updated"
  fi
  require_prod_env
  start_compose_stack true
  health_check
  log "Deploy of tag ${tag} complete"
}

main "$@"
