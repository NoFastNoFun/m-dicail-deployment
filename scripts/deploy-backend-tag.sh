#!/usr/bin/env bash
set -euo pipefail

# Runs on the VPS after Terraform bootstrap. Checks out a backend git tag and rebuilds Compose.
# Required env: BACKEND_TAG
# Optional env: DEPLOY_PATH, BACKEND_REPO_URL, DOMAIN, BACKEND_GIT_TOKEN

DEPLOY_PATH="${DEPLOY_PATH:-/opt/m-dicail}"
BACKEND_REPO_URL="${BACKEND_REPO_URL:-https://github.com/NoFastNoFun/m-dicail-backend.git}"
DOMAIN="${DOMAIN:-medicail.nf2.dev}"
BACKEND_TAG="${BACKEND_TAG:-}"

COMPOSE_FILE="${DEPLOY_PATH}/docker-compose.prod.yml"
BACKEND_DIR="${DEPLOY_PATH}/backend"
TOKEN_FILE="${DEPLOY_PATH}/.generated/backend-git-token"
FIREWALL_SCRIPT="${DEPLOY_PATH}/.generated/configure-host-firewall.sh"
MANAGE_FIREWALL="${MANAGE_FIREWALL:-true}"
SSH_PORT="${SSH_PORT:-22}"

# Never use SSH for GitHub on the VPS (avoids host-key prompts / deploy keys).
unset GIT_SSH_COMMAND || true

log() {
  echo "[m-dicail-deploy] $*"
}

die() {
  log "ERROR: $*"
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

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

read_backend_token() {
  if [[ -n "${BACKEND_GIT_TOKEN:-}" ]]; then
    printf '%s' "${BACKEND_GIT_TOKEN}"
    return
  fi
  if [[ -f "${TOKEN_FILE}" ]]; then
    tr -d '\r\n' < "${TOKEN_FILE}"
  fi
}

https_github_url() {
  local url="$1"
  case "${url}" in
    git@github.com:*)
      printf 'https://github.com/%s' "${url#git@github.com:}"
      ;;
    ssh://git@github.com/*)
      printf 'https://github.com/%s' "${url#ssh://git@github.com/}"
      ;;
    *)
      printf '%s' "${url}"
      ;;
  esac
}

github_authed_url() {
  local clean token hostpath
  clean="$(https_github_url "$1")"
  token="$(read_backend_token)"
  if [[ -z "${token}" ]]; then
    die "empty GitHub PAT. Set backend_git_token (terraform) or BACKEND_READ_TOKEN (Actions). File: ${TOKEN_FILE}"
  fi
  hostpath="${clean#https://}"
  hostpath="${hostpath#http://}"
  if [[ "${hostpath}" == *@* ]]; then
    hostpath="${hostpath#*@}"
  fi
  printf 'https://x-access-token:%s@%s' "${token}" "${hostpath}"
}

require_bootstrap() {
  mkdir -p "${DEPLOY_PATH}"

  [[ -f "${COMPOSE_FILE}" ]] || die "missing ${COMPOSE_FILE}; GitHub Actions should sync it from the deployment repo, or run terraform apply once"
  [[ -f "${DEPLOY_PATH}/.env" ]] || die "missing ${DEPLOY_PATH}/.env; bootstrap the VPS once with: cd terraform && terraform apply"
  [[ -f "${DEPLOY_PATH}/nginx/nginx.conf" ]] || log "WARN: missing ${DEPLOY_PATH}/nginx/nginx.conf (nginx may fail until terraform apply or Actions sync)"
  [[ -f "${DEPLOY_PATH}/nginx/conf.d/default.conf" ]] || die "missing ${DEPLOY_PATH}/nginx/conf.d/default.conf; bootstrap the VPS once with terraform apply (TLS site config)"

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
    git -C "${BACKEND_DIR}" remote set-url origin "${clean_url}"
  else
    log "Cloning backend from ${BACKEND_REPO_URL}"
    rm -rf "${BACKEND_DIR}"
    git -c credential.helper= -c core.askPass= clone "${auth_url}" "${BACKEND_DIR}"
    git -C "${BACKEND_DIR}" remote set-url origin "${clean_url}"
    git -C "${BACKEND_DIR}" remote set-url origin "${auth_url}"
    git -C "${BACKEND_DIR}" -c credential.helper= -c core.askPass= fetch --all --tags --prune
    git -C "${BACKEND_DIR}" remote set-url origin "${clean_url}"
  fi

  if ! git -C "${BACKEND_DIR}" rev-parse "refs/tags/${tag}" >/dev/null 2>&1; then
    die "tag '${tag}' not found in ${BACKEND_REPO_URL} (after fetch)"
  fi

  log "Checking out tag ${tag} (detached HEAD)"
  git -C "${BACKEND_DIR}" checkout --detach "refs/tags/${tag}"
  git -C "${BACKEND_DIR}" reset --hard "refs/tags/${tag}"

  log "Backend at $(git -C "${BACKEND_DIR}" rev-parse --short HEAD) (${tag})"
}

start_stack() {
  log "Building and starting Docker Compose stack"
  cd "${DEPLOY_PATH}"

  docker compose -f "${COMPOSE_FILE}" up -d --build --remove-orphans --force-recreate

  if [[ -x /usr/local/sbin/m-dicail-docker-user-fw ]]; then
    /usr/local/sbin/m-dicail-docker-user-fw || true
  fi
  if [[ -f "${FIREWALL_SCRIPT}" ]]; then
    chmod 755 "${FIREWALL_SCRIPT}"
    ASSERT_ONLY=true bash "${FIREWALL_SCRIPT}"
  fi
}

stop_insecure_published_stacks() {
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

configure_firewall() {
  if [[ ! -f "${FIREWALL_SCRIPT}" ]]; then
    log "WARN: missing ${FIREWALL_SCRIPT}; run terraform apply to install host firewall lockdown"
    return 0
  fi
  chmod 755 "${FIREWALL_SCRIPT}"
  env MANAGE_FIREWALL="${MANAGE_FIREWALL}" SSH_PORT="${SSH_PORT}" bash "${FIREWALL_SCRIPT}"
}

health_check() {
  local url="https://${DOMAIN}/health"
  log "Waiting for ${url}"
  local i
  for i in $(seq 1 36); do
    if curl -fsS --max-time 5 "${url}" | grep -q ok; then
      log "Health check passed"
      return 0
    fi
    sleep 5
  done
  log "Health check failed after retries"
  docker compose -f "${COMPOSE_FILE}" ps || true
  docker compose -f "${COMPOSE_FILE}" logs --tail=80 || true
  exit 1
}

main() {
  require_root

  [[ -n "${BACKEND_TAG}" ]] || die "BACKEND_TAG is required"

  local tag
  tag="$(normalize_tag "${BACKEND_TAG}")"
  [[ -n "${tag}" ]] || die "BACKEND_TAG is empty after normalization"

  require_bootstrap
  stop_insecure_published_stacks
  configure_firewall
  sync_backend_tag "${tag}"
  start_stack
  health_check
  log "Deploy of tag ${tag} complete"
}

main "$@"
