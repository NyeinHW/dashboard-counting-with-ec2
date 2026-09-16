# EC2 Auto Scaling Lab — Step-by-Step Notes

Dashboard (front-facing) + Counting (internal) services, running as a dedicated
non-root user under systemd, behind ALBs, scaled by an Auto Scaling Group.

---

## 1. Manual setup on a single EC2 instance (proof of concept)

Before automating anything, get one instance working end to end by hand.

### 1.1 Install Docker
```bash
sudo dnf update -y
sudo dnf install -y docker
sudo systemctl enable docker
sudo systemctl start docker
```

### 1.2 Create a dedicated, non-login app user
```bash
sudo useradd -r -s /sbin/nologin -m -d /home/appuser appuser
sudo usermod -aG docker appuser
```
- `-r` → system account, not a human login
- `-s /sbin/nologin` → can't be used to log in interactively
- Added to the `docker` group so it can talk to the Docker socket without root

Verify:
```bash
id appuser
```

### 1.3 Run the containers manually first (before wrapping in systemd)
```bash
sudo -u appuser docker run --rm \
  --name dashboard-service \
  -p 80:80 \
  -e COUNTING_SERVICE_URL='http://<counting-ip-or-alb>:9001' \
  -e PORT=80 \
  hashicorp/dashboard-service:0.0.4
```

**Key lesson learned:** the host user running `docker run` (`appuser`) is *not*
the same thing as the user the container's process runs as internally. Check
with:
```bash
ps -eo user,pid,ppid,cmd | grep "\./dashboard-service"
```
If this shows `root` instead of `appuser`, the image has no `USER` directive
and defaults to root. Force it with `--user`:
```bash
--user "$(id -u appuser):$(id -g appuser)"
```
Port 80 is privileged (<1024), so a non-root user also needs:
```bash
--cap-add=NET_BIND_SERVICE
```

---

## 2. Wrap each service in a systemd unit

Systemd (not a script you run once) is the OS's init system — it supervises
the container continuously: starts it on boot, restarts it on crash, and lets
you `systemctl start/stop/status` it like any other service.

### 2.1 Dashboard — `/etc/systemd/system/dashboard-service.service`
```ini
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
  --user "<appuser-uid>:<appuser-gid>" \
  --cap-add=NET_BIND_SERVICE \
  -p 80:80 \
  -e COUNTING_SERVICE_URL='http://<counting-internal-alb-dns>:9001' \
  -e PORT=80 \
  hashicorp/dashboard-service:0.0.4
ExecStop=/usr/bin/docker stop dashboard-service

[Install]
WantedBy=multi-user.target
```

### 2.2 Counting — `/etc/systemd/system/counting-service.service`
```ini
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
  --user "<appuser-uid>:<appuser-gid>" \
  -p 9001:9001 \
  hashicorp/counting-service:0.0.2
ExecStop=/usr/bin/docker stop counting-service

[Install]
WantedBy=multi-user.target
```
No `--cap-add` needed — port 9001 isn't privileged.

### 2.3 Apply
```bash
sudo systemctl daemon-reload   # systemd re-scans unit files it doesn't know about yet
sudo systemctl enable dashboard-service   # auto-start on every future boot
sudo systemctl start dashboard-service    # start it right now too
```
(repeat `enable`/`start` for counting-service)

**Why all three commands are needed:**
- `daemon-reload` — makes systemd notice the new unit file exists
- `enable` — makes it start automatically on *future* boots
- `start` — starts it *now*, since `enable` alone doesn't start anything immediately

### 2.4 Verify
```bash
sudo systemctl status dashboard-service      # should show active (running)
sudo systemctl is-enabled dashboard-service  # should show "enabled"
ps -eo user,pid,ppid,cmd | grep "\./dashboard-service"   # confirm appuser, not root
sudo docker logs -f dashboard-service
```

> Note: `User=appuser` in the unit only controls who runs the `docker` CLI
> command (matters for socket permissions). It does **not** control what user
> the container's internal process runs as — that's what `--user` inside
> `ExecStart` is for.

---

## 3. Networking prerequisites

### 3.1 Subnets
- **Dashboard** → public subnet(s), 2+ AZs (required for the ALB)
- **Counting** → private subnet(s), 2+ AZs

