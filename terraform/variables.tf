variable "aws_region" {
  description = "AWS region to deploy resources in"
  type        = string
  default     = "il-central-1"
}

variable "instance_type" {
  description = "EC2 instance type for the app server"
  type        = string
  default     = "t3.small"
}

variable "ami_id" {
  description = "AMI ID for the app instance (Amazon Linux 2023, il-central-1)"
  type        = string
  default     = "ami-03eff74cb4f6a6272"
}

variable "ssh_allowed_cidr" {
  description = "CIDR block allowed SSH access to the instance"
  type        = string
}

variable "db_password" {
  description = "Master password for the RDS PostgreSQL instance"
  type        = string
  sensitive   = true
}

variable "notification_email" {
  description = "Email address for SNS milestone notifications"
  type        = string
}

variable "key_name" {
  description = "EC2 key pair name for SSH access"
  type        = string
  default     = "Voteball-EC2-pem"
}
