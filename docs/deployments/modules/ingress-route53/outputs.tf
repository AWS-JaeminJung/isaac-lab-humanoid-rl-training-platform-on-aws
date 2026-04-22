################################################################################
# Ingress Route53 Module - Outputs
################################################################################

output "fqdn" {
  description = "The fully qualified domain name of the created Route53 record."
  value       = aws_route53_record.this.fqdn
}
