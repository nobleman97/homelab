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
terraform plan -target=proxmox_vm_qemu.example
terraform apply -target=proxmox_vm_qemu.example
```

## Architecture

### Provider Configuration
- **Proxmox API**: Connects to local Proxmox server at `192.168.100.20:8006`
- **TLS**: Currently set to insecure mode (`pm_tls_insecure = true`) for local development
- **Debug**: Provider debugging is enabled (`pm_debug = true`)
- **Providers**: Uses Telmate/proxmox v2.9.x and hashicorp/local v2.4.x

### State Management
- A commented S3 backend configuration exists in providers.tf for remote state storage
- Uses DynamoDB table "terraform-locks" for state locking
- Currently using local state (S3 backend is commented out)
- State files (*.tfstate) are gitignored

### File Structure
- `providers.tf`: Terraform and provider configuration, backend setup
- `main.tf`: Main infrastructure resources (currently empty)
- `variables.tf`: Input variable definitions (currently empty)
- `.terraform/`: Provider binaries and modules (gitignored)
- `.terraform.lock.hcl`: Provider version lock file (committed)

## Important Notes

### Sensitive Data
- Authentication credentials should be provided via environment variables or `.tfvars` files
- All `.tfvars` and `.tfvars.json` files are gitignored
- Never commit API credentials, passwords, or tokens
- Use Proxmox API token authentication in production

### Proxmox API Authentication
The provider expects authentication via environment variables:
```bash
export PM_API_URL="https://192.168.100.20:8006/api2/json"
export PM_API_TOKEN_ID="your-token-id"
export PM_API_TOKEN_SECRET="your-token-secret"
# OR
export PM_USER="user@pam"
export PM_PASS="password"
```

### Remote State (S3 Backend)
To enable remote state management:
1. Uncomment the backend "s3" block in providers.tf
2. Update bucket name and region as needed
3. Run `terraform init -migrate-state` to migrate local state to S3
