<#
.SYNOPSIS
  Destroys the dev stack and reports resources that survive the destroy.

.DESCRIPTION
  `tofu destroy` does not remove everything. Manual RDS snapshots, Secrets
  Manager secrets inside a recovery window, and the log group RDS creates for
  its own Postgres log export are all outside the state file, so they persist
  and continue to bill after the stack is gone.

  This script destroys the stack and then reports what is left. It does not
  delete anything unless -Delete is passed, because a sweep script that
  deletes by default is one typo away from removing the state bucket.

  The S3 state bucket and DynamoDB lock table in us-east-1 are never touched.

.PARAMETER SkipDestroy
  Only run the sweep. Useful when the stack is already down and the goal is
  finding what a previous destroy left behind.

.PARAMETER Delete
  Delete the orphaned resources found by the sweep instead of only listing
  them.

.EXAMPLE
  .\scripts\teardown.ps1
  Destroy the stack, then list anything left over.

.EXAMPLE
  .\scripts\teardown.ps1 -SkipDestroy -Delete
  Clean up leftovers from an earlier destroy.
#>

[CmdletBinding()]
param(
    [switch]$SkipDestroy,
    [switch]$Delete,
    [string]$Region = "ca-central-1",
    [string]$Project = "booklog-dev"
)

$ErrorActionPreference = "Stop"

function Write-Section($text) {
    Write-Host ""
    Write-Host "== $text" -ForegroundColor Cyan
}

function Write-Found($text) {
    Write-Host "   $text" -ForegroundColor Yellow
}

# destroy

if (-not $SkipDestroy) {
    Write-Section "Destroying stack"

    if (-not $env:TF_VAR_alert_email) {
        Write-Host "   TF_VAR_alert_email is not set; SNS subscription will plan as a change." -ForegroundColor DarkGray
    }

    Push-Location (Join-Path $PSScriptRoot "..\infra\envs\dev")
    try {
        # The -var matters. Without it github_repo defaults through a count = 0
        # path and the OIDC provider is destroyed silently.
        tofu destroy -var="github_repo=lieri123/booklog"
        if ($LASTEXITCODE -ne 0) { throw "tofu destroy failed with exit code $LASTEXITCODE" }
    }
    finally {
        Pop-Location
    }
}

# sweep

$found = 0

Write-Section "NAT gateways"
$nats = aws ec2 describe-nat-gateways --region $Region `
    --filter "Name=state,Values=available,pending" `
    --query "NatGateways[].NatGatewayId" --output text
if ($nats) {
    foreach ($id in $nats -split "\s+") {
        Write-Found "$id  (~`$32/month)"
        $found++
        if ($Delete) { aws ec2 delete-nat-gateway --region $Region --nat-gateway-id $id | Out-Null }
    }
}

Write-Section "Unassociated Elastic IPs"
$eips = aws ec2 describe-addresses --region $Region `
    --query "Addresses[?AssociationId==null].AllocationId" --output text
if ($eips) {
    foreach ($id in $eips -split "\s+") {
        Write-Found "$id  (billed while unattached)"
        $found++
        if ($Delete) { aws ec2 release-address --region $Region --allocation-id $id | Out-Null }
    }
}

Write-Section "Manual RDS snapshots"
$snaps = aws rds describe-db-snapshots --region $Region --snapshot-type manual `
    --query "DBSnapshots[].DBSnapshotIdentifier" --output text
if ($snaps) {
    foreach ($id in $snaps -split "\s+") {
        Write-Found $id
        $found++
        if ($Delete) { aws rds delete-db-snapshot --region $Region --db-snapshot-identifier $id | Out-Null }
    }
}

Write-Section "Secrets in a recovery window"
# RDS-managed master user secrets are deleted with the instance but sit in a
# recovery window first, so they still appear here for several days.
$secrets = aws secretsmanager list-secrets --region $Region --include-planned-deletion `
    --query "SecretList[?DeletedDate!=null].ARN" --output text
if ($secrets) {
    foreach ($arn in $secrets -split "\s+") {
        Write-Found $arn
        $found++
        if ($Delete) {
            aws secretsmanager delete-secret --region $Region --secret-id $arn `
                --force-delete-without-recovery | Out-Null
        }
    }
}

Write-Section "Log groups outside Terraform"
# The application log group is managed and destroyed with the stack. The one
# RDS creates for enabled_cloudwatch_logs_exports is not: RDS creates it
# lazily on first write, so it never enters the state file and survives every
# destroy with no retention policy set.
$logs = aws logs describe-log-groups --region $Region `
    --query "logGroups[?contains(logGroupName, 'booklog') || contains(logGroupName, 'rds')].logGroupName" `
    --output text
if ($logs) {
    foreach ($name in $logs -split "\s+") {
        Write-Found $name
        $found++
        if ($Delete) { aws logs delete-log-group --region $Region --log-group-name $name | Out-Null }
    }
}

Write-Section "ECR repositories"
$repos = aws ecr describe-repositories --region $Region `
    --query "repositories[].repositoryName" --output text 2>$null
if ($repos) {
    foreach ($name in $repos -split "\s+") {
        Write-Found "$name  (delete manually; force_delete should have removed this)"
        $found++
    }
}

# summary

Write-Host ""
if ($found -eq 0) {
    Write-Host "Nothing left in $Region." -ForegroundColor Green
}
elseif ($Delete) {
    Write-Host "$found resource(s) deleted." -ForegroundColor Green
}
else {
    Write-Host "$found resource(s) still billing. Re-run with -Delete to remove them." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Not checked and never delete: the S3 state bucket and DynamoDB lock" -ForegroundColor DarkGray
Write-Host "table in us-east-1. Destroying either one loses all Terraform state." -ForegroundColor DarkGray
