SHELL := /bin/bash

OS      := $(shell uname -s)
REPO    := $(CURDIR)

IMAGE         := k3s-toolbox
GITSERVER_IMAGE := k3s-gitserver:local
CONTAINER     := k3s-toolbox
DNS_CONTAINER := k3s-dnsmasq
DNS_PORT      := 5354
CFG           := gitops-config.yaml

# All cluster tools run inside the toolbox container
TOOLBOX  := docker exec -i $(CONTAINER)
KUBECTL  := $(TOOLBOX) kubectl
HELM     := $(TOOLBOX) helm
FLUX     := $(TOOLBOX) flux
YQ       := $(TOOLBOX) yq

# On macOS k3s runs in a Lima VM; on Linux it runs directly on the host
ifeq ($(OS), Darwin)
NERDCTL := limactl shell k3s sudo nerdctl --address /run/k3s/containerd/containerd.sock --namespace k8s.io
else
NERDCTL := sudo nerdctl --address /run/k3s/containerd/containerd.sock --namespace k8s.io
endif

.PHONY: build setup install-shims up sync sync-apps reconcile status stop clean help \
	namespace \
	cosign-key-export cosign-key-restore \
	gitops-credentials-export gitops-credentials-restore \
	openbao-init openbao-unseal openbao-configure openbao-token bao-put bao-get

## Build the k3s-toolbox Docker image
build:
	docker build -t $(IMAGE) --target toolbox .
	docker build -t $(GITSERVER_IMAGE) --target gitserver .

## One-time system setup (requires sudo): configure DNS + install shims
## macOS: writes /etc/resolver/dev.local
## Linux: installs k3s + dnsmasq, configures systemd-resolved
setup: build
ifeq ($(OS), Darwin)
	@command -v limactl >/dev/null 2>&1 || brew install lima
	@echo "sudo required: creating /etc/resolver/dev.local to delegate *.dev.local DNS to the k3s-dnsmasq container"
	@sudo mkdir -p /etc/resolver
	@printf 'nameserver 127.0.0.1\nport $(DNS_PORT)\n' | sudo tee /etc/resolver/dev.local > /dev/null
	@echo "DNS configured: *.dev.local → 127.0.0.1:$(DNS_PORT)"
else
	@echo "sudo required: installing k3s, dnsmasq, and configuring systemd-resolved"
	@if [ ! -f /usr/local/bin/k3s ]; then \
		echo "Installing k3s..."; \
		curl -sfL https://get.k3s.io | \
		INSTALL_K3S_EXEC="--disable=traefik --disable=servicelb \
		  --flannel-backend=none --disable-network-policy \
		  --disable-kube-proxy --write-kubeconfig-mode 644 \
		  --tls-san host.docker.internal \
		  --resolv-conf /run/systemd/resolve/resolv.conf" \
		sudo sh -; \
		mkdir -p ~/.kube; \
		sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config; \
		sudo chown "$$(id -u):$$(id -g)" ~/.kube/config; \
		chmod 600 ~/.kube/config; \
		echo "fs.inotify.max_user_instances=512"   | sudo tee    /etc/sysctl.d/99-inotify.conf > /dev/null; \
		echo "fs.inotify.max_user_watches=524288"  | sudo tee -a /etc/sysctl.d/99-inotify.conf > /dev/null; \
		sudo sysctl --system; \
	fi
	@sudo apt-get install -y --no-install-recommends dnsmasq
	@sudo mkdir -p /etc/systemd/resolved.conf.d
	@printf '[Resolve]\nDNS=127.0.0.1:5353\nDomains=~dev.local\n' \
		| sudo tee /etc/systemd/resolved.conf.d/dev-local.conf > /dev/null
	@sudo systemctl restart systemd-resolved
	@echo "DNS configured: *.dev.local → 127.0.0.1:5353 via systemd-resolved"
endif
	@$(MAKE) install-shims

## Install kubectl/helm/flux/etc. shims in ~/.local/bin
install-shims:
	@mkdir -p ~/.local/bin
	@for tool in kubectl helm flux cosign yq jq; do \
		printf '#!/bin/sh\nexec docker exec -i $(CONTAINER) %s "$$@"\n' $$tool \
			> ~/.local/bin/$$tool; \
		chmod +x ~/.local/bin/$$tool; \
	done
	@printf '#!/bin/sh\nTOKEN=$$(docker exec $(CONTAINER) jq -r .root_token /workspace/.local/openbao-init.json 2>/dev/null)\nexec docker exec -i $(CONTAINER) kubectl exec -n openbao openbao-0 -- env VAULT_TOKEN="$$TOKEN" bao "$$@"\n' \
		> ~/.local/bin/bao
	@chmod +x ~/.local/bin/bao
	@echo "Shims installed to ~/.local/bin/ — add to PATH if not already there"

