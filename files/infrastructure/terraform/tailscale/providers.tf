provider "tailscale" {
  # Operator credentials are injected only into this Terraform process.
  # Omitted tailnet uses TAILSCALE_TAILNET, otherwise the provider default "-".
}
