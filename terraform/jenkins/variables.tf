variable "region" {
  description = "AWS region. Must match the region holding the ECR repositories."
  type        = string
  default     = "il-central-1"
}

variable "cluster_name" {
  description = "Resource name prefix, matching the main stack. Also selects which ECR repositories this host may push to (<cluster_name>-*)."
  type        = string
  default     = "voteball"
}

variable "admin_cidr" {
  description = "CIDR permitted to SSH (port 22). Your home IP as a /32. Update and re-apply when your ISP reassigns it."
  type        = string
}

variable "public_key_path" {
  description = "Path to the PUBLIC half of the voteball-jenkins key pair. The private .pem never leaves your machine."
  type        = string
}

variable "instance_type" {
  description = "t3.medium (4GB) is the floor: four Docker builds plus Trivy's vulnerability database do not fit in 2GB."
  type        = string
  default     = "t3.medium"
}
