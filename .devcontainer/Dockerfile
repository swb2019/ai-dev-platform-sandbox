FROM mcr.microsoft.com/devcontainers/typescript-node:1-20-bullseye

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

USER root

ARG GITLEAKS_VERSION=8.18.2
ARG TRIVY_VERSION=0.55.2
ARG GRYPE_VERSION=0.79.3
ARG SYFT_VERSION=1.33.0
ARG TERRAFORM_LS_VERSION=0.38.0
ARG COSIGN_VERSION=2.3.0


RUN set -euo pipefail; \
    sed -i 's|http://deb.debian.org|https://deb.debian.org|g' /etc/apt/sources.list; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    apt-get install -y --no-install-recommends jq curl git python3-pip docker.io ca-certificates gnupg unzip; \
    CURL_RETRY="curl --fail --location --show-error --silent --retry 5 --retry-delay 2 --retry-all-errors"; \
    $CURL_RETRY "https://packages.cloud.google.com/apt/doc/apt-key.gpg" | gpg --dearmor --batch --yes --output /usr/share/keyrings/cloud.google.gpg; \
    echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" > /etc/apt/sources.list.d/google-cloud-sdk.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends google-cloud-cli; \
    rm -rf /var/lib/apt/lists/*; \
    $CURL_RETRY "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" | tar -xz -C /usr/local/bin gitleaks; \
    python3 -m pip install --no-cache-dir semgrep; \
    $CURL_RETRY https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin v${TRIVY_VERSION}; \
    $CURL_RETRY https://raw.githubusercontent.com/anchore/grype/main/install.sh | sh -s -- -b /usr/local/bin v${GRYPE_VERSION}; \
    $CURL_RETRY https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b /usr/local/bin v${SYFT_VERSION}; \
    $CURL_RETRY "https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/cosign-linux-amd64" -o /usr/local/bin/cosign; \
    chmod +x /usr/local/bin/cosign; \
    $CURL_RETRY "https://releases.hashicorp.com/terraform-ls/${TERRAFORM_LS_VERSION}/terraform-ls_${TERRAFORM_LS_VERSION}_linux_amd64.zip" -o /tmp/terraform-ls.zip; \
    unzip /tmp/terraform-ls.zip -d /tmp; \
    mv /tmp/terraform-ls /usr/local/bin/terraform-ls; \
    chmod +x /usr/local/bin/terraform-ls; \
    rm -f /tmp/terraform-ls.zip


USER node
CMD ["sleep", "infinity"]
