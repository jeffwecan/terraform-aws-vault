# ---------------------------------------------------------------------------------------------------------------------
# THESE TEMPLATES REQUIRE TERRAFORM VERSION 0.8 AND ABOVE
# ---------------------------------------------------------------------------------------------------------------------

terraform {
  required_version = ">= 0.9.3"
}

# ---------------------------------------------------------------------------------------------------------------------
# EXTRACT SUBNET INFORMATION IF availability_zones parameter not specified
# ---------------------------------------------------------------------------------------------------------------------

data "aws_subnet" "subnet" {
  id = "${var.subnet_ids[count.index]}"

  # Don't try to extract information about AZs in case they are explicitly specified (for backward compatibility).
  count = "${length(var.availability_zones) == 0 ? length(var.subnet_ids) : 0}"
}

# ---------------------------------------------------------------------------------------------------------------------
# CREATE THE ELB
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_elb" "vault" {
  name = "${var.name}"

  internal                    = "${var.internal}"
  cross_zone_load_balancing   = "${var.cross_zone_load_balancing}"
  idle_timeout                = "${var.idle_timeout}"
  connection_draining         = "${var.connection_draining}"
  connection_draining_timeout = "${var.connection_draining_timeout}"

  security_groups    = ["${aws_security_group.vault.id}"]
  # This split-join hack is a workaround for 'conditional operator cannot be used with list values' typecheck error.
  availability_zones = ["${split(",", length(var.availability_zones) == 0 ? join(",", data.aws_subnet.subnet.*.availability_zone) : join(",", var.availability_zones))}"]
  subnets            = ["${var.subnet_ids}"]

  # Run the ELB in TCP passthrough mode
  listener {
    lb_port           = "${var.lb_port}"
    lb_protocol       = "TCP"
    instance_port     = "${var.vault_api_port}"
    instance_protocol = "TCP"
  }

  health_check {
    target              = "${var.health_check_protocol}:${var.vault_api_port}${var.health_check_path}"
    interval            = "${var.health_check_interval}"
    healthy_threshold   = "${var.health_check_healthy_threshold}"
    unhealthy_threshold = "${var.health_check_unhealthy_threshold}"
    timeout             = "${var.health_check_timeout}"
  }

  tags {
    Name = "${var.name}"
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# CREATE THE SECURITY GROUP THAT CONTROLS WHAT TRAFFIC CAN GO IN AND OUT OF THE ELB
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_security_group" "vault" {
  name        = "${var.name}-elb"
  description = "Security group for the ${var.name} ELB"
  vpc_id      = "${var.vpc_id}"
}

resource "aws_security_group_rule" "allow_inbound_api" {
  type        = "ingress"
  from_port   = "${var.lb_port}"
  to_port     = "${var.lb_port}"
  protocol    = "tcp"
  cidr_blocks = ["${var.allowed_inbound_cidr_blocks}"]

  security_group_id = "${aws_security_group.vault.id}"
}

resource "aws_security_group_rule" "allow_all_outbound" {
  type        = "egress"
  from_port   = 0
  to_port     = 0
  protocol    = "-1"
  cidr_blocks = ["0.0.0.0/0"]

  security_group_id = "${aws_security_group.vault.id}"
}

# ---------------------------------------------------------------------------------------------------------------------
# OPTIONALLY CREATE A ROUTE 53 ENTRY FOR THE ELB
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_route53_record" "vault_elb" {
  count = "${var.create_dns_entry}"

  zone_id = "${var.hosted_zone_id}"
  name    = "${var.domain_name}"
  type    = "A"

  alias {
    name    = "${aws_elb.vault.dns_name}"
    zone_id = "${aws_elb.vault.zone_id}"

    # When set to true, if either none of the ELB's EC2 instances are healthy or the ELB itself is unhealthy,
    # Route 53 routes queries to "other resources." But since we haven't defined any other resources, we'd rather
    # avoid any latency due to switchovers and just wait for the ELB and Vault instances to come back online.
    # For more info, see http://docs.aws.amazon.com/Route53/latest/DeveloperGuide/resource-record-sets-values-alias.html#rrsets-values-alias-evaluate-target-health
    evaluate_target_health = false
  }
}
