################################################################################
# VPC Endpoint Module - Variables
################################################################################

variable "vpc_id" {
  description = "The ID of the VPC in which to create the endpoint."
  type        = string
}

variable "service_name" {
  description = "The full AWS service name for the endpoint (e.g. com.amazonaws.us-east-1.s3)."
  type        = string
}

variable "type" {
  description = "The type of VPC endpoint. Must be 'gateway' or 'interface'."
  type        = string

  validation {
    condition     = contains(["gateway", "interface"], lower(var.type))
    error_message = "The type must be either 'gateway' or 'interface'."
  }
}

variable "subnet_ids" {
  description = "List of subnet IDs in which to place the endpoint network interfaces. Required for interface endpoints."
  type        = list(string)
  default     = []
}

variable "security_group_ids" {
  description = "List of security group IDs to associate with the endpoint network interfaces. Required for interface endpoints."
  type        = list(string)
  default     = []
}

variable "route_table_ids" {
  description = "List of route table IDs to associate with the gateway endpoint. Required for gateway endpoints."
  type        = list(string)
  default     = []
}

variable "private_dns_enabled" {
  description = "Whether to enable private DNS for the interface endpoint. Only applicable to interface endpoints."
  type        = bool
  default     = true
}

variable "tags" {
  description = "A map of tags to apply to the VPC endpoint resource."
  type        = map(string)
  default     = {}
}
