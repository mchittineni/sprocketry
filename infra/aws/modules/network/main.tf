# ==================== VPC ====================
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr_block
  enable_dns_support   = true
  enable_dns_hostnames = true # RDS and ElastiCache endpoints resolve to private IPs only with this on

  tags = { Name = "${var.name}-vpc" }
}

# The default security group allows all traffic between its members. Nothing uses it, so strip its rules.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id
}

# ==================== Subnets ====================
# Nodes, pods (the VPC CNI gives pods VPC IPs, hence /20s), Postgres and Valkey.
resource "aws_subnet" "private" {
  count             = var.az_count
  vpc_id            = aws_vpc.this.id
  availability_zone = local.azs[count.index]
  cidr_block        = cidrsubnet(var.cidr_block, 4, count.index)

  tags = {
    Name = "${var.name}-private-${local.azs[count.index]}"
    # Where Kubernetes puts internal load balancers.
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# Load balancers and the NAT gateway only. Nothing here gets a public IP unless it asks for one.
resource "aws_subnet" "public" {
  count                   = var.az_count
  vpc_id                  = aws_vpc.this.id
  availability_zone       = local.azs[count.index]
  cidr_block              = cidrsubnet(var.cidr_block, 8, 240 + count.index)
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.name}-public-${local.azs[count.index]}"
    # Where Kubernetes puts internet-facing load balancers (the Envoy Gateway Service).
    "kubernetes.io/role/elb" = "1"
  }
}

# ==================== Internet and NAT ====================
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-igw" }
}

# One NAT gateway for the whole VPC keeps dev cheap. If its AZ goes down, private subnets lose outbound
# internet (image pulls, AWS APIs). Use one per AZ for anything that needs to survive an AZ outage.
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.name}-nat" }
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = { Name = "${var.name}-nat" }

  depends_on = [aws_internet_gateway.this]
}

# ==================== Routing ====================
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-public" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count          = var.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-private" }
}

resource "aws_route" "private_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}

resource "aws_route_table_association" "private" {
  count          = var.az_count
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
