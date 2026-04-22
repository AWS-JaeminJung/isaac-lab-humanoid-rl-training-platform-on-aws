################################################################################
# Phase 01 - Foundation: ACM Certificate
#
# Wildcard certificate for the internal domain. Uses DNS validation with
# records created in the private hosted zone.
################################################################################

resource "aws_acm_certificate" "internal" {
  domain_name       = "*.${var.domain}"
  validation_method = "DNS"

  subject_alternative_names = [
    var.domain,
  ]

  tags = {
    Name = "${var.s3_prefix}-cert-internal"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ------------------------------------------------------------------------------
# DNS Validation Records
# ------------------------------------------------------------------------------

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.internal.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = aws_route53_zone.internal.zone_id
}

resource "aws_acm_certificate_validation" "internal" {
  certificate_arn         = aws_acm_certificate.internal.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}
