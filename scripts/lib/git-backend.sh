#!/usr/bin/env bash
# Git HTTPS + PAT helpers for cloning/fetching m-dicail-backend on the VPS.
# Requires: die (from common.sh), TOKEN_FILE, optional BACKEND_GIT_TOKEN.

: "${TOKEN_FILE:=${DEPLOY_PATH:-/opt/m-dicail}/.generated/backend-git-token}"

read_backend_token() {
  if [[ -n "${BACKEND_GIT_TOKEN:-}" ]]; then
    printf '%s' "${BACKEND_GIT_TOKEN}"
    return
  fi
  if [[ -f "${TOKEN_FILE}" ]]; then
    tr -d '\r\n' < "${TOKEN_FILE}"
  fi
}

# Force HTTPS even if tfvars / an old clone uses git@github.com:...
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

# https://github.com/org/repo.git + PAT -> https://x-access-token:PAT@github.com/org/repo.git
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

git_cleanup_remote() {
  local dir="$1"
  local clean_url="$2"
  git -C "${dir}" remote set-url origin "${clean_url}"
}
