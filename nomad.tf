variable "access_key" {
  default = "AKIAII257KXB7OLFBQEA"
}

variable "secret_key" {
  default = "NKxLhVi90y2ttmqGUBEjka3yHZ/bkeoGlbUey8U0"
}

variable "region" {
  default = "us-west-1"
}

variable "az" {
  default = "us-west-1a"
}

variable "master_servers" {
  default = 3
}

variable "slave_servers" {
  default = 3
}

variable "instance_size" {
  default = {
    master = "t2.small"
    worker = "m3.medium"
  }
}

variable "ubuntu_amis" {
  default = {
    us-west-1 = "ami-06116566"
  }
}

provider "aws" {
  access_key = "${var.access_key}"
  secret_key = "${var.secret_key}"
  region = "${var.region}"
}

# VPC AND SUBNET SETTINGS

resource "aws_vpc" "bryan_vpc" {
  cidr_block = "10.0.0.0/16"
  tags {
    Name = "bryan-vpc"
  }
}

resource "aws_subnet" "bryan_public" {
  vpc_id = "${aws_vpc.bryan_vpc.id}"
  availability_zone = "${var.az}"
  cidr_block = "10.0.0.0/24"
  tags {
    Name = "bryan-public-subnet"
  }
}

resource "aws_subnet" "bryan_private" {
  vpc_id = "${aws_vpc.bryan_vpc.id}"
  availability_zone = "${var.az}"
  cidr_block = "10.0.1.0/24"
  tags {
    Name = "bryan-private-subnet"
  }
}

resource "aws_route_table" "public" {
  vpc_id = "${aws_vpc.bryan_vpc.id}"
  tags {
    Name = "bryan public subnet routing table"
  }
}

# associate the public subnet with the new route table
resource "aws_route_table_association" "public" {
  subnet_id = "${aws_subnet.bryan_public.id}"
  route_table_id = "${aws_route_table.public.id}"
}

# associate the private subnet with the main route table
resource "aws_route_table_association" "private" {
  subnet_id = "${aws_subnet.bryan_private.id}"
  route_table_id = "${aws_vpc.bryan_vpc.main_route_table_id}"
}

# the internet gateway for the public subnet
resource "aws_internet_gateway" "bryan_gateway" {
  vpc_id = "${aws_vpc.bryan_vpc.id}"
  tags {
    Name = "bryan-vpc-border"
  }
}

# elastic IP for the nat
resource "aws_eip" "nat" {
  vpc = true
}

# the nat for the private subnet (lives in the public subnet)
resource "aws_nat_gateway" "nat" {
  allocation_id = "${aws_eip.nat.id}"
  subnet_id = "${aws_subnet.bryan_public.id}"
}

# the public route table needs the internet gateway
resource "aws_route" "public" {
  route_table_id = "${aws_route_table.public.id}"
  destination_cidr_block = "0.0.0.0/0"
  gateway_id = "${aws_internet_gateway.bryan_gateway.id}"
}

# the private route table needs the NAT
resource "aws_route" "private" {
  route_table_id = "${aws_vpc.bryan_vpc.main_route_table_id}"
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id = "${aws_nat_gateway.nat.id}"
}

# INSTANCES

resource "aws_instance" "nomad_master" {
  ami = "${lookup(var.ubuntu_amis, var.region)}"
  instance_type = "${var.instance_size.master}"
  key_name = "bryan-vpc"
  count = "${var.master_servers}"
  availability_zone = "${var.az}"
  vpc_security_group_ids = [
    "${aws_security_group.nomad.id}",
    "${aws_security_group.nomad_master.id}"
  ]
  subnet_id = "${aws_subnet.bryan_public.id}"
  root_block_device {
    volume_size = 50
  }
}

resource "aws_instance" "nomad_slave" {
  ami = "${lookup(var.ubuntu_amis, var.region)}"
  instance_type = "${var.instance_size.worker}"
  key_name = "bryan-vpc"
  count = "${var.slave_servers}"
  availability_zone = "${var.az}"
  vpc_security_group_ids = [
    "${aws_security_group.nomad.id}",
    "${aws_security_group.nomad_slave.id}"
  ]
  subnet_id = "${aws_subnet.bryan_private.id}"
  root_block_device {
    volume_size = 500
  }
}

