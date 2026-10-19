variable "region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "ap-south-1"
}

variable "project" {
  description = "Name prefix for all resources"
  type        = string
  default     = "stockwatch"
}

variable "alert_email" {
  description = "Email that receives budget alerts (and SNS alerts in later phases)"
  type        = string
}

variable "budget_limit_usd" {
  description = "Monthly AWS Budget limit in USD"
  type        = number
  default     = 10
}

variable "log_retention_days" {
  description = "CloudWatch log retention for Lambda and API logs"
  type        = number
  default     = 7
}
