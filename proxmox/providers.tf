terraform {
  required_version = ">= 1.0.0"
  required_providers {
    proxmox = {
      source  = "Telmate/proxmox"
      version = "3.0.2-rc07"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4"
    }
  }

  backend "s3" {
    bucket         = "devopsroyale-state-files-ccsji365i"
    key            = "homelab/proxmox/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-locks"

    encrypt = true
  }
}

provider "proxmox" {
  pm_api_url      = "https://192.168.100.20:8006/api2/json"
  pm_debug        = true
  pm_tls_insecure = true
}