SHELL := /bin/bash

OS := $(shell uname -s)

# On Linux, k3s uses its own embedded containerd socket separate from the system containerd.
# Point nerdctl at the k3s socket so built images are available to k3s directly.
# On macOS with Lima, use limactl shell to execute nerdctl inside the VM.
ifeq ($(OS), Linux)
NERDCTL := sudo nerdctl --address /run/k3s/containerd/containerd.sock
else
NERDCTL := limactl shell k3s sudo nerdctl --address /run/k3s/containerd/containerd.sock
endif

.PHONY: setup up sync sync-apps reconcile status stop clean help \
	namespace \
	sealed-secrets-key-export sealed-secrets-key-restore \
	cosign-key-export cosign-key-restore \
	gitops-credentials-export gitops-credentials-restore

## One-time system setup (requires sudo): install tools, configure dnsmasq
setup:
	cd ansible && ansible-playbook -i inventory/localhost.yml setup.yml --ask-become-pass

## Start k3s and deploy via Flux (no sudo required)
up:
	cd ansible && ansible-playbook -i inventory/localhost.yml playbook.yml

## Re-apply infrastructure Flux manifests after editing flux/ files
sync:
	kubectl apply -k flux/infrastructure/sources/
	kubectl apply -k flux/infrastructure/namespaces/
	kubectl apply -k flux/infrastructure/cert-manager/
	kubectl apply -k flux/infrastructure/cilium/
	kubectl apply -k flux/infrastructure/sealed-secrets/
	kubectl apply -k flux/infrastructure/garage/
	kubectl apply -k flux/infrastructure/monitoring/
	kubectl apply -k flux/infrastructure/strimzi/
	kubectl apply -k flux/infrastructure/registry/
	kubectl apply -k flux/infrastructure/kyverno/
	kubectl apply -k flux/infrastructure/builds/

## Force Flux to re-pull every gitops repo and reconcile every apps-* Kustomization
sync-apps:
	@for s in $$(flux get sources git --no-header 2>/dev/null | awk '{print $$1}'); do \
		flux reconcile source git $$s; \
	done
	@for k in $$(flux get kustomizations --no-header 2>/dev/null | awk '/^apps-/ {print $$1}'); do \
		flux reconcile kustomization $$k; \
	done

## Force Flux to reconcile HelmReleases immediately
reconcile:
	flux reconcile helmrelease cert-manager -n cert-manager
	flux reconcile helmrelease cilium -n kube-system
	flux reconcile helmrelease sealed-secrets -n kube-system
	flux reconcile helmrelease garage -n garage
	flux reconcile helmrelease kube-prometheus-stack -n monitoring
	flux reconcile helmrelease loki -n monitoring
	flux reconcile helmrelease vector -n monitoring
	flux reconcile helmrelease strimzi-kafka-operator -n kafka
	flux reconcile helmrelease zot -n registry
	flux reconcile helmrelease kyverno -n kyverno
	flux reconcile helmrelease kafbat-ui -n default
	flux reconcile helmrelease valkey -n default

## Add a new gitops namespace entry to gitops-config.yaml + write credentials
##
## Usage:
##   make namespace NAME=<ns> URL=<https-clone-url> \
##                  GITOPS_USER=<user> GITOPS_TOKEN=<pat> \
##                  [BRANCH=main] [INTERVAL=1m] [PATH_IN_REPO=./] \
##                  [IMAGE_AUTOMATION=true]
namespace:
	@./scripts/add-namespace.sh

## Re-write a single namespace's PAT Secret manifest
##
## Usage:
##   make gitops-credentials-export NAME=<ns> GITOPS_USER=<user> GITOPS_TOKEN=<pat>
##
## The PAT needs repo read + write (write is required by Flux Image
## Update Automation). Stored locally; not committed.
gitops-credentials-export:
	@if [ -z "$(NAME)" ] || [ -z "$(GITOPS_USER)" ] || [ -z "$(GITOPS_TOKEN)" ]; then \
		echo "ERROR: set NAME, GITOPS_USER, and GITOPS_TOKEN" >&2; \
		echo "  e.g. make gitops-credentials-export NAME=wallet GITOPS_USER=alice GITOPS_TOKEN=ghp_..." >&2; \
		exit 1; \
	fi
	@mkdir -p .local
	@kubectl create secret generic gitops-credentials-$(NAME) \
		-n flux-system \
		--from-literal=username='$(GITOPS_USER)' \
		--from-literal=password='$(GITOPS_TOKEN)' \
		--dry-run=client -o yaml > .local/gitops-credentials-$(NAME).yaml
	@chmod 600 .local/gitops-credentials-$(NAME).yaml
	@echo "Wrote .local/gitops-credentials-$(NAME).yaml (mode 600)"

## Apply every saved gitops-credentials Secret in .local/
gitops-credentials-restore:
	@found=0; \
	for f in .local/gitops-credentials-*.yaml; do \
		[ -e "$$f" ] || continue; \
		found=1; \
		kubectl apply -f "$$f"; \
	done; \
	if [ $$found -eq 0 ]; then \
		echo "ERROR: no .local/gitops-credentials-*.yaml found" >&2; \
		echo "       Run 'make namespace NAME=... URL=... GITOPS_USER=... GITOPS_TOKEN=...' first." >&2; \
		exit 1; \
	fi

