terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  backend "s3" {
    bucket         = "autonomous-sre-tfstate"
    key            = "base-infra/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "autonomous-sre-tflock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region
}

# ─── VPC ────────────────────────────────────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = local.common_tags
} = merge(local.common_tags, { Name = "${var.project}-vpc" })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.common_tags, { Name = "${var.project}-igw" })
}

# ─── PUBLIC SUBNETS (2 AZs) ─────────────────────────────────────────────────
resource "aws_subnet" "public" {
  for_each                = { a = "10.0.1.0/24", b = "10.0.2.0/24" }
  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value
  availability_zone       = "${var.aws_region}${each.key}"
  map_public_ip_on_launch = true
  tags = merge(local.common_tags, { Name = "${var.project}-public-${each.key}" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = merge(local.common_tags, { Name = "${var.project}-public-rt" })
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# ─── PRIVATE SUBNETS (ECS tasks run here) ───────────────────────────────────
resource "aws_subnet" "private" {
  for_each          = { a = "10.0.10.0/24", b = "10.0.11.0/24" }
  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value
  availability_zone = "${var.aws_region}${each.key}"
  tags = merge(local.common_tags, { Name = "${var.project}-private-${each.key}" })
}

# ─── SECURITY GROUPS ────────────────────────────────────────────────────────
resource "aws_security_group" "alb" {
  name        = "${var.project}-alb-sg"
  description = "ALB inbound HTTP/HTTPS"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(local.common_tags, { Name = "${var.project}-alb-sg" })
}

resource "aws_security_group" "ecs_tasks" {
  name        = "${var.project}-ecs-tasks-sg"
  description = "ECS tasks — allow from ALB only"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 0
    to_port         = 65535
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(local.common_tags, { Name = "${var.project}-ecs-tasks-sg" })
}

# ─── ECS CLUSTER ────────────────────────────────────────────────────────────
resource "aws_ecs_cluster" "main" {
  name = "${var.project}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = local.common_tags
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

# ─── IAM: ECS TASK EXECUTION ROLE ───────────────────────────────────────────
resource "aws_iam_role" "ecs_task_execution" {
  name = "${var.project}-ecs-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}  

# CloudWatch log group for ECS
resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${var.project}"
  retention_in_days = 7
  tags              = local.common_tags
}

locals {
  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    Repo        = "repo1-base-infra"
  }
}
