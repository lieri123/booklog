# The EKS cluster, its node group, the IRSA provider, and the addons.
#
# Cost, stated plainly because it is the reason envs/dev runs on Fargate:
#
#   EKS control plane      $0.10/hour            ~$73/month
#   2 x t3.small nodes     $0.0208/hour each     ~$30/month
#   NAT gateway            $0.045/hour           ~$32/month
#   RDS db.t4g.micro       free tier eligible    ~$0-15/month
#   ---------------------------------------------------------
#                                                ~$135-150/month
#
# The ECS Fargate stack in envs/dev is roughly $60-70/month for the same
# application. The control plane alone is more than the entire difference, and
# it bills whether or not a single pod is running - which is exactly the
# reasoning in docs/decisions.md entry 8. Destroy this stack between sessions
# the same way: see docs/kubernetes.md.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# cluster IAM

data "aws_iam_policy_document" "eks_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name_prefix        = "${local.name}-cluster-"
  assume_role_policy = data.aws_iam_policy_document.eks_assume.json
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

# cluster

resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${local.name}/cluster"
  retention_in_days = 7
}

resource "aws_eks_cluster" "main" {
  name     = local.name
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids              = concat(aws_subnet.private[*].id, aws_subnet.public[*].id)
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  # Access entries rather than the aws-auth ConfigMap. The ConfigMap was a
  # single YAML blob with no API validation, editable only from inside the
  # cluster you had just locked yourself out of.
  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_cloudwatch_log_group.cluster,
  ]

  tags = { Name = local.name }
}

resource "aws_eks_access_entry" "admin" {
  count = var.admin_access_entry_arn == "" ? 0 : 1

  cluster_name  = aws_eks_cluster.main.name
  principal_arn = var.admin_access_entry_arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "admin" {
  count = var.admin_access_entry_arn == "" ? 0 : 1

  cluster_name  = aws_eks_cluster.main.name
  principal_arn = var.admin_access_entry_arn
  policy_arn    = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admin]
}

# IRSA
#
# Nothing in this application needs an AWS API - the ECS task role is empty for
# the same reason. The provider exists so that pulling the RDS password out of
# Secrets Manager with External Secrets, or adding the AWS Load Balancer
# Controller later, is a role and an annotation rather than a cluster rebuild.

data "tls_certificate" "oidc" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "oidc" {
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]
}

# node group IAM

data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name_prefix        = "${local.name}-node-"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "AmazonEKSWorkerNodePolicy",
    "AmazonEKS_CNI_Policy",
    "AmazonEC2ContainerRegistryReadOnly",
  ])

  role       = aws_iam_role.node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/${each.value}"
}

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = local.name
  node_role_arn   = aws_iam_role.node.arn

  # Private subnets only. Nodes reach ECR and the control plane through the NAT
  # gateway; nothing in the private subnets has a public IP, same as the ECS
  # tasks it replaces.
  subnet_ids = aws_subnet.private[*].id

  instance_types = [var.node_instance_type]
  ami_type       = "AL2023_x86_64_STANDARD"

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  update_config {
    max_unavailable = 1
  }

  depends_on = [aws_iam_role_policy_attachment.node]

  lifecycle {
    # The node group is sized by hand here; a cluster autoscaler or Karpenter
    # would own this field instead.
    ignore_changes = [scaling_config[0].desired_size]
  }

  tags = { Name = local.name }
}

# addons
#
# metrics-server is an addon rather than a Helm release because the HPA is
# useless without it, and a core dependency of the thing this stack exists to
# demonstrate should not be a manual post-apply step. If an HPA ever reads
# <unknown> in the TARGETS column, this is the first thing to check.

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # CoreDNS pods need somewhere to run.
  depends_on = [aws_eks_node_group.main]
}

resource "aws_eks_addon" "metrics_server" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "metrics-server"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.main]
}

# container registry
#
# Separate from the ECS stack's repository so this environment can be destroyed
# without taking the other one's images with it.

resource "aws_ecr_repository" "app" {
  name         = local.name
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the 10 most recent images, expire the rest"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = { type = "expire" }
      },
    ]
  })
}
