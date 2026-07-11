variable "aws_region" {
  description = "AWS region to deploy resources in"
  type        = string
  default     = "il-central-1"
}

variable "instance_type" {
  description = "EC2 instance type for the app server"
  type        = string
  default     = "t3.medium"
}

variable "ami_id" {
  # Verified via `aws ssm get-parameter --name
  # /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64
  # --region il-central-1` — the previous default (ami-03eff74cb4f6a6272) was
  # NOT a clean Amazon Linux 2023 image despite its description; it was a
  # golden image named "S3App-backend-20260430", snapshotted from a live
  # S3App server, with S3App's app code and an auto-starting systemd service
  # already baked in. Discovered when a Voteball deploy onto it found S3App's
  # backend running and competing for resources. Always verify a hardcoded
  # AMI id's actual Name/Description via `aws ec2 describe-images` before
  # reusing one across projects.
  description = "AMI ID for the app instance (Amazon Linux 2023, il-central-1)"
  type        = string
  default     = "ami-05471ba2d056f72c5"
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
