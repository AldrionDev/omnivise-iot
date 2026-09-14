mock_provider "aws" {}

run "foundation_contract" {
  command = plan

  assert {
    condition     = var.aws_region == "eu-north-1"
    error_message = "The AWS platform must remain in eu-north-1."
  }

  assert {
    condition = (
      length(var.availability_zones) == 2 &&
      var.availability_zones[0] == "eu-north-1a" &&
      var.availability_zones[1] == "eu-north-1b"
    )
    error_message = "The initial platform must use exactly eu-north-1a and eu-north-1b."
  }

  assert {
    condition = (
      length(var.public_subnet_cidrs) == 2 &&
      var.public_subnet_cidrs[0] == "10.20.0.0/20" &&
      var.public_subnet_cidrs[1] == "10.20.16.0/20"
    )
    error_message = "The initial public subnet CIDRs must remain deterministic."
  }

  assert {
    condition     = aws_subnet.public["eu-north-1a"].map_public_ip_on_launch
    error_message = "The eu-north-1a worker subnet must assign public IPs in the no-NAT portfolio design."
  }

  assert {
    condition     = aws_subnet.public["eu-north-1b"].map_public_ip_on_launch
    error_message = "The eu-north-1b worker subnet must assign public IPs in the no-NAT portfolio design."
  }

  assert {
    condition     = aws_route.public_internet.destination_cidr_block == "0.0.0.0/0"
    error_message = "The public route table must carry the Internet Gateway default route."
  }

  assert {
    condition     = aws_eks_cluster.this.version == "1.36"
    error_message = "The EKS cluster must use Kubernetes 1.36."
  }

  assert {
    condition     = aws_eks_cluster.this.access_config[0].authentication_mode == "API"
    error_message = "EKS authentication must use the API access-entry model."
  }

  assert {
    condition     = aws_eks_cluster.this.access_config[0].bootstrap_cluster_creator_admin_permissions == false
    error_message = "Implicit cluster-creator admin access must remain disabled."
  }

  assert {
    condition = (
      aws_eks_cluster.this.vpc_config[0].endpoint_public_access == true &&
      contains(aws_eks_cluster.this.vpc_config[0].public_access_cidrs, "0.0.0.0/0")
    )
    error_message = "The interview/portfolio milestone intentionally exposes the EKS API endpoint publicly while retaining IAM/EKS authentication."
  }

  assert {
    condition = (
      length(aws_eks_node_group.this.instance_types) == 1 &&
      contains(aws_eks_node_group.this.instance_types, "t3.medium")
    )
    error_message = "The initial managed node group must use t3.medium."
  }

  assert {
    condition     = aws_eks_node_group.this.scaling_config[0].min_size == 1
    error_message = "The managed node group minimum size must be 1."
  }

  assert {
    condition     = aws_eks_node_group.this.scaling_config[0].desired_size == 1
    error_message = "The managed node group desired size must be 1."
  }

  assert {
    condition     = aws_eks_node_group.this.scaling_config[0].max_size == 2
    error_message = "The managed node group maximum size must be 2."
  }

  assert {
    condition     = aws_eks_access_entry.operator.principal_arn == var.operator_principal_arn
    error_message = "Operator access must use the explicitly configured bootstrap IAM role."
  }

  assert {
    condition     = aws_eks_access_policy_association.operator_cluster_admin.access_scope[0].type == "cluster"
    error_message = "Bootstrap operator access must be cluster scoped."
  }

  assert {
    condition     = aws_eks_access_policy_association.operator_cluster_admin.policy_arn == "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
    error_message = "The bootstrap operator must use the explicit EKS cluster-admin access policy."
  }
}
