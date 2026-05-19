output "vm_ips" {
  value       = { for k, vm in module.vms : k => vm.ssh_host }
  description = "IP addresses of all provisioned VMs, keyed by VM identifier"
}
