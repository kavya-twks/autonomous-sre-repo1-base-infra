variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name prefix for all resources"
  type        = string
  default     = "autonomous-sre"
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "demo"
}
