vms = {
  control_plane = {
    name       = "k8s-control-plane-01"
    clone      = "debian-12-template-server"
    target_node = "proxmox"
    cores      = 2
    memory     = 4096
    disk_size  = "40G"
    ip_address = "192.168.100.25/24"
  }
  worker_node = {
    name       = "k8s-worker-node-01"
    clone      = "debian-12-template-worker"
    target_node = "proxmox"
    cores      = 3
    memory     = 6144
    disk_size  = "60G"
    ip_address = "192.168.100.26/24"
  }
}
