# set up
data "aws_caller_identity" "current" {}

# bucket
resource "aws_s3_bucket" "video_hls_bucket" {
  bucket = "video-hls-bucket-1"

  cors_rule {
    allowed_methods = ["GET", "HEAD"]
    allowed_origins = ["*"]
  }

  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm = "AES256"
      }
    }
  }
}

resource "aws_s3_bucket" "video_source_bucket" {
  bucket = "video-source-bucket-1"

  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm = "AES256"
      }
    }
  }
}

resource "aws_s3_bucket_policy" "video_hls_bucket_policy" {
  bucket = aws_s3_bucket.video_hls_bucket.id

  policy = jsonencode({
    Statement = [
      {
        Sid = "PolicyForCloudFrontPrivateContent"
        Effect = "Allow"
        Principal = {
          AWS = [
            aws_cloudfront_origin_access_identity.video_streaming_oai.iam_arn
          ]
        }
        Action = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.video_hls_bucket.arn}/*"
      },
      {
        Sid = "PolicyForLambdaEdgeAndMediaConvert"
        Effect = "Allow"
        Principal = {
          AWS = ["*"]
        }
        Action = ["s3:GetObject", "s3:PutObject","s3:ListBucket",]
        Resource = [
          "${aws_s3_bucket.video_hls_bucket.arn}/*",
          "${aws_s3_bucket.video_hls_bucket.arn}"
        ]
      }
    ]
  })
}

resource "aws_s3_bucket_policy" "source_media_bucket_policy" {
  bucket = aws_s3_bucket.video_source_bucket.id

  policy = jsonencode({
    Statement = [
      {
        Sid       = "PolicyForMediaConvertJobRole"
        Effect    = "Allow"
        Principal = { AWS = [aws_iam_role.media_convert_job_role.arn] }
        Action    = ["s3:GetObject", "s3:ListBucket"]
        Resource  = [
          "${aws_s3_bucket.video_source_bucket.arn}/*",
          "${aws_s3_bucket.video_source_bucket.arn}"
        ]
      }
    ]
  })
}



# cloudfront
resource "aws_cloudfront_origin_access_identity" "video_streaming_oai" {
  comment = "video streaming oai"
}

# media convert
resource "aws_iam_role" "media_convert_job_role" {
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = [
            "mediaconvert.amazonaws.com",
            "mediaconvert.us-east-1.amazonaws.com",
            "mediaconvert.ap-northeast-1.amazonaws.com",
            "mediaconvert.ap-southeast-1.amazonaws.com",
            "mediaconvert.ap-southeast-2.amazonaws.com",
            "mediaconvert.eu-central-1.amazonaws.com",
            "mediaconvert.eu-west-1.amazonaws.com",
            "mediaconvert.us-east-1.amazonaws.com",
            "mediaconvert.us-west-1.amazonaws.com",
            "mediaconvert.us-west-2.amazonaws.com",
          ]
        }
        Action = ["sts:AssumeRole"]
      }
    ]
  })

  name = "media-convert-job-role"

  inline_policy {
    name = "media-convert-job-policy"

    policy = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Effect = "Allow"
          Action = [
            "s3:GetObject",
            "s3:ListBucket",
            "s3:PutObject",
          ]
          Resource = [
            "arn:aws:s3:::${aws_s3_bucket.video_hls_bucket.arn}/*",
            "arn:aws:s3:::${aws_s3_bucket.video_source_bucket.arn}/*",
          ]
        }
      ]
    })
  }
}


resource "aws_iam_role" "lambda_edge_otf_video_convert_role" {
  name = "lambda-edge-otf-video-convert-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid = "AllowLambdaServiceToAssumeRole"
      Effect = "Allow"
      Principal = {
        Service = [
          "lambda.amazonaws.com",
          "edgelambda.amazonaws.com"
        ]
      }
      Action = ["sts:AssumeRole"]
    }]
  })

  managed_policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  ]

  inline_policy {
    name = "LimitedAllowGetS3AndCreateJobPolicy"
    policy = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket",
          "iam:PassRole",
          "mediaconvert:CreateJob",
          "mediaconvert:GetJob",
          "mediaconvert:CreateJobTemplate"
        ]
        Resource = [
          "arn:aws:s3:::${aws_s3_bucket.video_hls_bucket.arn}/*",
          "arn:aws:s3:::${aws_s3_bucket.video_hls_bucket.arn}",
          "arn:aws:mediaconvert:*:${data.aws_caller_identity.current.account_id}:jobTemplates/*",
          "arn:aws:mediaconvert:*:${data.aws_caller_identity.current.account_id}:queues/*",
          "arn:aws:mediaconvert:*:${data.aws_caller_identity.current.account_id}:jobs/*",
          aws_iam_role.media_convert_job_role.arn
        ]
      }]
    })
  }
}


resource "aws_lambda_function" "lambda-edge-otf-video-convert" {
  description      = "A Lambda function that returns a static string."
  function_name    = "lambda-edge-otf-video-convert"
  role             = aws_iam_role.lambda_edge_otf_video_convert_role.arn
  handler          = "lambda-at-edge-otf-video-convert.handler"
  runtime          = "nodejs12.x"
  memory_size      = 1024
  timeout          = 20
  s3_bucket        = "cloudfront-blog-resources"
  s3_key           = "cf-otf-video-convert/lambda-at-edge-otf-video-convert.zip"
  publish          = true
}

resource "aws_cloudfront_cache_policy" "m3u8" {
  name = "m3u8-cache-policy"
  comment = "cp-on-the-fly-video-convert-m3u8"
  min_ttl = 0
  default_ttl = 86400
  max_ttl = 31536000

  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_gzip = true

    cookies_config {
      cookie_behavior = "whitelist"
      cookies {
        items = ["no-cookie"]
      }
    }

    headers_config {
      header_behavior = "whitelist"
      headers {
        items = ["Access-Control-Request-Headers", "Access-Control-Request-Method", "Origin"]
      }
    }

    query_strings_config {
      query_string_behavior = "whitelist"
      query_strings {
        items = ["width", "height", "mediafilename"]
      }
    }
  }
}


resource "aws_cloudfront_origin_request_policy" "m3u8" {
  comment = "orp-on-the-fly-video-convert-m3u8"
  name = "orp-on-the-fly-video-convert-m3u8"

  cookies_config {
    cookie_behavior = "whitelist"
    cookies {
      items = ["no-cookie"]
    }
  }

  headers_config {
    header_behavior = "whitelist"
    headers {
      items = ["Access-Control-Request-Headers", "Access-Control-Request-Method", "Origin"]
    }
  }

  query_strings_config {
    query_string_behavior = "whitelist"
    query_strings {
      items = ["width", "height", "mediafilename"]
    }
  }
}

resource "aws_cloudfront_cache_policy" "ts" {
  comment = "cache policy for on-the-fly media convert ts"

  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config {
      cookie_behavior = "whitelist"
      cookies          {
        items = ["no-cookie"]
      }
    }

    enable_accept_encoding_gzip = true

    headers_config {
      header_behavior = "whitelist"
      headers          {
        items = ["Access-Control-Request-Headers", "Access-Control-Request-Method", "Origin"]
      }
    }

    query_strings_config {
      query_string_behavior = "whitelist"
      query_strings         {
        items = ["no-qs"]
      }
    }
  }

  default_ttl = 86400
  max_ttl     = 31536000
  min_ttl     = 0
  name        = "cp-on-the-fly-video-convert-ts"
}

resource "aws_cloudfront_origin_request_policy" "OriginRequestPolicyTs" {
  name = "orp-on-the-fly-video-convert-ts"
  comment = "Origin request policy for on-the-fly media convert ts"

  cookies_config {
    cookie_behavior = "whitelist"
    cookies {
      items = ["no-cookie"]
    }
  }

  headers_config {
    header_behavior = "whitelist"
    headers {
      items = ["Access-Control-Request-Headers", "Access-Control-Request-Method", "Origin"]
    }
  }

  query_strings_config {
    query_string_behavior = "whitelist"
    query_strings {
      items = ["no-qs"]
    }
  }
}

resource "aws_cloudfront_distribution" "CloudFrontDistribution" {
  enabled = true
  comment = "on-the-fly video convert"

  origin {
    domain_name = aws_s3_bucket.video_hls_bucket.bucket_regional_domain_name
    origin_id   = "otfS3Origin"

    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.video_streaming_oai.cloudfront_access_identity_path
    }

    custom_header {
      name  = "mediaconvert-api-endpoint"
      value = "https://q25wbt2lc.mediaconvert.us-east-1.amazonaws.com"
    }

    custom_header {
      name  = "mediaconvert-job-role"
      value = aws_iam_role.media_convert_job_role.arn
    }

    custom_header {
      name  = "SourceMediaBucket"
      value = aws_s3_bucket.video_source_bucket.id
    }

    custom_header {
      name  = "HlsMediaBucket"
      value = aws_s3_bucket.video_hls_bucket.id
    }
  }

  default_cache_behavior {
    target_origin_id = "otfS3Origin"
    viewer_protocol_policy = "allow-all"
    compress = false

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
  }

  default_root_object = "index.html"

  ordered_cache_behavior {
    allowed_methods = ["GET", "HEAD", "OPTIONS"]
    target_origin_id = "otfS3Origin"
    cache_policy_id = aws_cloudfront_cache_policy.m3u8.id
    origin_request_policy_id = aws_cloudfront_origin_request_policy.m3u8.id
    viewer_protocol_policy = "allow-all"
    path_pattern = "*.m3u8"

    lambda_function_association {
      event_type = "origin-request"
      lambda_arn = aws_lambda_function.lambda-edge-otf-video-convert.qualified_arn
      include_body = false
    }
    cached_methods = ["GET", "HEAD"]
  }

  ordered_cache_behavior {
    allowed_methods = ["GET", "HEAD", "OPTIONS"]
    target_origin_id = "otfS3Origin"
    cache_policy_id = aws_cloudfront_cache_policy.ts.id
    origin_request_policy_id = aws_cloudfront_origin_request_policy.OriginRequestPolicyTs.id
    viewer_protocol_policy = "allow-all"
    path_pattern = "*.ts"
    cached_methods = ["GET", "HEAD"]
  }

  price_class = "PriceClass_All"

  viewer_certificate {
    cloudfront_default_certificate = true
  }
  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}
