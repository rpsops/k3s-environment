FROM ubuntu:24.04 AS toolbox

ARG TARGETARCH=amd64
ARG FLUX_VERSION=2.4.0

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    dnsmasq \
    git \
    jq \
    libnss3-tools \
    openssl \
    python3 \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 install --break-system-packages ansible

RUN curl -fsSL \
    "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/${TARGETARCH}/kubectl" \
    -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl

RUN curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

RUN curl -fsSL \
    "https://github.com/fluxcd/flux2/releases/download/v${FLUX_VERSION}/flux_${FLUX_VERSION}_linux_${TARGETARCH}.tar.gz" \
    | tar -xz -C /usr/local/bin flux

RUN KUBESEAL_VER=$(curl -fsSL https://api.github.com/repos/bitnami-labs/sealed-secrets/releases/latest \
        | jq -r '.tag_name | ltrimstr("v")') \
    && curl -fsSL \
        "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VER}/kubeseal-${KUBESEAL_VER}-linux-${TARGETARCH}.tar.gz" \
    | tar -xz -C /usr/local/bin kubeseal

RUN curl -fsSL \
    "https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-${TARGETARCH}" \
    -o /usr/local/bin/cosign \
    && chmod +x /usr/local/bin/cosign

RUN curl -fsSL \
    "https://dl.filippo.io/mkcert/latest?for=linux/${TARGETARCH}" \
    -o /usr/local/bin/mkcert \
    && chmod +x /usr/local/bin/mkcert

RUN curl -fsSL \
    "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${TARGETARCH}" \
    -o /usr/local/bin/yq \
    && chmod +x /usr/local/bin/yq

WORKDIR /workspace

# ── git-http-backend (deployed into k3s as a pod) ──────────────────────────
FROM ubuntu:24.04 AS gitserver
RUN apt-get update && apt-get install -y --no-install-recommends \
    apache2 git && \
    a2enmod cgi alias env && \
    rm -rf /var/lib/apt/lists/*
COPY docker/gitserver-apache.conf /etc/apache2/sites-enabled/000-default.conf
RUN echo "ServerName localhost" >> /etc/apache2/apache2.conf && \
    mkdir -p /repos && \
    git config --system http.receivepack true
EXPOSE 80
CMD ["apache2ctl", "-D", "FOREGROUND"]
