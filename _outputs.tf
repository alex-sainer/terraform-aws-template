output "example_bucket_name" {
  description = "Name of the example bucket."
  value       = aws_s3_bucket.example.id
}

output "environment" {
  description = "Active environment. Matches the Terraform workspace."
  value       = local.environment
}
