################################################################################
# S3 Bucket Module - Outputs
################################################################################

output "bucket_id" {
  description = "The name (ID) of the S3 bucket."
  value       = aws_s3_bucket.this.id
}

output "bucket_arn" {
  description = "The ARN of the S3 bucket."
  value       = aws_s3_bucket.this.arn
}

output "bucket_name" {
  description = "The name of the S3 bucket (same as bucket_id)."
  value       = aws_s3_bucket.this.bucket
}

output "bucket_regional_domain_name" {
  description = "The regional domain name of the S3 bucket (e.g. bucket.s3.us-east-1.amazonaws.com)."
  value       = aws_s3_bucket.this.bucket_regional_domain_name
}
