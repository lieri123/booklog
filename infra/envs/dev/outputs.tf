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

output "alb_url" {
  description = "Public URL of the service. Try /healthz and /docs."
  value       = "http://${aws_lb.main.dns_name}"
}

output "ecr_repository_url" {
  description = "Push images here. Used by the deploy workflow."
  value       = aws_ecr_repository.app.repository_url
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  value = aws_ecs_service.app.name
}

output "task_definition_family" {
  value = aws_ecs_task_definition.app.family
}

output "github_actions_role_arn" {
  description = <<-EOT
    Add as the AWS_ROLE_ARN repository variable in GitHub. Empty if
    github_repo was not set.
  EOT
  value       = try(aws_iam_role.github_actions[0].arn, "")
}

output "dashboard_url" {
  description = "CloudWatch dashboard. Open this before starting a load test."
  value       = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards:name=${aws_cloudwatch_dashboard.main.dashboard_name}"
}

output "alerts_topic_arn" {
  description = "SNS topic the alarms publish to."
  value       = aws_sns_topic.alerts.arn
}

output "log_group_name" {
  description = "Application log group. `aws logs tail <this> --follow`."
  value       = aws_cloudwatch_log_group.app.name
}

output "alarm_names" {
  description = "Every alarm, for scripted state checks during a load test."
  value = [
    aws_cloudwatch_metric_alarm.alb_target_5xx.alarm_name,
    aws_cloudwatch_metric_alarm.alb_elb_5xx.alarm_name,
    aws_cloudwatch_metric_alarm.alb_latency.alarm_name,
    aws_cloudwatch_metric_alarm.unhealthy_targets.alarm_name,
    aws_cloudwatch_metric_alarm.rds_connections.alarm_name,
    aws_cloudwatch_metric_alarm.rds_cpu.alarm_name,
    aws_cloudwatch_metric_alarm.rds_cpu_credits.alarm_name,
    aws_cloudwatch_metric_alarm.rds_storage.alarm_name,
    aws_cloudwatch_metric_alarm.app_errors.alarm_name,
  ]
}
