resource "aws_security_group" "dashboard_sg" {
  name   = "dashboard-sg"
  vpc_id = aws_vpc.dashboard-counting.id

  tags = {
    Name = "dashboard-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "dashboard_http" {
  security_group_id = aws_security_group.dashboard_sg.id
  description        = "HTTP"
  from_port          = 80
  to_port             = 80
  ip_protocol         = "tcp"
  cidr_ipv4           = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "dashboard_all_outbound" {
  security_group_id = aws_security_group.dashboard_sg.id
  description        = "Allow all outbound traffic"
  ip_protocol         = "-1"
  cidr_ipv4           = "0.0.0.0/0"
}

# --- Counting Security Group ---

resource "aws_security_group" "counting_sg" {
  name   = "counting-sg"
  vpc_id = aws_vpc.dashboard-counting.id

  tags = {
    Name = "counting-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "counting_custom_tcp" {
  security_group_id            = aws_security_group.counting_sg.id
  description                   = "Custom TCP 9002 from dashboard-sg"
  from_port                     = 9002
  to_port                        = 9002
  ip_protocol                    = "tcp"
  referenced_security_group_id  = aws_security_group.dashboard_sg.id
}

resource "aws_vpc_security_group_egress_rule" "counting_all_outbound" {
  security_group_id = aws_security_group.counting_sg.id
  description        = "Allow all outbound traffic"
  ip_protocol         = "-1"
  cidr_ipv4           = "0.0.0.0/0"
}