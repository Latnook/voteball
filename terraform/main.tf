data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_subnet" "compute_az" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "availabilityZone"
    values = ["il-central-1c"]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

data "aws_route53_zone" "primary" {
  name = "latnook.com"
}

resource "aws_key_pair" "voteball" {
  key_name   = var.key_name
  public_key = file("${path.module}/../Voteball-EC2-pem.pub")
}

module "networking" {
  source           = "./modules/networking"
  ssh_allowed_cidr = var.ssh_allowed_cidr
}

module "notifications" {
  source             = "./modules/notifications"
  notification_email = var.notification_email
}

module "iam" {
  source                  = "./modules/iam"
  notifications_topic_arn = module.notifications.topic_arn
  hosted_zone_arn         = "arn:aws:route53:::hostedzone/${data.aws_route53_zone.primary.zone_id}"
}

module "database" {
  source                = "./modules/database"
  vpc_id                = module.networking.vpc_id
  sg_rds_id             = module.networking.sg_rds_id
  db_password           = var.db_password
  final_snapshot_suffix = var.db_final_snapshot_suffix
  snapshot_identifier   = var.db_snapshot_identifier
}

module "compute" {
  source           = "./modules/compute"
  ami_id           = var.ami_id
  instance_type    = var.instance_type
  key_name         = aws_key_pair.voteball.key_name
  subnet_id        = data.aws_subnet.compute_az.id
  sg_app_id        = module.networking.sg_app_id
  instance_profile = module.iam.instance_profile_name
}
