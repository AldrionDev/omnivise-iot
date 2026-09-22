resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.14.0"

  namespace = "kube-system"

  set = [
    {
      name  = "clusterName"
      value = aws_eks_cluster.this.name
    },
    {
      name  = "region"
      value = var.aws_region
    },
    {
      name  = "vpcId"
      value = aws_vpc.this.id
    },
    {
      name  = "serviceAccount.create"
      value = "true"
    },
    {
      name  = "serviceAccount.name"
      value = "aws-load-balancer-controller"
    },
  ]

  # The release is installed through the operator cluster-admin access entry;
  # it must be uninstalled before that access is removed.
  depends_on = [
    aws_eks_node_group.this,
    aws_eks_pod_identity_association.aws_load_balancer_controller,
    aws_eks_access_policy_association.operator_cluster_admin,
  ]
}