## Start k3s and deploy cluster via Flux (no sudo required)
up: build
	@mkdir -p .local .local/mkcert
ifeq ($(OS), Darwin)
	@if limactl list 2>/dev/null | grep -q '^k3s.*Running'; then \
		echo "Lima k3s VM already running"; \
	elif limactl list 2>/dev/null | grep -q '^k3s'; then \
		limactl start k3s; \
	else \
		limactl start --name=k3s --tty=false lima-k3s.yaml; \
	fi
	@limactl shell k3s sudo cat /etc/rancher/k3s/k3s.yaml \
		| sed 's|https://127.0.0.1:6443|https://host.docker.internal:6443|g' \
		> .local/toolbox-kubeconfig
	@chmod 600 .local/toolbox-kubeconfig
else
	@kubectl get nodes > /dev/null 2>&1 \
		|| { echo "ERROR: k3s is not running. Run: make setup"; exit 1; }
	@sed 's|https://127\.0\.0\.1:6443|https://host.docker.internal:6443|g; \
	      s|https://localhost:6443|https://host.docker.internal:6443|g' \
		~/.kube/config > .local/toolbox-kubeconfig
	@chmod 600 .local/toolbox-kubeconfig
endif
	@docker rm -f $(CONTAINER) 2>/dev/null || true
	@docker run -d --name $(CONTAINER) \
		--add-host=host.docker.internal:host-gateway \
		-v $(REPO)/.local/toolbox-kubeconfig:/root/.kube/config:ro \
		-v $(REPO)/.local/mkcert:/root/.local/share/mkcert \
		-v $(REPO):/workspace \
		-w /workspace \
		$(IMAGE) sleep infinity
	@echo "Loading git server image into k3s containerd..."
	@docker save $(GITSERVER_IMAGE) | $(NERDCTL) load
	@docker exec $(CONTAINER) \
		ansible-playbook -i ansible/inventory/localhost.yml ansible/playbook.yml
	@echo "Waiting for all HelmReleases to be Ready (up to 20m)..."
	@$(KUBECTL) wait helmrelease --all -A --for=condition=Ready --timeout=20m \
		|| { \
		echo "WARNING: some HelmReleases not Ready:"; \
		$(KUBECTL) get helmrelease -A --no-headers \
			| awk '$$4 != "True" {print "  " $$0}'; \
		}
	@echo "Waiting for Cilium gateway to be programmed..."
	@$(KUBECTL) wait gateway dev-local -n default \
		--for=condition=Programmed --timeout=5m
ifeq ($(OS), Darwin)
	@# macOS: Lima port-forwards 8080/8443 to the Cilium gateway; resolve to localhost
	@printf 'port=$(DNS_PORT)\nno-resolv\naddress=/dev.local/127.0.0.1\n' \
		> .local/dnsmasq.conf
	@echo "DNS: *.dev.local → 127.0.0.1 (Lima forwards 8080/8443 to Cilium gateway)"
else
	@# Linux: k3s is on the host; ClusterIP is directly routable
	@GATEWAY_IP=$$($(KUBECTL) get svc cilium-gateway-dev-local -n default \
		-o jsonpath='{.spec.clusterIP}' 2>/dev/null); \
	printf 'port=$(DNS_PORT)\nno-resolv\naddress=/dev.local/%s\n' "$$GATEWAY_IP" \
		> .local/dnsmasq.conf; \
	echo "DNS: *.dev.local → $$GATEWAY_IP (Cilium gateway ClusterIP)"
endif
	@docker rm -f $(DNS_CONTAINER) 2>/dev/null || true
	@docker run -d --name $(DNS_CONTAINER) \
		-p 127.0.0.1:$(DNS_PORT):$(DNS_PORT)/udp \
		-v $(REPO)/.local/dnsmasq.conf:/workspace/.local/dnsmasq.conf:ro \
		$(IMAGE) \
		dnsmasq --no-daemon --conf-file=/workspace/.local/dnsmasq.conf
