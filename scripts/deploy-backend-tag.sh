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

git_with_auth() {
  local token
  token="$(read_backend_token)"
  if [[ -n "${token}" ]]; then
    git -c "http.extraHeader=Authorization: Bearer ${token}" "$@"
  else
    git "$@"
  fi
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
  local token

  export GIT_TERMINAL_PROMPT=0
  token="$(read_backend_token)"
  if [[ -z "${token}" ]]; then
    log "WARN: no BACKEND_GIT_TOKEN / ${TOKEN_FILE}; private HTTPS clones will fail"
  fi

  if [[ -d "${BACKEND_DIR}/.git" ]]; then
    log "Fetching tags in ${BACKEND_DIR}"
    git -C "${BACKEND_DIR}" remote set-url origin "${BACKEND_REPO_URL}"
    git_with_auth -C "${BACKEND_DIR}" fetch --all --tags --prune
  else
    log "Cloning backend from ${BACKEND_REPO_URL}"
    rm -rf "${BACKEND_DIR}"
    git_with_auth clone "${BACKEND_REPO_URL}" "${BACKEND_DIR}"
    git -C "${BACKEND_DIR}" remote set-url origin "${BACKEND_REPO_URL}"
    git_with_auth -C "${BACKEND_DIR}" fetch --all --tags --prune
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
  docker compose -f "${COMPOSE_FILE}" up -d --build --remove-orphans
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
  sync_backend_tag "${tag}"
  start_stack
  health_check
  log "Deploy of tag ${tag} complete"
}

main "$@"
