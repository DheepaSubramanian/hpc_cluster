#########################################
# PCS COMPUTE COMPONENT
#########################################

resource "aws_imagebuilder_component" "pcs_compute_component" {

  name        = "openfe-pcs-compute-component"
  platform    = "Linux"
  version     = "1.0.0"
  description = "PCS Compute Node Component"

  data = <<EOF
name: openfe-pcs-compute
description: Install PCS Compute Packages
schemaVersion: 1.0

phases:

  - name: build

    steps:

      ###################################
      # Update
      ###################################

      - name: UpdateOS
        action: ExecuteBash
        inputs:
          commands:
            - |
              dnf update -y

      ###################################
      # Base Packages
      ###################################

      - name: BasePackages
        action: ExecuteBash
        inputs:
          commands:
            - |
              dnf install -y \
                git \
                vim \
                jq \
                htop \
                docker \
                python3 \
                python3-pip \
                amazon-efs-utils \
                amazon-cloudwatch-agent

      ###################################
      # Docker
      ###################################

      - name: EnableDocker
        action: ExecuteBash
        inputs:
          commands:
            - |
              systemctl enable docker

      ###################################
      # PCS Agent
      ###################################

      - name: DownloadPCSAgent
        action: ExecuteBash
        inputs:
          commands:
            - |
              cd /tmp

              curl -L -o aws-pcs-agent.tar.gz \
              https://aws-pcs-repo-${var.aws_region}.s3.${var.aws_region}.amazonaws.com/aws-pcs-agent/aws-pcs-agent-v1-latest.tar.gz

              tar -xzf aws-pcs-agent.tar.gz

      - name: InstallPCSAgent
        action: ExecuteBash
        inputs:
          commands:
            - |
              cd /tmp/aws-pcs-agent

              ./installer.sh

      ###################################
      # Slurm
      ###################################

      - name: DownloadSlurm
        action: ExecuteBash
        inputs:
          commands:
            - |
              cd /tmp

              curl -L -o slurm.tar.gz \
              https://aws-pcs-repo-${var.aws_region}.s3.${var.aws_region}.amazonaws.com/aws-pcs-slurm/aws-pcs-slurm-25.11-installer-latest.tar.gz

              tar -xzf slurm.tar.gz

      - name: InstallSlurm
        action: ExecuteBash
        inputs:
          commands:
            - |
              cd /tmp/aws-pcs-slurm-25.11-installer

              ./installer.sh -y

      ###################################
      # NVIDIA REPOSITORY
      ###################################

      - name: NvidiaRepo
        action: ExecuteBash
        inputs:
          commands:
            - |
              dnf config-manager \
              --add-repo \
              https://developer.download.nvidia.com/compute/cuda/repos/amzn2023/x86_64/cuda-amzn2023.repo

      ###################################
      # NVIDIA DRIVER
      ###################################

      - name: NvidiaDriver
        action: ExecuteBash
        inputs:
          commands:
            - |
              dnf module enable -y nvidia-driver:open-dkms

              dnf install -y \
              nvidia-open

      ###################################
      # CUDA
      ###################################

      - name: InstallCUDA
        action: ExecuteBash
        inputs:
          commands:
            - |
              dnf install -y cuda-toolkit

      ###################################
      # OpenMM
      ###################################

      - name: InstallOpenMM
        action: ExecuteBash
        inputs:
          commands:
            - |
              pip3 install openmm

      ###################################
      # OpenFE
      ###################################

      - name: InstallOpenFE
        action: ExecuteBash
        inputs:
          commands:
            - |
              pip3 install openfe

      ###################################
      # Services
      ###################################

      - name: EnableServices
        action: ExecuteBash
        inputs:
          commands:
            - |
              systemctl enable amazon-cloudwatch-agent

EOF
}

#########################################
# PCS IMAGE RECIPE
#########################################

resource "aws_imagebuilder_image_recipe" "pcs_compute" {

  name         = "openfe-pcs-compute-recipe"
  version      = "1.0.0"
  parent_image = data.aws_ssm_parameter.al2023.value

  component {
    component_arn = aws_imagebuilder_component.pcs_compute_component.arn
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
# PCS INFRASTRUCTURE
#########################################

resource "aws_imagebuilder_infrastructure_configuration" "pcs_compute" {

  name = "openfe-pcs-compute-infra"

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
# PCS DISTRIBUTION
#########################################

resource "aws_imagebuilder_distribution_configuration" "pcs_compute" {

  name = "openfe-pcs-compute-distribution"

  distribution {

    region = var.aws_region

    ami_distribution_configuration {

      name = "openfe-pcs-compute-{{ imagebuilder:buildDate }}"
    }
  }
}

#########################################
# CREATE PCS AMI
#########################################

resource "aws_imagebuilder_image" "pcs_compute" {

  image_recipe_arn = aws_imagebuilder_image_recipe.pcs_compute.arn

  infrastructure_configuration_arn = aws_imagebuilder_infrastructure_configuration.pcs_compute.arn

  distribution_configuration_arn = aws_imagebuilder_distribution_configuration.pcs_compute.arn

  # Build instance needs outbound internet via the NAT gateway
  depends_on = [
    aws_route.private,
    aws_route_table_association.priv1
  ]
}

#########################################
# OUTPUT
#########################################

output "pcs_compute_ami_arn" {
  value = aws_imagebuilder_image.pcs_compute.arn
}