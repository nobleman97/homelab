# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Terraform-based infrastructure-as-code project for managing a Proxmox homelab environment. The project uses the Telmate/proxmox provider to provision and manage VMs and containers on a local Proxmox server.

## Common Commands

### Terraform Basics
```bash
# Initialize Terraform and download providers
terraform init

# Validate configuration files
terraform validate

# Format Terraform files
terraform fmt

# Preview changes before applying
terraform plan

# Apply changes to infrastructure
terraform apply

# Destroy all managed infrastructure
terraform destroy

# Show current state
terraform show

# List resources in state
terraform state list
```

### Development Workflow
```bash
# Initialize after cloning or changing providers
terraform init

# Check configuration and preview changes
terraform validate && terraform plan

# Apply with auto-approve (use cautiously)
terraform apply -auto-approve

# Target specific resources
# VMs are module instances keyed by the map key in terraform.tfvars
terraform plan -target='module.vms["worker_node_2"]'
terraform apply -target='module.vms["worker_node_2"]'
```

## Architecture

### Provider Configuration
- **Proxmox API**: `https://192.168.100.20:8006/api2/json` (host `proxmox`); VMs also run on host `david`
- **TLS**: Insecure mode (`pm_tls_insecure = true`)
- **Debug**: Provider debugging is enabled (`pm_debug = true`)
- **Providers**: Telmate/proxmox `3.0.2-rc07` (pinned in both `providers.tf` and the module) and hashicorp/local `~> 2.4`

### State Management
- S3 backend is **active**: bucket `devopsroyale-state-files-ccsji365i`, key `homelab/proxmox/terraform.tfstate`, region `us-east-1`, encrypted
- DynamoDB table `terraform-locks` for state locking
- Local state files (*.tfstate) are gitignored

### File Structure
- `providers.tf`: Terraform/provider configuration and S3 backend
- `main.tf`: `module "vms"` — calls `../modules/k8s-vm` with `for_each = var.vms`
- `variables.tf`: `proxmox_api_token_secret` (sensitive) and the `vms` map type
- `terraform.tfvars`: the VM definitions (4 k3s nodes); **tracked in git** (the `*.tfvars` ignore rule is commented out)
- `outputs.tf`: `vm_ips` map keyed by VM identifier
- `../modules/k8s-vm/`: one `proxmox_vm_qemu` (q35, virtio-scsi, cloud-init on scsi0, disk on scsi1 in `local-lvm`, bridge `vmbr0`, default gateway 192.168.100.1 and DNS 192.168.100.30)
- `.terraform/`: Provider binaries and modules (gitignored)
- `.terraform.lock.hcl`: Provider version lock file (committed)

## Important Notes

### Sensitive Data
- Never commit API credentials, passwords, or tokens. `terraform.tfvars` is committed, so keep secrets out of it
- `.tfvars.json` files are gitignored

### Proxmox API Authentication
The token ID `terraform-prov@pve!terraform` is set in `providers.tf`; only the secret comes from the environment:
```bash
export TF_VAR_proxmox_api_token_secret="your-token-secret"
```
