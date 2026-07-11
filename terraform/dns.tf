resource "aws_route53_record" "app" {
  zone_id = data.aws_route53_zone.primary.zone_id
  name    = "voteball.latnook.com"
  type    = "A"
  ttl     = 300
  records = [module.compute.public_ip]
}
