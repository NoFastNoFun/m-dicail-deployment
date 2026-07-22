#!/usr/bin/env bash
# Restrict the VPS to SSH + HTTP/HTTPS.
# Docker published ports bypass UFW INPUT; DOCKER-USER closes that hole.
set -euo pipefail

SSH_PORT="${SSH_PORT:-22}"
MANAGE_FIREWALL="${MANAGE_FIREWALL:-true}"
ASSERT_ONLY="${ASSERT_ONLY:-false}"
RULES_HELPER=/usr/local/sbin/m-dicail-docker-user-fw

log() {
  echo "[m-dicail-firewall] $*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1
}

install_ufw() {
  if require_cmd ufw; then
    return 0
  fi
  log "Installing ufw"
  if require_cmd apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y ufw
  elif require_cmd dnf; then
    dnf install -y ufw
  else
    log "ERROR: ufw missing and no apt-get/dnf to install it"
    return 1
  fi
}

install_docker_user_helper() {
  cat > "${RULES_HELPER}" <<'EOF'
#!/usr/bin/env bash
# Re-apply DOCKER-USER policy. Safe to run repeatedly (e.g. after docker restart).
set -euo pipefail

if ! command -v iptables >/dev/null 2>&1; then
  exit 0
fi

iptables -N DOCKER-USER 2>/dev/null || true

# Drop previously installed m-dicail rules (identified by comment).
while true; do
  line="$(iptables -L DOCKER-USER -n --line-numbers 2>/dev/null | awk '/m-dicail-fw/ {print $1; exit}')"
  [[ -n "${line}" ]] || break
  iptables -D DOCKER-USER "${line}" || break
done

# Order matters: first match wins once we insert at position 1 bottom-up.
iptables -I DOCKER-USER 1 -m comment --comment "m-dicail-fw" -j DROP
iptables -I DOCKER-USER 1 -p tcp -m multiport --dports 80,443 -m comment --comment "m-dicail-fw" -j RETURN
iptables -I DOCKER-USER 1 -m conntrack --ctorigdstport 443 --ctdir ORIGINAL -m comment --comment "m-dicail-fw" -j RETURN 2>/dev/null \
  || iptables -I DOCKER-USER 1 -m conntrack --ctorigdstport 443 -m comment --comment "m-dicail-fw" -j RETURN
iptables -I DOCKER-USER 1 -m conntrack --ctorigdstport 80 --ctdir ORIGINAL -m comment --comment "m-dicail-fw" -j RETURN 2>/dev/null \
  || iptables -I DOCKER-USER 1 -m conntrack --ctorigdstport 80 -m comment --comment "m-dicail-fw" -j RETURN
iptables -I DOCKER-USER 1 -i lo -m comment --comment "m-dicail-fw" -j RETURN
iptables -I DOCKER-USER 1 -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment "m-dicail-fw" -j RETURN
EOF
  chmod 755 "${RULES_HELPER}"

  cat > /etc/systemd/system/m-dicail-docker-fw.service <<EOF
[Unit]
Description=m-dicail DOCKER-USER firewall (block published ports except 80/443)
After=docker.service network-online.target
Wants=network-online.target
PartOf=docker.service

[Service]
Type=oneshot
ExecStart=${RULES_HELPER}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target docker.service
EOF

  # Also bounce rules whenever docker.service is restarted.
  mkdir -p /etc/systemd/system/docker.service.d
  cat > /etc/systemd/system/docker.service.d/m-dicail-fw.conf <<EOF
[Service]
ExecStartPost=-${RULES_HELPER}
EOF

  systemctl daemon-reload || true
  systemctl enable m-dicail-docker-fw.service >/dev/null 2>&1 || true
  "${RULES_HELPER}"
  log "Installed DOCKER-USER helper at ${RULES_HELPER}"
}

configure_ufw() {
  install_ufw

  log "Configuring UFW (default deny; allow ${SSH_PORT}/tcp, 80, 443)"
  ufw --force reset >/dev/null 2>&1 || true
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow "${SSH_PORT}/tcp" comment "m-dicail-ssh" || true
  if [[ "${SSH_PORT}" == "22" ]]; then
    ufw allow OpenSSH || true
  fi
  ufw allow 80/tcp comment "m-dicail-http" || true
  ufw allow 443/tcp comment "m-dicail-https" || true
  ufw deny 5432/tcp comment "m-dicail-block-postgres" || true
  ufw deny 8000/tcp comment "m-dicail-block-api" || true
  ufw deny 8001/tcp comment "m-dicail-block-ai" || true
  ufw --force enable
  ufw status verbose || true
}

assert_no_public_app_ports() {
  local bad=0
  local line

  if require_cmd ss; then
    while IFS= read -r line; do
      if echo "${line}" | grep -Eq '0\.0\.0\.0:(5432|8000|8001)\b|\[::\]:(5432|8000|8001)\b|\*:(5432|8000|8001)\b'; then
        log "ERROR: public listener detected: ${line}"
        bad=1
      fi
    done < <(ss -lnt 2>/dev/null || true)
  fi

  if require_cmd docker; then
    while IFS= read -r line; do
      if echo "${line}" | grep -Eq '(^| )0\.0\.0\.0:(5432|8000|8001)->|:::(5432|8000|8001)->'; then
        log "ERROR: Docker published sensitive port: ${line}"
        bad=1
      fi
    done < <(docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null || true)
  fi

  if [[ "${bad}" -ne 0 ]]; then
    log "ERROR: 5432/8000/8001 must not be public. Only 80/443 (and SSH) should be open."
    return 1
  fi
  log "No public listeners on 5432/8000/8001"
}

main() {
  if [[ "${EUID}" -ne 0 ]]; then
    log "ERROR: run as root"
    exit 1
  fi

  if [[ "${ASSERT_ONLY}" == "true" ]]; then
    assert_no_public_app_ports
    return 0
  fi

  if [[ "${MANAGE_FIREWALL}" != "true" ]]; then
    log "Skipping firewall management (MANAGE_FIREWALL=${MANAGE_FIREWALL})"
    return 0
  fi

  configure_ufw
  install_docker_user_helper
  assert_no_public_app_ports
  log "Firewall configuration complete"
}

main "$@"
