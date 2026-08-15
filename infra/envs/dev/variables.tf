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

variable "alert_email" {
  description = <<-EOT
    Email address for alarm notifications. AWS sends a confirmation link that
    you must click before anything is delivered - until then the subscription
    reads "Pending confirmation" and alarms fire silently. Leave empty to
    create the SNS topic without a subscriber.
  EOT
  type        = string
  default     = ""
}

variable "alarm_latency_p95_seconds" {
  description = <<-EOT
    p95 response time that counts as a problem. Set this to a number you would
    actually defend, not one your service currently meets - an objective you
    always pass tells you nothing.
  EOT
  type        = number
  default     = 1.0
}

variable "alarm_5xx_threshold" {
  description = <<-EOT
    Target 5xx responses per minute before alarming. Zero is tempting and
    wrong for a dev environment: one restart during a deploy produces a
    handful of them and trains you to ignore the alarm.
  EOT
  type        = number
  default     = 5
}

variable "alarm_db_connections_threshold" {
  description = <<-EOT
    Database connections that count as approaching the limit. db.t4g.micro has
    1 GiB of memory and RDS derives max_connections from it - roughly 112.
    Recompute this if you resize the instance.
  EOT
  type        = number
  default     = 80
}

variable "alarm_app_error_threshold" {
  description = "Application error log lines per 5 minutes before alarming."
  type        = number
  default     = 10
}

variable "autoscaling_min_capacity" {
  description = "Floor for the ECS service. Two keeps one task per AZ."
  type        = number
  default     = 2
}

variable "autoscaling_max_capacity" {
  description = <<-EOT
    Ceiling for the ECS service. This is your cost control: at 0.25 vCPU and
    512 MiB, six tasks is roughly $0.05/hour. It is also a blast-radius limit
    on the database - every task opens its own connection pool, so the
    ceiling must keep total connections under the RDS maximum.
  EOT
  type        = number
  default     = 6
}

variable "autoscaling_cpu_target" {
  description = <<-EOT
    Average CPU percentage to hold steady. 60 leaves headroom to absorb load
    during the ~90 seconds a new Fargate task takes to pull, start, and pass
    two health checks.
  EOT
  type        = number
  default     = 60
}

variable "autoscaling_requests_per_target" {
  description = <<-EOT
    Requests per task per minute to hold steady. Derive this from a load test
    rather than guessing: find the throughput at which p95 crosses your
    objective with one task, then use ~70% of it.
  EOT
  type        = number
  default     = 300
}
