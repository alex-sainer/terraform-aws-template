variable "aws_region" {
  description = "AWS region for the provider."
  type        = string
}

variable "project" {
  description = "Project name. Used in the common tags."
  type        = string
}

variable "name_prefix" {
  description = "Globally unique prefix for resource names, for example acme-shop. The environment is appended, so one value works for every environment."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*[a-z0-9]$", var.name_prefix))
    error_message = "name_prefix must use lowercase letters, digits, and '-'. Replace REPLACE_ME in environments/*.tfvars."
  }
}
