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
  description = <<-EOT
    Environment name. Deliberately not "dev": this stack is a parallel
    deployment of the same application on EKS, and it must not collide with the
    ECS stack in envs/dev - same state bucket, different key, different names.
  EOT
  type        = string
  default     = "eks"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC. Self-contained so this stack can stand up and be destroyed without touching envs/dev."
  type        = string
  default     = "10.1.0.0/16"
}

variable "kubernetes_version" {
  description = <<-EOT
    EKS control plane version. Pin it: a version that falls out of standard
    support moves to extended support and the hourly price goes up roughly 6x.
  EOT
  type        = string
  default     = "1.31"
}

variable "node_instance_type" {
  description = <<-EOT
    Node instance type. t3.small, not t4g.small, on purpose: the Dockerfile
    produces an amd64 image, and an arm64 node group would leave every pod in
    CreateContainerError with an exec format error. Switch to t4g only together
    with a buildx --platform linux/arm64 build.
  EOT
  type        = string
  default     = "t3.small"
}

variable "node_desired_size" {
  description = <<-EOT
    Nodes in the managed node group. Two t3.small gives 2 vCPU and ~3.2 GiB of
    allocatable memory, which holds the HPA's 7-pod ceiling at 250m requests
    with room for kube-system. The pod ceiling, not the node ceiling, is what
    the connection budget constrains.
  EOT
  type        = number
  default     = 2
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  description = <<-EOT
    Node group ceiling. This is a different ceiling from the HPA's: nodes buy
    room to place pods, pods consume database connections. Raising this does not
    make it safe to raise autoscaling.maxReplicas - see docs/kubernetes.md.
  EOT
  type        = number
  default     = 3
}

variable "db_instance_class" {
  description = "RDS instance class. Matches envs/dev so load test numbers are comparable."
  type        = string
  default     = "db.t4g.micro"
}

variable "postgres_version" {
  description = "Postgres major version only. A pinned minor gets deprecated and RDS rejects it."
  type        = string
  default     = "16"
}

variable "admin_access_entry_arn" {
  description = <<-EOT
    IAM principal ARN to grant cluster-admin through an EKS access entry. Leave
    empty to grant it to whoever runs the apply.

    Access entries replace the aws-auth ConfigMap. The old failure mode was
    memorable: a cluster created by a role nobody assumes again, with no way to
    get a kubectl session back.
  EOT
  type        = string
  default     = ""
}
