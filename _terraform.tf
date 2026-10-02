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

# TODO: State-Bucket einmalig bootstrapen, danach wieder auskommentieren.
# 1. backend "s3" auskommentieren
# 2. diesen Block einkommentieren und den Bucket-Namen setzen
# 3. apply mit lokalem State
# 4. Block wieder auskommentieren, Backend aktivieren, init -migrate-state
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
