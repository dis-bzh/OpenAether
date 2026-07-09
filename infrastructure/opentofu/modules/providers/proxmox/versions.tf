terraform {
  required_version = ">= 1.11.0"

  required_providers {
    proxmox = {
      source = "bpg/proxmox"
      # bpg is the de-facto Proxmox VE provider (VMs, cloud-init, firewall).
      # Pin the 0.x line; bpg has no 1.0 yet and moves fast on VM schema.
      version = ">= 0.66.0"
    }
  }
}
