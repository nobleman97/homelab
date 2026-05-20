resource "proxmox_vm_qemu" "vm" {
  name        = var.name
  target_node = var.target_node
  clone       = var.clone

  cores   = var.cores
  sockets = 1
  memory  = var.memory
  balloon = 0
  machine = "q35"
  start_at_node_boot = var.start_at_node_boot
  tags               = length(var.tags) > 0 ? join(";", var.tags) : null

  startup_shutdown {
    order            = -1
    shutdown_timeout = -1
    startup_delay    = -1
  }

  scsihw = "virtio-scsi-single"
  disks {
    scsi {
      scsi0 {
        cloudinit {
          storage = "local-lvm"
        }
      }
      scsi1 {
        disk {
          size    = var.disk_size
          storage = "local-lvm"
          discard = true
        }
      }
    }
  }

  network {
    id     = 0
    model  = "virtio"
    bridge = "vmbr0"
  }

  agent  = 1
  # onboot = true
  boot   = "order=scsi1"

  tpm_state {
    storage = "local-lvm"
    version = "v2.0"
  }

  ciuser     = "debian"
  sshkeys    = var.ssh_public_key
  nameserver = var.nameserver
  ipconfig0  = "ip=${var.ip_address},gw=${var.gateway}"
  ciupgrade  = true
}
