locals {
  ssh_private_key = file(pathexpand(var.ssh_private_key_path))

  connection = {
    type        = "ssh"
    user        = var.ssh_user
    private_key = local.ssh_private_key
    host        = var.ssh_host
    port        = var.ssh_port
    timeout     = "5m"
  }

  env_file = templatefile("${path.module}/templates/env.tftpl", {
    port                   = var.port
    ai_port                = var.ai_port
    secret_key             = var.secret_key
    postgres_user          = var.postgres_user
    postgres_password      = var.postgres_password
    postgres_db            = var.postgres_db
    ncbi_api_key           = var.ncbi_api_key
    ncbi_email             = var.ncbi_email
    access_token_ttl       = var.access_token_ttl
    refresh_token_ttl_days = var.refresh_token_ttl_days
    app_public_url         = "https://${var.domain}"
    smtp_host              = var.smtp_host
    smtp_port              = var.smtp_port
    smtp_user              = var.smtp_user
    smtp_pass              = var.smtp_pass
    smtp_from              = var.smtp_from
    webauthn_rp_id         = var.domain
    webauthn_rp_name       = var.webauthn_rp_name
    webauthn_origin        = "https://${var.domain}"
  })

  nginx_default = replace(
    file("${path.module}/templates/nginx-default.conf"),
    "__DOMAIN__",
    var.domain,
  )

  deploy_script = replace(templatefile("${path.module}/templates/deploy.sh.tftpl", {
    deploy_path      = var.deploy_path
    domain           = var.domain
    acme_email       = var.acme_email
    backend_repo_url = var.backend_repo_url
    backend_ref      = var.backend_ref
    manage_firewall  = var.manage_firewall
    ssh_port         = var.ssh_port
  }), "\r\n", "\n")

  backend_git_token_file = var.backend_git_token
  # Strip CR so bash on the VPS never sees `pipefail\r` (invalid option name).
  firewall_script = replace(replace(
    file("${path.module}/../scripts/configure-host-firewall.sh"),
    "\r\n",
    "\n",
  ), "\r", "")

  # Bump when deploy semantics change so null_resource always re-runs.
  deploy_generation = "6-docker-user-egress"

  # Triggers re-provision when deploy inputs or artifacts change.
  content_fingerprint = sha256(join("|", [
    local.env_file,
    local.nginx_default,
    local.deploy_script,
    local.firewall_script,
    local.deploy_generation,
    file("${path.module}/../docker/docker-compose.prod.yml"),
    file("${path.module}/../docker/nginx/nginx.conf"),
    var.backend_repo_url,
    var.backend_ref,
    var.domain,
    var.deploy_path,
    tostring(var.ssh_port),
    sha256(var.backend_git_token),
  ]))
}

resource "local_file" "rendered_nginx_default" {
  content         = local.nginx_default
  filename        = "${path.module}/.generated/nginx-default.conf"
  file_permission = "0644"
}

resource "local_file" "rendered_env" {
  content         = local.env_file
  filename        = "${path.module}/.generated/env"
  file_permission = "0600"
}

resource "local_file" "rendered_deploy_script" {
  content         = local.deploy_script
  filename        = "${path.module}/.generated/deploy.sh"
  file_permission = "0755"
}

resource "local_file" "rendered_backend_git_token" {
  content         = local.backend_git_token_file
  filename        = "${path.module}/.generated/backend-git-token"
  file_permission = "0600"
}

resource "local_file" "rendered_firewall_script" {
  content         = local.firewall_script
  filename        = "${path.module}/.generated/configure-host-firewall.sh"
  file_permission = "0755"
}

resource "null_resource" "deploy" {
  triggers = {
    fingerprint = local.content_fingerprint
  }

  connection {
    type        = local.connection.type
    user        = local.connection.user
    private_key = local.connection.private_key
    host        = local.connection.host
    port        = local.connection.port
    timeout     = local.connection.timeout
  }

  provisioner "remote-exec" {
    inline = [
      "mkdir -p ${var.deploy_path}/nginx/conf.d ${var.deploy_path}/.generated",
      # Drop any leftover nginx site configs from earlier broken deploys.
      "rm -f ${var.deploy_path}/nginx/conf.d/*.conf ${var.deploy_path}/nginx/conf.d/*.conf.bak || true",
    ]
  }

  provisioner "file" {
    source      = "${path.module}/../docker/docker-compose.prod.yml"
    destination = "${var.deploy_path}/docker-compose.prod.yml"
  }

  provisioner "file" {
    source      = "${path.module}/../docker/nginx/nginx.conf"
    destination = "${var.deploy_path}/nginx/nginx.conf"
  }

  provisioner "file" {
    source      = local_file.rendered_nginx_default.filename
    destination = "${var.deploy_path}/nginx/conf.d/default.conf"
  }

  provisioner "file" {
    source      = local_file.rendered_env.filename
    destination = "${var.deploy_path}/.env"
  }

  provisioner "file" {
    source      = local_file.rendered_deploy_script.filename
    destination = "${var.deploy_path}/.generated/deploy.sh"
  }

  provisioner "file" {
    source      = local_file.rendered_backend_git_token.filename
    destination = "${var.deploy_path}/.generated/backend-git-token"
  }

  provisioner "file" {
    source      = local_file.rendered_firewall_script.filename
    destination = "${var.deploy_path}/.generated/configure-host-firewall.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod 600 ${var.deploy_path}/.env",
      "chmod 600 ${var.deploy_path}/.generated/backend-git-token",
      "chmod 755 ${var.deploy_path}/.generated/deploy.sh",
      "chmod 755 ${var.deploy_path}/.generated/configure-host-firewall.sh",
      # Belt-and-suspenders: drop any CR that survived the file provisioner.
      "sed -i 's/\\r$//' ${var.deploy_path}/.generated/deploy.sh ${var.deploy_path}/.generated/configure-host-firewall.sh",
      "if grep -nE 'upstream_|[$][$]' ${var.deploy_path}/nginx/conf.d/default.conf; then echo 'REFUSING broken nginx config' >&2; exit 1; fi",
      "echo '[m-dicail-deploy] nginx site config (head):' && sed -n '1,45p' ${var.deploy_path}/nginx/conf.d/default.conf",
      "sudo ${var.deploy_path}/.generated/deploy.sh",
    ]
  }

  depends_on = [
    local_file.rendered_nginx_default,
    local_file.rendered_env,
    local_file.rendered_deploy_script,
    local_file.rendered_backend_git_token,
    local_file.rendered_firewall_script,
  ]
}
