resource "proxmox_vm_qemu" "control_plane" {
  name        = "k8s-control-plane-01"
  target_node = "proxmox"
  clone       = "debian-12-template-server"

  # CPU Configuration
  cores   = 2
  sockets = 1

  # Memory Configuration (in MB)
  memory  = 4096
  balloon = 0
  machine = "q35"

  # Disk Configuration
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
          size    = "40G"
          storage = "local-lvm"
          discard = true
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
  agent  = 1
  onboot = true
  boot   = "order=scsi1"

  tpm_state {
    storage = "local-lvm"
    version = "v2.0"
  }

  # Cloud-init settings
  ciuser     = "debian"
  sshkeys    = file("~/.ssh/lab.pub")
  nameserver = "192.168.100.30"
  ipconfig0  = "ip=192.168.100.25/24,gw=192.168.100.1"
  ciupgrade  = true
}

resource "proxmox_vm_qemu" "worker_node" {
  name        = "k8s-worker-node-01"
  target_node = "proxmox"
  clone       = "debian-12-template-worker"

  # CPU Configuration
  cores   = 3
  sockets = 1

  # Memory Configuration (in MB)
  memory  = 6144
  balloon = 0
  machine = "q35"

  # Disk Configuration
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
          size    = "60G"
          storage = "local-lvm"
          discard = true
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
  agent  = 1
  onboot = true
  boot   = "order=scsi1"

  tpm_state {
    storage = "local-lvm"
    version = "v2.0"
  }

  # Cloud-init settings
  ciuser     = "debian"
  sshkeys    = file("~/.ssh/lab.pub")
  nameserver = "192.168.100.30"
  ipconfig0  = "ip=192.168.100.26/24,gw=192.168.100.1"
}