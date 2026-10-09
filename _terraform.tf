terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    encrypt      = true
    use_lockfile = true
  }
}

# TODO: Bootstrap the state bucket once, then comment this out again.
# 1. Comment out backend "s3"
# 2. Uncomment this block and set the bucket name
# 3. Apply with local state
# 4. Comment the block out again, enable the backend, run init -migrate-state
#
# resource "aws_s3_bucket" "tfstate" {
#   bucket = "REPLACE_ME-tfstate"
# }
#
# resource "aws_s3_bucket_versioning" "tfstate" {
#   bucket = aws_s3_bucket.tfstate.id
#
#   versioning_configuration {
#     status = "Enabled"
#   }
# }
#
# resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
#   bucket = aws_s3_bucket.tfstate.id
#
#   rule {
#     apply_server_side_encryption_by_default {
#       sse_algorithm = "AES256"
#     }
#   }
# }
#
# resource "aws_s3_bucket_public_access_block" "tfstate" {
#   bucket                  = aws_s3_bucket.tfstate.id
#   block_public_acls       = true
#   block_public_policy     = true
#   ignore_public_acls      = true
#   restrict_public_buckets = true
# }
