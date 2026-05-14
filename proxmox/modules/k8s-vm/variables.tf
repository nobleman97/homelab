variable "name" {
  type        = string
  description = "VM name shown in Proxmox"
}

variable "clone" {
  type        = string
  description = "Proxmox template to clone from"
}

variable "target_node" {
  type        = string
  description = "Proxmox node to provision on"
  default     = "proxmox"
}

variable "cores" {
  type        = number
  description = "Number of vCPU cores"
}

variable "memory" {
  type        = number
  description = "RAM in MB"
}

variable "disk_size" {
  type        = string
  description = "Root disk size (e.g. \"40G\")"
}

variable "ip_address" {
  type        = string
  description = "Static IP with prefix length (e.g. \"192.168.100.25/24\")"
}

variable "gateway" {
  type        = string
  description = "Default gateway IP"
  default     = "192.168.100.1"
}

variable "nameserver" {
  type        = string
  description = "DNS server IP"
  default     = "192.168.100.30"
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key injected via cloud-init"
}

variable "start_at_node_boot" {
  description = "Whether the guest should start automatically when the Proxmox node boots."
  type        = bool
  default     = true
}

variable "tags" {
  type        = list(string)
  description = "Tags to apply to the VM in Proxmox (used by Ansible dynamic inventory)"
  default     = []
}
