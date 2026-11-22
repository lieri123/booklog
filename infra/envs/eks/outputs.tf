output "cluster_name" {
  value = aws_eks_cluster.main.name
}

output "kubeconfig_command" {
  description = "Run this first."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${aws_eks_cluster.main.name}"
}

output "cluster_endpoint" {
  value = aws_eks_cluster.main.endpoint
}

output "oidc_provider_arn" {
  description = "For IRSA roles - External Secrets, the AWS Load Balancer Controller."
  value       = aws_iam_openid_connect_provider.oidc.arn
}

output "ecr_repository_url" {
  description = "Push images here, then set image.repository to this in the Helm values."
  value       = aws_ecr_repository.app.repository_url
}

output "db_endpoint" {
  description = "Hostname:port. Set database.host to the hostname half, without the port."
  value       = aws_db_instance.main.endpoint
}

output "db_host" {
  description = "Set this as database.host in the Helm values."
  value       = aws_db_instance.main.address
}

output "db_secret_arn" {
  description = <<-EOT
    Secrets Manager ARN holding the RDS master credentials. The chart wants a
    Kubernetes Secret with keys `password` and `jwt-secret`; see
    docs/kubernetes.md for the one-liner and for the External Secrets version.
  EOT
  value       = aws_db_instance.main.master_user_secret[0].secret_arn
}

output "helm_install_command" {
  description = "After pushing an image and creating the credentials Secret."
  value       = <<-EOT
    helm upgrade --install booklog deploy/helm/booklog \
      --namespace booklog --create-namespace \
      --set image.repository=${aws_ecr_repository.app.repository_url} \
      --set image.tag=$(git rev-parse --short HEAD) \
      --set database.host=${aws_db_instance.main.address} \
      --set database.existingSecret=booklog-rds \
      --set loadBalancer.enabled=true \
      --atomic --wait
  EOT
}

output "estimated_monthly_cost" {
  description = "Why envs/dev is not this."
  value       = "~$135-150/month: EKS control plane ~$73 + 2 x ${var.node_instance_type} ~$30 + NAT ~$32 + RDS. The ECS Fargate stack is ~$60-70 for the same application."
}
