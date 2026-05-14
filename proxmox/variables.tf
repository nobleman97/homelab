variable "proxmox_api_token_secret" {
  type      = string
  sensitive = true
}

variable "vms" {
  type = map(object({
    name        = string
    clone       = string
    target_node = string
    cores       = number
    memory      = number
    disk_size   = string
    ip_address  = string
  }))
  description = "Map of k8s VMs to provision. Key is used as a logical identifier."
}