## Export the sealed-secrets master key Secret to .local/ for restore on rebuild
sealed-secrets-key-export:
	@mkdir -p .local
	@COUNT=$$(kubectl get secret -n kube-system \
		-l sealedsecrets.bitnami.com/sealed-secrets-key=active \
		-o name 2>/dev/null | wc -l | tr -d ' ') && \
	if [ "$$COUNT" -eq 0 ]; then \
		echo "ERROR: no active sealed-secrets key found in kube-system" >&2; \
		echo "       (label sealedsecrets.bitnami.com/sealed-secrets-key=active)" >&2; \
		exit 1; \
	elif [ "$$COUNT" -gt 1 ]; then \
		echo "ERROR: multiple active sealed-secrets keys found ($$COUNT); aborting" >&2; \
		exit 1; \
	fi
	@kubectl get secret -n kube-system \
		-l sealedsecrets.bitnami.com/sealed-secrets-key=active \
		-o yaml | \
		yq 'del(.items[].metadata.resourceVersion, .items[].metadata.uid, .items[].metadata.creationTimestamp, .items[].metadata.managedFields, .items[].metadata.ownerReferences) | .items[0]' \
		> .local/sealed-secrets-master.key.yaml
	@chmod 600 .local/sealed-secrets-master.key.yaml
	@echo "Wrote .local/sealed-secrets-master.key.yaml (mode 600)"

## Restore the sealed-secrets master key from .local/ and restart the controller
sealed-secrets-key-restore:
	@if [ ! -f .local/sealed-secrets-master.key.yaml ]; then \
		echo "ERROR: .local/sealed-secrets-master.key.yaml not found" >&2; \
		echo "       Run 'make sealed-secrets-key-export' on a working cluster first." >&2; \
		exit 1; \
	fi
	kubectl apply -f .local/sealed-secrets-master.key.yaml
	kubectl rollout restart deploy/sealed-secrets -n kube-system
	kubectl rollout status  deploy/sealed-secrets -n kube-system --timeout=120s

## Export the cosign signing key Secret to .local/ for restore on rebuild
cosign-key-export:
	@mkdir -p .local
	@if ! kubectl get secret cosign-key -n flux-system >/dev/null 2>&1; then \
		echo "ERROR: Secret/cosign-key not found in flux-system" >&2; \
		exit 1; \
	fi
	@kubectl get secret cosign-key -n flux-system -o yaml | \
		yq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.managedFields, .metadata.ownerReferences)' \
		> .local/cosign-key.yaml
	@chmod 600 .local/cosign-key.yaml
	@echo "Wrote .local/cosign-key.yaml (mode 600)"

## Restore the cosign signing key from .local/
cosign-key-restore:
	@if [ ! -f .local/cosign-key.yaml ]; then \
		echo "ERROR: .local/cosign-key.yaml not found" >&2; \
		echo "       Run 'make cosign-key-export' on a working cluster first." >&2; \
		exit 1; \
	fi
	kubectl apply -f .local/cosign-key.yaml

## Show Flux status
status:
	@echo "=== Git Sources ==="
	@flux get sources git
	@echo ""
	@echo "=== Kustomizations ==="
	@flux get kustomizations
	@echo ""
	@echo "=== HelmReleases ==="
	@flux get helmreleases -A

## Stop k3s (preserves data)
stop:
ifeq ($(OS), Darwin)
	@echo "Stopping Lima k3s VM..."
	@if limactl list | grep -q "^k3s"; then \
		limactl stop k3s; \
		echo "Lima k3s VM stopped"; \
	else \
		echo "Lima k3s VM does not exist"; \
	fi
else ifeq ($(OS), Linux)
	@echo "Stopping k3s service..."
	@sudo systemctl stop k3s || sudo service k3s stop
	@echo "k3s service stopped"
else
	@echo "Unsupported OS: $(OS)"
endif

## Destroy k3s completely
clean:
ifeq ($(OS), Darwin)
	@echo "Deleting Lima k3s VM..."
	@if limactl list | grep -q "^k3s"; then \
		limactl delete --force k3s; \
		echo "Lima k3s VM deleted"; \
	else \
		echo "Lima k3s VM does not exist"; \
	fi
	@echo "Cleaning up kubeconfig..."
	@rm -f ~/.kube/config
else ifeq ($(OS), Linux)
	@echo "Uninstalling k3s..."
	@if [ -f /usr/local/bin/k3s-uninstall.sh ]; then \
		sudo /usr/local/bin/k3s-uninstall.sh; \
		echo "k3s uninstalled"; \
	else \
		echo "k3s not installed"; \
	fi
else
	@echo "Unsupported OS: $(OS)"
endif

## Display available targets
help:
	@echo "Available targets:"
	@echo "  setup      - One-time system setup (requires sudo): tools + dnsmasq"
	@echo "  up         - Start k3s and deploy via Flux (no sudo)"
	@echo "  sync       - Re-apply infrastructure Flux manifests"
	@echo "  sync-apps  - Force Flux to re-pull every gitops repo and reconcile apps"
	@echo "  reconcile  - Force Flux to reconcile HelmReleases immediately"
	@echo "  namespace  - Add a gitops namespace entry (NAME, URL, GITOPS_USER, GITOPS_TOKEN; opt: IMAGE_AUTOMATION=true)"
	@echo "  gitops-credentials-export  - Re-write .local/gitops-credentials-<NAME>.yaml"
	@echo "  gitops-credentials-restore - Apply every saved gitops-credentials Secret"
	@echo "  sealed-secrets-key-export  - Save active sealed-secrets master key to .local/"
	@echo "  sealed-secrets-key-restore - Apply saved sealed-secrets key + restart controller"
	@echo "  cosign-key-export          - Save cluster cosign signing key to .local/"
	@echo "  cosign-key-restore         - Apply saved cosign signing key"
	@echo "  status     - Show Flux sources, kustomizations, and HelmReleases"
	@echo "  stop       - Stop k3s (preserves data)"
	@echo "  clean      - Destroy k3s completely"
	@echo ""
	@echo "Container runtime:"
	@echo "  NERDCTL = $(NERDCTL)"
