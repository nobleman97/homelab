resource "proxmox_vm_qemu" "control_plane" {
  name        = "k8s-control-plane-01"
  target_node = "proxmox"
  clone       = "ubuntu-24.04-template"

  # CPU Configuration
  cores = 2
  sockets = 1

  # Memory Configuration (in MB)
  memory = 4096

  # Disk Configuration
  scsihw = "virtio-scsi-pci"
  disks {
    scsi {
      scsi0 {
        disk {
          size    = "40G"
          storage = "local-lvm"
        }
      }
    }
    ide {
      ide2 {
        cloudinit {
          storage = "local-lvm"
        }
      }
    }
  }

  # Network Configuration
  network {
    id     = 0
    model  = "virtio"
    bridge = "vmbr0"
  }

  # VM Options
  agent    = 1
  onboot   = true
  boot     = "order=scsi0"

  # Cloud-init settings
  ciuser     = "ubuntu"
  sshkeys    = file("~/.ssh/lab.pub")
  nameserver = "192.168.100.30"
  ipconfig0  = "ip=192.168.100.21/24,gw=192.168.100.1"
}

resource "proxmox_vm_qemu" "worker_node" {
  name        = "k8s-worker-node-01"
  target_node = "proxmox"
  clone       = "ubuntu-24.04-template"

  # CPU Configuration
  cores = 2
  sockets = 1

  # Memory Configuration (in MB)
  memory = 4096

  # Disk Configuration
  scsihw = "virtio-scsi-pci"
  disks {
    scsi {
      scsi0 {
        disk {
          size    = "40G"
          storage = "local-lvm"
        }
      }
    }
    ide {
      ide2 {
        cloudinit {
          storage = "local-lvm"
        }
      }
    }
  }

  # Network Configuration
  network {
    id     = 0
    model  = "virtio"
    bridge = "vmbr0"
  }

  # VM Options
  agent    = 1
  onboot   = true
  boot     = "order=scsi0"

  # Cloud-init settings
  ciuser     = "ubuntu"
  sshkeys    = file("~/.ssh/lab.pub")
  nameserver = "192.168.100.30"
  ipconfig0  = "ip=192.168.100.22/24,gw=192.168.100.1"
}