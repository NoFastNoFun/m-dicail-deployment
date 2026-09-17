variable "ssh_host" {
  description = "VPS public IP or hostname"
  type        = string
}

variable "ssh_user" {
  description = "SSH user with sudo privileges"
  type        = string
  default     = "root"
}

variable "ssh_port" {
  description = "SSH port"
  type        = number
  default     = 22
}

variable "ssh_private_key_path" {
  description = "Path to the SSH private key used to connect to the VPS"
  type        = string
}

variable "domain" {
  description = "Public domain pointing at the VPS via Cloudflare DNS (Let's Encrypt HTTP-01)"
  type        = string
  default     = "medicail.nf2.tech"

  validation {
    condition     = !can(regex("\\.nf2\\.dev$", var.domain))
    error_message = "domain uses expired nf2.dev; set domain = \"medicail.nf2.tech\"."
  }
}

variable "acme_email" {
  description = "Email for Let's Encrypt registration and expiry notices"
  type        = string
}

variable "deploy_path" {
  description = "Absolute path on the VPS where the stack is installed"
  type        = string
  default     = "/opt/m-dicail"
}

variable "backend_repo_url" {
  description = "Git URL of m-dicail-backend (cloned on the VPS as build context)"
  type        = string
  default     = "https://github.com/NoFastNoFun/m-dicail-backend.git"
}

variable "backend_git_token" {
  description = "GitHub PAT (classic or fine-grained) with contents:read on the backend repo. Required for private repos; avoids interactive username/password prompts on the VPS."
  type        = string
  default     = ""
  sensitive   = true
}

variable "backend_ref" {
  description = "Git branch, tag, or commit to deploy"
  type        = string
  default     = "main"
}

variable "manage_firewall" {
  description = "If true, enable UFW (default deny; SSH/80/443 only) and DOCKER-USER rules so container ports cannot bypass the firewall"
  type        = bool
  default     = true
}

variable "port" {
  description = "API listen port inside the Compose network"
  type        = number
  default     = 8000
}

variable "ai_port" {
  description = "AI service listen port inside the Compose network"
  type        = number
  default     = 8001
}

variable "secret_key" {
  description = "JWT / app secret (SECRET_KEY)"
  type        = string
  sensitive   = true
}

variable "postgres_user" {
  description = "Postgres username for the Medicail database"
  type        = string
  sensitive   = true
}

variable "postgres_password" {
  description = "Postgres password"
  type        = string
  sensitive   = true
}

variable "postgres_db" {
  description = "Postgres database name"
  type        = string
}

variable "ncbi_api_key" {
  description = "Optional NCBI/PubMed API key"
  type        = string
  default     = ""
  sensitive   = true
}

variable "groq_api_key" {
  description = "Groq API key for AI speech-to-text (apps/ai). Required for cloud transcription enhance."
  type        = string
  default     = ""
  sensitive   = true
}

variable "ncbi_email" {
  description = "Optional NCBI contact email for E-utilities requests"
  type        = string
  default     = ""
}

variable "access_token_ttl" {
  description = "JWT access token lifetime (e.g. 1h)"
  type        = string
  default     = "1h"
}

variable "refresh_token_ttl_days" {
  description = "Refresh token lifetime in days"
  type        = number
  default     = 7
}

variable "smtp_host" {
  description = "Outbound SMTP host (e.g. smtp.proton.me). Required to send password-reset mail."
  type        = string
  default     = "smtp.proton.me"
}

variable "smtp_port" {
  description = "Outbound SMTP port (587 for Proton STARTTLS)"
  type        = number
  default     = 587
}

variable "smtp_user" {
  description = "SMTP username (Proton address or Bridge user)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "smtp_pass" {
  description = "SMTP password or Proton SMTP token"
  type        = string
  default     = ""
  sensitive   = true
}

variable "smtp_from" {
  description = "From header for outbound mail (e.g. Medicail <noreply@proton.me>)"
  type        = string
  default     = ""
}

variable "webauthn_rp_name" {
  description = "WebAuthn relying party display name"
  type        = string
  default     = "Medicail"
}

variable "firebase_project_id" {
  description = "Optional Firebase project ID for FCM (API skips push when empty)"
  type        = string
  default     = ""
}

variable "firebase_client_email" {
  description = "Optional Firebase service-account client email for FCM"
  type        = string
  default     = ""
  sensitive   = true
}

variable "firebase_private_key" {
  description = "Optional Firebase service-account PEM private key (\\n escaped)"
  type        = string
  default     = ""
  sensitive   = true
}
