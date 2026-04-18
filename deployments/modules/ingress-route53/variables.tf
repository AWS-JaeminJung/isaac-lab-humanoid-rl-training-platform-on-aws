################################################################################
# Ingress Route53 Module - Variables
################################################################################

variable "hostname" {
  description = "The fully qualified domain name for the DNS record (e.g. app.example.com)."
  type        = string
}

variable "hosted_zone_id" {
  description = "The Route53 hosted zone ID in which to create the record."
  type        = string
}

variable "alb_dns_name" {
  description = "The DNS name of the Application Load Balancer to alias to (e.g. my-alb-123456.us-east-1.elb.amazonaws.com)."
  type        = string
}

variable "alb_zone_id" {
  description = "The canonical hosted zone ID of the Application Load Balancer (used by Route53 for alias resolution)."
  type        = string
}

variable "evaluate_target_health" {
  description = "Whether Route53 should evaluate the health of the ALB target when responding to DNS queries."
  type        = bool
  default     = true
}
