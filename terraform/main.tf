# CodeBuild Configuration
resource "aws_s3_bucket" "codebuild_cache_bucket" {
  bucket        = "theplayer007-codebuild-cache-bucket"
  force_destroy = true
}

data "aws_iam_policy_document" "codebuild_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "codebuild_iam_role" {
  name               = "codebuild-iam-role"
  assume_role_policy = data.aws_iam_policy_document.codebuild_assume_role.json
}

data "aws_iam_policy_document" "codebuild_cache_bucket_policy_document" {
  statement {
    effect = "Allow"

    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]

    resources = ["*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:*"]
    resources = ["*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    effect    = "Allow"
    actions   = [
	"ecr:BatchGetImage",
        "ecr:BatchCheckLayerAvailability",
        "ecr:CompleteLayerUpload",
        "ecr:DescribeImages",
        "ecr:DescribeRepositories",
        "ecr:GetDownloadUrlForLayer",
        "ecr:InitiateLayerUpload",
        "ecr:ListImages",
        "ecr:PutImage",
        "ecr:UploadLayerPart"
    ]
    resources = [aws_ecr_repository.nodeapp.arn]
  }
}

resource "aws_iam_role_policy" "codebuild_cache_bucket_policy" {
  role   = aws_iam_role.codebuild_iam_role.name
  policy = data.aws_iam_policy_document.codebuild_cache_bucket_policy_document.json
}

resource "aws_codebuild_project" "nodeapp_build" {
  name          = "nodeapp-build"
  description   = "nodeapp-build"
  build_timeout = 60
  service_role  = aws_iam_role.codebuild_iam_role.arn

  artifacts {
    type = "NO_ARTIFACTS"
  }

  cache {
    type     = "S3"
    location = aws_s3_bucket.codebuild_cache_bucket.bucket
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode             = true

    environment_variable {
      name  = "ACCOUNT_ID"
      value = data.aws_caller_identity.current.account_id
    }

    environment_variable {
      name  = "REGION"
      value = var.region
    }

    environment_variable {
      name  = "REPO"
      value = "nodeapp"
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name  = "nodeapp-log-group"
      stream_name = "nodeapp-log-stream"
    }

    s3_logs {
      status   = "ENABLED"
      location = "${aws_s3_bucket.codebuild_cache_bucket.id}/build-log"
    }
  }

  source {
    type            = "GITHUB"
    location        = "https://github.com/mmdcloud/aws-ecr-ecs.git"
    git_clone_depth = 1

    git_submodules_config {
      fetch_submodules = true
    }
  }

  source_version = "master"

  tags = {
    Environment = "NodeApp-Build"
  }
}

# CodePipeline Configuration
resource "aws_codestarconnections_connection" "codepipeline_codestart_connection" {
  name          = "codestar-connection"
  provider_type = "GitHub"
}

resource "aws_codepipeline" "nodeapp_pipeline" {
  name     = "nodeapp-pipeline"
  role_arn = aws_iam_role.codepipeline_role.arn

  artifact_store {
    location = aws_s3_bucket.codepipeline_bucket.bucket
    type     = "S3"
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source_output"]
      input_artifacts  = []

      configuration = {
        ConnectionArn    = aws_codestarconnections_connection.codepipeline_codestart_connection.arn
        FullRepositoryId = "mmdcloud/aws-ecr-ecs"
        BranchName       = "master"
      }
    }
  }

  stage {
    name = "Build"

    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      input_artifacts  = ["source_output"]
      output_artifacts = ["build_output"]
      version          = "1"

      configuration = {
        ProjectName = aws_codebuild_project.nodeapp_build.name
      }
    }
  }

  stage {
    name = "Deploy"

    action {
      name            = "Deploy"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "ECS"
      input_artifacts = ["build_output"]
      version         = "1"

      configuration = {
        ClusterName = aws_ecs_cluster.nodeapp-cluster.name
        ServiceName = aws_ecs_service.nodeapp-service.name
        FileName    = "imagedefinitions.json"
      }
    }
  }
}

