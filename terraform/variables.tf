# ---------- Authentication (all required) ----------

variable "tenancy_ocid" {
  description = "Tenancy OCID. Console: Profile menu > Tenancy."
  type        = string
}

variable "user_ocid" {
  description = "User OCID. Console: Profile menu > My profile."
  type        = string
}

variable "fingerprint" {
  description = "API key fingerprint, shown when you upload the public key."
  type        = string
}

variable "private_key_path" {
  description = "Absolute path to the API private key PEM file."
  type        = string
}

variable "region" {
  description = "Your HOME region, e.g. ap-mumbai-1. Always Free A1 only exists here."
  type        = string
}

variable "compartment_ocid" {
  description = "Compartment to create the instance in. Root compartment == tenancy OCID."
  type        = string
}

# ---------- Instance shape ----------

variable "instance_name" {
  description = "Display name. The retry driver uses this to detect that we already won."
  type        = string
  default     = "arm-always-free"
}

variable "ocpus" {
  description = "OCPUs. Always Free ceiling is 2 as of 2026-06-15 (was 4)."
  type        = number
  default     = 2

  validation {
    condition     = var.ocpus >= 1 && var.ocpus <= 2
    error_message = "Always Free allows at most 2 OCPUs total since 2026-06-15."
  }
}

variable "memory_in_gbs" {
  description = "RAM in GB. Always Free ceiling is 12 (was 24). A1 requires 6 GB per OCPU."
  type        = number
  default     = 12

  validation {
    condition     = var.memory_in_gbs >= 6 && var.memory_in_gbs <= 12
    error_message = "Always Free allows at most 12 GB of memory since 2026-06-15."
  }
}

variable "boot_volume_size_in_gbs" {
  description = <<-EOT
    Boot volume size. Minimum 47, default 50. Always Free gives 200 GB TOTAL
    across all boot + block volumes, so 200 here consumes the entire allowance
    and leaves room for no other volumes.
  EOT
  type        = number
  default     = 200

  validation {
    condition     = var.boot_volume_size_in_gbs >= 47 && var.boot_volume_size_in_gbs <= 200
    error_message = "Boot volume must be between 47 and 200 GB to stay inside Always Free."
  }
}

variable "ssh_public_key" {
  description = "SSH public key contents used for the default user on the instance."
  type        = string
}

# ---------- Image ----------

variable "operating_system" {
  description = "OS name as OCI reports it, e.g. 'Canonical Ubuntu' or 'Oracle Linux'."
  type        = string
  default     = "Canonical Ubuntu"
}

variable "operating_system_version" {
  description = "OS version, e.g. '22.04' or '24.04'."
  type        = string
  default     = "22.04"
}

# ---------- Availability domain rotation ----------

variable "ad_index" {
  description = <<-EOT
    Which availability domain to try, by index. The retry driver increments this
    on every attempt and wraps around, because A1 capacity frees up in one AD at
    a time. Single-AD regions just always resolve to index 0.
  EOT
  type        = number
  default     = 0
}

# ---------- Networking ----------

variable "create_network" {
  description = "Create a VCN, subnet, gateway and security rules. Set false to reuse an existing subnet."
  type        = bool
  default     = true
}

variable "existing_subnet_ocid" {
  description = "Existing public subnet OCID. Only used when create_network = false."
  type        = string
  default     = ""
}

variable "vcn_cidr" {
  description = "CIDR block for the VCN created when create_network = true."
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR block for the subnet created when create_network = true."
  type        = string
  default     = "10.0.1.0/24"
}

variable "allowed_ssh_cidr" {
  description = "Source CIDR permitted to reach port 22. Narrow this to your IP if you can."
  type        = string
  default     = "0.0.0.0/0"
}
