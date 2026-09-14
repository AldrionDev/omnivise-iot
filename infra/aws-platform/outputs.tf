output "aws_region" {
  description = "AWS region that hosts the OmniVise EKS platform."
  value       = var.aws_region
}

output "vpc_id" {
  description = "ID of the dedicated OmniVise AWS VPC."
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "Public subnet IDs used by the initial EKS platform."
  value       = [for subnet in aws_subnet.public : subnet.id]
}

output "cluster_name" {
  description = "Amazon EKS cluster name."
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "Amazon EKS Kubernetes API endpoint."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded certificate authority data for the EKS cluster."
  value       = aws_eks_cluster.this.certificate_authority[0].data
  sensitive   = true
}

output "node_group_name" {
  description = "EKS managed node group name."
  value       = aws_eks_node_group.this.node_group_name
}

output "operator_principal_arn" {
  description = "Bootstrap/operator IAM principal with declarative EKS cluster-admin access."
  value       = aws_eks_access_entry.operator.principal_arn
}
