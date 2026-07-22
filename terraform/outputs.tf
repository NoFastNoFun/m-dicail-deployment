output "deploy_path" {
  description = "Remote install directory"
  value       = var.deploy_path
}

output "api_base_url" {
  description = "Public API base URL (versioned routes under /api/v1)"
  value       = "https://${var.domain}/api"
}

output "health_url" {
  description = "Health check URL"
  value       = "https://${var.domain}/health"
}

output "docs_url" {
  description = "Swagger docs URL"
  value       = "https://${var.domain}/docs"
}

output "domain" {
  value = var.domain
}
