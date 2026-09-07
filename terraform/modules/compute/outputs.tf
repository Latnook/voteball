output "cluster_name" {
  description = "EKS cluster name (for aws eks update-kubeconfig)."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint."
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 CA bundle for the kubernetes/helm providers."
  value       = module.eks.cluster_certificate_authority_data
}

output "cluster_service_cidr" {
  description = "Service CIDR, used by the Jenkins NetworkPolicies."
  value       = module.eks.cluster_service_cidr
}

output "node_security_group_id" {
  description = "Node security group -- the only source RDS and EFS accept traffic from."
  value       = module.eks.node_security_group_id
}

output "oidc_provider" {
  description = "OIDC provider hostpath, the condition-key prefix in every IRSA trust policy."
  value       = module.eks.oidc_provider
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN, the federated principal every IRSA role trusts."
  value       = module.eks.oidc_provider_arn
}
