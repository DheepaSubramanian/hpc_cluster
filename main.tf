terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }

    # AWS PCS resources are only available in the Cloud Control provider
    awscc = {
      source  = "hashicorp/awscc"
      version = "~> 1.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

provider "awscc" {
  region = var.aws_region
}

###############################################
# VARIABLES
###############################################

variable "aws_region" {
  default = "us-east-2"
}

variable "vpc_cidr" {
  default = "10.3.0.0/16"
}

variable "public_subnet_1" {
  default = "10.3.0.0/20"
}

variable "public_subnet_2" {
  default = "10.3.16.0/20"
}

variable "private_subnet_1" {
  default = "10.3.128.0/20"
}

variable "private_subnet_2" {
  default = "10.3.144.0/20"
}

variable "dcv_instance_type" {
  default = "g6e.xlarge"
}

variable "s3_archive_bucket_name" {
  description = "Optional override. If null, derived from account and region."
  type        = string
  default     = null
}

variable "cluster_users" {
  description = "Cluster user accounts as name => UID, created identically on the DCV and compute nodes"
  type        = map(number)
  default     = {}

  validation {
    condition = alltrue([
      for name, uid in var.cluster_users :
      can(regex("^[a-z_][a-z0-9_-]{0,31}$", name)) && uid >= 2000 && uid < 60000
    ]) && length(distinct(values(var.cluster_users))) == length(var.cluster_users)
    error_message = "User names must be lowercase Linux names and UIDs must be unique and between 2000 and 59999."
  }
}

locals {
  # "alice:2001 bob:2002" for the bash loops in user_data
  cluster_users = join(" ", [for name, uid in var.cluster_users : "${name}:${uid}"])
  archive_bucket_name = coalesce(var.s3_archive_bucket_name, "openfe-results-archive-${data.aws_caller_identity.current.account_id}-${var.aws_region}")
}

###############################################
# AVAILABILITY ZONES
###############################################

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

###############################################
# AMAZON LINUX 2023
###############################################

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

###############################################
# VPC
###############################################

resource "aws_vpc" "pcs" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "pcs-vpc"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.pcs.id

  tags = {
    Name = "pcs-igw"
  }
}

###############################################
# PUBLIC SUBNETS
###############################################

resource "aws_subnet" "public_1" {
  vpc_id                  = aws_vpc.pcs.id
  cidr_block              = var.public_subnet_1
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "public-subnet-1"
  }
}

resource "aws_subnet" "public_2" {
  vpc_id                  = aws_vpc.pcs.id
  cidr_block              = var.public_subnet_2
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = true

  tags = {
    Name = "public-subnet-2"
  }
}

###############################################
# PRIVATE SUBNETS
###############################################

resource "aws_subnet" "private_1" {
  vpc_id            = aws_vpc.pcs.id
  cidr_block        = var.private_subnet_1
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = {
    Name = "private-subnet-1"
  }
}

resource "aws_subnet" "private_2" {
  vpc_id            = aws_vpc.pcs.id
  cidr_block        = var.private_subnet_2
  availability_zone = data.aws_availability_zones.available.names[1]

  tags = {
    Name = "private-subnet-2"
  }
}

###############################################
# NAT GATEWAY
###############################################

resource "aws_eip" "nat" {
  domain = "vpc"
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_1.id

  tags = {
    Name = "pcs-nat"
  }
}

###############################################
# ROUTING
###############################################

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.pcs.id
}

resource "aws_route" "public" {
  route_table_id         = aws_route_table.public.id
  gateway_id             = aws_internet_gateway.igw.id
  destination_cidr_block = "0.0.0.0/0"
}

