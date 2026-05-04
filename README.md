# K3s Local Development Environment

Declarative local Kubernetes environment using **Ansible** for host bootstrap, **Flux** for GitOps, and **Cilium** for networking.

The cluster deploys whatever you list in `gitops-config.yaml` as
`namespaces:` entries. Each entry is `{ name, url, branch, interval, path }`
and produces a Kubernetes Namespace plus a Flux GitRepository +
Kustomization that deploys the repo contents into that namespace. An
empty list means the base infrastructure comes up but no app namespaces
are created. Add an entry with `make namespace`.

## Prerequisites

- `make`
- `ansible` (with `community.general` collection)
- macOS: Xcode Command Line Tools (`xcode-select --install`)
- Optional: `k9s` for cluster management

```bash
# macOS
brew install ansible
# Linux
sudo apt install ansible

# Required collection
ansible-galaxy collection install community.general
```

## Quick Start

```bash
# One-time: install tools, configure dnsmasq (requires sudo)
make setup

# Start k3s, deploy everything via Flux (no sudo)
make up
```

## Make Targets

| Target | Description | Sudo |
|--------|-------------|------|
| `make setup` | One-time: install tools, k3s (Linux), dnsmasq, sysctl (requires sudo) | yes |
| `make up` | Start k3s (macOS), install Cilium, deploy all infrastructure + apps via Flux | no |
| `make sync` | Re-apply infrastructure Flux manifests after editing `flux/` files | no |
| `make sync-apps` | Force Flux to re-pull every gitops repo and reconcile apps-* | no |
| `make reconcile` | Force all HelmReleases to reconcile immediately | no |
| `make namespace` | Add a gitops namespace entry (`NAME`, `URL`, `GITOPS_USER`, `GITOPS_TOKEN`) | no |
| `make gitops-credentials-export` | Re-write `.local/gitops-credentials-<NAME>.yaml` for one entry | no |
| `make gitops-credentials-restore` | Apply every saved gitops-credentials Secret in `.local/` | no |
| `make sealed-secrets-key-export` | Save active sealed-secrets master key to `.local/` | no |
| `make sealed-secrets-key-restore` | Apply saved sealed-secrets key + restart controller | no |
| `make cosign-key-export` | Save cluster cosign signing key to `.local/` | no |
| `make cosign-key-restore` | Apply saved cosign signing key | no |
| `make status` | Show Flux sources, kustomizations, and HelmReleases | no |
| `make stop` | Stop k3s (preserves data) | no |
| `make clean` | Destroy k3s VM completely | no |

## GitOps namespaces

`gitops-config.yaml` holds a list of namespace entries:

```yaml
namespaces:
  - name: wallet
    url: https://github.com/<owner>/wallet-local-gitops.git
    branch: main         # optional, default "main"
    interval: 1m         # optional, default "1m"
    path: ./             # optional, default "./"
    imageAutomation: true  # optional, default false; see below
```

For each entry the playbook applies:

- `Namespace/<name>`
- `GitRepository/<name>` in `flux-system`, authenticated with
  `Secret/gitops-credentials-<name>` (HTTPS + PAT)
- `Kustomization/apps-<name>` in `flux-system`, with
  `targetNamespace: <name>` and `path: <path>`

Ordering between resources inside the gitops repo is the repo's own
responsibility (top-level `kustomization.yaml`, or per-app Flux
Kustomization manifests committed in the repo).

An empty list (`namespaces: []`) means no app namespaces are created;
only the base infrastructure comes up.

### Adding an entry

```bash
# Create a PAT on your git host with read + write access to the gitops repo:
#   GitHub:  Settings > Developer settings > Personal access tokens > Fine-grained
#            Repository: <owner>/<repo>
#            Permissions: Contents = read & write
#   GitLab:  Project access token with developer role + write_repository

make namespace \
  NAME=wallet \
  URL=https://github.com/diggsweden/wallet-local-gitops.git \
  GITOPS_USER=<user> \
  GITOPS_TOKEN=<pat>
```

This appends the entry to `gitops-config.yaml` and writes
`.local/gitops-credentials-<NAME>.yaml` (mode 600). Optional vars:
`BRANCH`, `INTERVAL`, `PATH_IN_REPO`, `IMAGE_AUTOMATION`.