### 3.2 NAT Gateway (for counting's outbound internet access)
Private subnets have no outbound internet route by default. Counting needs
this for `docker pull` (Docker Hub) and SSM Agent registration.

1. **VPC → NAT Gateways → Create** — place it in a **public** subnet, allocate
   an Elastic IP
2. **VPC → Route Tables** → find the private subnet's route table → add route
   `0.0.0.0/0` → target: the NAT Gateway
3. Confirm the private subnet is associated with that route table

Test from the counting instance:
```bash
sudo docker pull hashicorp/counting-service:0.0.2
```

### 3.3 Security groups (chained, least-privilege)
| SG | Inbound rule | Source |
|---|---|---|
| `dashboard-alb-sg` | HTTP 80 | `0.0.0.0/0` |
| `dashboard-ec2-sg` | HTTP 80 | `dashboard-alb-sg` |
| `counting-alb-sg` | TCP 9001 | `dashboard-ec2-sg` |
| `counting-ec2-sg` | TCP 9001 | `counting-alb-sg` |

---

## 4. Target groups + ALBs

### 4.1 Target groups
- `dashboard-tg` — HTTP:80, health check path `/health`
- `counting-tg` — HTTP:9001, health check path `/health`

### 4.2 Load balancers
- `dashboard-alb` — **internet-facing**, public subnets, SG `dashboard-alb-sg`,
  listener HTTP:80 → `dashboard-tg`
- `counting-internal-alb` — **internal**, private subnets, SG `counting-alb-sg`,
  listener HTTP:9001 → `counting-tg`

### 4.3 Point dashboard at counting via the internal ALB's DNS name
Never hardcode an instance's private IP — it won't survive instance
replacement. Use the ALB's stable DNS name instead:
```bash
sudo nano /etc/systemd/system/dashboard-service.service
# update COUNTING_SERVICE_URL to http://<counting-internal-alb-dns>:9001
sudo systemctl daemon-reload
sudo systemctl restart dashboard-service
```

### 4.4 Verify target health
```bash
aws elbv2 describe-target-health --target-group-arn <tg-arn>
```
Or console: **Target Groups → [name] → Targets tab**, look for `healthy`.

Test end to end:
```bash
curl -v http://<dashboard-alb-dns-name>/
```

---

## 5. Launch template (bakes in everything from steps 1–2)

This is what lets the ASG launch fully-configured instances with **zero
manual intervention** — user data runs once, automatically, as root, on
first boot only.

```bash
#!/bin/bash
set -ex

dnf update -y
dnf install -y docker
systemctl enable docker
systemctl start docker

useradd -r -s /sbin/nologin -m -d /home/appuser appuser || true
usermod -aG docker appuser

APP_UID=$(id -u appuser)
APP_GID=$(id -g appuser)

cat > /etc/systemd/system/dashboard-service.service << EOF
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
  --user "${APP_UID}:${APP_GID}" \
  --cap-add=NET_BIND_SERVICE \
  -p 80:80 \
  -e COUNTING_SERVICE_URL='http://<counting-internal-alb-dns>:9001' \
  -e PORT=80 \
  hashicorp/dashboard-service:0.0.4
ExecStop=/usr/bin/docker stop dashboard-service

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable dashboard-service
systemctl start dashboard-service
```
No `sudo` needed anywhere — user data already runs as root via cloud-init.

**Launch template checklist:**
- AMI: same as manually-tested instance
- Security group: `dashboard-ec2-sg`
- IAM instance profile: needs SSM permissions at minimum
- **Network settings → Network interfaces → Subnet → Auto-assign public IP:
  set to Enable explicitly.** Leaving this as "Don't include in launch
  template" can override the subnet's own default and launch instances with
  no public IP — which then breaks both SSM connectivity and internet-dependent
  steps in user data (image pulls, package installs).

**Debugging a bad boot:**
```bash
sudo cat /var/log/cloud-init-output.log   # every user-data command's output
sudo systemctl status dashboard-service
sudo docker logs dashboard-service
```

---

## 6. Auto Scaling Group

- Launch template: the one from step 5 (use version `$Latest` so template
  updates apply to future launches automatically)
