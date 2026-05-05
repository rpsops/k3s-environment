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

For a full end-to-end walkthrough including key persistence and per-fork
app deploy, see [From zero to a running fork](#from-zero-to-a-running-fork)
below.

## From zero to a running fork

End-to-end procedure covering host prerequisites, cluster bring-up, key
persistence, and per-fork app deploy. Follow phases in order; each phase
is idempotent and safe to re-run.

### Phase 0 — Host prerequisites (one-time per developer)

1. Install host tools: `make`, `ansible` (with `community.general`),
   plus on macOS Xcode CLT (`xcode-select --install`) and Lima.
   `make setup` installs the rest (`kubectl`, `helm`, `flux`, `mkcert`,
   `cosign`, `kubeseal`, `dnsmasq`).
2. After `make setup`, run `mkcert -install` if it wasn't already — this
   trusts the mkcert root CA in your system + browsers so
   `*.dev.local` certs validate.
3. Fork `wallet-local-gitops` into your own org/user (one fork per
   isolated app stack you want to run side-by-side).
4. Create a PAT on the git host with **repo read + write** scope
   (write is required so Flux Image Automation can commit tag bumps).
5. Export creds for the bring-up shell:
   ```bash
   export GITOPS_USER=<git-user>
   export GITOPS_TOKEN=<pat>
   ```

### Phase 1 — Restore-or-fresh decision (before `make up`)

Check `.local/` for keys carried over from a prior cluster:

```
.local/
├── sealed-secrets-master.key.yaml   # CRITICAL — restore to keep committed SealedSecrets decryptable
├── cosign-key.yaml                  # CRITICAL — restore to keep prior image signatures valid
└── gitops-credentials-<name>.yaml   # one per gitops-config.yaml entry
```

If you have these from a previous environment, drop them in `.local/`
now (mode 600). Ansible picks them up automatically and skips
regeneration. Missing files are fine for a brand-new setup — fresh keys
will be generated and you'll persist them in Phase 3.

### Phase 2 — Cluster bring-up (`make up`)

`make up` runs the Ansible flow in this order:

1. Gateway API CRDs → Cilium CNI → Flux (with image-automation
   components).
2. cert-manager → `mkcert-ca` Secret from host CAROOT → `mkcert`
   ClusterIssuer.
3. **Sealed-secrets controller** — restores key from
   `.local/sealed-secrets-master.key.yaml` if absent in cluster, else
   lets the controller generate a fresh one.
4. **Grafana admin** — auto-generates `openssl rand -base64 16`, seals
   it, applies (only if absent in cluster).
5. Infrastructure pass 1 (garage, monitoring, strimzi, registry,
   kyverno) → wait for HelmReleases to converge → pass 2 (cilium,
   monitoring re-apply now that CRDs exist).
6. dnsmasq Gateway IP update (Linux only).
7. For each `gitops-config.yaml` entry: restore
   `gitops-credentials-<name>` from `.local/` (or fail fast with a
   `make namespace` hint), then render and apply Namespace +
   GitRepository + Kustomization (+ ImageUpdateAutomation if
   `imageAutomation: true`).
8. Build infrastructure (`flux/infrastructure/builds/`) →
   **cosign key**: restore from `.local/cosign-key.yaml` if absent,
   else `cosign generate-key-pair k8s://flux-system/cosign-key`.

### Phase 3 — Persist newly-generated keys

Run after the **first** successful `make up` (and any time keys are
regenerated):

```bash
make sealed-secrets-key-export   # → .local/sealed-secrets-master.key.yaml (mode 600)
make cosign-key-export           # → .local/cosign-key.yaml (mode 600)
```

`.local/` is gitignored. The files contain **private keys** —
distribute out-of-band (1Password, age/sops, etc.) if multiple
developers share the same cluster identity.

If the cosign key was freshly generated (no prior `.local/cosign-key.yaml`),
also update the public key embedded in
`flux/infrastructure/kyverno/verify-internal-images.yaml` and re-sign
all images (`make -C ../wallet-r2ps push-bff push-hsm`) — otherwise
Kyverno will reject pulls.

### Phase 4 — Per-fork app deploy

In each fork of `wallet-local-gitops` you want to run:

1. **Re-seal hsm-worker secrets for the fork's namespace** (one-time,
   then commit). SealedSecret payloads are namespace-bound, so a fork
   targeting namespace `<fork-ns>` needs its own re-seal:
   ```bash
   # Source plaintext lives in wallet-r2ps (NOT committed):
   #   .env.softhsm  →  Secret/hsm-worker-softhsm
   #   .env.opaque   →  Secret/hsm-worker-opaque
   kubectl create secret generic hsm-worker-softhsm \
     --namespace=<fork-ns> --from-env-file=../wallet-r2ps/.env.softhsm \
     --dry-run=client -o yaml \
     | kubeseal --controller-namespace=kube-system -o yaml \
     > apps/hsm-worker/sealed-secrets.yaml
   # Repeat for hsm-worker-opaque and merge both SealedSecrets into
   # apps/hsm-worker/sealed-secrets.yaml, then commit + push.
   ```
