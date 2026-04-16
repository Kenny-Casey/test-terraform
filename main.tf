terraform {
  required_version = ">= 0.13"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.0"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# -------------------------------------------------------------------
# Random suffix for globally-unique S3 bucket name
# -------------------------------------------------------------------
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# -------------------------------------------------------------------
# S3 Bucket for Image Uploads
# -------------------------------------------------------------------
resource "aws_s3_bucket" "images" {
  bucket        = "${var.bucket_name_prefix}-${random_id.bucket_suffix.hex}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "images" {
  bucket                  = aws_s3_bucket.images.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# -------------------------------------------------------------------
# API Gateway → S3 IAM Role
# -------------------------------------------------------------------
resource "aws_iam_role" "apigw_s3_role" {
  name = "apigw-s3-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "apigateway.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "apigw_s3_policy" {
  name = "apigw-s3-putobject"
  role = aws_iam_role.apigw_s3_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "s3:PutObject"
      Resource = "${aws_s3_bucket.images.arn}/*"
    }]
  })
}

# -------------------------------------------------------------------
# DynamoDB Table for Storing Scores
# -------------------------------------------------------------------
resource "aws_dynamodb_table" "clothing_storage" {
  name         = "clothing-storage"
  billing_mode = "PAY_PER_REQUEST"

  hash_key = "image_key"

  attribute {
    name = "image_key"
    type = "S"
  }
}

# -------------------------------------------------------------------
# SNS Topic (needed by lambda IAM policy)
# -------------------------------------------------------------------
resource "aws_sns_topic" "notification" {
  name = "clothing-notification"
}

# -------------------------------------------------------------------
# Lambda IAM Role
# -------------------------------------------------------------------
resource "aws_iam_role" "lambda_role" {
  name = "clothing_rekog_lambda_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# -------------------------------------------------------------------
# Lambda IAM Policy
# -------------------------------------------------------------------
resource "aws_iam_role_policy" "lambda_policy" {
  name = "clothing_rekog_policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # CloudWatch Logs
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      },

      # Rekognition
      {
        Effect = "Allow"
        Action = [
          "rekognition:DetectLabels"
        ]
        Resource = "*"
      },

      # DynamoDB
      {
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:BatchWriteItem",
          "dynamodb:ListTables"
        ]
        Resource = aws_dynamodb_table.clothing_storage.arn
      },

      # S3
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.images.arn,
          "${aws_s3_bucket.images.arn}/*"
        ]
      },

      # SNS
      {
        Effect = "Allow"
        Action = [
          "sns:GetTopicAttributes",
          "sns:Publish"
        ]
        Resource = aws_sns_topic.notification.arn
      }
    ]
  })
}

# -------------------------------------------------------------------
# Lambda Function (expects a prebuilt zip: ./clothing_lambda.zip)
# -------------------------------------------------------------------
resource "aws_lambda_function" "upload" {
  function_name = "clothing-rekog"
  role          = aws_iam_role.lambda_role.arn
  handler       = "lambda.lambda_handler"

  # aws provider ~> 3.0 runtime validation supports up to python3.9
  runtime = "python3.9"

  filename         = "${path.module}/clothing_lambda.zip"
  source_code_hash = filebase64sha256("${path.module}/clothing_lambda.zip")
}

# -------------------------------------------------------------------
# Allow S3 to Invoke Lambda
# -------------------------------------------------------------------
resource "aws_lambda_permission" "allow_s3_invoke" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.upload.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.images.arn
}

# -------------------------------------------------------------------
# S3 Event → Lambda Trigger
# -------------------------------------------------------------------
resource "aws_s3_bucket_notification" "images_notifications" {
  bucket = aws_s3_bucket.images.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.upload.arn
    events              = ["s3:ObjectCreated:*"]
    filter_suffix       = ".jpg"
  }

  depends_on = [
    aws_lambda_permission.allow_s3_invoke
  ]
}

########################
# API GATEWAY
########################

