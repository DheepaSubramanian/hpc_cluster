#########################################
# PCS COMPUTE NODE IAM
#########################################

# PCS requires the role name to start with AWSPCS (or use the /aws-pcs/ path)
resource "aws_iam_role" "pcs_compute" {
  name = "AWSPCS-openfe-compute-role"

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

resource "aws_iam_role_policy" "pcs_compute_register" {
  name = "pcs-register-instance"
  role = aws_iam_role.pcs_compute.id

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [{
      Effect   = "Allow"
      Action   = "pcs:RegisterComputeNodeGroupInstance"
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "pcs_compute_ssm" {
  role       = aws_iam_role.pcs_compute.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "pcs_compute_cw" {
  role       = aws_iam_role.pcs_compute.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "pcs" {
  name = "AWSPCS-openfe-compute-profile"
  role = aws_iam_role.pcs_compute.name
}

#########################################
# PCS COMPUTE LAUNCH TEMPLATE
#########################################

# Instance type and IAM profile are set on the PCS compute node group
resource "aws_launch_template" "pcs_compute" {

  name                   = "openfe-pcs-compute-lt"
  update_default_version = true

  image_id = one(one(aws_imagebuilder_image.pcs_compute.output_resources).amis).image

  monitoring {
    enabled = true
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
    http_tokens                 = "required"
  }

  network_interfaces {
    device_index = 0

    security_groups = [
      aws_security_group.pcs_compute.id
    ]
  }

  block_device_mappings {

    device_name = "/dev/xvda"

    ebs {
      volume_size           = 200
      volume_type           = "gp3"
      delete_on_termination = true
      encrypted             = true
    }
  }

  # PCS requires MIME multi-part user data so it can append its own bootstrap
  user_data = base64encode(<<-EOF
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="==OPENFEBOUNDARY=="

    --==OPENFEBOUNDARY==
    Content-Type: text/x-shellscript; charset="us-ascii"

    #!/bin/bash

    set -eux

    ###################################################
    # Mount EFS
    ###################################################

    echo "${aws_efs_file_system.home.id}:/ /home efs _netdev,tls 0 0" >> /etc/fstab

    mount -a

    ###################################################
    # User accounts (homes already exist on EFS)
    ###################################################

    # UIDs/GIDs must match the DCV node so jobs can write to /home/<user>
    for entry in ${local.cluster_users}; do
      name=$${entry%%:*}
      uid=$${entry##*:}
      getent group "$name" >/dev/null || groupadd -g "$uid" "$name"
      id -u "$name" >/dev/null 2>&1 || useradd -M -u "$uid" -g "$uid" "$name"
    done

    ###################################################
    # Local scratch on NVMe instance store (wiped on stop)
    ###################################################

    mkdir -p /scratch

    SCRATCH_DEV=$(lsblk -dpno NAME,MODEL | awk '/Instance Storage/ {print $1; exit}')

    if [ -n "$SCRATCH_DEV" ]; then
      mkfs.xfs -f "$SCRATCH_DEV"
      mount -o noatime "$SCRATCH_DEV" /scratch
    fi

    chmod 1777 /scratch

    ###################################################
    # Verify EFS mount
    ###################################################

    df -h

    ###################################################
    # Restart monitoring
    ###################################################

    systemctl restart amazon-cloudwatch-agent || true

    ###################################################
    # Bootstrap log
    ###################################################

    echo "OpenFE PCS node configured successfully" \
      >> /var/log/openfe-bootstrap.log

    date >> /var/log/openfe-bootstrap.log

    --==OPENFEBOUNDARY==--
  EOF
  )

  tag_specifications {

    resource_type = "instance"

    tags = {
      Name = "openfe-pcs-compute"
    }
  }

  tags = {
    Name = "openfe-pcs-compute-lt"
  }
}