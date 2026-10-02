output "example_bucket_name" {
  description = "Name des Beispiel-Buckets."
  value       = aws_s3_bucket.example.id
}

output "environment" {
  description = "Aktives Environment. Entspricht dem Terraform-Workspace."
  value       = local.environment
}