resource "aws_route_table_association" "pub1" {
  subnet_id      = aws_subnet.public_1.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "pub2" {
  subnet_id      = aws_subnet.public_2.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.pcs.id
}

resource "aws_route" "private" {
  route_table_id         = aws_route_table.private.id
  nat_gateway_id         = aws_nat_gateway.nat.id
  destination_cidr_block = "0.0.0.0/0"
}

resource "aws_route_table_association" "priv1" {
  subnet_id      = aws_subnet.private_1.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "priv2" {
  subnet_id      = aws_subnet.private_2.id
  route_table_id = aws_route_table.private.id
}

###############################################
# SECURITY GROUPS
###############################################

resource "aws_security_group" "dcv" {
  name        = "dcv-sg"
  description = "DCV Access"
  vpc_id      = aws_vpc.pcs.id


  ingress {
    description = "DCV"
    from_port   = 8443
    to_port     = 8443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Internal traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "efs" {
  name   = "efs-sg"
  vpc_id = aws_vpc.pcs.id

  ingress {
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [
      aws_security_group.dcv.id,
      aws_security_group.pcs_compute.id
    ]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

###############################################
# IAM ROLE
###############################################

resource "aws_iam_role" "dcv_role" {
  name = "dcv-login-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [{
      Effect = "Allow"

      Principal = {
        Service = "ec2.amazonaws.com"
      }

      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.dcv_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cw" {
  role       = aws_iam_role.dcv_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_role_policy_attachment" "s3" {
  role       = aws_iam_role.dcv_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

resource "aws_iam_instance_profile" "dcv" {
  name = "dcv-login-profile"
  role = aws_iam_role.dcv_role.name
}

resource "aws_iam_role_policy" "dcv_slurm_key" {
  name = "pcs-slurm-auth-key"
  role = aws_iam_role.dcv_role.id

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = awscc_pcs_cluster.openfe.slurm_configuration.auth_key.secret_arn
    }]
  })
}

###############################################
# EFS
###############################################

resource "aws_efs_file_system" "home" {
  encrypted = true

  tags = {
    Name = "shared-home"
  }
}

resource "aws_efs_mount_target" "az1" {
  file_system_id  = aws_efs_file_system.home.id
  subnet_id       = aws_subnet.private_1.id
  security_groups = [aws_security_group.efs.id]
}

resource "aws_efs_mount_target" "az2" {
  file_system_id  = aws_efs_file_system.home.id
  subnet_id       = aws_subnet.private_2.id
  security_groups = [aws_security_group.efs.id]
}

###############################################
# S3 ARCHIVE
###############################################

resource "aws_s3_bucket" "archive" {
  bucket = local.archive_bucket_name
}

resource "aws_s3_bucket_server_side_encryption_configuration" "archive" {
  bucket = aws_s3_bucket.archive.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

###############################################
# DCV / LOGIN NODE
###############################################

resource "aws_instance" "dcv_login" {

  depends_on = [aws_iam_role_policy.dcv_slurm_key]

  ami                    = one(one(aws_imagebuilder_image.dcv.output_resources).amis).image
  instance_type          = var.dcv_instance_type
  subnet_id              = aws_subnet.public_1.id
  associate_public_ip_address = true
  vpc_security_group_ids = [aws_security_group.dcv.id]

  iam_instance_profile = aws_iam_instance_profile.dcv.name

  root_block_device {
    volume_size = 100
    volume_type = "gp3"
  }

  user_data = <<-EOF
              #!/bin/bash

              dnf update -y
              dnf install -y amazon-efs-utils cronie

              echo "${aws_efs_file_system.home.id}:/ /home efs _netdev,tls 0 0" >> /etc/fstab

              mount -a

              # Same UID/GID on every node so EFS file ownership matches
              for entry in ${local.cluster_users}; do
                name=$${entry%%:*}
                uid=$${entry##*:}
                getent group "$name" >/dev/null || groupadd -g "$uid" "$name"
                id -u "$name" >/dev/null 2>&1 || useradd -M -u "$uid" -g "$uid" "$name"

                if [ ! -d "/home/$name" ]; then
                  mkdir -p "/home/$name"
                  cp -a /etc/skel/. "/home/$name/"
                  chown -R "$name:$name" "/home/$name"
                  chmod 700 "/home/$name"
                fi

                install -d -o "$name" -g "$name" -m 700 "/home/$name/results"
              done

              cat > /usr/local/bin/archive-results.sh << 'ARCHIVE'
              #!/bin/bash
              for dir in /home/*/results; do
                [ -d "$dir" ] || continue
                user=$(basename "$(dirname "$dir")")
                aws s3 sync "$dir" "s3://${local.archive_bucket_name}/results/$user/" \
                  && find "$dir" -type f -mtime +30 -delete
              done
              ARCHIVE

              chmod 755 /usr/local/bin/archive-results.sh

              echo "0 2 * * * /usr/local/bin/archive-results.sh" >> /var/spool/cron/root

              systemctl enable --now crond

              # Slurm client: fetch the cluster key and point sackd at the PCS controller
              mkdir -p /etc/slurm
              aws secretsmanager get-secret-value --region ${var.aws_region} \
                --secret-id ${awscc_pcs_cluster.openfe.slurm_configuration.auth_key.secret_arn} \
                --query SecretString --output text | base64 -d > /etc/slurm/slurm.key
              chmod 0600 /etc/slurm/slurm.key
              chown -R slurm:slurm /etc/slurm

              echo "SACKD_OPTIONS='--conf-server=${local.slurmctld.private_ip_address}:${local.slurmctld.port}'" > /etc/sysconfig/sackd

              cat > /etc/systemd/system/sackd.service << 'UNIT'
              [Unit]
              Description=Slurm auth and cred kiosk daemon
              After=network-online.target remote-fs.target
              Wants=network-online.target
              ConditionPathExists=/etc/sysconfig/sackd

              [Service]
              Type=notify
              EnvironmentFile=/etc/sysconfig/sackd
              User=slurm
              Group=slurm
              RuntimeDirectory=slurm
              RuntimeDirectoryMode=0755
              ExecStart=/opt/aws/pcs/scheduler/slurm-25.11/sbin/sackd --systemd $SACKD_OPTIONS
              ExecReload=/bin/kill -HUP $MAINPID
              KillMode=process
              LimitNOFILE=131072
              LimitMEMLOCK=infinity
              LimitSTACK=infinity

              [Install]
              WantedBy=multi-user.target
              UNIT

              systemctl daemon-reload
              systemctl enable --now sackd
              EOF

  tags = {
    Name = "shared-dcv-login"
  }
}

###############################################
# OUTPUTS
###############################################

output "vpc_id" {
  value = aws_vpc.pcs.id
}

output "efs_id" {
  value = aws_efs_file_system.home.id
}

output "archive_bucket" {
  value = aws_s3_bucket.archive.bucket
}

output "dcv_instance_id" {
  value = aws_instance.dcv_login.id
}




output "dcv_public_ip" {
  value = aws_instance.dcv_login.public_ip
}

output "dcv_public_dns" {
  value = aws_instance.dcv_login.public_dns
}
