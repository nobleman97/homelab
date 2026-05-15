output "ssh_host" {
  value       = proxmox_vm_qemu.vm.ssh_host
  description = "IP address assigned to the VM"
}
