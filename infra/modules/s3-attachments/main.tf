resource "aws_s3_bucket" "att" {
  bucket = "${var.prefix}-attachments"
  tags   = var.tags
}

resource "aws_s3_bucket_public_access_block" "att" {
  bucket                  = aws_s3_bucket.att.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "att" {
  bucket = aws_s3_bucket.att.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_cors_configuration" "att" {
  bucket = aws_s3_bucket.att.id
  cors_rule {
    allowed_methods = ["PUT", "GET"]
    allowed_origins = var.cors_origins
    allowed_headers = ["*"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "att" {
  bucket = aws_s3_bucket.att.id

  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"
    filter {
      prefix = "attachments/"
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}
