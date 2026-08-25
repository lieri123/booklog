# Bootstrap: creates the S3 bucket and DynamoDB table that hold Terraform
# state for everything else.


terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "booklog"
      ManagedBy = "terraform"
    }
  }
}

variable "region" {
  description = "AWS region. Must match the region in envs/dev."
  type        = string
  default     = "us-east-1"
}

resource "random_id" "suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "state" {
  bucket = "booklog-tfstate-${random_id.suffix.hex}"

  lifecycle {
    prevent_destroy = true
  }
}


resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}


resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}


# Versioning is on so a corrupted state file can be rolled back, but every
# apply writes a new version and nothing removes the old ones. Ninety days is
# far longer than any realistic rollback and stops the bucket growing without
# limit.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-noncurrent-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.state]
}


resource "aws_dynamodb_table" "locks" {
  name         = "booklog-tf-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  # Same protection as the bucket. Losing the lock table does not lose state,
  # but it does mean the next apply runs without locking and can corrupt it.
  lifecycle {
    prevent_destroy = true
  }
}

output "state_bucket" {
  description = "Copy this into infra/envs/dev/backend.tf"
  value       = aws_s3_bucket.state.id
}

output "lock_table" {
  value = aws_dynamodb_table.locks.name
}
