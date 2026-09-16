resource "aws_instance" "counting_ec2" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.dashboard-counting-private.id
  vpc_security_group_ids = [aws_security_group.counting_sg.id]
  key_name               = aws_key_pair.dashboard-counting.key_name
  iam_instance_profile   = var.ssm_instance_profile_name

  user_data = <<-EOF
    #!/bin/bash
    set -e
    dnf install -y docker
    systemctl enable docker
    systemctl start docker

    useradd -m appuser || true
    usermod -aG docker appuser

    cat <<'UNIT' > /etc/systemd/system/counting-service.service
    [Unit]
    Description=Counting Service Container
    After=docker.service network-online.target
    Requires=docker.service
    Wants=network-online.target

    [Service]
    Type=simple
    User=appuser
    Group=docker
    Restart=always
    RestartSec=5
    ExecStartPre=-/usr/bin/docker rm -f counting-service
    ExecStart=/usr/bin/docker run --rm \
      --name counting-service \
      -p 9002:9001 \
      -e PORT=9001 \
      hashicorp/counting-service:0.0.2
    ExecStop=/usr/bin/docker stop counting-service

    [Install]
    WantedBy=multi-user.target
    UNIT

    systemctl daemon-reload
    systemctl enable counting-service
    systemctl start counting-service
  EOF

  tags = {
    Name = "counting-ec2"
  }
}

# --- Dashboard EC2 (public subnet) ---

resource "aws_instance" "dashboard_ec2" {
  ami                          = data.aws_ami.amazon_linux.id
  instance_type                = "t3.micro"
  subnet_id                    = aws_subnet.dashboard-counting-public.id
  vpc_security_group_ids       = [aws_security_group.dashboard_sg.id]
  key_name               = aws_key_pair.dashboard-counting.key_name
  associate_public_ip_address  = true
  iam_instance_profile   = var.ssm_instance_profile_name

  user_data = <<-EOF
    #!/bin/bash
    set -e
    dnf install -y docker
    systemctl enable docker
    systemctl start docker

    useradd -m appuser || true
    usermod -aG docker appuser

    cat <<'UNIT' > /etc/systemd/system/dashboard-service.service
    [Unit]
    Description=Dashboard Service Container
    After=docker.service network-online.target
    Requires=docker.service
    Wants=network-online.target

    [Service]
    Type=simple
    User=appuser
    Group=docker
    Restart=always
    RestartSec=5
    ExecStartPre=-/usr/bin/docker rm -f dashboard-service
    ExecStart=/usr/bin/docker run --rm \
      --name dashboard-service \
      -p 80:80 \
      -e COUNTING_SERVICE_URL='http://${aws_instance.counting_ec2.private_ip}:9002' \
      -e PORT=80 \
      hashicorp/dashboard-service:0.0.4
    ExecStop=/usr/bin/docker stop dashboard-service

    [Install]
    WantedBy=multi-user.target
    UNIT

    systemctl daemon-reload
    systemctl enable dashboard-service
    systemctl start dashboard-service
  EOF

  tags = {
    Name = "dashboard-ec2"
  }

  depends_on = [aws_instance.counting_ec2]
}
