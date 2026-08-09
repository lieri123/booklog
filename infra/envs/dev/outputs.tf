output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "Load balancer goes here in phase 3."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "ECS tasks and RDS live here."
  value       = aws_subnet.private[*].id
}

output "app_security_group_id" {
  description = "Attach to ECS tasks in phase 3."
  value       = aws_security_group.app.id
}

output "alb_security_group_id" {
  value = aws_security_group.alb.id
}

output "db_endpoint" {
  description = "Hostname:port. Only reachable from inside the VPC."
  value       = aws_db_instance.main.endpoint
}

output "db_secret_arn" {
  description = <<-EOT
    Secrets Manager ARN holding the RDS master credentials. Phase 3 references
    this from the ECS task definition's `secrets` block - the password never
    appears in the task definition or in Terraform state.
  EOT
  value       = aws_db_instance.main.master_user_secret[0].secret_arn
}