resource "aws_s3_bucket" "codepipeline_bucket" {
  bucket        = "theplayer007-codepipeline-bucket"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "codepipeline_bucket_pab" {
  bucket = aws_s3_bucket.codepipeline_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "codepipeline_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["codepipeline.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "codepipeline_role" {
  name               = "codepipeline-role"
  assume_role_policy = data.aws_iam_policy_document.codepipeline_assume_role.json
}

resource "aws_iam_role_policy_attachment" "codepipeline_ecs_full_access" {
  role       = aws_iam_role.codepipeline_role.name
  policy_arn  = "arn:aws:iam::aws:policy/AmazonECS_FullAccess"
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "codepipeline_policy" {
  statement {
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:GetBucketVersioning",
      "s3:PutObjectAcl",
      "s3:PutObject",
    ]

    resources = [
      aws_s3_bucket.codepipeline_bucket.arn,
      "${aws_s3_bucket.codepipeline_bucket.arn}/*"
    ]
  }

  statement {
    effect = "Allow"

    actions = [
      "codedeploy:GetDeploymentConfig",
    ]

    resources = [
      "arn:aws:codedeploy:us-east-1:${data.aws_caller_identity.current.account_id}:deploymentconfig:CodeDeployDefault.OneAtATime"
    ]
  }

  statement {
    effect    = "Allow"
    actions   = ["codestar-connections:UseConnection"]
    resources = [aws_codestarconnections_connection.codepipeline_codestart_connection.arn]
  }

  statement {
    effect = "Allow"

    actions = [
      "codebuild:BatchGetBuilds",
      "codebuild:StartBuild",
    ]

    resources = ["*"]
  }
 
}

resource "aws_iam_role_policy" "codepipeline_policy" {
  name   = "codepipeline-policy"
  role   = aws_iam_role.codepipeline_role.id
  policy = data.aws_iam_policy_document.codepipeline_policy.json
}

# VPC
resource "aws_vpc" "vpc" {
  cidr_block = "10.0.0.0/16"
  tags = {
    Name = "vpc"
  }
}

# Security Group Creation
resource "aws_security_group" "security_group" {
  name   = "ecs-security-group"
  vpc_id = aws_vpc.vpc.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = -1
    self        = "false"
    cidr_blocks = ["0.0.0.0/0"]
    description = "any"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Public subnets
resource "aws_subnet" "public_subnets" {
  count             = length(var.public_subnet_cidrs)
  vpc_id            = aws_vpc.vpc.id
  cidr_block        = element(var.public_subnet_cidrs, count.index)
  availability_zone = element(var.azs, count.index)
  tags = {
    Name = "public subnet ${count.index + 1}"
  }
}

# Private subnets
resource "aws_subnet" "private_subnets" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.vpc.id
  cidr_block        = element(var.private_subnet_cidrs, count.index)
  availability_zone = element(var.azs, count.index)
  tags = {
    Name = "private subnet ${count.index + 1}"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.vpc.id
  tags = {
    Name = "igw"
  }
}

# Route Table
resource "aws_route_table" "route_table" {
  vpc_id = aws_vpc.vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = {
    Name = "route table"
  }
}

# Route Table - Subnet Association
resource "aws_route_table_association" "route_table_association" {
  count          = length(var.public_subnet_cidrs)
  subnet_id      = element(aws_subnet.public_subnets[*].id, count.index)
  route_table_id = aws_route_table.route_table.id
}

# Load Balancer Creation
resource "aws_lb" "lb" {
  name                       = "lb"
  internal                   = false
  ip_address_type            = "ipv4"
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.security_group.id]
  subnets                    = aws_subnet.public_subnets[*].id
  enable_deletion_protection = false
  tags = {
    Name = "lb"
  }
}

# Creating a Target Group
resource "aws_lb_target_group" "lb_target_group" {
  name            = "lb-target-group"
  port            = 80
  ip_address_type = "ipv4"
  protocol        = "HTTP"
  target_type     = "ip"
  vpc_id          = aws_vpc.vpc.id

  health_check {
    interval            = 30
    path                = "/"
    enabled             = true
    protocol            = "HTTP"
    timeout             = 5
    healthy_threshold   = 5
    unhealthy_threshold = 2
    port                = 80
  }

  tags = {
    Name = "lb_target_group"
  }
}

# Creating a Load Balancer listener
resource "aws_lb_listener" "lb_listener" {
  load_balancer_arn = aws_lb.lb.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.lb_target_group.arn
  }
}

# ECR 
resource "aws_ecr_repository" "nodeapp" {
  name                 = "nodeapp"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
  image_scanning_configuration {
    scan_on_push = false
  }
}

# Bash script to build the docker image and push it to ECR
resource "null_resource" "push_to_ecr" {
  provisioner "local-exec" {
    command = "bash ${path.cwd}/../ecr-build-push.sh ${aws_ecr_repository.nodeapp.name} ${var.region}"
  }
}

# ECS Cluster
resource "aws_ecs_cluster" "nodeapp-cluster" {
  name = "nodeapp-cluster"
  setting {
    name  = "containerInsights"
    value = "disabled"
  }
}

# ECR-ECS IAM Role
resource "aws_iam_role" "ecs-task-execution-role" {
  name               = "ecs-task-execution-role"
  assume_role_policy = <<EOF
    {
    "Version": "2012-10-17",
    "Statement": [
        {
        "Effect": "Allow",
        "Principal": {
            "Service": "ecs-tasks.amazonaws.com"
        },
        "Action": "sts:AssumeRole"
        }
    ]
    }
    EOF
}

# ECR-ECS policy attachment 
resource "aws_iam_role_policy_attachment" "ecs-task-execution-role-policy-attachment" {
  role       = aws_iam_role.ecs-task-execution-role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ECS Task Definition
resource "aws_ecs_task_definition" "nodeapp-task-definition" {
  family                   = "nodeapp-task-definition"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 1024
  memory                   = 2048
  execution_role_arn       = aws_iam_role.ecs-task-execution-role.arn
  task_role_arn            = aws_iam_role.ecs-task-execution-role.arn
  network_mode             = "awsvpc"
  runtime_platform {
    cpu_architecture        = "X86_64"
    operating_system_family = "LINUX"
  }
  container_definitions = jsonencode(
    [
      {
        "name" : "nodeapp",
        "image" : "${aws_ecr_repository.nodeapp.repository_url}:latest",
        "cpu" : 1024,
        "memory" : 2048,
        "essential" : true,
        "portMappings" : [
          {
            "containerPort" : 80,
            "hostPort" : 80,
            "name" : "nodeapp-http-80",
            "appProtocol" : "http",
            "protocol" : "tcp"
          }
        ]
      }
  ])
  # container_definitions = jsonencode([
  #   {
  #     name      = "nodeapp"
  #     image     = "${aws_ecr_repository.nodeapp.repository_url}:latest"
  #     cpu       = 256
  #     memory    = 512
  #     essential = true
  #     portMappings = [
  #       {
  #         containerPort = 80
  #         hostPort      = 80
  #         protocol      = "tcp"
  #       }
  #     ]
  #   }
  # ])
  tags_all = {
    Name = "nodeapp-task-definition"
  }
}

# ECS Service
resource "aws_ecs_service" "nodeapp-service" {
  name                 = "nodeapp-service"
  cluster              = aws_ecs_cluster.nodeapp-cluster.id
  task_definition      = aws_ecs_task_definition.nodeapp-task-definition.arn
  launch_type          = "FARGATE"
  scheduling_strategy  = "REPLICA"
  desired_count        = 1
  force_new_deployment = true
  network_configuration {
    security_groups  = [aws_security_group.security_group.id]
    subnets          = aws_subnet.public_subnets[*].id
    assign_public_ip = true
  }
  deployment_controller {
    type = "ECS"
  }
  load_balancer {
    container_name   = "nodeapp"
    container_port   = 80
    target_group_arn = aws_lb_target_group.lb_target_group.arn
  }
}
