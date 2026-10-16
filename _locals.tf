locals {
  environment = terraform.workspace
  is_preview  = startswith(local.environment, "preview-")

  common_tags = {
    Project     = var.project
    Environment = local.environment
    ManagedBy   = "terraform"
  }
}