2. Add an entry to `gitops-config.yaml` and run
   `make namespace NAME=<fork-ns> URL=<fork-url> GITOPS_USER=… GITOPS_TOKEN=…`.
   This appends the entry, writes `.local/gitops-credentials-<fork-ns>.yaml`,
   and applies the Secret + Namespace + GitRepository + Kustomization.
3. Valkey password (auto-generated by the Bitnami chart) and
   `kafka-tls` (issued by cert-manager) come up automatically inside
   the namespace — no manual handling.
4. Bootstrap images on first boot (StatefulSets reference a
   `:test-0-placeholder` tag that doesn't exist yet):
   ```bash
   make -C ../wallet-r2ps cosign-key
   make -C ../wallet-r2ps push-all
   ```
   Entries with `imageAutomation: true` will get the tag bump committed
   to the fork repo automatically; without it, edit the manifests by
   hand.

### Failure-mode quick reference

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `SealedSecret` won't decrypt (`no key could decrypt secret`) | Master key changed since payload was sealed | Restore `.local/sealed-secrets-master.key.yaml` and `kubectl rollout restart deploy/sealed-secrets -n kube-system`, or re-seal payloads against the new key |
| Kyverno blocks image pull (`signature verification failed`) | cosign key regenerated, pubkey in policy stale | Update pubkey in `flux/infrastructure/kyverno/verify-internal-images.yaml` + re-push & re-sign images |
| BFF crashloops on Redis auth after valkey reinstall | Bitnami chart regenerated `valkey-password` | `kubectl rollout restart statefulset wallet-bff -n <fork-ns>` |
| Flux can't pull fork repo | PAT expired or missing write scope | Recreate `gitops-credentials-<name>` (`make namespace` again with new token) |
| `*.dev.local` cert untrusted in browser/curl | mkcert root CA not in host/VM trust store | `mkcert -install` on host; on Lima VM re-run `make setup` |
| `make up` fails with "gitops-credentials-X missing both in-cluster and on disk" | New entry in `gitops-config.yaml` without matching `.local/` file | `make namespace NAME=X URL=… GITOPS_USER=… GITOPS_TOKEN=…` |

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

## Cluster-generated keys reference

Two cluster-generated keys must survive `make clean` + `make up`. Both
are handled automatically by Phases 1–3 of [From zero to a running
fork](#from-zero-to-a-running-fork); this section is a reference for
manual ops.

| Key | Location | Why it matters |
|-----|----------|----------------|
| **sealed-secrets master key** | `Secret` in `kube-system`, label `sealedsecrets.bitnami.com/sealed-secrets-key=active` | Decrypts every `SealedSecret` committed to `wallet-local-gitops` forks. If lost, all sealed payloads must be re-sealed against the new key. |
| **cosign signing key** | `Secret/cosign-key` in `flux-system` | Signs images pushed by `wallet-r2ps`'s `make push-bff`/`push-hsm`. Kyverno's `verify-internal-images` ClusterPolicy verifies against the pubkey in `flux/infrastructure/kyverno/verify-internal-images.yaml`. If regenerated, update the pubkey + re-sign all images. |

### Manual export / restore

```bash
make sealed-secrets-key-export   # → .local/sealed-secrets-master.key.yaml (mode 600)
make sealed-secrets-key-restore  # apply + restart controller

make cosign-key-export           # → .local/cosign-key.yaml (mode 600)
make cosign-key-restore          # apply Secret
```

Auto-restore on `make up` only fires when the corresponding Secret is
**missing** in the cluster, so a freshly rotated in-cluster key is
never clobbered by an old `.local/` file.

### Limitations

- Only the **active** sealed-secrets key is captured. If key rotation is
  ever enabled, retired decryption keys are not preserved.
- The Kyverno public key is committed in
  `flux/infrastructure/kyverno/verify-internal-images.yaml`. If a brand
  new cosign key is generated (no prior `.local/cosign-key.yaml`),
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
