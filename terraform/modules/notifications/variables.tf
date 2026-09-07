variable "cluster_name" {
  description = "Resource name prefix for this stack."
  type        = string
}

variable "notification_email" {
  description = "Address subscribed to the SNS topic and to all three budget thresholds."
  type        = string
}

variable "monthly_budget_usd" {
  description = "Monthly cost budget in USD."
  type        = string
}
