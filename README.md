# Dashboard + Counting Service (Terraform / AWS)

A small two-tier demo app deployed on AWS with Terraform, based on HashiCorp's
[demo-consul-101](https://github.com/hashicorp/demo-consul-101) dashboard/counting
services, running as Docker containers on EC2.

## Architecture

```
                          Internet
                             │
                    ┌────────▼────────┐
                    │ Internet Gateway │
                    └────────┬────────┘
                             │
                   ┌─────────▼──────────┐
                   │   Public Subnet     │
                   │                     │
                   │  ┌───────────────┐  │
                   │  │ dashboard-ec2 │  │   Port 80 (HTTP) open to 0.0.0.0/0
                   │  │  (t3.micro)   │  │   SSH (22) open to 0.0.0.0/0
                   │  └───────┬───────┘  │
                   │          │          │
                   │  ┌───────▼───────┐  │
                   │  │  NAT Gateway  │  │
                   │  └───────┬───────┘  │
                   └──────────┼──────────┘
                              │
                   ┌──────────▼──────────┐
                   │   Private Subnet     │
                   │                      │
                   │  ┌────────────────┐  │
                   │  │  counting-ec2  │  │   Port 9002 open only to dashboard-sg
                   │  │   (t3.micro)   │  │   SSH (22) open to 0.0.0.0/0
                   │  └────────────────┘  │
                   └──────────────────────┘
```

- **dashboard-ec2** sits in the **public subnet**, reachable directly from the
  internet on port 80. It calls the counting service internally over its
  private IP.
- **counting-ec2** sits in the **private subnet**, with no direct inbound
  path from the internet. It only accepts traffic from `dashboard-sg` on
  port 9002.
- The **NAT Gateway** lives in the public subnet and gives the private
  subnet outbound-only internet access (needed to `dnf install docker` and
  pull container images on boot). It does not allow any inbound connections
  from the internet to `counting-ec2`.

## Components

| Resource | Purpose |
|---|---|
| `aws_vpc.dashboard-counting` | The VPC both subnets and instances live in |
| `aws_subnet.dashboard-counting-public` | Public subnet, routes `0.0.0.0/0` to the Internet Gateway |
| `aws_subnet.dashboard-counting-private` | Private subnet, routes `0.0.0.0/0` to the NAT Gateway |
| `aws_internet_gateway.dashboard-counting` | Gives the public subnet direct internet access |
| `aws_nat_gateway.dashboard-counting` + `aws_eip.nat` | Gives the private subnet outbound-only internet access |
| `aws_security_group.dashboard_sg` | Allows inbound HTTP (80) and SSH (22) from anywhere; all outbound |
| `aws_security_group.counting_sg` | Allows inbound TCP 9002 only from `dashboard_sg`, plus SSH (22); all outbound |
| `aws_instance.dashboard_ec2` | Runs `hashicorp/dashboard-service:0.0.4` via Docker/systemd, public IP assigned |
| `aws_instance.counting_ec2` | Runs `hashicorp/counting-service:0.0.4` via Docker/systemd, private subnet only |
| `aws_key_pair.dashboard-counting` + `tls_private_key.dashboard-counting` | Auto-generated SSH key pair for both instances |
| `data.aws_ami.amazon_linux` | Looks up the latest Amazon Linux 2023 AMI |

## How the services connect

- Both EC2 instances run their app as a **Docker container managed by
  systemd**, installed via `user_data` on first boot.
- `counting-service` listens on port **9001** inside its container, mapped
  to host port **9002** (`-p 9002:9001`) — this is the port opened in
  `counting_sg`.
- `dashboard-service` is configured with
  `COUNTING_SERVICE_URL=http://<counting-ec2 private IP>:9002`, resolved
  automatically by Terraform via `aws_instance.counting_ec2.private_ip`.

## Prerequisites

- Terraform >= 1.x
- An AWS account with credentials configured (`aws configure` or environment
  variables)
- An existing IAM instance profile with SSM permissions, referenced as
  `instanceRole` — used for Session Manager access to both instances instead
  of relying solely on SSH

## Usage

```bash
terraform init
terraform plan
terraform apply
```

On success, Terraform outputs:

- `dashboard_public_ip` — open `http://<this-ip>` in a browser to view the
  dashboard
- `counting_private_ip` — for reference/debugging only; not reachable
  directly from outside the VPC

## Connecting to the instances

- **dashboard-ec2** (public subnet): SSH directly using the generated key
  pair, or connect via SSM Session Manager.
- **counting-ec2** (private subnet): not reachable via SSH from outside the
  VPC. Use **SSM Session Manager** (via the `instanceRole` instance profile),
  or SSH from `dashboard-ec2` as a jump host.

## Cost note

The NAT Gateway is **not free** — it incurs an hourly charge plus per-GB
data processing fees, unlike the two `t3.micro` instances, which may fall
under the AWS Free Tier. If this is a short-lived demo, remember to
`terraform destroy` when you're done to avoid ongoing charges.

## Cleanup

```bash
terraform destroy
```
