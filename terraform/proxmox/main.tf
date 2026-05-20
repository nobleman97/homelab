module "vms" {
  source   = "../modules/k8s-vm"
  for_each = var.vms

  name           = each.value.name
  clone          = each.value.clone
  target_node    = each.value.target_node
  cores          = each.value.cores
  memory         = each.value.memory
  disk_size      = each.value.disk_size
  ip_address     = each.value.ip_address
  ssh_public_key = file(each.value.public_key_path)

  tags           = each.value.tags
}