`make up` auto-restores every `.local/gitops-credentials-*.yaml` on
cluster rebuild as long as the file exists. If a Secret is missing both
in-cluster and on disk, the playbook fails fast with a `make namespace`
hint for that specific entry.

### Why a PAT and not just public read

Flux Image Update Automation (opt-in per entry, see "How auto-tag-bumps
work" below) commits image tag bumps back to the gitops repo when a new
`test-…` image is pushed to the in-cluster registry. That commit needs
write credentials. Public-read-only is technically sufficient for
`source-controller` but leaves Image Automation broken; the playbook
therefore requires the PAT unconditionally.

### How auto-tag-bumps work

Setting `imageAutomation: true` on an entry deploys a Flux
`ImageUpdateAutomation` (named `<entry-name>-image-update` in
`flux-system`) that watches the entry's `GitRepository` and rewrites
image tags in-place using Flux's `Setters` strategy.

For this to do anything useful the gitops repo must contain marker
comments next to each image reference, e.g.:

```yaml
containers:
  - name: wallet-bff
    image: zot.registry.svc.cluster.local:5000/rust-wallet-bff:test-0-placeholder # {"$imagepolicy": "flux-system:rust-wallet-bff-test"}
```

The referenced `ImagePolicy` (here `rust-wallet-bff-test`) lives in
`flux/infrastructure/builds/`. When a new tag matching the policy is
pushed to the registry, Flux commits the bump to the entry's branch as
`flux-image-automation <flux@dev.local>`.

Entries with `imageAutomation` unset or `false` get no
`ImageUpdateAutomation` resource; image tag bumps in their gitops repo
remain manual.

## Persisting cluster keys across rebuilds

Two cluster-generated keys must survive `make clean` + `make up` so that
in-repo material keeps working after a cluster rebuild:

| Key | Why it matters |
|-----|----------------|
| **sealed-secrets master key** (`Secret` in `kube-system`, label `sealedsecrets.bitnami.com/sealed-secrets-key=active`) | The controller needs this RSA keypair to decrypt every `SealedSecret` you commit to `wallet-local-gitops`. If it changes, all sealed payloads must be re-sealed. |
| **cosign signing key** (`Secret/cosign-key` in `flux-system`) | Used by the build pipeline (e.g. `make push-bff` / `make push-hsm` in `wallet-r2ps`) to sign images. Kyverno's `verify-internal-images` ClusterPolicy verifies signatures against the public key embedded in `flux/infrastructure/kyverno/verify-internal-images.yaml`. If the keypair changes, all previously-pushed image signatures fail verification. |

### One-time export (after first successful `make up`)

```bash
make sealed-secrets-key-export   # writes .local/sealed-secrets-master.key.yaml (mode 600)
make cosign-key-export           # writes .local/cosign-key.yaml (mode 600)
```

`.local/` is gitignored. The files contain **private keys** — distribute
out-of-band (1Password, age/sops, etc.) if more than one developer needs
the same cluster identity.

### Automatic restore on `make up`

Subsequent `make up` runs auto-restore both keys from `.local/` **only
if** the corresponding Secret is missing in the cluster (so a freshly
rotated or re-generated in-cluster key is never clobbered). When no
saved file is present, Ansible logs a friendly notice and the cluster
generates fresh keys as before.

### Manual restore

```bash
make sealed-secrets-key-restore  # applies + restarts the controller
make cosign-key-restore          # applies the cosign Secret
```

### Limitations

- Only the **active** sealed-secrets key is captured. If key rotation is
  ever enabled, retired decryption keys are not preserved.
- The Kyverno public key is committed in
  `flux/infrastructure/kyverno/verify-internal-images.yaml`. If you
  generate a brand-new cosign key (i.e. start without `.local/cosign-key.yaml`),
  update that file too — otherwise newly-signed images won't verify.

## Endpoints

All `*.dev.local` resolve via dnsmasq. TLS certificates signed by mkcert local CA.

| Service | URL | Description |
|---------|-----|-------------|
| Grafana | https://grafana.dev.local | Dashboards, metrics, logs |
| Hubble | https://hubble.dev.local | Cilium network flow visibility |
| KafBat | https://kafbat.dev.local | Kafka cluster UI |
| Headlamp | https://headlamp.dev.local | Kubernetes UI |
| Zot Registry | https://registry.dev.local | OCI container/artifact registry |
| Wallet BFF | https://wallet-bff.dev.local | r2ps REST API (StatefulSet, 3 pods) |

## Credentials

All passwords are auto-generated and stored as Sealed Secrets. Retrieve them with:

### Grafana

```bash
# Username
kubectl get secret grafana-admin -n monitoring -o jsonpath='{.data.username}' | base64 -d; echo

# Password
kubectl get secret grafana-admin -n monitoring -o jsonpath='{.data.password}' | base64 -d; echo
```

### Headlamp

Headlamp uses a ServiceAccount token. Create one with:

```bash
kubectl create token headlamp -n headlamp --duration=24h
```

## Architecture

```
k3s/
  ansible/                 Ansible playbooks & roles
    setup.yml              One-time system setup (sudo)
    playbook.yml           Day-to-day startup (no sudo)
    roles/
      prerequisites/       Install tools (kubectl, helm, flux, mkcert, cosign, kubeseal)
      k3s/                 Start k3s (Lima on macOS, systemd on Linux)
      dnsmasq/             Configure *.dev.local wildcard DNS
      flux/                Install Flux + Cilium, deploy infrastructure, configure GitOps source

  flux/infrastructure/     Flux manifests (applied directly by Ansible)
    sources/               HelmRepository CRs
    namespaces/            Namespace resources
    cilium/                Cilium CNI + Gateway API + Hubble + TLS certificate
    cert-manager/          cert-manager + mkcert ClusterIssuer
    sealed-secrets/        Sealed Secrets controller
    monitoring/            Prometheus + Grafana + Loki + Vector
    garage/                Garage S3 object storage (backs Loki)
    strimzi/               Strimzi Kafka operator
    registry/              Zot OCI registry
    kyverno/               Kyverno admission controller (image signature verification)
    builds/                Flux Image Update Automation

  gitops-config.yaml       List of namespace + gitops-repo entries (see "GitOps namespaces")
  lima-k3s.yaml            Lima VM config (macOS)
```

### GitOps Repos

One per entry in `gitops-config.yaml#namespaces`. Each repo's contents
are deployed by Flux into the matching namespace (`targetNamespace:
<entry.name>`). The example wallet repo lays out apps as:

```
apps/
  kafka-cluster/           Strimzi Kafka (3 controllers + 3 brokers, KRaft)
                           plus shared KafkaTopics
                           (r2ps-wallet-state, hsm-requests, state-init-requests)
  kafbat/                  KafBat Kafka UI
  valkey/                  Valkey (Redis alternative, Sentinel HA)
  headlamp/                Headlamp Kubernetes UI
  wallet-bff/              r2ps REST API StatefulSet (3 replicas) +
                           per-pod response KafkaTopics + HTTPRoute
  hsm-worker/              HSM worker StatefulSet (3 replicas) +
                           per-replica SoftHSM PVC + SealedSecrets
```

## Modifying Infrastructure

Edit files under `flux/infrastructure/`, then:

```bash
make sync       # Apply changes
make reconcile  # Force immediate reconciliation
make status     # Verify
```

## Modifying App Deployments

Push changes to the gitops repo for the relevant entry:

```bash
cd <your-gitops-repo>
# edit files...
git add -A && git commit -m "update deployment"
git push origin main
# Flux auto-pulls every entry's `interval` (default 1m); to force:
make sync-apps
```

## Building & pushing application images manually

Image builds are currently manual; CI integration is TBD. Images are
built on the developer machine and pushed to the in-cluster Zot
registry exposed at `registry.dev.local`. The `wallet-r2ps` Makefile
contains the helpers.

### Prerequisites

- `make setup` already installed the mkcert root CA, so
  `https://registry.dev.local` is trusted by your local docker/podman.
- `dnsmasq` resolves `registry.dev.local` to the cluster gateway.
- `docker` (or `podman`/`buildah`) available locally.
- `cosign` available locally (installed by `make setup`).

### One-time: export the cluster cosign signing key

Kyverno's `verify-internal-images` ClusterPolicy is in **Enforce** mode
for everything pulled from `zot.registry.svc.cluster.local:5000/*`, so
every image push must be cosign-signed with the in-cluster key
(`Secret/cosign-key` in `flux-system`, generated automatically by
`make up`).

```bash
make -C ../wallet-r2ps cosign-key
# Writes /tmp/cosign.key (mode 600).
```

### Build, push, sign

```bash
cd ../wallet-r2ps

# Each push target builds the image, pushes it to registry.dev.local,
# and signs the resulting digest with cosign.
make push-bff      # builds + pushes + signs rust-wallet-bff
make push-hsm      # builds + pushes + signs rust-hsm-worker
make push-all      # both

# Override the tag to feed the stage / prod ImagePolicies:
make push-all TAG=stage-$(date +%s)-$(git rev-parse --short HEAD)
```

The default tag is `test-<unix-ts>-<short-sha>`, matching the
`rust-wallet-bff-test` / `rust-hsm-worker-test` `ImagePolicy` filters in
`flux/infrastructure/builds/`.

Cosign attaches the signature to the image digest, not the registry
hostname, so the signature pushed to `registry.dev.local` verifies when
the cluster pulls via the in-cluster name
`zot.registry.svc.cluster.local:5000/...`.

### First deployment bootstrap

The StatefulSets in `wallet-local-gitops` reference a placeholder tag
(`:test-0-placeholder`) that does not exist in the registry. On a brand
new cluster the pods will sit in `ImagePullBackOff` until the first
manual push:

```bash
make -C ../wallet-r2ps cosign-key
make -C ../wallet-r2ps push-all
```

Once a real `test-<ts>-<sha>` tag exists, entries with
`imageAutomation: true` get the bump committed automatically; entries
without it must be edited by hand. The StatefulSets roll on the next
Flux reconcile. Watch the promotion:

```bash
flux get image policy
flux get image update
kubectl rollout status statefulset/wallet-bff
kubectl rollout status statefulset/hsm-worker
```

## CI

CI integration for `wallet-bff` and `hsm-worker` is TBD. For now use the
manual flow in
[Building & pushing application images manually](#building--pushing-application-images-manually).

## Observability Stack

| Component | Role |
|-----------|------|
| Prometheus | Metrics collection (kube-prometheus-stack) |
| Grafana | Dashboards + visualization |
| Loki | Log aggregation (S3 backend via Garage) |
| Vector | Log collection (DaemonSet, ships to Loki) |
| Hubble | Cilium network flow observability |

Pre-loaded Grafana dashboards: Kafka, Valkey, HSM Worker, BFF REST API.

## Networking

| Component | Role |
|-----------|------|
| Cilium | CNI (eBPF), replaces Flannel + kube-proxy |
| Cilium Gateway API | Ingress (replaces Traefik), HTTPS termination |
| Hubble | Network flow monitoring |
| cert-manager + mkcert | Wildcard TLS for `*.dev.local` |
| dnsmasq | Local DNS resolution |

## Supply Chain (planned)

| Component | Role |
|-----------|------|
| CI (TBD) | Build / push / sign pipeline (manual today) |
| Buildah | Container image builds (daemonless, rootless) |
| Cosign | Image signing |
| Zot | OCI registry (stores images + signatures) |
| Kyverno | Admission-time signature verification |
| Flux Image Automation | Auto-update gitops repo with new image tags |

## Troubleshooting

```bash
# Check all HelmReleases
flux get helmreleases -A

# Check Flux sources
flux get sources git

# Check Flux kustomizations
flux get kustomizations

# Check Cilium health
kubectl exec -n kube-system ds/cilium -- cilium-dbg status --brief

# Check Gateway routes
kubectl get gateways,httproutes -A

# Check certificates
kubectl get certificates -A

# Check sealed secrets
kubectl get sealedsecrets -A

# View logs for a component
kubectl logs -n <namespace> deploy/<name> --tail=50

# Force reconcile a single HelmRelease
flux reconcile helmrelease <name> -n <namespace>
```