resource "aws_eip" "ip" {
  count = "${var.master_servers}"
  instance = "${element(aws_instance.nomad_master.*.id, count.index)}"
  vpc = true
}

# SECURITY GROUPS

# `nomad`
resource "aws_security_group" "nomad" {
  name = "nomad"
  description = "nomad general security group"
  vpc_id = "${aws_vpc.bryan_vpc.id}"
  tags {
    Name = "nomad cluster"
  }
}

resource "aws_security_group_rule" "allow_all_egress" {
  security_group_id = "${aws_security_group.nomad.id}"
  type = "egress"
  from_port = 0
  to_port = 0
  protocol = "-1"
  cidr_blocks = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "nomad_http" {
  security_group_id = "${aws_security_group.nomad.id}"
  type = "ingress"
  from_port = 4646
  to_port = 4646
  protocol = "tcp"
  source_security_group_id = "${aws_security_group.nomad.id}"
}

resource "aws_security_group_rule" "consul_http" {
  security_group_id = "${aws_security_group.nomad.id}"
  type = "ingress"
  from_port = 8500
  to_port = 8500
  protocol = "tcp"
  source_security_group_id = "${aws_security_group.nomad.id}"
}

resource "aws_security_group_rule" "consul_serf_lan_tcp" {
  security_group_id = "${aws_security_group.nomad.id}"
  type = "ingress"
  from_port = 8301
  to_port = 8301
  protocol = "tcp"
  source_security_group_id = "${aws_security_group.nomad.id}"
}

resource "aws_security_group_rule" "consul_serf_lan_udp" {
  security_group_id = "${aws_security_group.nomad.id}"
  type = "ingress"
  from_port = 8301
  to_port = 8301
  protocol = "udp"
  source_security_group_id = "${aws_security_group.nomad.id}"
}

resource "aws_security_group" "nomad_master" {
  name = "nomad-master"
  description = "nomad master sg"
  vpc_id = "${aws_vpc.bryan_vpc.id}"
  tags {
    Name = "nomad master"
  }
}

resource "aws_security_group_rule" "consul_server_rpc" {
  security_group_id = "${aws_security_group.nomad_master.id}"
  type = "ingress"
  from_port = 8300
  to_port = 8300
  protocol = "tcp"
  source_security_group_id = "${aws_security_group.nomad.id}"
}

resource "aws_security_group_rule" "nomad_ssh" {
  security_group_id = "${aws_security_group.nomad_master.id}"
  type = "ingress"
  protocol = "tcp"
  from_port = 22
  to_port = 22
  cidr_blocks = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "nomad_rpc" {
  security_group_id = "${aws_security_group.nomad_master.id}"
  type = "ingress"
  from_port = 4647
  to_port = 4647
  protocol = "tcp"
  source_security_group_id = "${aws_security_group.nomad.id}"
}

resource "aws_security_group_rule" "nomad_serf" {
  security_group_id = "${aws_security_group.nomad_master.id}"
  type = "ingress"
  from_port = 4648
  to_port = 4648
  protocol = "tcp"
  source_security_group_id = "${aws_security_group.nomad_master.id}"
}

resource "aws_security_group" "nomad_slave" {
  name = "nomad-slave"
  description = "nomad slave sg"
  vpc_id = "${aws_vpc.bryan_vpc.id}"
  tags {
    Name = "nomad slave"
  }
}

resource "aws_security_group_rule" "nomad_ssh_slave" {
  security_group_id = "${aws_security_group.nomad_slave.id}"
  type = "ingress"
  protocol = "tcp"
  from_port = 22
  to_port = 22
  source_security_group_id = "${aws_security_group.nomad_master.id}"
}

# OUTPUTS

output "master_ids" {
  value = "${join(",", aws_instance.nomad_master.*.id)}"
}

output "master_ips" {
  value = "${join(",", aws_eip.ip.*.public_ip)}"
}

output "master_private_ips" {
  value = "${join(",", aws_instance.nomad_master.*.private_ip)}"
}

output "slave_ips" {
  value = "${join(",", aws_instance.nomad_slave.*.private_ip)}"
}
