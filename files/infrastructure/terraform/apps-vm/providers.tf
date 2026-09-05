provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = var.proxmox_insecure

  # The provider uses SSH only for operations that cannot be performed via
  # the API.  Authentication is delegated to the operator's SSH agent.
  ssh {
    agent    = true
    username = "root"
  }
}
