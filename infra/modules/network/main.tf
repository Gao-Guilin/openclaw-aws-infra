data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  selected_availability_zones = slice(
    data.aws_availability_zones.available.names,
    0,
    length(var.public_subnet_cidrs)
  )

  public_subnets = {
    for index, cidr in var.public_subnet_cidrs :
    tostring(index) => {
      cidr_block        = cidr
      availability_zone = local.selected_availability_zones[index]
      number            = index + 1
    }
  }
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  instance_tenancy     = "default"

  tags = {
    Name = "${var.name_prefix}-vpc"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-igw"
  }
}

resource "aws_subnet" "public" {
  for_each = local.public_subnets

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value.cidr_block
  availability_zone       = each.value.availability_zone
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.name_prefix}-public-subnet-${each.value.number}"
    Type = "public"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-public-rt"
  }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "ecs_tasks" {
  name                   = "${var.name_prefix}-ecs-tasks-sg"
  description            = "Security group for OpenClaw ECS Fargate tasks."
  vpc_id                 = aws_vpc.this.id
  revoke_rules_on_delete = true

  tags = {
    Name = "${var.name_prefix}-ecs-tasks-sg"
  }
}

resource "aws_vpc_security_group_egress_rule" "ecs_tasks_all_ipv4" {
  security_group_id = aws_security_group.ecs_tasks.id
  description       = "Allow ECS tasks to access AWS services and external APIs."
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "efs" {
  name                   = "${var.name_prefix}-efs-sg"
  description            = "Security group for OpenClaw EFS mount targets."
  vpc_id                 = aws_vpc.this.id
  revoke_rules_on_delete = true

  tags = {
    Name = "${var.name_prefix}-efs-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "efs_from_ecs" {
  security_group_id            = aws_security_group.efs.id
  referenced_security_group_id = aws_security_group.ecs_tasks.id
  description                  = "Allow NFS traffic from OpenClaw ECS tasks."
  from_port                    = 2049
  to_port                      = 2049
  ip_protocol                  = "tcp"
}
