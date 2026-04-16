variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "bucket_name_prefix" {
  type        = string
  description = "Prefix for the S3 bucket name; a random suffix will be appended"
}

variable "api_stage" {
  type    = string
  default = "dev"
}