ifeq ($(OS), Darwin)
	@if [ -f .local/mkcert/rootCA.pem ]; then \
		security add-trusted-cert -r trustRoot \
			-k ~/Library/Keychains/login.keychain \
			.local/mkcert/rootCA.pem \
		&& echo "CA trusted in macOS Keychain" \
		|| echo "CA already trusted (or failed — check Keychain manually)"; \
	fi
	@echo "Waiting for HTTP ingress (Mac:8080 → socat → Cilium gateway)..."
	@i=0; while [ $$i -lt 60 ]; do \
		code=$$(curl -s --max-time 3 http://127.0.0.1:8080/ \
			-o /dev/null -w '%{http_code}' 2>/dev/null); \
		[ "$$code" != "000" ] && echo "Ingress OK (HTTP $$code)" && break; \
		i=$$((i+1)); echo "  ($$i/60) waiting..."; sleep 5; \
	done; \
	code=$$(curl -s --max-time 3 http://127.0.0.1:8080/ \
		-o /dev/null -w '%{http_code}' 2>/dev/null); \
	[ "$$code" != "000" ] \
		|| { echo "ERROR: HTTP ingress not responding after 5m"; exit 1; }
else
	@if [ -f .local/mkcert/rootCA.pem ]; then \
		mkdir -p ~/.pki/nssdb; \
		certutil -d sql:$$HOME/.pki/nssdb -N --empty-password 2>/dev/null || true; \
		certutil -d sql:$$HOME/.pki/nssdb -A -t "CT,," -n k3s-env-ca \
			-i .local/mkcert/rootCA.pem 2>/dev/null \
		&& echo "CA trusted in NSS store (~/.pki/nssdb)" \
		|| echo "CA already trusted"; \
	fi
endif

## Re-apply infrastructure Flux manifests after editing flux/ files
sync:
	$(KUBECTL) apply -k flux/infrastructure/sources/
	$(KUBECTL) apply -k flux/infrastructure/namespaces/
	$(KUBECTL) apply -k flux/infrastructure/cert-manager/
	$(KUBECTL) apply -k flux/infrastructure/cilium/
	$(KUBECTL) apply -k flux/infrastructure/openbao/
	$(KUBECTL) apply -k flux/infrastructure/external-secrets/
	$(KUBECTL) apply -k flux/infrastructure/garage/
	$(KUBECTL) apply -k flux/infrastructure/monitoring/
	$(KUBECTL) apply -k flux/infrastructure/strimzi/
	$(KUBECTL) apply -k flux/infrastructure/registry/
	$(KUBECTL) apply -k flux/infrastructure/kyverno/
	$(KUBECTL) apply -k flux/infrastructure/builds/
	$(KUBECTL) apply -k flux/infrastructure/git-server/

## Force Flux to re-pull every gitops repo and reconcile every apps-* Kustomization
sync-apps:
	@for s in $$($(FLUX) get sources git --no-header 2>/dev/null | awk '{print $$1}'); do \
		$(FLUX) reconcile source git $$s; \
	done
	@for k in $$($(FLUX) get kustomizations --no-header 2>/dev/null | awk '/^apps-/ {print $$1}'); do \
		$(FLUX) reconcile kustomization $$k; \
	done

## Force Flux to reconcile HelmReleases immediately
reconcile:
	$(FLUX) reconcile helmrelease cert-manager -n cert-manager
	$(FLUX) reconcile helmrelease cilium -n kube-system
	$(FLUX) reconcile helmrelease openbao -n openbao
	$(FLUX) reconcile helmrelease external-secrets -n external-secrets
	$(FLUX) reconcile helmrelease garage -n garage
	$(FLUX) reconcile helmrelease kube-prometheus-stack -n monitoring
	$(FLUX) reconcile helmrelease loki -n monitoring
	$(FLUX) reconcile helmrelease vector -n monitoring
	$(FLUX) reconcile helmrelease strimzi-kafka-operator -n kafka
	$(FLUX) reconcile helmrelease zot -n registry
	$(FLUX) reconcile helmrelease kyverno -n kyverno
	$(FLUX) reconcile helmrelease kafbat-ui -n default
	$(FLUX) reconcile helmrelease valkey -n default

## Create namespace + Flux resources (NAME=<ns>)
namespace:
	@NAME='$(NAME)' BRANCH='$(BRANCH)' INTERVAL='$(INTERVAL)' \
	 PATH_IN_REPO='$(PATH_IN_REPO)' CONTAINER='$(CONTAINER)' \
	 ./scripts/setup-namespace.sh

## Re-write a single namespace's PAT Secret manifest
##
## Usage:
##   make gitops-credentials-export NAME=<ns> GITOPS_USER=<user> GITOPS_TOKEN=<pat>
gitops-credentials-export:
	@if [ -z "$(NAME)" ] || [ -z "$(GITOPS_USER)" ] || [ -z "$(GITOPS_TOKEN)" ]; then \
		echo "ERROR: set NAME, GITOPS_USER, and GITOPS_TOKEN" >&2; \
		exit 1; \
	fi
	@mkdir -p .local
	@$(KUBECTL) create secret generic gitops-credentials-$(NAME) \
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
		$(KUBECTL) apply -f "$$f"; \
	done; \
	if [ $$found -eq 0 ]; then \
		echo "ERROR: no .local/gitops-credentials-*.yaml found" >&2; \
		exit 1; \
	fi

