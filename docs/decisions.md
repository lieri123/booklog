# Decisions

Infrastructure and operational choices. Application-level decisions (works vs
editions, `/healthz` not touching the database, 404 instead of 403, constraints
instead of application checks) are covered in the README and not repeated here.

Each entry gives the decision, the alternative, and what it cost.

---

## 1. OpenTofu rather than Terraform

**Decision.** `tofu` throughout. The configuration is unmodified HCL and would
run under Terraform 1.5 without edits.

**Alternative.** Terraform, or CDK.

**Why.** The 2023 licence change makes Terraform's position in commercial
settings a question this project has no reason to inherit. The syntax is
identical, so the choice costs nothing and keeps the option to move back.

**Cost.** Most provider documentation and nearly all tutorials assume
`terraform`. Every command in this repo is written as `tofu`.

---

## 2. OIDC federation rather than access keys

**Decision.** GitHub Actions assumes `booklog-dev-github-actions` through an IAM
OIDC provider. No `AWS_ACCESS_KEY_ID` exists in the repository or in GitHub
secrets.

**Alternative.** An IAM user with a long-lived key pair stored as a repository
secret.

**Why.** A long-lived key is a credential that leaks silently. A federated
session lasts minutes and is scoped to one repository and one branch.

**Cost.** The trust policy failed for several hours with `Not authorized to
perform sts:AssumeRoleWithWebIdentity` while matching GitHub's documented `sub`
format exactly. Decoding the JWT inside the workflow showed GitHub issuing:

```
repo:lieri123@142183090/booklog@1329125631:ref:refs/heads/main
```

Immutable numeric IDs are interpolated into the claim, so the documented
`repo:OWNER/REPO:ref:refs/heads/main` never matches. The condition is now a
wildcard:

```hcl
"token.actions.githubusercontent.com:sub" = "repo:lieri123*/booklog*:ref:refs/heads/main"
```

The `:ref:refs/heads/main` suffix keeps this from being a hole. A pull request
branch produces a different suffix and fails the condition.

**Related failure.** `github_repo` had no default, so an apply that omitted
`-var="github_repo=..."` evaluated `count = 0` and destroyed the OIDC provider
and the deploy role. The failure was silent and only became visible on the next
push. The default is now set in `variables.tf`. A variable that controls `count`
should not be allowed to default to empty.

---

## 3. One NAT gateway rather than one per AZ

**Decision.** A single NAT gateway in the first public subnet. Both private
route tables point at it.

**Alternative.** One per AZ, which is the production pattern.

**Why.** Roughly $32/month each plus data processing. In an environment that is
destroyed between sessions, the second gateway buys availability against an AZ
failure that would only affect outbound Open Library calls.

**Cost.** An AZ outage takes out all outbound traffic instead of half of it.
Acceptable here and not acceptable in production. The fix is a change to one
route table association.

---

## 4. State bucket in `us-east-1`, workloads in `ca-central-1`

**Decision.** Left as is.

**Why it happened.** The bootstrap module was applied before the region decision
was revisited.

**Why it stays.** Moving state cross-region means creating a new bucket, copying
the state file, and re-initialising every backend. That is real risk for no
functional gain. State access happens once per plan and is not latency
sensitive. Recording the inconsistency is more useful than performing a
migration to make the documentation look tidy.

**Cost.** Anyone reading the configuration has to be told why the regions
differ, which is what this entry is for.

---

## 5. `treat_missing_data = "notBreaching"`

**Decision.** All nine alarms treat missing data as healthy.

**Alternative.** The CloudWatch default of `missing`, or `breaching`.

**Why.** ALB metrics such as `HTTPCode_Target_5XX_Count` are only emitted when
the event occurs. Under `breaching`, zero traffic puts every alarm into ALARM
and sends email. Zero traffic is the normal overnight state of this stack. An
alerting system that fires when nothing is happening gets muted, and a muted
alarm is worse than no alarm.

**Cost.** A total outage that stops metric publication entirely reads as silence
rather than as an alarm. `UnHealthyHostCount` with a `Maximum` statistic
partially compensates, since it keeps reporting for as long as the ALB itself is
alive.

---

## 6. Target tracking rather than step scaling

**Decision.** Two target-tracking policies on the ECS service: average CPU at
60%, and ALB request count per target at 300, between 2 and 6 tasks.

**Alternative.** Step scaling with explicit CloudWatch alarm thresholds.