- Subnets: dashboard's public subnets (2+ AZs)
- **Attach to existing load balancer** → `dashboard-tg` (this replaces manual
  `register-targets` calls)
- Health check type: **ELB** (so failed app-level health checks trigger
  replacement, not just EC2 status checks)
- Group size: Min/Desired/Max per your test needs (e.g. 1 / 1 / 4)

### Scaling policy (target tracking — simplest)
- Metric: **ALB request count per target**
- Target value: e.g. `10` (requests/target/minute — low, so easy to trigger)
- Instance warmup: ~60s

### Updating the launch template later
Modifying a launch template creates a **new version** — it does not retroactively
change the ASG or already-running instances. After updating:
```bash
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name dashboard-asg \
  --launch-template LaunchTemplateId=<id>,Version='$Latest'

aws autoscaling terminate-instance-in-auto-scaling-group \
  --instance-id <old-instance-id> \
  --should-decrement-desired-capacity false
```
The second command forces the ASG to replace an existing (possibly broken)
instance with a fresh one from the corrected template.

---

## 7. Load testing with `hey`

Install (Mac):
```bash
brew install hey
```

Run a load test that comfortably breaches a target of 10 req/target/min:
```bash
hey -z 5m -q 1 -c 5 http://<dashboard-alb-dns-name>/
```
- `-z 5m` — run for 5 minutes (target tracking needs a few data points)
- `-q 1 -c 5` — ~5 requests/sec ≈ 300 req/min, well above target

Watch it react, in a second/third terminal:
```bash
watch -n 15 'aws autoscaling describe-scaling-activities --auto-scaling-group-name dashboard-asg --max-items 5'

watch -n 15 'aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names dashboard-asg \
  --query "AutoScalingGroups[0].Instances[].[InstanceId,LifecycleState]" \
  --output table'
```
Or console: **Auto Scaling Groups → dashboard-asg → Activity tab** /
**Instance management tab**.

Stop the test with `Ctrl+C`. CloudWatch metrics lag by roughly a minute, and
target tracking has its own cooldown, so scale-in takes a few minutes after
traffic actually stops — this is expected, not a bug.

Manually reset desired capacity when done, if you don't want to wait:
```bash
aws autoscaling set-desired-capacity --auto-scaling-group-name dashboard-asg --desired-capacity 1
```

---

## 8. Common failure signatures (troubleshooting cheat sheet)

| Symptom | Likely cause |
|---|---|
| `curl` hangs / times out (no response at all) | Security group silently blocking — check the ALB→EC2 SG chain |
| `curl` says "Connection refused" instantly | Nothing listening on that port — app crashed or never started |
| SSM Agent: `i/o timeout` reaching `ssm.<region>.amazonaws.com` | No outbound internet route — check NAT Gateway / public IP |
| `ps` shows `root` for the container's binary | Image has no `USER` directive — add `--user UID:GID` explicitly |
| New ASG instance has no public IP despite subnet default being on | Launch template's network interface is overriding the subnet default — set "Auto-assign public IP" to Enable in the template |
| Target group stuck "Target registration is in progress" | Health check failing — check SG chain, health check path/port match the app |
| ASG keeps replacing instances in a loop | Instances failing ELB health checks (often the public-IP/NAT issue above) — check `describe-scaling-activities` for the actual reason, not just "scaling" |
| `systemctl restart` → "Access denied" | Forgot `sudo` |
| Editing `/etc/systemd/system/*.service` has no effect | Forgot `systemctl daemon-reload` after editing, or forgot to restart the service |

---

## 9. Teardown checklist (avoid ongoing charges)

Delete in this order (dependencies matter):
1. Load balancers (`dashboard-alb`, `counting-internal-alb`)
2. Target groups
3. ASG (this terminates its instances) — or just set desired capacity to 0/1 if pausing short-term
4. Any manually-created EC2 instances — **stop**, don't terminate, if resuming soon
5. **NAT Gateway** — the highest ongoing cost, delete first if pausing for more than a few hours
6. Release the NAT Gateway's Elastic IP separately (`aws ec2 release-address`)
7. Security groups (only after nothing references them)
8. Any subnets created solely for this lab

ALBs and the ASG itself are cheap/free respectively for short pauses — NAT
Gateway is the one that actually adds up if left running idle.
