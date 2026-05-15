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

## Host footprint

Besides Docker and the Lima VM, `make setup` + `make up` leave four things on the host:

| What | Where | Written by |
|------|-------|------------|
| DNS resolver delegation | `/etc/resolver/dev.local` | `make setup` (sudo) |
| Tool shims (kubectl, helm, flux, cosign, kubeseal, yq, jq) | `~/.local/bin/` | `make setup` |
| mkcert CA trusted by the OS | macOS Keychain / Linux NSS store | `make up` |
| Kubeconfig for the toolbox container | `.local/toolbox-kubeconfig` | `make up` |

The shims are one-line shell scripts that delegate to `docker exec k3s-toolbox <tool>` — no cluster tools are installed on the host itself.

The DNS resolver entry points `*.dev.local` at `127.0.0.1:5354`, where a second Docker container (`k3s-dnsmasq`) answers. On macOS, Lima port-forwards 8080/8443 from localhost into the cluster's Cilium gateway.

Both Docker containers (`k3s-toolbox` and `k3s-dnsmasq`) are started by `make up` with no restart policy — they won't come back automatically after a Docker restart or reboot. Re-run `make up` to bring them back (it is idempotent and skips the Lima VM if already running).

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

## Full test sequence

End-to-end walkthrough using `wallet-accessmechanism-gitops` (gitops repo) and `wallet-r2ps` (source repo) as the tenant example.

### 1. Rebuild cluster from scratch

```bash
# In k3s-environment/
make clean && make up
```

`make up` waits until all infrastructure HelmReleases are Ready before returning.

### 2. Register the gitops tenant

```bash
# In wallet-accessmechanism-gitops/
make k3s-push       # initialises bare repo on git-server and force-pushes
make k3s-register   # creates Namespace + GitRepository + Kustomization in Flux,
                    # then waits for Flux to fetch the repo and apply the kustomization
```

`make k3s-register` blocks until the kustomization is Applied — all tenant resources
(Kafka cluster, Valkey, HelmReleases, SealedSecrets, …) exist in the cluster before it returns.

### 3. Build and deploy images

```bash
# In wallet-r2ps/
make k3s-deploy   # docker build → docker push :k3s tag
```

Builds `rust-wallet-bff` and `rust-hsm-worker` and pushes them to the in-cluster Zot registry
(`registry.dev.local:8443`). Does not restart pods.

### 4. Authorize rollout

```bash
# In wallet-accessmechanism-gitops/
make k3s-rollout   # bumps timestamp annotation, commits, tags, pushes → Flux applies → rollout status
```

Bumps `rollout-authorized-at` on both StatefulSet pod templates, commits, creates a `rollout/...` git tag,
pushes to the in-cluster git server, triggers Flux reconciliation, and waits for the rollout to complete.

### 5. Smoke test — wallet-bff → Kafka → hsm-worker round-trip

```bash
curl -X POST https://wallet-bff.dev.local:8443/hsm/v1/device-states \
  -H 'Content-Type: application/json' \
  -d '{
    "publicKey": {
      "kty": "EC",
      "crv": "P-256",
      "x": "yRPnAy1TVytmFdOfJIqqJnFGR-vzlU88bar14facJ_A",
      "y": "eqacPxdS2jLDQH2fAEKwogwhoB5yxx-Dk6WyQoIfpKQ",
      "kid": "test-key-1"
    }
  }'
```

Expected: HTTP 200 with a JSON body containing `"status":"OK"`, a `clientId` UUID,
a `devAuthorizationCode`, and a `serverJwsPublicKey` from hsm-worker.
### Tear down tenant

```bash
# In wallet-accessmechanism-gitops/
make k3s-unregister   # deletes Flux registration, strips Strimzi finalizers, waits for namespace gone
```

`make k3s-unregister` blocks until the namespace has fully terminated, so
`make k3s-push && make k3s-register` can be run immediately after without a race.

## Endpoints

| Service | URL |
|---------|-----|
| Grafana | https://grafana.dev.local:8443 |
| Hubble | https://hubble.dev.local:8443 |
| KafBat | https://kafbat.dev.local:8443 |
| Headlamp | https://headlamp.dev.local:8443 |
| Zot registry | https://registry.dev.local:8443 |
| Git server | http://git.dev.local:8080 |

All `*.dev.local` resolved via dnsmasq. TLS via mkcert local CA (trusted by `make setup`).
