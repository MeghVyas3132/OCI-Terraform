# ---------------------------------------------------------------------------
# Availability domains. A1 capacity frees up one AD at a time, so the retry
# driver walks ad_index across whatever this returns.
# ---------------------------------------------------------------------------

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

locals {
  ads         = data.oci_identity_availability_domains.ads.availability_domains
  selected_ad = local.ads[var.ad_index % length(local.ads)].name
  subnet_id   = var.create_network ? oci_core_subnet.this[0].id : var.existing_subnet_ocid
}

# ---------------------------------------------------------------------------
# Newest matching ARM image. Filtering on the shape keeps aarch64 images only.
# ---------------------------------------------------------------------------

data "oci_core_images" "os" {
  compartment_id           = var.compartment_ocid
  operating_system         = var.operating_system
  operating_system_version = var.operating_system_version
  shape                    = "VM.Standard.A1.Flex"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

# ---------------------------------------------------------------------------
# Networking. All of this is free and, unlike the instance, never runs out of
# capacity — so it gets created on the first attempt and reused thereafter.
# ---------------------------------------------------------------------------

resource "oci_core_vcn" "this" {
  count = var.create_network ? 1 : 0

  compartment_id = var.compartment_ocid
  cidr_blocks    = [var.vcn_cidr]
  display_name   = "${var.instance_name}-vcn"
  dns_label      = "armvcn"
}

resource "oci_core_internet_gateway" "this" {
  count = var.create_network ? 1 : 0

  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this[0].id
  display_name   = "${var.instance_name}-igw"
  enabled        = true
}

resource "oci_core_route_table" "this" {
  count = var.create_network ? 1 : 0

  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this[0].id
  display_name   = "${var.instance_name}-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.this[0].id
  }
}

resource "oci_core_security_list" "this" {
  count = var.create_network ? 1 : 0

  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this[0].id
  display_name   = "${var.instance_name}-sl"

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  ingress_security_rules {
    source   = var.allowed_ssh_cidr
    protocol = "6" # TCP

    tcp_options {
      min = 22
      max = 22
    }
  }

  # ICMP path MTU discovery, otherwise large packets silently hang.
  ingress_security_rules {
    source   = "0.0.0.0/0"
    protocol = "1" # ICMP

    icmp_options {
      type = 3
      code = 4
    }
  }
}

resource "oci_core_subnet" "this" {
  count = var.create_network ? 1 : 0

  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.this[0].id
  cidr_block                 = var.subnet_cidr
  display_name               = "${var.instance_name}-subnet"
  dns_label                  = "armsubnet"
  route_table_id             = oci_core_route_table.this[0].id
  security_list_ids          = [oci_core_security_list.this[0].id]
  prohibit_public_ip_on_vnic = false
}

# ---------------------------------------------------------------------------
# The prize. Every attempt is a plain `terraform apply` against this resource;
# "Out of host capacity" is just an expected failure that we retry later.
# ---------------------------------------------------------------------------

resource "oci_core_instance" "arm" {
  availability_domain = local.selected_ad
  compartment_id      = var.compartment_ocid
  display_name        = var.instance_name
  shape               = "VM.Standard.A1.Flex"

  shape_config {
    ocpus         = var.ocpus
    memory_in_gbs = var.memory_in_gbs
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.os.images[0].id
    boot_volume_size_in_gbs = var.boot_volume_size_in_gbs
  }

  create_vnic_details {
    subnet_id        = local.subnet_id
    assign_public_ip = true
    display_name     = "${var.instance_name}-vnic"
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
  }

  lifecycle {
    # Once we finally win, the next apply must not tear the instance down just
    # because ad_index has rotated on or a newer base image was published.
    ignore_changes = [
      availability_domain,
      source_details[0].source_id,
      metadata,
    ]
  }

  timeouts {
    create = "15m"
  }
}
