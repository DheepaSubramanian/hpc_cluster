#########################################
# IMAGE BUILDER ROLE
#########################################

resource "aws_iam_role" "imagebuilder_role" {
  name = "openfe-imagebuilder-role"

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

resource "aws_iam_role_policy_attachment" "imagebuilder" {
  role       = aws_iam_role.imagebuilder_role.name
  policy_arn = "arn:aws:iam::aws:policy/EC2InstanceProfileForImageBuilder"
}

resource "aws_iam_role_policy_attachment" "imagebuilder_ssm" {
  role       = aws_iam_role.imagebuilder_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "imagebuilder" {
  name = "openfe-imagebuilder-profile"
  role = aws_iam_role.imagebuilder_role.name
}

#########################################
# IMAGE BUILDER COMPONENT
#########################################

resource "aws_imagebuilder_component" "dcv_component" {

  name        = "openfe-dcv-component"
  platform    = "Linux"
  version     = "1.1.0"
  description = "DCV Login Node Component"

  data = <<EOF
name: openfe-dcv-component
description: Install DCV Login Node Packages
schemaVersion: 1.0

phases:
  - name: build

    steps:

      - name: UpdateOS
        action: ExecuteBash
        inputs:
          commands:
            - |
              set -euo pipefail
              dnf update -y

      # Boot into the updated kernel so the NVIDIA DKMS module is built against it
      - name: RebootAfterUpdate
        action: Reboot
        onFailure: Abort
        maxAttempts: 2
        inputs:
          delaySeconds: 60

      - name: InstallBasePackages
        action: ExecuteBash
        inputs:
          commands:
            - |
              set -euo pipefail
              dnf install -y \
                git \
                vim \
                jq \
                htop \
                amazon-efs-utils \
                amazon-cloudwatch-agent

      - name: InstallDesktop
        action: ExecuteBash
        inputs:
          commands:
            - |
              set -euo pipefail
              dnf groupinstall -y "Desktop"

      - name: InstallNvidiaDrivers
        action: ExecuteBash
        inputs:
          commands:
            - |
              set -euo pipefail
              dnf install -y \
                dkms \
                kernel-devel-matched-$(uname -r) \
                kernel-headers-$(uname -r) \
                kernel-modules-extra-$(uname -r)
              dnf config-manager --add-repo https://developer.download.nvidia.com/compute/cuda/repos/amzn2023/x86_64/cuda-amzn2023.repo
              dnf clean expire-cache
              dnf install -y nvidia-open

      - name: InstallOpenFE
        action: ExecuteBash
        inputs:
          commands:
            - |
              set -euo pipefail
              curl -fsSL -o /tmp/miniforge.sh https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh
              bash /tmp/miniforge.sh -b -p /opt/miniforge
              rm -f /tmp/miniforge.sh
              /opt/miniforge/bin/mamba create -y -n openfe -c conda-forge python=3.11 openfe jupyterlab
              /opt/miniforge/bin/conda clean -afy
              echo 'export PATH=/opt/miniforge/envs/openfe/bin:$PATH' > /etc/profile.d/openfe.sh

      # Defaults already give web-port=8443 and authentication=system, so dcv.conf is left as shipped
      - name: InstallDCV
        action: ExecuteBash
        inputs:
          commands:
            - |
              set -euo pipefail
              cd /tmp
              rpm --import https://d1uj6qtbmh3dt5.cloudfront.net/NICE-GPG-KEY
              curl -fsSL -O https://d1uj6qtbmh3dt5.cloudfront.net/nice-dcv-amzn2023-x86_64.tgz
              tar -xzf nice-dcv-amzn2023-x86_64.tgz
              cd nice-dcv-*-amzn2023-x86_64
              dnf install -y ./nice-dcv-server-*.rpm ./nice-dcv-web-viewer-*.rpm ./nice-xdcv-*.rpm
              systemctl enable dcvserver
              cd /tmp
              rm -rf nice-dcv-*

      # Same PCS agent and Slurm version as the compute AMI so the login node can submit jobs
      - name: InstallPCSAgent
        action: ExecuteBash
        inputs:
          commands:
            - |
              set -euo pipefail
              cd /tmp
              curl -fsSL -o aws-pcs-agent.tar.gz https://aws-pcs-repo-${var.aws_region}.s3.${var.aws_region}.amazonaws.com/aws-pcs-agent/aws-pcs-agent-v1-latest.tar.gz
              tar -xzf aws-pcs-agent.tar.gz
              cd aws-pcs-agent
              ./installer.sh
              cd /tmp
              rm -rf aws-pcs-agent aws-pcs-agent.tar.gz

      - name: InstallSlurm
        action: ExecuteBash
        inputs:
          commands:
            - |
              set -euo pipefail
              cd /tmp
              curl -fsSL -o slurm.tar.gz https://aws-pcs-repo-${var.aws_region}.s3.${var.aws_region}.amazonaws.com/aws-pcs-slurm/aws-pcs-slurm-25.11-installer-latest.tar.gz
              tar -xzf slurm.tar.gz
              cd aws-pcs-slurm-25.11-installer
              ./installer.sh -y
              cd /tmp
              rm -rf aws-pcs-slurm-25.11-installer slurm.tar.gz
              echo 'export PATH=/opt/aws/pcs/scheduler/slurm-25.11/bin:$PATH' > /etc/profile.d/slurm.sh

  - name: test

    steps:

      - name: ValidateImage
        action: ExecuteBash
        inputs:
          commands:
            - |
              set -euo pipefail
              modinfo nvidia > /dev/null
              systemctl is-enabled dcvserver
              /opt/miniforge/envs/openfe/bin/python -c "import openfe"
              /opt/miniforge/envs/openfe/bin/jupyter lab --version
              test -x /opt/aws/pcs/scheduler/slurm-25.11/sbin/sackd
              /opt/aws/pcs/scheduler/slurm-25.11/bin/sbatch --version

EOF
}

#########################################
# IMAGE RECIPE
#########################################

resource "aws_imagebuilder_image_recipe" "dcv" {

  name         = "openfe-dcv-recipe"
  version      = "1.1.0"
  parent_image = data.aws_ssm_parameter.al2023.value

  component {
    component_arn = aws_imagebuilder_component.dcv_component.arn
  }

  # Pin the base AMI after the first apply; use `terraform apply -replace` to rebase
  lifecycle {
    ignore_changes = [parent_image]
  }

  block_device_mapping {

    device_name = "/dev/xvda"

    ebs {
      volume_size           = 100
      volume_type           = "gp3"
      delete_on_termination = true
    }
  }
}

#########################################
# INFRA CONFIG
#########################################

resource "aws_security_group" "imagebuilder" {
  name        = "openfe-imagebuilder-sg"
  description = "Image Builder build instances (egress only)"
  vpc_id      = aws_vpc.pcs.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_imagebuilder_infrastructure_configuration" "dcv" {

  name = "openfe-dcv-infra"

  instance_profile_name = aws_iam_instance_profile.imagebuilder.name

  instance_types = [
    "m5.xlarge"
  ]

  subnet_id = aws_subnet.private_1.id

  security_group_ids = [
    aws_security_group.imagebuilder.id
  ]

  terminate_instance_on_failure = true
}

#########################################
# DISTRIBUTION CONFIG
#########################################

resource "aws_imagebuilder_distribution_configuration" "dcv" {

  name = "openfe-dcv-distribution"

  distribution {

    region = var.aws_region

    ami_distribution_configuration {

      name = "openfe-dcv-{{ imagebuilder:buildDate }}"
    }
  }
}

#########################################
# CREATE AMI
#########################################

resource "aws_imagebuilder_image" "dcv" {

  image_recipe_arn = aws_imagebuilder_image_recipe.dcv.arn

  infrastructure_configuration_arn = aws_imagebuilder_infrastructure_configuration.dcv.arn

  distribution_configuration_arn = aws_imagebuilder_distribution_configuration.dcv.arn

  # Build instance needs outbound internet via the NAT gateway
  depends_on = [
    aws_route.private,
    aws_route_table_association.priv1
  ]

  timeouts {
    create = "120m"
  }
}

#########################################
# OUTPUT
#########################################

output "dcv_ami_arn" {
  value = aws_imagebuilder_image.dcv.arn
}
