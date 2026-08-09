# Remote state in S3, with DynamoDB locking.

terraform {
  backend "s3" {
    bucket         = "booklog-tfstate-5b6bf061"
    key            = "dev/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "booklog-tf-locks"
    encrypt        = true
  }
}