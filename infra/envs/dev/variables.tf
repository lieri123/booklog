variable "region" {
  description = "AWS region. Keep everything in one region."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Name prefix for all resources."
  type        = string
  default     = "booklog"
}

variable "environment" {
  description = "Environment name. Used in resource names and tags."
  type        = string
  default     = "dev"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC. /16 leaves room for 256 /24 subnets."
  type        = string
  default     = "10.0.0.0/16"
}

variable "app_port" {
  description = "Port the application listens on inside the container."
  type        = number
  default     = 8080
}

variable "db_instance_class" {
  description = "RDS instance class. db.t4g.micro is free tier eligible."
  type        = string
  default     = "db.t4g.micro"
}

variable "postgres_version" {
  description = <<-EOT
    Postgres major version only. Pinning a full minor version like "16.4" is
    a common first failure: minor versions get deprecated and RDS rejects
    them with InvalidParameterCombination. Major-only lets RDS pick the
    current minor.
  EOT
  type        = string
  default     = "16"
}
