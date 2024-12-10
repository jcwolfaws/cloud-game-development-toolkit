resource "aws_launch_template" "unreal_horde_agent_template" {
  for_each    = var.agents
  name_prefix = "unreal_horde_agent-${each.key}"
  description = "Launch template for ${each.key} Unreal Horde Agents"

  image_id      = each.value.ami
  instance_type = each.value.instance_type
  ebs_optimized = true

  dynamic "block_device_mappings" {
    for_each = each.value.block_device_mappings
    content {
      device_name = block_device_mappings.value.device_name
      ebs {
        volume_size = block_device_mappings.value.ebs.volume_size
        volume_type = "gp2"
      }
    }
  }

  vpc_security_group_ids = [aws_security_group.unreal_horde_agent_sg[0].id]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }
  iam_instance_profile {
    arn = aws_iam_instance_profile.unreal_horde_agent_instance_profile[0].arn
  }
}

resource "aws_autoscaling_group" "unreal_horde_agent_asg" {
  for_each = aws_launch_template.unreal_horde_agent_template
  name_prefix = "unreal_horde_agents-${each.key}-"
  
  mixed_instances_policy {
    launch_template {
      launch_template_specification {
        launch_template_id = each.value.id
        version = "$Latest"
      }

      # Here's where we specify instance types
      override {
        instance_type = "c7a.4xlarge"
      }
      override {
        instance_type = "c7a.8xlarge"
      }
      override {
        instance_type = "c6a.4xlarge"
      }
      override {
        instance_type = "c6a.8xlarge"
      }
      override {
        instance_type = "c5a.4xlarge"
      }
      override {
        instance_type = "c5a.8xlarge"
      }
    }

    instances_distribution {
      on_demand_percentage_above_base_capacity = 0
      spot_allocation_strategy = "price-capacity-optimized"
    }
  }
  
  vpc_zone_identifier = var.unreal_horde_service_subnets
  min_size = var.agents[each.key].min_size
  max_size = var.agents[each.key].max_size
  desired_capacity = var.agents[each.key].desired_capacity
  
  tag {
    key = "Name"
    value = "${each.key} Horde Agent"
    propagate_at_launch = true
  }

  # Enable group metrics collection
  enabled_metrics = [
    "GroupMinSize",
    "GroupMaxSize",
    "GroupDesiredCapacity",
    "GroupInServiceInstances",
    "GroupInServiceCapacity",
    "GroupPendingInstances",
    "GroupPendingCapacity",
    "GroupTerminatingInstances",
    "GroupTerminatingCapacity",
    "GroupStandbyInstances",
    "GroupStandbyCapacity",
    "GroupTotalInstances",
    "GroupTotalCapacity",
    "WarmPoolMinSize",
    "WarmPoolDesiredCapacity",
    "WarmPoolPendingCapacity",
    "WarmPoolTerminatingCapacity",
    "WarmPoolWarmedCapacity",
    "WarmPoolTotalCapacity",
    "GroupAndWarmPoolDesiredCapacity",
    "GroupAndWarmPoolTotalCapacity"
  ]
  
  depends_on = [aws_ecs_service.unreal_horde]
}

# Then create the scaling policy for the ASG
resource "aws_autoscaling_policy" "cpu_policy" {
  # Use the same for_each as the ASG
  for_each = aws_launch_template.unreal_horde_agent_template

  name                   = "cpu-tracking-policy-${each.key}"
  # Reference the ASG using the same key from for_each
  autoscaling_group_name = aws_autoscaling_group.unreal_horde_agent_asg[each.key].name
  policy_type           = "TargetTrackingScaling"
  estimated_instance_warmup = 300

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    
    target_value = 75.0
    disable_scale_in = true
  }
}

# CloudWatch Alarm for high CPU
resource "aws_cloudwatch_metric_alarm" "cpu_alarm_high" {
  for_each = aws_launch_template.unreal_horde_agent_template

  alarm_name          = "cpu-utilization-high-${each.key}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name        = "CPUUtilization"
  namespace          = "AWS/EC2"
  period             = "300"
  statistic          = "Average"
  threshold          = 75

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.unreal_horde_agent_asg[each.key].name
  }

  alarm_description = "This metric monitors EC2 CPU utilization for scaling out"
  alarm_actions     = [aws_autoscaling_policy.cpu_policy[each.key].arn]
}

# CPU Scale-IN Policy (Scale Down)
resource "aws_autoscaling_policy" "cpu_scale_in" {
  for_each = aws_autoscaling_group.unreal_horde_agent_asg

  name                   = "cpu-scale-in-policy-${each.key}"
  autoscaling_group_name = each.value.name
  adjustment_type        = "ChangeInCapacity"
  policy_type           = "SimpleScaling"
  scaling_adjustment     = -1  # Remove one instance at a time
  cooldown              = 7200 # 2 hour cooldown before next scale-in
}

# CloudWatch Alarm for low CPU
resource "aws_cloudwatch_metric_alarm" "cpu_alarm_low" {
  for_each = aws_launch_template.unreal_horde_agent_template

  alarm_name          = "cpu-utilization-low-${each.key}"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "24"
  metric_name        = "CPUUtilization"
  namespace          = "AWS/EC2"
  period             = "300"
  statistic          = "Average"
  threshold          = 30 # 30 percent CPU

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.unreal_horde_agent_asg[each.key].name
  }

  alarm_description = "Scale in if CPU is below 30% for 2 hours"
  alarm_actions     = [aws_autoscaling_policy.cpu_scale_in[each.key].arn]  # This links the alarm to the policy
}

