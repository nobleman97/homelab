vms = {
  # Kubernetes Cluster Nodes
  control_plane = {
    name        = "k8s-control-plane-01"
    clone       = "debian-12-template-server"
    target_node = "proxmox"
    cores       = 2
    memory      = 4096
    disk_size   = "40G"
    ip_address  = "192.168.100.25/24"
    public_key_path = "~/.ssh/lab.pub"

    tags        = [
      "k8s_nodes", 
      "k8s_control_plane",
      "k8s-control-plane-01"
    ]
  }
  worker_node = {
    name        = "k8s-worker-node-01"
    clone       = "debian-12-template-worker"
    target_node = "proxmox"
    cores       = 3
    memory      = 6144
    disk_size   = "60G"
    ip_address  = "192.168.100.26/24"
    public_key_path = "~/.ssh/lab.pub"

    tags        = [
      "k8s_nodes", 
      "k8s_workers",
      "k8s-worker-node-01"
    ]
  }
  worker_node_2 = {
    name        = "k8s-worker-node-02"
    clone       = "debian-12-template-worker"
    target_node = "david"
    cores       = 3
    memory      = 6144
    disk_size   = "90G"
    ip_address  = "192.168.100.27/24"
    public_key_path = "~/.ssh/lab.pub"

    tags        = [
      "k8s_nodes",
      "k8s_workers",
      "k8s-worker-node-02"
    ]
  }

  # Extra VMs
  # traffic_proxy = {
  #   name        = "traffic-proxy-01"
  #   clone       = "debian-12-template-worker"
  #   target_node = "david"
  #   cores       = 2
  #   memory      = 4096
  #   disk_size   = "60G"
  #   ip_address  = "192.168.100.31/24"
  #   public_key_path = "~/.ssh/lab.pub"

  #   tags        = [
  #     "devops-demo",
  #     "nginx-proxy",
  #     "traffic-proxy-01"
  #   ]
  # }
  # app_server = {
  #   name        = "app-server-01"
  #   clone       = "debian-12-template-worker"
  #   target_node = "david"
  #   cores       = 2
  #   memory      = 4096
  #   disk_size   = "60G"
  #   ip_address  = "192.168.100.32/24"
  #   public_key_path = "~/.ssh/lab.pub"

  #   tags        = [
  #     "devops-demo",
  #     "app-server",
  #     "app-server-01"
  #   ]
  # }
  # postgres_1 = {
  #   name        = "postgres-01"
  #   clone       = "debian-12-template-worker"
  #   target_node = "david"
  #   cores       = 2
  #   memory      = 4096
  #   disk_size   = "60G"
  #   ip_address  = "192.168.100.33/24"
  #   public_key_path = "~/.ssh/lab.pub"

  #   tags        = [
  #     "devops-demo",
  #     "database",
  #     "postgres-01"
  #   ]
  # }

}
