- In all interactions and commit messages, be extremely concise and sacrifice grammar for the sake of consision.

## Plans

- At the end of each plan, give me a list of unresolved questions if any. Make the questions extremely concise. Sacrifice grammar for the sake of consision.

## Design principles

**Works on Linux and macOS.** k3s runs in Lima VM on macOS, directly on host on Linux. OS branches via `uname -s`. No platform-specific assumptions.

**Infrastructure/tenant separation.** This repo sets up cluster infra only — no tenant names, URLs, or namespaces here. Tenants self-register via their own Makefile targets.

**sudo only on initial setup.** `make setup` needs elevated privileges. Everything after (`make up`, `make sync`, daily operation) runs without sudo.

**Tooling in toolbox container.** kubectl, helm, argocd, cosign, kubeseal, yq, jq live only inside k3s-toolbox. Host gets shims in `~/.local/bin` delegating to `docker exec k3s-toolbox`.

**No external dependencies during normal operation.** Git server and image registry (Zot) run in-cluster. Tenant repos push to in-cluster git-server; images push to Zot. No GitHub or external registry required.

**Code repos emulate CI/CD via `make k3s-deploy`.** Builds, signs, pushes, and deploys images to the local cluster in one target — replicating what a real pipeline does in production.

**Gitops repos self-register with ArgoCD.** `make k3s-push` publishes to the in-cluster git server; `make k3s-register` creates an ArgoCD Application and policy exceptions. No registration logic in k3s-environment.

**Infra managed via app-of-apps.** `argocd/` holds ArgoCD Application manifests; `make infra-push` syncs them to the in-cluster git-server; ArgoCD picks up changes automatically. Istio is the service mesh (replaced Cilium).

**`k3s-` prefix for cluster-interacting targets.** Any Makefile target or variable in a tenant/source repo that touches k3s uses the prefix (`k3s-deploy`, `k3s-push`, `K3S_NAMESPACE`, `K3S_REGISTRY`, etc.).
