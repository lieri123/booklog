variable "region" {
  description = "AWS region. Keep everything in one region."
  type        = string
  default     = "ca-central-1"
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

variable "github_repo" {
  description = <<-EOT
    GitHub repo as "owner/name", e.g. "aihfo/booklog". Enables the OIDC
    provider and deploy role. Leave empty to skip creating them - useful
    before you've pushed the repo anywhere.
  EOT
  type        = string
  default     = ""
}

variable "image_tag" {
  description = <<-EOT
    Image tag for the initial task definition. The deploy pipeline overrides
    this with the git SHA on every push; this default only matters for the
    very first apply, before any image exists.
  EOT
  type        = string
  default     = "bootstrap"
}

variable "task_cpu" {
  description = "Fargate CPU units. 256 = 0.25 vCPU."
  type        = number
  default     = 256
}

variable "task_memory" {
  description = "Fargate memory in MiB. Must be a valid pairing with task_cpu."
  type        = number
  default     = 512
}

variable "desired_count" {
  description = "Number of tasks. Two so an AZ failure doesn't take you down."
  type        = number
  default     = 2
}
