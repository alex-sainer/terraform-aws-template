variable "aws_region" {
  description = "AWS region for the provider."
  type        = string
}

variable "project" {
  description = "Project name. Used in the common tags."
  type        = string
}

variable "example_bucket_name" {
  description = "Globally unique name of the example bucket. Must follow the S3 naming rules."
  type        = string
}