resource "aws_api_gateway_rest_api" "clothing_api" {
  name = "clothing-api"

  binary_media_types = [
    "image/jpeg",
    "image/png",
    "image/*"
  ]
}

# /upload resource
resource "aws_api_gateway_resource" "upload" {
  rest_api_id = aws_api_gateway_rest_api.clothing_api.id
  parent_id   = aws_api_gateway_rest_api.clothing_api.root_resource_id
  path_part   = "upload"
}

########################
# PUT /upload
########################

resource "aws_api_gateway_method" "upload_put" {
  rest_api_id   = aws_api_gateway_rest_api.clothing_api.id
  resource_id   = aws_api_gateway_resource.upload.id
  http_method   = "PUT"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "upload_put" {
  rest_api_id = aws_api_gateway_rest_api.clothing_api.id
  resource_id = aws_api_gateway_resource.upload.id
  http_method = aws_api_gateway_method.upload_put.http_method

  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.upload.invoke_arn
}

########################
# OPTIONS /upload (CORS)
########################

resource "aws_api_gateway_method" "upload_options" {
  rest_api_id   = aws_api_gateway_rest_api.clothing_api.id
  resource_id   = aws_api_gateway_resource.upload.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "upload_options" {
  rest_api_id = aws_api_gateway_rest_api.clothing_api.id
  resource_id = aws_api_gateway_resource.upload.id
  http_method = aws_api_gateway_method.upload_options.http_method

  type = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "upload_options_200" {
  rest_api_id = aws_api_gateway_rest_api.clothing_api.id
  resource_id = aws_api_gateway_resource.upload.id
  http_method = aws_api_gateway_method.upload_options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin"  = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Headers" = true
  }
}

resource "aws_api_gateway_integration_response" "upload_options_200" {
  rest_api_id = aws_api_gateway_rest_api.clothing_api.id
  resource_id = aws_api_gateway_resource.upload.id
  http_method = aws_api_gateway_method.upload_options.http_method
  status_code = aws_api_gateway_method_response.upload_options_200.status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
    "method.response.header.Access-Control-Allow-Methods" = "'PUT,OPTIONS'"
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token'"
  }

  depends_on = [
    aws_api_gateway_integration.upload_options
  ]
}

########################
# Lambda Permission
########################

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"

  function_name = aws_lambda_function.upload.function_name
  principal     = "apigateway.amazonaws.com"

  source_arn = "${aws_api_gateway_rest_api.clothing_api.execution_arn}/*/*"
}

########################
# Global CORS for 4XX/5XX
########################

resource "aws_api_gateway_gateway_response" "cors_4xx" {
  rest_api_id   = aws_api_gateway_rest_api.clothing_api.id
  response_type = "DEFAULT_4XX"

  response_parameters = {
    "gatewayresponse.header.Access-Control-Allow-Origin"  = "'*'"
    "gatewayresponse.header.Access-Control-Allow-Headers" = "'*'"
    "gatewayresponse.header.Access-Control-Allow-Methods" = "'*'"
  }
}

resource "aws_api_gateway_gateway_response" "cors_5xx" {
  rest_api_id   = aws_api_gateway_rest_api.clothing_api.id
  response_type = "DEFAULT_5XX"

  response_parameters = {
    "gatewayresponse.header.Access-Control-Allow-Origin"  = "'*'"
    "gatewayresponse.header.Access-Control-Allow-Headers" = "'*'"
    "gatewayresponse.header.Access-Control-Allow-Methods" = "'*'"
  }
}

########################
# Deployment + Stage
########################

resource "aws_api_gateway_deployment" "clothing_api" {
  rest_api_id = aws_api_gateway_rest_api.clothing_api.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_integration.upload_put,
      aws_api_gateway_integration.upload_options,
      aws_api_gateway_gateway_response.cors_4xx,
      aws_api_gateway_gateway_response.cors_5xx
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "dev" {
  rest_api_id   = aws_api_gateway_rest_api.clothing_api.id
  deployment_id = aws_api_gateway_deployment.clothing_api.id
  stage_name    = var.api_stage
}
