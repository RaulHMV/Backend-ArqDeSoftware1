output "bucket_name" {
  value = aws_s3_bucket.att.id
}

output "bucket_arn" {
  value = aws_s3_bucket.att.arn
}
