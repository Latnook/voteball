variable "cluster_name" {
  description = "EKS cluster name, and the resource name prefix for this stack."
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes minor version. Keep this on a STANDARD-support EKS release -- extended support costs 5x. See docs/maintenance.md."
  type        = string
}

variable "cluster_endpoint_public_access_cidrs" {
  description = <<-EOT
    Allow-list for the public API endpoint. Deliberately has NO default at the root, so a plan fails
    until voteball.tfvars names a CIDR (scripts/refresh-api-cidr.sh writes the current one). When it
    goes stale AWS DROPS packets rather than refusing them, so every helm_release and kubernetes_*
    resource fails with "Kubernetes cluster unreachable ... i/o timeout" and the run reads as a dead
    cluster.
  EOT
  type        = list(string)
}

variable "vpc_id" {
  description = "VPC to place the cluster in."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnet ids for the control-plane ENIs and the node group."
  type        = list(string)
}

variable "node_instance_types" {
  description = "Diversified instance types for the Spot node group."
  type        = list(string)
}

variable "node_min_size" {
  description = "Node group minimum size."
  type        = number
}

variable "node_max_size" {
  description = "Node group maximum size."
  type        = number
}

variable "node_desired_size" {
  description = "Node group desired size."
  type        = number
}
