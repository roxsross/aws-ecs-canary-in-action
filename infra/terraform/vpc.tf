# Network: created by default, or referenced when vpc_id is set. Either way,
# the rest of the stack reads local.vpc_id / local.public_subnet_ids and does
# not care which path was taken.

locals {
  create_vpc = var.vpc_id == ""
}

# ---- created path ----

data "aws_availability_zones" "available" {
  count = local.create_vpc ? 1 : 0
  state = "available"
}

resource "aws_vpc" "created" {
  count = local.create_vpc ? 1 : 0

  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${local.name}-vpc" }
}

resource "aws_internet_gateway" "created" {
  count = local.create_vpc ? 1 : 0

  vpc_id = aws_vpc.created[0].id

  tags = { Name = "${local.name}-igw" }
}

resource "aws_route_table" "public" {
  count = local.create_vpc ? 1 : 0

  vpc_id = aws_vpc.created[0].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.created[0].id
  }

  tags = { Name = "${local.name}-public" }
}

resource "aws_subnet" "public" {
  count = local.create_vpc ? var.vpc_az_count : 0

  vpc_id            = aws_vpc.created[0].id
  availability_zone = data.aws_availability_zones.available[0].names[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index)
  #trivy:ignore:AWS-0164 this lab VPC has no NAT gateway, so tasks need a public IP to pull the image from ECR. Bring your own VPC with private subnets + NAT for anything less disposable.
  map_public_ip_on_launch = true

  tags = { Name = "${local.name}-public-${data.aws_availability_zones.available[0].names[count.index]}" }
}

resource "aws_route_table_association" "public" {
  count = local.create_vpc ? var.vpc_az_count : 0

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[0].id
}

# ---- existing path ----

data "aws_vpc" "existing" {
  count = local.create_vpc ? 0 : 1
  id    = var.vpc_id
}

data "aws_subnet" "existing_public" {
  for_each = local.create_vpc ? toset([]) : toset(var.public_subnet_ids)
  id       = each.value
}

# ---- unified outputs ----

locals {
  vpc_id = local.create_vpc ? aws_vpc.created[0].id : data.aws_vpc.existing[0].id

  public_subnet_ids = local.create_vpc ? aws_subnet.public[*].id : var.public_subnet_ids

  service_subnet_ids = length(var.service_subnet_ids) > 0 ? var.service_subnet_ids : local.public_subnet_ids
}
