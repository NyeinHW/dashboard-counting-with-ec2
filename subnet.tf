resource "aws_subnet" "dashboard-counting-public" {
  vpc_id     = aws_vpc.dashboard-counting.id
  cidr_block = var.subnet_prefix

  tags = {
    name = "${var.prefix}-public-subnet"
  }
}

resource "aws_internet_gateway" "dashboard-counting" {
  vpc_id = aws_vpc.dashboard-counting.id

  tags = {
    Name = "${var.prefix}-internet-gateway"
  }
}

resource "aws_route_table" "dashboard-counting-public" {
  vpc_id = aws_vpc.dashboard-counting.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.dashboard-counting.id
  }
}

resource "aws_route_table_association" "dashboard-counting" {
  subnet_id      = aws_subnet.dashboard-counting-public.id
  route_table_id = aws_route_table.dashboard-counting-public.id
}

resource "aws_eip" "dashboard-counting" {
  domain   = "vpc"
  tags = {
    Name = "dashboard-counting-nat-eip"
  }
}

resource "aws_nat_gateway" "dashboard-counting" {
  allocation_id = aws_eip.dashboard-counting.id
  subnet_id     = aws_subnet.dashboard-counting-public.id

  tags = {
    Name = "dashboard-counting-nat-gateway"
  }

  # NAT Gateway must be created after the Internet Gateway is attached
  depends_on = [aws_internet_gateway.dashboard-counting]
}

resource "aws_subnet" "dashboard-counting-private" {
  vpc_id     = aws_vpc.dashboard-counting.id
  cidr_block = var.subnet_private_prefix

  tags = {
    name = "${var.prefix}-private-subnet"
  }
}

resource "aws_route_table" "dashboard-counting-private" {
  vpc_id = aws_vpc.dashboard-counting.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.dashboard-counting.id
  }
}

resource "aws_route_table_association" "dashboard-counting-private" {
  subnet_id      = aws_subnet.dashboard-counting-private.id
  route_table_id = aws_route_table.dashboard-counting-private.id
}