data "aws_iam_policy_document" "ec2_trust_relationship" {
  count = length(var.agents) > 0 ? 1 : 0
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

data "aws_iam_policy_document" "horde_agents_s3_policy" {
  count = length(var.agents) > 0 ? 1 : 0
  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
      "s3:PutObject",
      "s3:PutObjectAcl",
      "s3:GetEncryptionConfiguration"
    ]
    resources = [
      aws_s3_bucket.ansible_playbooks[0].arn,
      "${aws_s3_bucket.ansible_playbooks[0].arn}/*"
    ]
  }
}

resource "aws_iam_policy" "horde_agents_s3_policy" {
  count       = length(var.agents) > 0 ? 1 : 0
  name        = "${var.project_prefix}-horde-agents-s3-policy"
  description = "Policy granting Horde Agent EC2 instances access to Amazon S3."
  policy      = data.aws_iam_policy_document.horde_agents_s3_policy[0].json
}

# Instance Role
resource "aws_iam_role" "unreal_horde_agent_default_role" {
  count = length(var.agents) > 0 ? 1 : 0
  name = "unreal-horde-agent-default-instance-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust_relationship[0].json
  tags = local.tags
}

# Policy Attachments (new resource)
resource "aws_iam_role_policy_attachments_exclusive" "unreal_horde_agent_role_policies" {
  count = length(var.agents) > 0 ? 1 : 0
  role_name  = aws_iam_role.unreal_horde_agent_default_role[0].name
  
  policy_arns = [
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
    aws_iam_policy.horde_agents_s3_policy[0].arn
  ]
}

# Instance Profile
resource "aws_iam_instance_profile" "unreal_horde_agent_instance_profile" {
  count = length(var.agents) > 0 ? 1 : 0
  name  = "unreal-horde-agent-instance-profile"
  role  = aws_iam_role.unreal_horde_agent_default_role[0].name
}

resource "random_string" "unreal_horde_ansible_playbooks_bucket_suffix" {
  count   = length(var.agents) > 0 ? 1 : 0
  length  = 8
  special = false
  upper   = false
}

resource "aws_s3_bucket" "ansible_playbooks" {
  count  = length(var.agents) > 0 ? 1 : 0
  bucket = "unreal-horde-ansible-playbooks-${random_string.unreal_horde_ansible_playbooks_bucket_suffix[0].id}"

  #checkov:skip=CKV_AWS_144: Cross-region replication not necessary
  #checkov:skip=CKV_AWS_145: KMS encryption with CMK not currently supported
  #checkov:skip=CKV_AWS_18: S3 access logs not necessary
  #checkov:skip=CKV2_AWS_62: Event notifications not necessary
  #checkov:skip=CKV2_AWS_61: Lifecycle configuration not necessary
  #checkov:skip=CKV2_AWS_6: Public access block conditionally defined
  #checkov:skip=CKV_AWS_21: Versioning enabled conditionally

  tags = local.tags
}

resource "aws_s3_bucket_versioning" "ansible_playbooks_versioning" {
  count = length(var.agents) > 0 ? 1 : 0

  bucket = aws_s3_bucket.ansible_playbooks[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "ansible_playbooks_bucket_public_block" {
  count = length(var.agents) > 0 ? 1 : 0

  depends_on = [
    aws_s3_bucket.ansible_playbooks[0]
  ]
  bucket                  = aws_s3_bucket.ansible_playbooks[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "unreal_horde_agent_playbook" {
  count  = length(var.agents) > 0 ? 1 : 0
  bucket = aws_s3_bucket.ansible_playbooks[0].id
  key    = "/agent/horde-agent.ansible.yml"
  source = "${path.module}/config/agent/horde-agent.ansible.yml"
  etag   = filemd5("${path.module}/config/agent/horde-agent.ansible.yml")
}

resource "aws_s3_object" "unreal_horde_agent_service" {
  count  = length(var.agents) > 0 ? 1 : 0
  bucket = aws_s3_bucket.ansible_playbooks[0].id
  key    = "/agent/horde-agent.service"
  source = "${path.module}/config/agent/horde-agent.service"
  etag   = filemd5("${path.module}/config/agent/horde-agent.service")
}

resource "aws_ssm_document" "ansible_run_document" {
  count         = length(var.agents) > 0 ? 1 : 0
  document_type = "Command"
  name          = "AnsibleRun"
  content       = file("${path.module}/config/ssm/AnsibleRunCommand.json")
  tags          = local.tags
}

resource "aws_ssm_association" "configure_unreal_horde_agent" {
  count            = length(var.agents) > 0 ? 1 : 0
  association_name = "ConfigureUnrealHordeAgent"
  name             = aws_ssm_document.ansible_run_document[0].name
  parameters = {
    SourceInfo     = "{\"path\":\"https://${aws_s3_bucket.ansible_playbooks[0].bucket_domain_name}/agent/\"}"
    PlaybookFile   = "horde-agent.ansible.yml"
    ExtraVariables = "horde_server_url=${var.fully_qualified_domain_name}"
  }

  output_location {
    s3_bucket_name = aws_s3_bucket.ansible_playbooks[0].bucket
    s3_key_prefix  = "logs"
  }

  targets {
    key    = "tag:aws:autoscaling:groupName"
    values = values(aws_autoscaling_group.unreal_horde_agent_asg)[*].name
  }

  # Wait for service to be ready before attempting enrollment
  depends_on = [aws_ecs_service.unreal_horde]
}
