provider "aws" {
  region = "us-west-2"  # Replace with your desired AWS region
}

module "horde" {
    source = "../modules/unreal/horde"

    # Set values for required variables
    github_credentials_secret_arn = var.github_credentials_secret_arn  # ARN of your GitHub credentials secret
    certificate_arn = var.certificate_arn # ARN of the Certificate
    unreal_horde_service_subnets = var.unreal_horde_service_subnets
    vpc_id = var.vpc_id

    # Add the fully_qualified_domain_name
    fully_qualified_domain_name   = var.domain_name  # Replace with your desired FQDN

    # Add other variables as needed based on variables.tf requirements

    unreal_horde_external_alb_subnets = var.unreal_horde_external_alb_subnets  # External ALB used by developers
    unreal_horde_internal_alb_subnets = var.unreal_horde_internal_alb_subnets # Internal ALB used by agents
    horde_token = var.horde_token

    agents = {
        ubuntu-x86 = {
            ami           = data.aws_ami.ubuntu_noble_amd.id
            instance_type = "c7a.8xlarge"
            min_size      = 2
            max_size      = 10
            desired_capacity  = 8
            block_device_mappings = [
                {
                    device_name = "/dev/sda1"
                    ebs = {
                    volume_size = 64
                    }
                }
            ]
        }
    }
}