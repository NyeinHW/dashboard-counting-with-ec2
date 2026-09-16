resource "aws_vpc" "dashboard-counting" {
  cidr_block           = var.address_space
  enable_dns_hostnames = true

  tags = {
    name        = "${var.prefix}-vpc"
    environment = "${var.environment}"
  }
}