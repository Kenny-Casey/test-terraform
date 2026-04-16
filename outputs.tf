output "api_base_url" {
  value = aws_api_gateway_deployment.clothing_api.invoke_url
}

output "upload_url" {
  value = "${aws_api_gateway_deployment.clothing_api.invoke_url}${aws_api_gateway_stage.dev.stage_name}/upload"
}

output "bucket_name" {
  value = aws_s3_bucket.images.bucket
}