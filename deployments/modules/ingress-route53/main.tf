################################################################################
# Ingress Route53 Module
#
# Creates a Route53 A record as an alias to an Application Load Balancer.
# This is the standard pattern for exposing Kubernetes Ingress resources
# behind a friendly DNS name managed in Route53.
################################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ---------------------------------------------------------------------------
# Route53 A Record (Alias to ALB)
# ---------------------------------------------------------------------------

resource "aws_route53_record" "this" {
  zone_id = var.hosted_zone_id
  name    = var.hostname
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = var.evaluate_target_health
  }
}
