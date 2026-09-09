output "instance_id" {
  description = "OCID of the instance, once one exists."
  value       = oci_core_instance.arm.id
}

output "public_ip" {
  description = "Public IP to SSH into."
  value       = oci_core_instance.arm.public_ip
}

output "availability_domain" {
  description = "Which AD finally had capacity."
  value       = oci_core_instance.arm.availability_domain
}

output "ssh_command" {
  description = "Ready-to-paste SSH command. Default user is 'ubuntu' on Ubuntu images, 'opc' on Oracle Linux."
  value       = "ssh ubuntu@${oci_core_instance.arm.public_ip}"
}
