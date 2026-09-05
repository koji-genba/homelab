provider "tailscale" {
  # Credentials are intentionally not variables. The provider reads
  # TAILSCALE_OAUTH_CLIENT_ID/SECRET (or TAILSCALE_API_KEY) from the
  # management environment; no credential is written into this repository.
  tailnet = var.tailnet
}
