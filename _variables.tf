variable "aws_region" {
  description = "AWS-Region für den Provider."
  type        = string
}

variable "project" {
  description = "Projektname. Wird in den gemeinsamen Tags verwendet."
  type        = string
}

variable "example_bucket_name" {
  description = "Global eindeutiger Name des Beispiel-Buckets. Muss den S3-Namensregeln entsprechen."
  type        = string
}
