output "vpc_id" {
  description = "VPC id."
  value       = module.vpc.vpc_id
}

output "vpc_cidr_block" {
  description = "VPC CIDR, used by the Jenkins NetworkPolicies."
  value       = module.vpc.vpc_cidr_block
}

output "private_subnets" {
  description = <<-EOT
    Private subnet IDS (not CIDRs). Safe as for_each VALUES anywhere, never as for_each KEYS -- they
    do not exist until the subnets do. Consumers needing keys take the static CIDR list instead.
  EOT
  value       = module.vpc.private_subnets
}

output "database_subnets" {
  description = "Isolated DB subnet ids, for the RDS subnet group."
  value       = module.vpc.database_subnets
}

output "public_subnets_cidr_blocks" {
  description = "Public subnet CIDRs, used by the Jenkins ALB NetworkPolicy."
  value       = module.vpc.public_subnets_cidr_blocks
}