## Export the cosign signing key to .local/
cosign-key-export:
	@mkdir -p .local
	@if ! $(KUBECTL) get secret cosign-key -n flux-system >/dev/null 2>&1; then \
		echo "ERROR: Secret/cosign-key not found in flux-system" >&2; exit 1; \
	fi
	@$(KUBECTL) get secret cosign-key -n flux-system -o yaml | \
		$(YQ) 'del(.metadata.resourceVersion, .metadata.uid, \
		           .metadata.creationTimestamp, .metadata.managedFields, \
		           .metadata.ownerReferences)' \
		> .local/cosign-key.yaml
	@chmod 600 .local/cosign-key.yaml
	@echo "Wrote .local/cosign-key.yaml (mode 600)"

## Restore the cosign signing key from .local/
cosign-key-restore:
	@if [ ! -f .local/cosign-key.yaml ]; then \
		echo "ERROR: .local/cosign-key.yaml not found" >&2; exit 1; \
	fi
	$(KUBECTL) apply -f .local/cosign-key.yaml

## Initialize OpenBao — saves unseal key + root token to .local/openbao-init.json
openbao-init:
	@mkdir -p .local
	@if [ -f .local/openbao-init.json ]; then \
		echo "ERROR: .local/openbao-init.json already exists" >&2; exit 1; \
	fi
	@$(KUBECTL) exec -n openbao openbao-0 -- \
		bao operator init -key-shares=1 -key-threshold=1 -format=json \
		> .local/openbao-init.json
	@chmod 600 .local/openbao-init.json
	@echo "Wrote .local/openbao-init.json (mode 600)"

## Unseal OpenBao using key from .local/openbao-init.json
openbao-unseal:
	@if [ ! -f .local/openbao-init.json ]; then \
		echo "ERROR: .local/openbao-init.json not found" >&2; exit 1; \
	fi
	@KEY=$$(jq -r '.unseal_keys_b64[0]' .local/openbao-init.json) && \
	$(KUBECTL) exec -n openbao openbao-0 -- bao operator unseal "$$KEY"

## Configure OpenBao: enable KV v2, enable k8s auth, create eso policy + role
## Run once after openbao-init + openbao-unseal
openbao-configure:
	@if [ ! -f .local/openbao-init.json ]; then \
		echo "ERROR: .local/openbao-init.json not found — run make openbao-init first" >&2; exit 1; \
	fi
	@TOKEN=$$(jq -r '.root_token' .local/openbao-init.json) && \
	$(KUBECTL) exec -n openbao openbao-0 -- \
		env VAULT_TOKEN="$$TOKEN" bao secrets enable -path=secret kv-v2 2>/dev/null \
		|| echo "KV v2 at secret/ already enabled"
	@TOKEN=$$(jq -r '.root_token' .local/openbao-init.json) && \
	$(KUBECTL) exec -n openbao openbao-0 -- \
		env VAULT_TOKEN="$$TOKEN" bao auth enable kubernetes 2>/dev/null \
		|| echo "kubernetes auth already enabled"
	@TOKEN=$$(jq -r '.root_token' .local/openbao-init.json) && \
	K8S_HOST="https://kubernetes.default.svc.cluster.local" && \
	SA_JWT=$$($(KUBECTL) exec -n openbao openbao-0 -- \
		cat /var/run/secrets/kubernetes.io/serviceaccount/token) && \
	CA_CERT=$$($(KUBECTL) exec -n openbao openbao-0 -- \
		cat /var/run/secrets/kubernetes.io/serviceaccount/ca.crt) && \
	$(KUBECTL) exec -n openbao openbao-0 -- \
		env VAULT_TOKEN="$$TOKEN" \
		bao write auth/kubernetes/config \
			kubernetes_host="$$K8S_HOST" \
			kubernetes_ca_cert="$$CA_CERT" \
			token_reviewer_jwt="$$SA_JWT"
	@TOKEN=$$(jq -r '.root_token' .local/openbao-init.json) && \
	printf 'path "secret/data/*" { capabilities = ["read"] }\npath "secret/metadata/*" { capabilities = ["read", "list"] }\n' | \
	$(KUBECTL) exec -n openbao openbao-0 -i -- \
		env VAULT_TOKEN="$$TOKEN" bao policy write eso -
	@TOKEN=$$(jq -r '.root_token' .local/openbao-init.json) && \
	ESO_NS="external-secrets" && \
	$(KUBECTL) exec -n openbao openbao-0 -- \
		env VAULT_TOKEN="$$TOKEN" \
		bao write auth/kubernetes/role/eso \
			bound_service_account_names="external-secrets" \
			bound_service_account_namespaces="$$ESO_NS" \
			policies="eso" \
			ttl=1h
	@echo "OpenBao configured: KV v2, k8s auth, eso policy + role"

