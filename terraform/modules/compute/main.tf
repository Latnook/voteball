locals {
  name_prefix = "voteball"
}

resource "aws_eip" "app" {
  domain = "vpc"

  tags = {
    Name     = "${local.name_prefix}-app"
    Voteball = "app"
  }
}

resource "aws_instance" "app" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  key_name               = var.key_name
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.sg_app_id]
  iam_instance_profile   = var.instance_profile

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    http_endpoint               = "enabled"
  }

  tags = {
    Name     = "${local.name_prefix}-app"
    Voteball = "app"
  }
}

resource "aws_eip_association" "app" {
  instance_id   = aws_instance.app.id
  allocation_id = aws_eip.app.id
}
