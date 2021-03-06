######################################################
## Collect Instance Types available in the vpc zone ##
######################################################

data "alicloud_instance_types" "default" {
  cpu_core_count       = "${var.cpu_core_count}"
  memory_size          = "${var.memory_size}"
  instance_type_family = "${var.instance_type_family}"
}

#######################
## Collect zone data ##
#######################

data "alicloud_zones" "main" {
  available_resource_creation = "VSwitch"
  multi                       = true
  network_type                = "Vpc"
}

data "alicloud_regions" "current" {
  current = true
}

# Save zone names in local variable

locals {
  vpc_azs = "${data.alicloud_zones.main.zones.0.id}, ${data.alicloud_zones.main.zones.1.id}"
}

###########################
## Create Management VPC ##
###########################

resource "alicloud_vpc" "vpc" {
  name       = "${var.vpc_prefix}-vpc"
  cidr_block = "${var.vpc_cidr}"
}

####################
## Create vswitch ##
####################

resource "alicloud_vswitch" "vswitch" {
  count             = "${length(var.vswitch_cidrs)}"
  vpc_id            = "${alicloud_vpc.vpc.id}"
  name              = "${format("vsw-%s-%02d", var.vpc_prefix, count.index + 1)}"
  cidr_block        = "${var.vswitch_cidrs[count.index]}"
  availability_zone = "${element(split(", ", local.vpc_azs), count.index)}"
}


######################################
## Create Management Security Group ##
######################################

module "security-group" {
  source = "alibaba/security-group/alicloud"

  vpc_id          = "${alicloud_vpc.vpc.id}"
  group_name      = "sg-${var.vpc_prefix}"
  rule_directions = ["ingress"]
  ip_protocols    = ["tcp", "tcp", "tcp"]
  policies        = ["accept", "accept"]
  port_ranges     = "${var.sg_port_ranges}"
  priorities      = [1, 2]
  cidr_ips        = ["${var.vswitch_cidrs}", "${var.ssl_vpn_ip_pool}"]
}

########################
## Create VPN Gateway ##
########################

module "vpn-gateway" {
  source          = "../../../modules/infra/vpn-gateway"
  vpc_id          = "${alicloud_vpc.vpc.id}"
  ssl_vpn_ip_pool = "${var.ssl_vpn_ip_pool}"
  vpc_cidr        = "${var.vpc_cidr}"
}


######################################
## Create ssh key for admin servers ##
######################################

resource "alicloud_key_pair" "key" {
  key_name = "admin_ssh_key"
  key_file = "admin_ssh_key.pem"
}

#####################################################################
## Create Admin Workstation for executing infra and app deployment ##
#####################################################################

resource "alicloud_instance" "mgmt-srv" {
  count           = "1"
  security_groups = ["${module.security-group.security_group_id}"]

  vswitch_id = "${alicloud_vswitch.vswitch.*.id[count.index]}"

  instance_name = "${format("srv-%s-%02d", var.app_prefix, count.index + 1)}"
  instance_type = "${data.alicloud_instance_types.default.instance_types.0.id}"
  host_name     = "${format("srv-%s-%02d", var.app_prefix, count.index + 1)}"
  image_id      = "${var.image_id}"

  key_name = "${alicloud_key_pair.key.key_name}"
}

#################################################
## Add NAT Gateway for ougoing internet access ##
#################################################

resource "alicloud_nat_gateway" "default" {
  vpc_id        = "${alicloud_vpc.vpc.id}"
  specification = "${var.natgw_spec}"
  name          = "${var.vpc_prefix}-natgw"
}

resource "alicloud_eip" "eip" {
  depends_on = ["alicloud_nat_gateway.default"]
}

resource "alicloud_eip_association" "eip_asso" {
  allocation_id = "${alicloud_eip.eip.id}"
  instance_id   = "${alicloud_nat_gateway.default.id}"
}

resource "alicloud_snat_entry" "snat" {
  snat_table_id     = "${alicloud_nat_gateway.default.snat_table_ids}"
  source_vswitch_id = "${alicloud_vswitch.vswitch.id}"
  snat_ip           = "${alicloud_eip.eip.ip_address}"
}

## Private DNS Record and Zone attachment

resource "alicloud_pvtz_zone_record" "a_name" {
   
    zone_id = "${var.pvtz_zone_id}"
    resource_record = "${alicloud_instance.mgmt-srv.host_name}"
    type = "A"
    value = "${alicloud_instance.mgmt-srv.private_ip}"
    ttl = "86400"
    depends_on = ["alicloud_instance.mgmt-srv"]
}


