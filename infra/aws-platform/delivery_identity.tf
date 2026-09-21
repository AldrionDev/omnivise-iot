resource "aws_iam_user" "jenkins_bootstrap" {
  name          = "omnivise-iot-jenkins-bootstrap"
  force_destroy = true

  tags = {
    Name = "omnivise-iot-jenkins-bootstrap"
  }
}

resource "aws_iam_user_policy" "jenkins_bootstrap_assume_delivery" {
  name = "omnivise-iot-jenkins-bootstrap-assume-delivery"
  user = aws_iam_user.jenkins_bootstrap.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = aws_iam_role.jenkins_delivery.arn
      }
    ]
  })
}

resource "aws_iam_user_policies_exclusive" "jenkins_bootstrap" {
  user_name    = aws_iam_user.jenkins_bootstrap.name
  policy_names = [aws_iam_user_policy.jenkins_bootstrap_assume_delivery.name]
}

resource "aws_iam_user_policy_attachments_exclusive" "jenkins_bootstrap" {
  user_name   = aws_iam_user.jenkins_bootstrap.name
  policy_arns = []
}

resource "aws_iam_role" "jenkins_delivery" {
  name = "omnivise-iot-jenkins-delivery"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_user.jenkins_bootstrap.arn
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "omnivise-iot-jenkins-delivery"
  }
}

resource "aws_iam_role_policy" "jenkins_delivery_describe_cluster" {
  name = "omnivise-iot-jenkins-delivery-describe-cluster"
  role = aws_iam_role.jenkins_delivery.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "eks:DescribeCluster"
        Resource = aws_eks_cluster.this.arn
      }
    ]
  })
}

resource "aws_iam_role_policies_exclusive" "jenkins_delivery" {
  role_name    = aws_iam_role.jenkins_delivery.name
  policy_names = [aws_iam_role_policy.jenkins_delivery_describe_cluster.name]
}

resource "aws_iam_role_policy_attachments_exclusive" "jenkins_delivery" {
  role_name   = aws_iam_role.jenkins_delivery.name
  policy_arns = []
}

resource "aws_eks_access_entry" "jenkins_delivery" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.jenkins_delivery.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "jenkins_delivery_namespace_admin" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_eks_access_entry.jenkins_delivery.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminPolicy"

  access_scope {
    type       = "namespace"
    namespaces = [local.application_namespace]
  }
}
