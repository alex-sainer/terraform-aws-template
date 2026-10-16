locals {
  example_bucket_name = "${var.name_prefix}-${local.environment}-example"
}

resource "aws_s3_bucket" "example" {
  bucket = local.example_bucket_name

  # Previews are destroyed when their pull request closes, objects included.
  force_destroy = local.is_preview

  lifecycle {
    precondition {
      condition     = length(local.example_bucket_name) <= 63
      error_message = "Bucket name '${local.example_bucket_name}' is longer than 63 characters. Shorten name_prefix or the branch name."
    }
  }
}

resource "aws_s3_bucket_ownership_controls" "example" {
  bucket = aws_s3_bucket.example.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "example" {
  bucket = aws_s3_bucket.example.id

  versioning_configuration {
    status = "Enabled"
  }
}

# SSE-S3 keeps the example free of KMS keys and their cost. Switch to aws:kms with your own key if you need one.
#trivy:ignore:AWS-0132
resource "aws_s3_bucket_server_side_encryption_configuration" "example" {
  bucket = aws_s3_bucket.example.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "example" {
  bucket                  = aws_s3_bucket.example.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
