variable "certificate_arn" {
  description = "ARN of the SSL/TLS certificate"
  type        = string
}

variable "domain_name" {
  description = "Domain name of the website"
  type        = string
}

variable "vpc_id" {
    description = "ID of the VPC"
    type        = string
}

variable "unreal_horde_service_subnets" {
    description = "IDs of the subnets"
    type        = list(string)
}

variable "github_credentials_secret_arn" {
    description = "ARN of the secret containing GitHub credentials"
    type        = string
}

variable "unreal_horde_internal_alb_subnets" {
    description = "IDs of the subnets"
    type        = list(string)
}

variable "unreal_horde_external_alb_subnets" {
    description = "IDs of the subnets"
    type        = list(string)
}

variable "horde_token" {
    description = "Token for Horde"
    type        = string
}