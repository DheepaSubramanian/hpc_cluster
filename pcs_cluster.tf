resource "aws_security_group" "pcs_compute" {
  name        = "pcs-compute-sg"
  description = "PCS controller and compute nodes"
  vpc_id      = aws_vpc.pcs.id

  # Slurm controller <-> compute node traffic
  ingress {
    description = "Cluster internal"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  ingress {
    description     = "Slurm client on DCV login node"
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    security_groups = [aws_security_group.dcv.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "pcs-compute-sg"
  }
}

resource "awscc_pcs_cluster" "openfe" {

  name = "openfe-cluster"

  scheduler = {
    type    = "SLURM"
    version = "25.11"
  }

  size = "SMALL"

  networking = {
    # PCS places the controller in exactly one subnet
    subnet_ids = [
      aws_subnet.private_1.id
    ]

    security_group_ids = [
      aws_security_group.pcs_compute.id
    ]
  }

  slurm_configuration = {

    accounting = {
      mode                       = "STANDARD"
      default_purge_time_in_days = 30
    }

    slurm_custom_settings = [
      {
        parameter_name  = "MetricsType"
        parameter_value = "metrics/openmetrics"
      },
      {
        parameter_name  = "CommunicationParameters"
        parameter_value = "enable_http"
      }
    ]
  }

  tags = {
    Name = "openfe-cluster"
  }
}

locals {
  slurmctld = one([
    for e in awscc_pcs_cluster.openfe.endpoints : e if e.type == "SLURMCTLD"
  ])
}

#########################################
# COMPUTE NODE GROUP
#########################################

variable "pcs_compute_instance_type" {
  default = "g6e.xlarge"
}

variable "pcs_compute_max_nodes" {
  default = 4
}

resource "awscc_pcs_compute_node_group" "gpu" {

  name       = "gpu-g6e"
  cluster_id = awscc_pcs_cluster.openfe.cluster_id

  custom_launch_template = {
    template_id = aws_launch_template.pcs_compute.id
    version     = tostring(aws_launch_template.pcs_compute.latest_version)
  }

  iam_instance_profile_arn = aws_iam_instance_profile.pcs.arn

  instance_configs = [
    {
      instance_type = var.pcs_compute_instance_type
    }
  ]

  # Nodes launch on demand when jobs are queued and scale back to zero when idle
  scaling_configuration = {
    min_instance_count = 0
    max_instance_count = var.pcs_compute_max_nodes
  }

  subnet_ids = [
    aws_subnet.private_1.id,
    aws_subnet.private_2.id
  ]

  purchase_option = "ONDEMAND"

  tags = {
    Name = "openfe-pcs-gpu-nodes"
  }
}

#########################################
# QUEUE
#########################################

resource "awscc_pcs_queue" "gpu" {

  name       = "gpu"
  cluster_id = awscc_pcs_cluster.openfe.cluster_id

  compute_node_group_configurations = [
    {
      compute_node_group_id = awscc_pcs_compute_node_group.gpu.compute_node_group_id
    }
  ]

  tags = {
    Name = "openfe-pcs-gpu-queue"
  }
}

#########################################
# OUTPUTS
#########################################

output "pcs_cluster_id" {
  value = awscc_pcs_cluster.openfe.cluster_id
}

output "pcs_queue_name" {
  value = awscc_pcs_queue.gpu.name
}