## Print the OpenBao root token
openbao-token:
	@jq -r '.root_token' .local/openbao-init.json 2>/dev/null \
		|| { echo "ERROR: .local/openbao-init.json not found" >&2; exit 1; }

## Put a secret into OpenBao KV v2
## Usage: make bao-put SECRET=<path> KEY=<key> VALUE=<value>
##   e.g. make bao-put SECRET=myapp KEY=api-key VALUE=secret123
bao-put:
	@if [ -z "$(SECRET)" ] || [ -z "$(KEY)" ] || [ -z "$(VALUE)" ]; then \
		echo "ERROR: set SECRET, KEY, and VALUE" >&2; \
		echo "  e.g. make bao-put SECRET=myapp KEY=api-key VALUE=secret123" >&2; \
		exit 1; \
	fi
	@TOKEN=$$(jq -r '.root_token' .local/openbao-init.json) && \
	$(KUBECTL) exec -n openbao openbao-0 -- \
		env VAULT_TOKEN="$$TOKEN" bao kv put secret/$(SECRET) $(KEY)='$(VALUE)'

## Get a secret from OpenBao KV v2
## Usage: make bao-get SECRET=<path>
##   e.g. make bao-get SECRET=myapp
bao-get:
	@if [ -z "$(SECRET)" ]; then \
		echo "ERROR: set SECRET" >&2; \
		echo "  e.g. make bao-get SECRET=myapp" >&2; \
		exit 1; \
	fi
	@TOKEN=$$(jq -r '.root_token' .local/openbao-init.json) && \
	$(KUBECTL) exec -n openbao openbao-0 -- \
		env VAULT_TOKEN="$$TOKEN" bao kv get secret/$(SECRET)

## Show Flux status
status:
	@echo "=== Git Sources ==="
	@$(FLUX) get sources git
	@echo ""
	@echo "=== Kustomizations ==="
	@$(FLUX) get kustomizations
	@echo ""
	@echo "=== HelmReleases ==="
	@$(FLUX) get helmreleases -A

## Stop k3s and toolbox containers (preserves data)
stop:
	@docker stop $(CONTAINER) $(DNS_CONTAINER) 2>/dev/null || true
ifeq ($(OS), Darwin)
	@if limactl list 2>/dev/null | grep -q '^k3s.*Running'; then \
		limactl stop k3s; \
	fi
endif

## Destroy k3s and all containers completely
clean:
	@docker rm -f $(CONTAINER) $(DNS_CONTAINER) 2>/dev/null || true
ifeq ($(OS), Darwin)
	@if limactl list 2>/dev/null | grep -q '^k3s'; then \
		limactl delete --force k3s; \
	fi
	@rm -f ~/.kube/config
else
	@if [ -f /usr/local/bin/k3s-uninstall.sh ]; then \
		sudo /usr/local/bin/k3s-uninstall.sh; \
	fi
endif
	@rm -f .local/openbao-init.json
	@echo "Removed .local/openbao-init.json (new cluster needs fresh init)"

## Display available targets
help:
	@echo "Available targets:"
	@echo "  build      - Build the k3s-toolbox Docker image"
	@echo "  setup      - One-time setup (sudo): DNS + k3s (Linux) + shims"
	@echo "  up         - Start k3s and deploy cluster via Flux (no sudo)"
	@echo "  sync       - Re-apply infrastructure Flux manifests"
	@echo "  sync-apps  - Force Flux to re-pull every gitops repo"
	@echo "  reconcile  - Force Flux to reconcile HelmReleases"
	@echo "  namespace  - Create namespace + Flux resources (NAME=<ns>)"
	@echo "  status     - Show Flux sources, kustomizations, and HelmReleases"
	@echo "  stop       - Stop containers and Lima VM (preserves data)"
	@echo "  clean      - Destroy everything"
	@echo ""
	@echo "Container: $(CONTAINER)  Image: $(IMAGE)"
	@echo "NERDCTL:   $(NERDCTL)"