**Why.** Step scaling requires choosing scale-out and scale-in thresholds,
cooldowns, and step adjustments with no data to justify any of them. Target
tracking needs one number per policy and manages its own alarms.

**Cost.** Two policies on one service can conflict, with CPU wanting to scale in
while request count wants to scale out. Application Auto Scaling resolves this
by taking the larger desired count, so the service biases toward scaling out.
That bias is right for latency and wrong for cost, which is why `max_capacity`
is capped at 6 rather than left open. Load testing showed the cap matters more
than the target values. See `load-test.md`.

---

## 7. `manage_master_user_password = true`

**Decision.** RDS generates and rotates the master password into Secrets
Manager. The password never enters Terraform state.

**Alternative.** `random_password` in Terraform, written to state.

**Why.** State is plaintext JSON in S3. Anything in it is readable by anyone
with bucket access.

**Cost.** The password cannot be read from an output, so local psql sessions
need a `secretsmanager get-secret-value` call first. The JWT secret does not get
the same treatment. It is a `random_password` in Secrets Manager, which means it
is in state. That is inconsistent, and only defensible because rotating it does
nothing worse than invalidate existing sessions.

---

## 8. Fargate rather than EC2 or EKS

**Decision.** ECS on Fargate.

**Alternative.** ECS on EC2, or EKS.

**Why.** Fargate has no instance fleet to patch, size, or drain. EKS adds about
$72/month for the control plane before running a single pod, and a
two-container workload does not need a scheduler that sophisticated.

**Cost.** Per-vCPU-hour pricing is higher than a reserved EC2 instance, and task
startup is slower. Neither matters below a fairly high constant load.

---

## 9. The stack is destroyed between sessions

**Decision.** `tofu destroy` at the end of a working session, and a rebuild of
roughly 58 resources over about 12 minutes at the start of the next.

**Why.** The NAT gateway, ALB, and RDS instance cost roughly $60 to $70/month
running continuously, for a project used a few hours a week.

**Cost.** Two consequences are worth naming.

Every AWS resource identifier changes on rebuild, including the RDS endpoint,
the ALB DNS name, and all subnet IDs. Nothing can hardcode them. This turned out
to be a useful constraint, though it was enforced by accident rather than by
design.

A push to `main` while the stack is down fails the deploy job at ECR login. The
workflow now checks whether the ECR repository exists and exits the job cleanly
if it does not, so a torn-down stack produces a skipped deploy instead of a red
badge.

---

## 10. Retention limits everywhere, and a sweep script for what escapes them

**Decision.** Every resource that accumulates has an explicit expiry, and the
resources that cannot be given one are handled by `scripts/teardown.ps1`.

**What prompted it.** A budget alert arrived while the stack was supposedly
destroyed. Cost Explorer, grouped by service at daily granularity and then by
usage type, showed charges continuing after the destroy. Nothing was
misconfigured. The charges came from resources that were never in the state file
in the first place.

**What changed.**

The ECR lifecycle policy expired untagged images but not tagged ones. Every
deploy pushes an image tagged with a commit SHA, so tagged images accumulated
with nothing to remove them. A second rule now keeps the 10 most recent and
expires the rest. A rule with `tagStatus = "any"` has to hold the highest
`rulePriority`, which is why the untagged rule stays at priority 1.

The state bucket had versioning enabled and no lifecycle configuration, so every
apply added a version that was never removed. Noncurrent versions now expire
after 90 days, which is far longer than any realistic rollback window.

The DynamoDB lock table had no `prevent_destroy` while the state bucket did.
Losing the table does not lose state, but it means the next apply runs without
locking, and an interrupted apply without a lock is how state gets corrupted.
The protection is now on both.

**What could not be fixed in Terraform.** `enabled_cloudwatch_logs_exports`
makes RDS create its own log group, lazily, on first write. It never enters the
state file, so destroy does not remove it and no `retention_in_days` can be set
on it from here. Declaring an `aws_cloudwatch_log_group` to match would race
with RDS creating the same group, and the identifier is generated from
`identifier_prefix` so the name is not known until after the instance exists.
The sweep script reports and removes it instead. Recording this is more useful
than shipping a resource that intermittently fails on apply.

**Cost.** The sweep is a script rather than infrastructure, so it only runs when
invoked. It defaults to reporting rather than deleting, on the grounds that a
cleanup script which deletes by default is one typo away from removing something
that matters.
