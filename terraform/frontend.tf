# Phase 4: dashboard hosting
#
#  Browser -> CloudFront (HTTPS, OAC) -> private S3 bucket
#  The bucket is never public; only this distribution can read it.

# CloudFront is blocked on brand-new AWS accounts until Support verifies them.
# Set enable_cloudfront = false to deploy everything else and test on localhost.
variable "enable_cloudfront" {
  type    = bool
  default = true
}

locals {
  site_origins = [for d in aws_cloudfront_distribution.site : "https://${d.domain_name}"]
  frontend_dir = "${path.module}/../frontend"
  site_files   = toset([for f in fileset(local.frontend_dir, "**") : f if f != "config.js"])

  content_types = {
    html = "text/html; charset=utf-8"
    js   = "application/javascript; charset=utf-8"
    css  = "text/css; charset=utf-8"
    svg  = "image/svg+xml"
    png  = "image/png"
    ico  = "image/x-icon"
    json = "application/json"
  }
}

resource "aws_s3_bucket" "site" {
  bucket_prefix = "${var.project}-site-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "site" {
  bucket                  = aws_s3_bucket.site.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "site" {
  bucket = aws_s3_bucket.site.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_cloudfront_origin_access_control" "site" {
  name                              = "${var.project}-site-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

resource "aws_cloudfront_distribution" "site" {
  count               = var.enable_cloudfront ? 1 : 0
  enabled             = true
  default_root_object = "index.html"
  price_class         = "PriceClass_100"
  comment             = "${var.project} dashboard"

  origin {
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_id                = "site"
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  default_cache_behavior {
    target_origin_id       = "site"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = data.aws_cloudfront_cache_policy.disabled.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

data "aws_iam_policy_document" "site" {
  count = var.enable_cloudfront ? 1 : 0

  statement {
    sid       = "AllowCloudFrontRead"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.site.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [one(aws_cloudfront_distribution.site[*].arn)]
    }
  }
}

resource "aws_s3_bucket_policy" "site" {
  count      = var.enable_cloudfront ? 1 : 0
  bucket     = aws_s3_bucket.site.id
  policy     = data.aws_iam_policy_document.site[0].json
  depends_on = [aws_s3_bucket_public_access_block.site]
}

resource "aws_s3_object" "site" {
  for_each = local.site_files

  bucket        = aws_s3_bucket.site.id
  key           = each.value
  source        = "${local.frontend_dir}/${each.value}"
  etag          = filemd5("${local.frontend_dir}/${each.value}")
  content_type  = lookup(local.content_types, reverse(split(".", each.value))[0], "application/octet-stream")
  cache_control = "no-cache"
}

# Settings the browser needs. Generated from Terraform so nothing is hard-coded.
resource "aws_s3_object" "config" {
  bucket        = aws_s3_bucket.site.id
  key           = "config.js"
  content_type  = "application/javascript; charset=utf-8"
  cache_control = "no-cache"
  content = "window.STOCKWATCH_CONFIG = ${jsonencode({
    region   = var.region
    apiUrl   = aws_apigatewayv2_api.main.api_endpoint
    clientId = aws_cognito_user_pool_client.web.id
  })};\n"
}

output "site_url" {
  value = length(local.site_origins) > 0 ? local.site_origins[0] : "CloudFront disabled: run the dashboard from localhost:8080"
}
