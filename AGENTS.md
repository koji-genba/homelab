# homelab

## Codebase Overview

Infrastructure-as-code for a single-node homelab: Proxmox host `pve1` plus one Debian 13 Apps VM defining 12 Docker Compose projects behind Caddy, reached over Tailscale. Terraform defines the VMs and tailnet, Ansible configures the Apps VM, and a 15-minute reconcile timer deploys Compose changes from main.

**Stack**: Proxmox VE + ZFS/NFS, Terraform (`bpg/proxmox`, `tailscale`), Ansible, Docker Compose, Caddy, AdGuard Home, SOPS+age, GitHub Actions; Makefile entry points use the pinned `homelab-toolbox` container plus documented host-side helpers.

**Structure**: `files/infrastructure/{terraform,ansible,secrets,network,storage}`, `files/services/{compose,images}`, `files/tools/homelab-toolbox`, `scripts/`, `docs/` (mostly Japanese ADRs and runbooks), `Makefile`.

For detailed architecture, see [docs/CODEBASE_MAP.md](docs/CODEBASE_MAP.md). Read its §0 "Read this first" before changing anything. In short:

- Merging to main is a production deploy for Compose changes.
- Live operations (applies, rollback, state restore, NFS/ZFS/router changes) need explicit approval; read-only make validation is fine.
- Never read or print secrets; refer to the encrypted runtime bundle and gitignored sensitive files only generically.
