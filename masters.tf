// IAM instance role
resource "aws_iam_role" "master" {
  name = "${var.cluster_name}_master"

  assume_role_policy = <<EOS
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOS
}

resource "aws_iam_instance_profile" "master" {
  name = "${var.cluster_name}-master"
  role = "${aws_iam_role.master.name}"
}

resource "aws_iam_role_policy" "master" {
  name = "${var.cluster_name}_master"
  role = "${aws_iam_role.master.id}"

  policy = <<EOS
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
        "ec2:*"
      ],
      "Effect": "Allow",
      "Resource": [ "*" ]
    },
    {
      "Action": [
        "elasticloadbalancing:DescribeLoadBalancers"
      ],
      "Effect": "Allow",
      "Resource": [ "*" ]
    }
  ]
}
EOS
}

// EC2 AutoScaling Group
resource "aws_launch_configuration" "master" {
  iam_instance_profile = "${aws_iam_instance_profile.master.name}"
  image_id             = "${var.containerlinux_ami_id}"
  instance_type        = "${var.master_instance_type}"
  security_groups      = ["${aws_security_group.master.id}"]
  user_data            = "${var.master_user_data}"

  lifecycle {
    create_before_destroy = true
  }

  # Storage
  root_block_device {
    volume_type = "gp2"
    volume_size = 50
  }
}

resource "aws_autoscaling_group" "master" {
  name                      = "master ${var.cluster_name}"
  desired_capacity          = "3"
  health_check_grace_period = 60
  health_check_type         = "EC2"
  force_delete              = true
  launch_configuration      = "${aws_launch_configuration.master.name}"
  max_size                  = "${var.master_instance_count}"
  min_size                  = "${var.master_instance_count}"
  vpc_zone_identifier       = ["${var.private_subnet_ids}"]
  load_balancers            = ["${aws_elb.master.name}"]
  default_cooldown          = 60

  tags = [
    {
      key                 = "Name"
      value               = "master ${var.cluster_name}"
      propagate_at_launch = true
    },
    {
      key                 = "terraform.io/component"
      value               = "${var.cluster_name}/master"
      propagate_at_launch = true
    },
    {
      // kube uses this tag to learn its cluster name and tag managed resources
      key                 = "kubernetes.io/cluster/${var.cluster_name}"
      value               = "owned"
      propagate_at_launch = true
    },
  ]
}

// ELBs
resource "aws_elb" "master" {
  name            = "${var.cluster_name}-master-elb"
  subnets         = ["${var.public_subnet_ids}"]
  security_groups = ["${aws_security_group.master-elb.id}"]

  cross_zone_load_balancing = true
  idle_timeout              = 3600

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 3
    target              = "TCP:443"
    interval            = 30
  }

  listener {
    instance_port     = 443
    instance_protocol = "tcp"
    lb_port           = 443
    lb_protocol       = "tcp"
  }

  // kube uses the kubernetes.io tag to learn its cluster name and tag managed resources
  tags = "${map(
    "Name", "master ${var.cluster_name}",
    "terraform.io/component", "${var.cluster_name}/master",
    "kubernetes.io/cluster/${var.cluster_name}", "owned",
  )}"
}

// VPC Security Group
resource "aws_security_group" "master" {
  name        = "${var.cluster_name}-master"
  description = "k8s master security group"
  vpc_id      = "${var.vpc_id}"

  // kube uses the kubernetes.io tag to learn its cluster name and tag managed resources
  tags = "${map(
    "Name", "master ${var.cluster_name}",
    "terraform.io/component", "${var.cluster_name}/master",
    "kubernetes.io/cluster/${var.cluster_name}", "owned",
  )}"
}

resource "aws_security_group_rule" "egress-from-master" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = "${aws_security_group.master.id}"
}

resource "aws_security_group_rule" "ingress-master-to-self" {
  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = "${aws_security_group.master.id}"
  self              = true
}

resource "aws_security_group_rule" "ingress-elb-https-to-master" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = "${aws_security_group.master-elb.id}"
  security_group_id        = "${aws_security_group.master.id}"
}

resource "aws_security_group_rule" "ingress-worker-to-master" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  source_security_group_id = "${aws_security_group.worker.id}"
  security_group_id        = "${aws_security_group.master.id}"
}

resource "aws_security_group_rule" "master-ssh" {
  count                    = "${length(var.ssh_security_group_ids)}"
  type                     = "ingress"
  from_port                = 22
  to_port                  = 22
  protocol                 = "tcp"
  source_security_group_id = "${element(var.ssh_security_group_ids, count.index)}"
  security_group_id        = "${aws_security_group.master.id}"
}

resource "aws_security_group" "master-elb" {
  name        = "${var.cluster_name}-master-external-elb"
  description = "k8s master (apiserver) external elb"
  vpc_id      = "${var.vpc_id}"

  // kube uses the kubernetes.io tag to learn its cluster name and tag managed resources
  tags = "${map(
    "Name", "master elb ${var.cluster_name}",
    "terraform.io/component", "${var.cluster_name}/master",
    "kubernetes.io/cluster/${var.cluster_name}", "owned",
  )}"
}

resource "aws_security_group_rule" "egress-from-master-elb" {
  type                     = "egress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  source_security_group_id = "${aws_security_group.master.id}"
  security_group_id        = "${aws_security_group.master-elb.id}"
}

resource "aws_security_group_rule" "ingress-public-https-to-master-elb" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = "${aws_security_group.master-elb.id}"
}

// Route53 records
resource "aws_route53_record" "master-elb" {
  zone_id = "${var.route53_zone_id}"
  name    = "elb.master.${var.cluster_name}.${data.aws_route53_zone.main.name}"
  type    = "CNAME"
  ttl     = "30"
  records = ["${aws_elb.master.dns_name}"]
}
