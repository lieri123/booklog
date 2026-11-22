# Same state bucket and lock table as envs/dev, different key. The bucket and
# table live in us-east-1 while the workload is in ca-central-1; see
# docs/decisions.md entry 4 for why that split is recorded rather than fixed.
terraform {
  backend "s3" {
    bucket         = "booklog-tfstate-5b6bf061"
    key            = "eks/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "booklog-tf-locks"
    encrypt        = true
  }
}
