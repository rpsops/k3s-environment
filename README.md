# k3s-environment

Local Kubernetes environment using Lima (macOS) / k3s (Linux), Flux GitOps, and Cilium.

This repo is **infrastructure only**. It knows nothing about tenants. Tenant gitops repos self-register.

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                        k3s-environment                           │
│                                                                  │
│  Cilium · Gateway API · cert-manager · Sealed Secrets · Flux    │
│  Zot (registry) · Strimzi (Kafka op) · Kyverno · Monitoring    │
│  git-server (in-cluster HTTP git)                                │
└────────────────────┬─────────────────────────┬───────────────────┘
                     │ Flux reconciles          │ Flux reconciles
          ┌──────────┴──────────┐   ┌──────────┴──────────┐
          │   wallet-hsm ns     │   │   other-tenant ns   │   ...
          └──────────▲──────────┘   └──────────▲──────────┘
                     │                         │
             k3s-push + k3s-register   k3s-push + k3s-register
                     │                         │
          ┌──────────┴──────────┐   ┌──────────┴──────────┐
          │ wallet-accessmech-  │   │  other-gitops-repo  │
          │ anism-gitops        │   │  (gitops repo)      │
          └──────────▲──────────┘   └─────────────────────┘
                     │
            k3s-deploy (builds, signs, pushes images)
                     │
          ┌──────────┴──────────┐
          │    wallet-r2ps      │
          │    (source code)    │
          └─────────────────────┘
```

## Quick start

```bash
# One-time (requires sudo): DNS + k3s (Linux) + shims
make setup

# Start cluster and deploy infrastructure
make up
```

After `make up` the cluster is running with no tenant workloads. Tenants register themselves — see their own repos.

## Prerequisites

- `docker`
- macOS: `lima` (`brew install lima`)
- Linux: `sudo` access for `make setup`

All cluster tools (kubectl, helm, flux, cosign, kubeseal, yq) run inside the `k3s-toolbox` container. `make setup` installs shims in `~/.local/bin`.

## Make targets

| Target | Description | Sudo |
|--------|-------------|------|
| `make setup` | One-time: DNS, k3s (Linux), shims | yes |
| `make up` | Start cluster, deploy infra via Flux | no |
| `make sync` | Re-apply `flux/infrastructure/` manifests | no |
| `make sync-apps` | Force Flux to re-pull all gitops repos | no |
| `make reconcile` | Force all HelmReleases to reconcile | no |
| `make status` | Flux sources, kustomizations, HelmReleases | no |
| `make stop` | Stop cluster (preserves data) | no |
| `make clean` | Destroy cluster completely | no |
| `make sealed-secrets-key-export` | Save master key to `.local/` | no |
| `make sealed-secrets-key-restore` | Restore master key from `.local/` | no |
| `make cosign-key-export` | Save cosign key to `.local/` | no |
| `make cosign-key-restore` | Restore cosign key from `.local/` | no |

## Persisting keys across rebuilds

Two cluster-generated keys must survive `make clean` + `make up`:

| Key | Risk if lost |
|-----|-------------|
| Sealed Secrets master key | All committed SealedSecrets become unreadable |
| cosign signing key | Kyverno rejects images signed with the old key |

```bash
# After first successful make up:
make sealed-secrets-key-export   # → .local/sealed-secrets-master.key.yaml
make cosign-key-export           # → .local/cosign-key.yaml
```

`.local/` is gitignored. On next `make up`, Ansible restores both automatically if the files exist.

If the cosign key changes, update the public key in `flux/infrastructure/kyverno/verify-internal-images.yaml`.

## Endpoints

| Service | URL |
|---------|-----|
| Grafana | https://grafana.dev.local |
| Hubble | https://hubble.dev.local |
| KafBat | https://kafbat.dev.local |
| Headlamp | https://headlamp.dev.local |
| Zot registry | https://registry.dev.local |
| Git server | http://git.dev.local:8080 |

All `*.dev.local` resolved via dnsmasq. TLS via mkcert local CA (trusted by `make setup`).
