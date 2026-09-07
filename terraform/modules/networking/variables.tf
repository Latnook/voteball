variable "cluster_name" {
  description = "Resource name prefix for this stack."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR block."
  type        = string
}

variable "azs" {
  description = "Availability zones. Must be the same length and order as the three subnet lists."
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = <<-EOT
    Node/pod subnets. Passed in from the root rather than declared here because modules/storage keys
    its EFS mount-target for_each on the SAME list, and a for_each key may not be unknown at plan
    time -- so both consumers must read one static list, not this module's outputs.
  EOT
  type        = list(string)
}

variable "public_subnet_cidrs" {
  description = "ALB + NAT gateway subnets."
  type        = list(string)
}

variable "database_subnet_cidrs" {
  description = "Isolated RDS subnets -- no NAT or IGW route."
  type        = list(string)
}
