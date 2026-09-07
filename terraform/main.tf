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

  # Inputs that feed scripts/render-env.sh (single env source of truth).
  env_fingerprint = sha256(join("|", [
    tostring(var.port),
    tostring(var.ai_port),
    var.secret_key,
    var.postgres_user,
    var.postgres_password,
    var.postgres_db,
    var.ncbi_api_key,
    var.ncbi_email,
    var.access_token_ttl,
    tostring(var.refresh_token_ttl_days),
    var.smtp_host,
    tostring(var.smtp_port),
    var.smtp_user,
    var.smtp_pass,
    var.smtp_from,
    var.webauthn_rp_name,
    var.domain,
  ]))

  # Normalize LF only (repo enforces eol=lf via .gitattributes).
  nginx_template = replace(file("${path.module}/templates/nginx-default.conf"), "\r", "")

  ensure_site_tls_script = replace(file("${path.module}/../scripts/ensure-site-tls.sh"), "\r", "")

  deploy_script = replace(templatefile("${path.module}/templates/deploy.sh.tftpl", {
    deploy_path      = var.deploy_path
    domain           = var.domain
    acme_email       = var.acme_email
    backend_repo_url = var.backend_repo_url
    backend_ref      = var.backend_ref
    manage_firewall  = var.manage_firewall
    ssh_port         = var.ssh_port
  }), "\r", "")

  firewall_script = replace(file("${path.module}/../scripts/configure-host-firewall.sh"), "\r", "")

  common_lib_script = replace(file("${path.module}/../scripts/lib/common.sh"), "\r", "")
  git_lib_script    = replace(file("${path.module}/../scripts/lib/git-backend.sh"), "\r", "")
  proxy_headers     = replace(file("${path.module}/../docker/nginx/snippets/proxy-headers.conf"), "\r", "")

  backend_git_token_file = var.backend_git_token

  # Bump when deploy semantics change so null_resource always re-runs.
  deploy_generation = "8-clean-code-shared-lib"

  content_fingerprint = sha256(join("|", [
    local.env_fingerprint,
    local.nginx_template,
    local.ensure_site_tls_script,
    local.deploy_script,
    local.firewall_script,
    local.common_lib_script,
    local.git_lib_script,
    local.proxy_headers,
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

resource "null_resource" "render_env" {
  triggers = {
    fingerprint = local.env_fingerprint
  }

  provisioner "local-exec" {
    command = "mkdir -p '${path.module}/.generated' && bash '${path.module}/../scripts/render-env.sh' > '${path.module}/.generated/env' && chmod 600 '${path.module}/.generated/env'"
    environment = {
      PORT                   = tostring(var.port)
      AI_PORT                = tostring(var.ai_port)
      SECRET_KEY             = var.secret_key
      POSTGRES_USER          = var.postgres_user
      POSTGRES_PASSWORD      = var.postgres_password
      POSTGRES_DB            = var.postgres_db
      NCBI_API_KEY           = var.ncbi_api_key
      NCBI_EMAIL             = var.ncbi_email
      ACCESS_TOKEN_TTL       = var.access_token_ttl
      REFRESH_TOKEN_TTL_DAYS = tostring(var.refresh_token_ttl_days)
      SMTP_HOST              = var.smtp_host
      SMTP_PORT              = tostring(var.smtp_port)
      SMTP_USER              = var.smtp_user
      SMTP_PASS              = var.smtp_pass
      SMTP_FROM              = var.smtp_from
      WEBAUTHN_RP_NAME       = var.webauthn_rp_name
      DOMAIN                 = var.domain
    }
  }
}

resource "local_file" "nginx_template" {
  content         = local.nginx_template
  filename        = "${path.module}/.generated/nginx-default.conf.tpl"
  file_permission = "0644"
}

resource "local_file" "rendered_ensure_site_tls" {
  content         = local.ensure_site_tls_script
  filename        = "${path.module}/.generated/ensure-site-tls.sh"
  file_permission = "0755"
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

resource "local_file" "rendered_common_lib" {
  content         = local.common_lib_script
  filename        = "${path.module}/.generated/lib/common.sh"
  file_permission = "0755"
}

resource "local_file" "rendered_git_lib" {
  content         = local.git_lib_script
  filename        = "${path.module}/.generated/lib/git-backend.sh"
  file_permission = "0755"
}

resource "local_file" "rendered_proxy_headers" {
  content         = local.proxy_headers
  filename        = "${path.module}/.generated/proxy-headers.conf"
  file_permission = "0644"
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
      "mkdir -p ${var.deploy_path}/nginx/conf.d ${var.deploy_path}/nginx/snippets ${var.deploy_path}/.generated/lib",
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
    source      = local_file.nginx_template.filename
    destination = "${var.deploy_path}/nginx/nginx-default.conf.tpl"
  }

  provisioner "file" {
    source      = local_file.rendered_proxy_headers.filename
    destination = "${var.deploy_path}/nginx/snippets/proxy-headers.conf"
  }

  provisioner "file" {
    source      = local_file.rendered_ensure_site_tls.filename
    destination = "${var.deploy_path}/.generated/ensure-site-tls.sh"
  }

  provisioner "file" {
    source      = "${path.module}/.generated/env"
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

  provisioner "file" {
    source      = local_file.rendered_common_lib.filename
    destination = "${var.deploy_path}/.generated/lib/common.sh"
  }

  provisioner "file" {
    source      = local_file.rendered_git_lib.filename
    destination = "${var.deploy_path}/.generated/lib/git-backend.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod 600 ${var.deploy_path}/.env",
      "chmod 600 ${var.deploy_path}/.generated/backend-git-token",
      "chmod 755 ${var.deploy_path}/.generated/deploy.sh",
      "chmod 755 ${var.deploy_path}/.generated/configure-host-firewall.sh",
      "chmod 755 ${var.deploy_path}/.generated/ensure-site-tls.sh",
      "chmod 755 ${var.deploy_path}/.generated/lib/common.sh ${var.deploy_path}/.generated/lib/git-backend.sh",
      "sudo ${var.deploy_path}/.generated/deploy.sh",
    ]
  }

  depends_on = [
    null_resource.render_env,
    local_file.nginx_template,
    local_file.rendered_ensure_site_tls,
    local_file.rendered_deploy_script,
    local_file.rendered_backend_git_token,
    local_file.rendered_firewall_script,
    local_file.rendered_common_lib,
    local_file.rendered_git_lib,
    local_file.rendered_proxy_headers,
  ]
}
