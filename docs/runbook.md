# Runbook

Nine alarms publish to one SNS topic, which emails `alert_email`. All of them
use `treat_missing_data = "notBreaching"`. See `decisions.md` for why, and for
what that costs.

## Orientation

```powershell
tofu output -raw dashboard_url        # CloudWatch dashboard
tofu output alarm_names               # all nine
tofu output -raw log_group_name

aws cloudwatch describe-alarms --state-value ALARM --region ca-central-1
aws ecs describe-services --cluster booklog --services booklog-dev --region ca-central-1
```

Recent application errors:

```powershell
aws logs filter-log-events --log-group-name (tofu output -raw log_group_name) `
  --filter-pattern "ERROR" --start-time ((Get-Date).AddMinutes(-15) | Get-Date -UFormat %s) `
  --region ca-central-1
```

---

## Alarms

### `alb_target_5xx`, 5 errors/min for 2 minutes

The application returned 5xx. The ALB reached it, so the fault is in the
application or the database rather than in networking.

Check the log group for `ERROR` and `Traceback` in the window. If the errors
mention pool, connection, or timeout, go to `rds_connections` below. If they are
Open Library timeouts, the upstream is degraded, `POST /library` fails while
reads stay healthy, and there is nothing to fix locally.

### `alb_elb_5xx`, any occurrence for 2 minutes

The load balancer itself failed the request and the application was never
reached.

This almost always means no healthy targets: tasks crash-looping, or a deploy
that replaced every task at once. Check `aws ecs describe-services` for
`runningCount` against `desiredCount`, then `describe-tasks` for
`stoppedReason`. A task failing at startup is usually a missing or unreadable
secret.

### `alb_latency`, p95 above 1.0 s for 3 minutes

Slow rather than broken. Three minutes of evaluation is intentional, since a
single slow minute during a deploy is not an incident.

Look at RDS CPU and `DatabaseConnections` first. If connections are near 80,
this is pool contention, and adding tasks makes it worse rather than better. See
`load-test.md`. If both are low, the slowness is in the application, and the
stats aggregations are the place to look.

### `unhealthy_targets`, any unhealthy target for 2 minutes

Targets are failing `/healthz`, which does not touch the database. A failure
here means the process is not responding at all.

Check whether the count is partial or total. One bad task gets replaced by ECS
without intervention. Every task failing points at the last deploy, and the
right response is to re-run the previous good deploy rather than debug live.

### `rds_connections`, 80 connections for 2 minutes

About 70% of the 112 ceiling on `db.t4g.micro`. At `POOL_MAX_SIZE = 10` per
task, 80 connections is roughly 8 tasks.

Confirm the task count. If autoscaling has run out to `max_capacity`, the
service is connection-bound rather than CPU-bound, and scaling in will improve
latency. That is counterintuitive and documented in `load-test.md`. Do not raise
`max_capacity` in response to this alarm.

To see what holds the connections:

```sql
SELECT state, count(*) FROM pg_stat_activity GROUP BY state;
```

A large number of `idle in transaction` rows means the application is leaking
connections.

### `rds_cpu`, 80% average for 10 minutes

Sustained rather than spiky. At this instance size it is usually an unindexed
query pattern under load rather than genuine capacity exhaustion.

```sql
SELECT query, calls, mean_exec_time FROM pg_stat_statements
ORDER BY mean_exec_time DESC LIMIT 10;
```

### `rds_cpu_credits`, balance below 20

Specific to burstable `t4g` instances. Credits are nearly exhausted, and when
they reach zero the instance is throttled to baseline and everything slows at
once.

This is the one alarm that gives useful warning. The fix is a non-burstable
instance class, or reducing sustained load. There is nothing to do in the
moment except expect `alb_latency` next.

### `rds_storage`, below 2 GB free

Storage does not free itself, and autoscaling storage is off in this
configuration, so ignoring this ends in a stuck instance. Check table sizes. The
usual cause here is accumulated `library_entries` from repeated load test runs,
which is safe to truncate in dev.

### `app_errors`, 10 or more matches in 5 minutes

A log metric filter counting `ERROR`, `CRITICAL`, and `Traceback` in the app log
group. It catches failures that never become 5xx, such as a background call
failing or an exception caught and logged.

This alarm can fire on its own with every ALB metric healthy. That combination
is usually Open Library returning errors on the enrichment path.

---

## Common situations

**Deploy failed at ECR login.** The stack is torn down. The workflow's guard
step should skip the deploy job cleanly. If it did not, run `tofu apply` and
re-run the workflow.

**Deploy failed at migrations.** The migration task ran and exited non-zero, so
no tasks were replaced and the running service is still on the previous image.
The migration task's logs are in the same log group.

**Everything alarms at once after a rebuild.** Expected. A fresh stack has no
metric history and tasks take a minute or two to pass health checks. Wait five
minutes before treating any of it as real.

## Teardown

```powershell
.\scripts\teardown.ps1            # destroy, then report what survived
.\scripts\teardown.ps1 -Delete    # and remove it
```

The script wraps `tofu destroy -var="github_repo=lieri123/booklog"`. The `-var`
matters. Omitting it evaluates `count = 0` on the OIDC provider and the deploy
role, and both are destroyed silently. See `decisions.md`.

Three things outlive a destroy and keep billing:

The log group RDS creates for `enabled_cloudwatch_logs_exports` is not managed
by Terraform. RDS creates it lazily on first write, so it never enters the state
file, and it has no retention policy. It is the most persistent leftover in this
stack.

The RDS master user secret goes into a recovery window rather than being deleted
outright, since `manage_master_user_password = true` hands its lifecycle to AWS.

Manual snapshots, if any were taken by hand, are never removed by destroy.

The sweep reports all three and deletes them under `-Delete`. It never touches
the S3 state bucket or the DynamoDB lock table in `us-east-1`, and neither
should anything else.
