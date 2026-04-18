################################################################################
# S3 Bucket Module - Variables
################################################################################

variable "bucket_name" {
  description = "The name of the S3 bucket. Must be globally unique across all AWS accounts."
  type        = string
}

variable "versioning_enabled" {
  description = "Whether to enable versioning on the S3 bucket."
  type        = bool
  default     = true
}

variable "lifecycle_rules" {
  description = <<-EOT
    A list of lifecycle rule objects to apply to the bucket. Each object supports:
      - id                       : A unique identifier for the rule.
      - transition_days          : Number of days after creation to transition objects (null to skip).
      - transition_storage_class : The storage class to transition to (e.g. STANDARD_IA, GLACIER).
      - expiration_days          : Number of days after creation to expire (delete) objects (null to skip).
  EOT
  type = list(object({
    id                       = string
    transition_days          = optional(number)
    transition_storage_class = optional(string)
    expiration_days          = optional(number)
  }))
  default = []
}

variable "force_destroy" {
  description = "Whether to allow Terraform to destroy the bucket even if it contains objects. Use with caution."
  type        = bool
  default     = false
}

variable "tags" {
  description = "A map of tags to apply to the S3 bucket and related resources."
  type        = map(string)
  default     = {}
}
