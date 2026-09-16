variable "region" {
  description = "The region where the resources are created."
  default     = "ap-southeast-1"
}

variable "prefix" {
  default = "dashboard-counting"
  description = "This prefix will be included in the name of most resources."
}

variable "address_space" {
  description = "The address space that is used by the virtual network. You can supply more than one address space. Changing this forces a new resource to be created."
  default     = "172.0.0.0/16"
}

variable "environment" {
  default     = "Production"
  description = "target environment"
}

variable "subnet_prefix" {
  description = "The address prefix to use for the subnet."
  default     = "172.0.0.0/24"
}

variable "subnet_private_prefix" {
  description = "The address prefix to use for the private subnet."
  default     = "172.0.1.0/24"
}

variable "ssm_instance_profile_name" {
  default = "instanceRole"
  description = "Name of the existing IAM instance profile with SSM permissions"
}