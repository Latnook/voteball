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

variable "github_repo" {
  description = "GitHub repository as owner/name. The host clones it (public, over HTTPS) at boot to fetch casc/, and JCasC builds both the job's SSH remote and its project URL from it. No default: a fork must supply its own, which is what keeps the repository identity out of the Jenkinsfile and jenkins.yaml."
  type        = string
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
