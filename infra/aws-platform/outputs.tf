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


output "pod_identity_agent_addon_version" {
  description = "Pinned EKS Pod Identity Agent add-on version."
  value       = aws_eks_addon.pod_identity_agent.addon_version
}

output "ebs_csi_addon_version" {
  description = "Pinned Amazon EBS CSI Driver add-on version."
  value       = aws_eks_addon.ebs_csi.addon_version
}

output "ebs_csi_role_arn" {
  description = "IAM role used by the EBS CSI controller through EKS Pod Identity."
  value       = aws_iam_role.ebs_csi.arn
}

output "aws_load_balancer_controller_role_arn" {
  description = "IAM role used by the AWS Load Balancer Controller through EKS Pod Identity."
  value       = aws_iam_role.aws_load_balancer_controller.arn
}
