# -----------------------------------------------------------------------------
# DNS & SSL CERTIFICATES
# Route53 records and ACM certificate management
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# ACM CERTIFICATE
# -----------------------------------------------------------------------------

resource "aws_acm_certificate" "pluto" {
  domain_name               = local.domain_root
  validation_method         = "DNS"
  subject_alternative_names = var.subdomain_prefix != "" ? ["*.${local.domain_root}", "${local.domain_root}"] : ["*.${local.domain_root}"]

  tags = {
    Name = "${var.project_name}-cert"
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.pluto.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id = data.aws_route53_zone.selected.zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "pluto" {
  certificate_arn         = aws_acm_certificate.pluto.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

# -----------------------------------------------------------------------------
# ROUTE53 RECORDS
# -----------------------------------------------------------------------------

resource "aws_route53_record" "services" {
  for_each = local.service_hosts

  zone_id = data.aws_route53_zone.selected.zone_id
  name    = each.value
  type    = "A"

  alias {
    name                   = aws_lb.pluto.dns_name
    zone_id                = aws_lb.pluto.zone_id
    evaluate_target_health = false
  }
}

# A Record for root domain if subdomain_prefix matches local.domain_root
resource "aws_route53_record" "root" {
  zone_id = data.aws_route53_zone.selected.zone_id
  name    = local.domain_root
  type    = "A"

  alias {
    name                   = aws_lb.pluto.dns_name
    zone_id                = aws_lb.pluto.zone_id
    evaluate_target_health = false
  }
}
